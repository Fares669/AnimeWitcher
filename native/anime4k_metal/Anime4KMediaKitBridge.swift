// Copyright 2026 AnimeWitcher contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import CoreVideo
import Foundation
import Metal

/// Bounds complete Anime4K publications, not merely the compute command buffer.
///
/// `Anime4KMetalRuntime` can release a compute slot as soon as its processed
/// output is ready, while the bridge may still be blitting that output into
/// media_kit's destination IOSurface. Keeping a second per-player ledger here
/// prevents those final publishes from allowing the runtime output pool to grow
/// without bound when the copy/presentation side is slower than compute.
struct Anime4KMetalPublicationLedger {
    private let capacity: Int
    private var inflightByRuntime: [UInt: Int] = [:]

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func reserve(for runtimeKey: UInt) -> Bool {
        let current = inflightByRuntime[runtimeKey, default: 0]
        guard current < capacity else { return false }
        inflightByRuntime[runtimeKey] = current + 1
        return true
    }

    mutating func release(for runtimeKey: UInt) {
        let current = inflightByRuntime[runtimeKey, default: 0]
        guard current > 0 else { return }
        if current == 1 {
            inflightByRuntime.removeValue(forKey: runtimeKey)
        } else {
            inflightByRuntime[runtimeKey] = current - 1
        }
    }

    func inflightCount(for runtimeKey: UInt) -> Int {
        inflightByRuntime[runtimeKey, default: 0]
    }
}

/// Connects media_kit's Apple TextureHW render path to the per-player Anime4K
/// Metal runtime. AKP-12 adds the Dart-facing configuration transport; until a
/// handle is configured this bridge deliberately returns `false` and media_kit
/// publishes the original mpv frame unchanged.
final class Anime4KMediaKitBridge {
    static let shared = Anime4KMediaKitBridge()

    private let lock = NSLock()
    private let device: MTLDevice?
    private let copyQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    private var runtimes: [UInt: Anime4KMetalRuntime] = [:]
    private var publicationLedger = Anime4KMetalPublicationLedger(capacity: 3)

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.copyQueue = device?.makeCommandQueue()

        if let device = device {
            var cache: CVMetalTextureCache?
            let result = CVMetalTextureCacheCreate(
                kCFAllocatorDefault,
                nil,
                device,
                nil,
                &cache
            )
            if result == kCVReturnSuccess {
                textureCache = cache
            }
        }
    }

    func configure(
        handle: OpaquePointer,
        configuration: Anime4KMetalRuntimeConfiguration
    ) throws {
        guard let device = device else {
            throw Anime4KMetalRuntimeError.commandQueueUnavailable
        }
        let key = handleKey(handle)
        let runtime: Anime4KMetalRuntime
        if let current = lock.anime4kWithLock({ runtimes[key] }) {
            runtime = current
        } else {
            runtime = try Anime4KMetalRuntime(device: device, maxInflightFrames: 3)
        }
        do {
            try runtime.configure(configuration)
            lock.anime4kWithLock { runtimes[key] = runtime }
        } catch {
            runtime.disable()
            lock.anime4kWithLock { _ = runtimes.removeValue(forKey: key) }
            throw error
        }
    }

    func disable(handle: OpaquePointer) {
        disable(key: handleKey(handle))
    }

    func telemetry(handle: OpaquePointer) -> Anime4KMetalRuntimeTelemetry? {
        let key = handleKey(handle)
        let runtime = lock.anime4kWithLock { runtimes[key] }
        return runtime?.telemetry
    }

    /// Returns true only when this bridge owns asynchronous frame publication.
    /// A false result means TextureHW must immediately publish the untouched
    /// mpv buffer itself.
    func process(
        handle: OpaquePointer,
        pixelBuffer: CVPixelBuffer,
        completion: @escaping () -> Void
    ) -> Bool {
        let key = handleKey(handle)
        guard let runtime = lock.anime4kWithLock({ () -> Anime4KMetalRuntime? in
            guard let runtime = runtimes[key] else { return nil }
            guard publicationLedger.reserve(for: key) else {
                runtime.recordLateOrDroppedFrame()
                return nil
            }
            return runtime
        }) else {
            // Saturation is deliberately non-blocking: TextureHW publishes the
            // untouched frame rather than waiting for a Metal/output slot.
            return false
        }

        // The reservation spans runtime compute plus the final bridge blit into
        // media_kit's owned destination. media_kit's existing three-buffer
        // manager then owns that destination until Flutter consumes it.
        let publicationCompletion: () -> Void = { [self] in
            releasePublication(for: key)
            completion()
        }

        // Anime4KMetalRuntime may call completion synchronously if setup fails
        // after reserving a slot. Gate the callback until we know whether the
        // submission was actually accepted, avoiding double publication when
        // TextureHW takes its immediate fallback path.
        let decisionLock = NSLock()
        var decisionKnown = false
        var accepted = false
        var earlyResult: CVPixelBuffer?

        let submission = runtime.process(pixelBuffer: pixelBuffer) { [self] processed in
            var deliver: CVPixelBuffer?
            decisionLock.lock()
            if decisionKnown {
                if accepted { deliver = processed }
            } else {
                earlyResult = processed
            }
            decisionLock.unlock()

            if let deliver = deliver {
                copyProcessedFrame(
                    deliver,
                    into: pixelBuffer,
                    runtimeKey: key,
                    completion: publicationCompletion
                )
            }
        }

        decisionLock.lock()
        decisionKnown = true
        accepted = submission == .submitted
        let pending = accepted ? earlyResult : nil
        decisionLock.unlock()

        guard accepted else {
            releasePublication(for: key)
            return false
        }

        if let pending = pending {
            copyProcessedFrame(
                pending,
                into: pixelBuffer,
                runtimeKey: key,
                completion: publicationCompletion
            )
        }
        return true
    }

    private func copyProcessedFrame(
        _ processed: CVPixelBuffer,
        into destination: CVPixelBuffer,
        runtimeKey: UInt,
        completion: @escaping () -> Void
    ) {
        if processed === destination {
            completion()
            return
        }

        let width = CVPixelBufferGetWidth(destination)
        let height = CVPixelBufferGetHeight(destination)
        guard width == CVPixelBufferGetWidth(processed),
              height == CVPixelBufferGetHeight(processed),
              let textureCache = textureCache,
              let copyQueue = copyQueue else {
            disable(key: runtimeKey)
            completion()
            return
        }

        var sourceRef: CVMetalTexture?
        var destinationRef: CVMetalTexture?
        let sourceResult = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            processed,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &sourceRef
        )
        let destinationResult = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            destination,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &destinationRef
        )
        guard sourceResult == kCVReturnSuccess,
              destinationResult == kCVReturnSuccess,
              let sourceRef = sourceRef,
              let destinationRef = destinationRef,
              let source = CVMetalTextureGetTexture(sourceRef),
              let target = CVMetalTextureGetTexture(destinationRef),
              let commandBuffer = copyQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder() else {
            disable(key: runtimeKey)
            completion()
            return
        }

        encoder.label = "Anime4K media_kit final publish"
        encoder.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: target,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [weak self, processed, destination, sourceRef, destinationRef] buffer in
            _ = processed
            _ = destination
            _ = sourceRef
            _ = destinationRef
            if buffer.status == .error {
                self?.disable(key: runtimeKey)
            }
            completion()
        }
        commandBuffer.commit()
    }

    private func releasePublication(for key: UInt) {
        lock.anime4kWithLock { publicationLedger.release(for: key) }
    }

    private func disable(key: UInt) {
        let runtime = lock.anime4kWithLock { runtimes.removeValue(forKey: key) }
        runtime?.disable()
    }

    private func handleKey(_ handle: OpaquePointer) -> UInt {
        UInt(bitPattern: Int(bitPattern: handle))
    }
}

private extension NSLock {
    func anime4kWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
