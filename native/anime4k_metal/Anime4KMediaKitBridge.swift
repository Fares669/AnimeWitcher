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
/// The reservation spans the complete asynchronous Metal publication into
/// media_kit's destination IOSurface. It keeps per-player frame ownership bounded
/// while Flutter catches up with the texture registry.
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
    private var runtimes: [UInt: Anime4KMetalRuntime] = [:]
    private var configurations: [UInt: Anime4KMetalRuntimeConfiguration] = [:]
    private var bypassedRuntimeKeys: Set<UInt> = []
    private var publicationLedger = Anime4KMetalPublicationLedger(capacity: 3)

    private init() {
        self.device = MTLCreateSystemDefaultDevice()
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
            lock.anime4kWithLock {
                runtimes[key] = runtime
                configurations[key] = configuration
            }
        } catch {
            runtime.disable()
            lock.anime4kWithLock {
                _ = runtimes.removeValue(forKey: key)
                _ = configurations.removeValue(forKey: key)
                bypassedRuntimeKeys.remove(key)
            }
            throw error
        }
    }

    func disable(handle: OpaquePointer) {
        disable(key: handleKey(handle))
    }

    /// Returns the live runtime state rather than a configure-time cached Dart
    /// status. C API polling uses this to detect asynchronous command-buffer or
    /// final-publication failures and restore the mpv fallback immediately.
    func runtimeStatus(handle: OpaquePointer) -> Anime4KMetalRuntimeStatus? {
        let key = handleKey(handle)
        let runtime = lock.anime4kWithLock { runtimes[key] }
        return runtime?.status
    }

    /// Returns the configuration the native render path is actually using.
    /// Unlike the initial Dart estimate, output dimensions are retargeted to
    /// media_kit's live CVPixelBuffer size before a frame is processed.
    func activeConfiguration(
        handle: OpaquePointer
    ) -> Anime4KMetalRuntimeConfiguration? {
        let key = handleKey(handle)
        return lock.anime4kWithLock { configurations[key] }
    }

    /// Temporarily bypasses Anime4K frame processing while preserving the
    /// configured runtime and telemetry. Eco uses this for critical thermal
    /// protection so ProcessInfo telemetry can observe recovery and resume the
    /// same per-player runtime without a decode/render-path restart.
    @discardableResult
    func setBypass(handle: OpaquePointer, bypass: Bool) -> Bool {
        let key = handleKey(handle)
        return lock.anime4kWithLock {
            guard runtimes[key] != nil else { return false }
            if bypass {
                bypassedRuntimeKeys.insert(key)
            } else {
                bypassedRuntimeKeys.remove(key)
            }
            return true
        }
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
        guard let prepared = lock.anime4kWithLock({ () -> (
            runtime: Anime4KMetalRuntime,
            configuration: Anime4KMetalRuntimeConfiguration
        )? in
            guard let runtime = runtimes[key],
                  let configuration = configurations[key],
                  !bypassedRuntimeKeys.contains(key) else {
                return nil
            }
            return (runtime, configuration)
        }) else {
            return false
        }

        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard frameWidth > 0, frameHeight > 0 else { return false }

        if prepared.configuration.outputWidth != frameWidth ||
            prepared.configuration.outputHeight != frameHeight {
            let retargeted = Anime4KMetalRuntimeConfiguration(
                shaderPaths: prepared.configuration.shaderPaths,
                pipelineHash: prepared.configuration.pipelineHash,
                sourceWidth: prepared.configuration.sourceWidth,
                sourceHeight: prepared.configuration.sourceHeight,
                outputWidth: frameWidth,
                outputHeight: frameHeight,
                precision: prepared.configuration.precision,
                upscaleStrategy: prepared.configuration.upscaleStrategy
            )
            do {
                // Resize/reconfigure only when the real media_kit surface
                // changes. Identical frames keep the existing output pool and
                // intermediate texture working set untouched.
                try prepared.runtime.configure(retargeted)
                let stillCurrent = lock.anime4kWithLock { () -> Bool in
                    guard let current = runtimes[key], current === prepared.runtime else {
                        return false
                    }
                    configurations[key] = retargeted
                    return true
                }
                guard stillCurrent else { return false }
            } catch {
                disable(key: key)
                return false
            }
        }

        guard let runtime = lock.anime4kWithLock({ () -> Anime4KMetalRuntime? in
            guard let runtime = runtimes[key], runtime === prepared.runtime else {
                return nil
            }
            // Intentional Eco bypass is not a late/dropped frame. It is a
            // deliberate pass-through while thermal pressure recovers.
            if bypassedRuntimeKeys.contains(key) { return nil }
            guard publicationLedger.reserve(for: key) else {
                runtime.recordLateOrDroppedFrame()
                return nil
            }
            return runtime
        }) else {
            // Saturation and intentional Eco bypass are both non-blocking:
            // TextureHW immediately publishes the untouched mpv frame.
            return false
        }

        // The runtime final-writes directly into media_kit's owned destination.
        // The reservation remains held until that command buffer completes.
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
    var completedBeforeDecision = false

    let submission = runtime.process(
        pixelBuffer: pixelBuffer,
        destinationPixelBuffer: pixelBuffer
    ) { _ in
        var shouldPublish = false
        decisionLock.lock()
        if decisionKnown {
            shouldPublish = accepted
        } else {
            completedBeforeDecision = true
        }
        decisionLock.unlock()

        if shouldPublish {
            publicationCompletion()
        }
    }

    decisionLock.lock()
    decisionKnown = true
    accepted = submission == .submitted
    let publishEarlyCompletion = accepted && completedBeforeDecision
    decisionLock.unlock()

    guard accepted else {
        releasePublication(for: key)
        return false
    }

    if publishEarlyCompletion {
        publicationCompletion()
    }
    return true
}

    private func releasePublication(for key: UInt) {
        lock.anime4kWithLock { publicationLedger.release(for: key) }
    }

    private func disable(key: UInt) {
        let runtime = lock.anime4kWithLock { () -> Anime4KMetalRuntime? in
            bypassedRuntimeKeys.remove(key)
            _ = configurations.removeValue(forKey: key)
            return runtimes.removeValue(forKey: key)
        }
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
