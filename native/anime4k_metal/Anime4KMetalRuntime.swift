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

enum Anime4KAppleUpscaleStrategy: String, Equatable {
    case fullAnime4K
    case restoreDenoiseMetalFXSpatial
}

struct Anime4KMetalRuntimeConfiguration: Equatable {
    let shaderPaths: [String]
    let pipelineHash: String
    let sourceWidth: Int
    let sourceHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let precision: Anime4KMetalPrecisionPolicy
    let upscaleStrategy: Anime4KAppleUpscaleStrategy

    init(
        shaderPaths: [String],
        pipelineHash: String,
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        precision: Anime4KMetalPrecisionPolicy = .mixedFP16,
        upscaleStrategy: Anime4KAppleUpscaleStrategy = .fullAnime4K
    ) {
        self.shaderPaths = shaderPaths
        self.pipelineHash = pipelineHash
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.precision = precision
        self.upscaleStrategy = upscaleStrategy
    }
}

enum Anime4KMetalRuntimeStatus: Equatable {
    case disabled
    case ready
    case failed(String)
}

enum Anime4KMetalRuntimeSubmission: Equatable {
    case submitted
    case bypassed
    case busy
}

struct Anime4KMetalSlotLease: Equatable {
    let slot: Int
    let epoch: UInt64
}

/// Keeps the finite GPU working set bounded across configure/disable cycles.
/// A slot owned by an older command buffer never becomes reusable merely
/// because a new pipeline configuration was installed.
struct Anime4KMetalSlotLedger {
    private let capacity: Int
    private var availableSlots: [Int]
    private var inflightEpochBySlot: [Int: UInt64] = [:]
    private(set) var epoch: UInt64 = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.availableSlots = Array(0..<capacity)
    }

    var availableCount: Int { availableSlots.count }
    var inflightCount: Int { inflightEpochBySlot.count }

    mutating func reserve() -> Anime4KMetalSlotLease? {
        guard !availableSlots.isEmpty else { return nil }
        let slot = availableSlots.removeFirst()
        inflightEpochBySlot[slot] = epoch
        return Anime4KMetalSlotLease(slot: slot, epoch: epoch)
    }

    mutating func advanceEpoch() {
        epoch &+= 1
        availableSlots = (0..<capacity).filter {
            inflightEpochBySlot[$0] == nil
        }
    }

    mutating func release(_ lease: Anime4KMetalSlotLease) {
        guard inflightEpochBySlot[lease.slot] == lease.epoch else {
            return
        }
        inflightEpochBySlot.removeValue(forKey: lease.slot)
        guard !availableSlots.contains(lease.slot) else { return }
        availableSlots.append(lease.slot)
        availableSlots.sort()
    }
}

enum Anime4KMetalRuntimeError: Error, LocalizedError {
    case invalidDimensions
    case commandQueueUnavailable
    case textureCacheCreation(CVReturn)
    case shaderRead(String)
    case shaderCompile(String)
    case pipelineFunction(String)
    case outputPoolCreation(CVReturn)
    case outputBufferCreation(CVReturn)
    case inputTextureCreation(CVReturn)
    case outputTextureCreation(CVReturn)
    case missingTexture(String)
    case commandBufferUnavailable
    case encoderUnavailable(String)
    case invalidWhen(String)
    case metalFXUnavailable
    case metalFXPipeline(String)

    var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "Anime4K Metal runtime received invalid dimensions"
        case .commandQueueUnavailable:
            return "Anime4K Metal command queue is unavailable"
        case .textureCacheCreation(let value):
            return "Anime4K Metal texture-cache creation failed: \(value)"
        case .shaderRead(let path):
            return "Anime4K Metal shader could not be read: \(path)"
        case .shaderCompile(let detail):
            return "Anime4K Metal shader compilation failed: \(detail)"
        case .pipelineFunction(let name):
            return "Anime4K Metal kernel function is missing: \(name)"
        case .outputPoolCreation(let value):
            return "Anime4K Metal output pool creation failed: \(value)"
        case .outputBufferCreation(let value):
            return "Anime4K Metal output buffer creation failed: \(value)"
        case .inputTextureCreation(let value):
            return "Anime4K Metal input texture creation failed: \(value)"
        case .outputTextureCreation(let value):
            return "Anime4K Metal output texture creation failed: \(value)"
        case .missingTexture(let name):
            return "Anime4K Metal input texture is missing: \(name)"
        case .commandBufferUnavailable:
            return "Anime4K Metal command buffer is unavailable"
        case .encoderUnavailable(let name):
            return "Anime4K Metal encoder is unavailable for: \(name)"
        case .invalidWhen(let expression):
            return "Anime4K Metal WHEN expression is invalid: \(expression)"
        case .metalFXUnavailable:
            return "Anime4K MetalFX spatial scaler is unavailable"
        case .metalFXPipeline(let detail):
            return "Anime4K MetalFX spatial scaler failed: \(detail)"
        }
    }
}

final class Anime4KMetalRuntime {
    private struct CompiledPass {
        let shader: Anime4KMetalShader
        let pipeline: MTLComputePipelineState
    }

    /// A shader file is one mpv stage. Its private SAVE textures are local to
    /// the file and its final output becomes MAIN for the next file. Keeping
    /// this boundary avoids accidentally flattening A+A/B+B into one mpv file.
    private struct CompiledGroup {
        let passes: [CompiledPass]
    }

    private struct TextureKey: Hashable {
        let name: String
        let width: Int
        let height: Int
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let nearestSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState
    private let finalCopyPipeline: MTLComputePipelineState
    private let metalFXScaler: Anime4KMetalFXScaler
    private let maxInflightFrames: Int
    private let stateLock = NSLock()

    private var compiledGroups: [CompiledGroup] = []
    private var activeConfiguration: Anime4KMetalRuntimeConfiguration?
    private var outputPool: CVPixelBufferPool?
    private var slotLedger: Anime4KMetalSlotLedger
    private var slotTextures: [[TextureKey: MTLTexture]]
    private var telemetryAccumulator = Anime4KMetalTelemetryAccumulator()
    private var _status: Anime4KMetalRuntimeStatus = .disabled
    private var _compileGeneration = 0

    var status: Anime4KMetalRuntimeStatus {
        stateLock.withLock { _status }
    }

    var compileGeneration: Int {
        stateLock.withLock { _compileGeneration }
    }

    var telemetry: Anime4KMetalRuntimeTelemetry {
        stateLock.withLock { telemetryAccumulator.snapshot }
    }

    func recordLateOrDroppedFrame() {
        stateLock.withLock {
            telemetryAccumulator.recordLateOrDroppedFrame()
        }
    }

    init(device: MTLDevice, maxInflightFrames: Int = 3) throws {
        guard maxInflightFrames > 0 else {
            throw Anime4KMetalRuntimeError.invalidDimensions
        }
        guard let queue = device.makeCommandQueue() else {
            throw Anime4KMetalRuntimeError.commandQueueUnavailable
        }

        var cache: CVMetalTextureCache?
        let cacheResult = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard cacheResult == kCVReturnSuccess, let cache else {
            throw Anime4KMetalRuntimeError.textureCacheCreation(cacheResult)
        }

        let nearestDescriptor = MTLSamplerDescriptor()
        nearestDescriptor.minFilter = .nearest
        nearestDescriptor.magFilter = .nearest
        nearestDescriptor.sAddressMode = .clampToEdge
        nearestDescriptor.tAddressMode = .clampToEdge
        guard let nearest = device.makeSamplerState(descriptor: nearestDescriptor) else {
            throw Anime4KMetalRuntimeError.shaderCompile("nearest sampler")
        }

        let linearDescriptor = MTLSamplerDescriptor()
        linearDescriptor.minFilter = .linear
        linearDescriptor.magFilter = .linear
        linearDescriptor.sAddressMode = .clampToEdge
        linearDescriptor.tAddressMode = .clampToEdge
        guard let linear = device.makeSamplerState(descriptor: linearDescriptor) else {
            throw Anime4KMetalRuntimeError.shaderCompile("linear sampler")
        }

        let copySource = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void anime4kFinalCopy(
            texture2d<float, access::sample> input [[texture(0)]],
            texture2d<float, access::write> output [[texture(1)]],
            uint2 gid [[thread_position_in_grid]],
            sampler linearSampler [[sampler(0)]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            float2 size = float2(output.get_width(), output.get_height());
            float2 uv = (float2(gid) + 0.5) / max(size, float2(1.0));
            output.write(input.sample(linearSampler, uv), gid);
        }
        """
        let copyLibrary: MTLLibrary
        do {
            copyLibrary = try device.makeLibrary(source: copySource, options: nil)
        } catch {
            throw Anime4KMetalRuntimeError.shaderCompile(String(describing: error))
        }
        guard let copyFunction = copyLibrary.makeFunction(name: "anime4kFinalCopy") else {
            throw Anime4KMetalRuntimeError.pipelineFunction("anime4kFinalCopy")
        }
        let copyPipeline: MTLComputePipelineState
        do {
            copyPipeline = try device.makeComputePipelineState(function: copyFunction)
        } catch {
            throw Anime4KMetalRuntimeError.shaderCompile(String(describing: error))
        }

        self.device = device
        self.commandQueue = queue
        self.textureCache = cache
        self.nearestSampler = nearest
        self.linearSampler = linear
        self.finalCopyPipeline = copyPipeline
        self.metalFXScaler = Anime4KMetalFXScaler(device: device)
        self.maxInflightFrames = maxInflightFrames
        self.slotLedger = Anime4KMetalSlotLedger(capacity: maxInflightFrames)
        self.slotTextures = Array(repeating: [:], count: maxInflightFrames)
    }

    func configure(_ configuration: Anime4KMetalRuntimeConfiguration) throws {
        guard configuration.sourceWidth > 0,
              configuration.sourceHeight > 0,
              configuration.outputWidth > 0,
              configuration.outputHeight > 0,
              !configuration.shaderPaths.isEmpty else {
            return try failAndThrow(.invalidDimensions)
        }

        if stateLock.withLock({ activeConfiguration == configuration && _status == .ready }) {
            return
        }

        do {
            let shaderPaths: [String]
            switch configuration.upscaleStrategy {
            case .fullAnime4K:
                shaderPaths = configuration.shaderPaths
            case .restoreDenoiseMetalFXSpatial:
                guard metalFXScaler.isAvailable else {
                    throw Anime4KMetalRuntimeError.metalFXUnavailable
                }
                shaderPaths = experimentalShaderPaths(configuration.shaderPaths)
                guard !shaderPaths.isEmpty else {
                    throw Anime4KMetalRuntimeError.metalFXPipeline(
                        "no restore/denoise stages remain after filtering"
                    )
                }
            }

            var nextGroups: [CompiledGroup] = []
            nextGroups.reserveCapacity(shaderPaths.count)

            for path in shaderPaths {
                let url = URL(fileURLWithPath: path)
                guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                    throw Anime4KMetalRuntimeError.shaderRead(path)
                }
                let shaders = try Anime4KMetalShader.parse(source)
                var compiled: [CompiledPass] = []
                compiled.reserveCapacity(shaders.count)
                for shader in shaders {
                    let library: MTLLibrary
                    do {
                        library = try device.makeLibrary(
                            source: shader.metalSource(precision: configuration.precision),
                            options: nil
                        )
                    } catch {
                        throw Anime4KMetalRuntimeError.shaderCompile(
                            "\(url.lastPathComponent)/\(shader.name): \(error)"
                        )
                    }
                    guard let function = library.makeFunction(name: shader.functionName) else {
                        throw Anime4KMetalRuntimeError.pipelineFunction(shader.functionName)
                    }
                    let pipeline = try device.makeComputePipelineState(function: function)
                    compiled.append(CompiledPass(shader: shader, pipeline: pipeline))
                }
                nextGroups.append(CompiledGroup(passes: compiled))
            }

            let pool = try makeOutputPool(
                width: configuration.outputWidth,
                height: configuration.outputHeight
            )

            stateLock.withLock {
                compiledGroups = nextGroups
                outputPool = pool
                activeConfiguration = configuration
                slotTextures = Array(repeating: [:], count: maxInflightFrames)
                slotLedger.advanceEpoch()
                _compileGeneration += 1
                _status = .ready
            }
        } catch {
            stateLock.withLock {
                compiledGroups = []
                outputPool = nil
                activeConfiguration = nil
                slotTextures = Array(repeating: [:], count: maxInflightFrames)
                slotLedger.advanceEpoch()
                _status = .failed(String(describing: error))
            }
            throw error
        }
    }

    func disable() {
        stateLock.withLock {
            compiledGroups = []
            outputPool = nil
            activeConfiguration = nil
            slotTextures = Array(repeating: [:], count: maxInflightFrames)
            slotLedger.advanceEpoch()
            _status = .disabled
        }
    }

    @discardableResult
    func process(
        pixelBuffer inputBuffer: CVPixelBuffer,
        destinationPixelBuffer: CVPixelBuffer? = nil,
        completion: @escaping (CVPixelBuffer) -> Void
    ) -> Anime4KMetalRuntimeSubmission {
        var busy = false
        let snapshot: (
            lease: Anime4KMetalSlotLease,
            groups: [CompiledGroup],
            configuration: Anime4KMetalRuntimeConfiguration,
            pool: CVPixelBufferPool
        )? = stateLock.withLock {
            guard _status == .ready,
                  let configuration = activeConfiguration,
                  let pool = outputPool else {
                return nil
            }
            guard let lease = slotLedger.reserve() else {
                telemetryAccumulator.recordLateOrDroppedFrame()
                busy = true
                return nil
            }
            return (lease, compiledGroups, configuration, pool)
        }

        guard let snapshot else {
            return busy ? .busy : .bypassed
        }

        do {
    let outputBuffer: CVPixelBuffer
    if let destinationPixelBuffer {
        guard CVPixelBufferGetWidth(destinationPixelBuffer) == snapshot.configuration.outputWidth,
              CVPixelBufferGetHeight(destinationPixelBuffer) == snapshot.configuration.outputHeight else {
            throw Anime4KMetalRuntimeError.invalidDimensions
        }
        outputBuffer = destinationPixelBuffer
    } else {
        var pooledOutputBuffer: CVPixelBuffer?
        let outputResult = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            snapshot.pool,
            &pooledOutputBuffer
        )
        guard outputResult == kCVReturnSuccess, let pooledOutputBuffer else {
            throw Anime4KMetalRuntimeError.outputBufferCreation(outputResult)
        }
        outputBuffer = pooledOutputBuffer
    }

            let inputTextureRef = try makeCVTexture(
                pixelBuffer: inputBuffer,
                width: CVPixelBufferGetWidth(inputBuffer),
                height: CVPixelBufferGetHeight(inputBuffer),
                error: Anime4KMetalRuntimeError.inputTextureCreation
            )
            let outputTextureRef = try makeCVTexture(
                pixelBuffer: outputBuffer,
                width: snapshot.configuration.outputWidth,
                height: snapshot.configuration.outputHeight,
                error: Anime4KMetalRuntimeError.outputTextureCreation
            )
            guard let nativeTexture = CVMetalTextureGetTexture(inputTextureRef),
                  let destinationTexture = CVMetalTextureGetTexture(outputTextureRef) else {
                throw Anime4KMetalRuntimeError.missingTexture("CVMetalTexture")
            }
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw Anime4KMetalRuntimeError.commandBufferUnavailable
            }

            var currentMain = nativeTexture
            for group in snapshot.groups {
                currentMain = try encode(
                    group: group,
                    main: currentMain,
                    native: nativeTexture,
                    outputWidth: snapshot.configuration.outputWidth,
                    outputHeight: snapshot.configuration.outputHeight,
                    slot: snapshot.lease.slot,
                    commandBuffer: commandBuffer
                )
            }
            if snapshot.configuration.upscaleStrategy == .restoreDenoiseMetalFXSpatial &&
                (currentMain.width < snapshot.configuration.outputWidth ||
                 currentMain.height < snapshot.configuration.outputHeight) {
                do {
                    currentMain = try metalFXScaler.encode(
                        input: currentMain,
                        outputWidth: snapshot.configuration.outputWidth,
                        outputHeight: snapshot.configuration.outputHeight,
                        slot: snapshot.lease.slot,
                        commandBuffer: commandBuffer
                    )
                } catch {
                    throw Anime4KMetalRuntimeError.metalFXPipeline(
                        String(describing: error)
                    )
                }
            }
            try encodeFinalCopy(
                input: currentMain,
                output: destinationTexture,
                commandBuffer: commandBuffer
            )

            let submittedAt = ProcessInfo.processInfo.systemUptime

            // The completion intentionally retains `self`, the source/output
            // CVPixelBuffers and their CVMetalTexture wrappers until GPU work
            // has completed. The runtime may be removed from the bridge while
            // this command is in flight; frame publication must still finish.
            commandBuffer.addCompletedHandler { [inputBuffer, outputBuffer, inputTextureRef, outputTextureRef] buffer in
                _ = inputBuffer
                _ = inputTextureRef
                _ = outputTextureRef

                let fallbackMilliseconds = max(
                    0,
                    (ProcessInfo.processInfo.systemUptime - submittedAt) * 1000
                )
                let gpuMilliseconds: Double? = {
                    let start = buffer.gpuStartTime
                    let end = buffer.gpuEndTime
                    guard start.isFinite,
                          end.isFinite,
                          end >= start,
                          end > 0 else {
                        return nil
                    }
                    return (end - start) * 1000
                }()

                self.stateLock.withLock {
                    let belongsToCurrentEpoch =
                        snapshot.lease.epoch == self.slotLedger.epoch
                    self.slotLedger.release(snapshot.lease)
                    if buffer.status == .completed {
                        self.telemetryAccumulator.recordCompletedFrame(
                            milliseconds: gpuMilliseconds ?? fallbackMilliseconds
                        )
                    } else {
                        self.telemetryAccumulator.recordLateOrDroppedFrame()
                    }
                    if belongsToCurrentEpoch && buffer.status == .error {
                        self._status = .failed(
                            buffer.error.map(String.init(describing:)) ??
                                "Metal command failed"
                        )
                    }
                }
                completion(buffer.status == .completed ? outputBuffer : inputBuffer)
            }
            commandBuffer.commit()
            return .submitted
        } catch {
            stateLock.withLock {
                let belongsToCurrentEpoch =
                    snapshot.lease.epoch == slotLedger.epoch
                slotLedger.release(snapshot.lease)
                telemetryAccumulator.recordLateOrDroppedFrame()
                if belongsToCurrentEpoch {
                    _status = .failed(String(describing: error))
                }
            }
            completion(inputBuffer)
            return .bypassed
        }
    }

    private func experimentalShaderPaths(_ shaderPaths: [String]) -> [String] {
        // The benchmark route keeps Anime4K restore/denoise work but removes
        // Anime4K's own resize stages so MetalFX is the only spatial upscaler.
        // Keep the concrete v4 names here as a source-level regression guard.
        let knownUpscaleStages = [
            "Anime4K_Upscale_CNN_x2_",
            "Anime4K_Upscale_Denoise_CNN_x2_",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
        ]
        let restoreStagePrefix = "Anime4K_Restore_CNN_"

        return shaderPaths.filter { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            if name.contains(restoreStagePrefix) { return true }
            if knownUpscaleStages.contains(where: { name.contains($0) }) {
                return false
            }
            return !name.contains("Anime4K_Upscale_") &&
                !name.contains("Anime4K_AutoDownscalePre_")
        }
    }

    private func encode(
        group: CompiledGroup,
        main: MTLTexture,
        native: MTLTexture,
        outputWidth: Int,
        outputHeight: Int,
        slot: Int,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        var textures: [String: MTLTexture] = [
            "MAIN": main,
            "NATIVE": native,
        ]
        var sizes: [String: (Int, Int)] = [
            "MAIN": (main.width, main.height),
            "NATIVE": (native.width, native.height),
            "OUTPUT": (outputWidth, outputHeight),
        ]
        var lastOutput: MTLTexture = main

        for compiled in group.passes {
            let shader = compiled.shader
            if let when = shader.when,
               try !evaluateWhen(when, sizes: sizes) {
                continue
            }

            let hookName = shader.hook ?? "MAIN"
            guard let hookTexture = textures[hookName] else {
                throw Anime4KMetalRuntimeError.missingTexture(hookName)
            }
            sizes["HOOKED"] = (hookTexture.width, hookTexture.height)

            var width = hookTexture.width
            var height = hookTexture.height
            if let dimension = shader.width {
                guard let base = sizes[dimension.0] else {
                    throw Anime4KMetalRuntimeError.missingTexture(dimension.0)
                }
                width = max(1, Int((Float(base.0) * dimension.1).rounded()))
            }
            if let dimension = shader.height {
                guard let base = sizes[dimension.0] else {
                    throw Anime4KMetalRuntimeError.missingTexture(dimension.0)
                }
                height = max(1, Int((Float(base.1) * dimension.1).rounded()))
            }

            let outputName = shader.outputTextureName
            let outputTexture = reusableTexture(
                slot: slot,
                name: outputName,
                width: width,
                height: height
            )
            textures[outputName] = outputTexture
            if let save = shader.save, save != "MAIN" {
                sizes[save] = (width, height)
            }

            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw Anime4KMetalRuntimeError.encoderUnavailable(shader.functionName)
            }
            encoder.label = "Anime4K \(shader.name)"
            encoder.setComputePipelineState(compiled.pipeline)
            encoder.setSamplerState(
                width < hookTexture.width || height < hookTexture.height
                    ? linearSampler
                    : nearestSampler,
                index: 0
            )

            for (index, requestedName) in shader.inputTextureNames.enumerated() {
                let resolvedName = requestedName == "HOOKED" ? hookName : requestedName
                guard let texture = textures[resolvedName] else {
                    encoder.endEncoding()
                    throw Anime4KMetalRuntimeError.missingTexture(resolvedName)
                }
                encoder.setTexture(texture, index: index)
            }
            encoder.setTexture(outputTexture, index: shader.inputTextureNames.count)
            dispatch(encoder: encoder, pipeline: compiled.pipeline, texture: outputTexture)
            encoder.endEncoding()
            lastOutput = outputTexture
        }
        return lastOutput
    }

    private func encodeFinalCopy(
        input: MTLTexture,
        output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw Anime4KMetalRuntimeError.encoderUnavailable("anime4kFinalCopy")
        }
        encoder.label = "Anime4K final copy"
        encoder.setComputePipelineState(finalCopyPipeline)
        encoder.setSamplerState(linearSampler, index: 0)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        dispatch(encoder: encoder, pipeline: finalCopyPipeline, texture: output)
        encoder.endEncoding()
    }

    private func dispatch(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        texture: MTLTexture
    ) {
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        let threads = MTLSize(width: width, height: height, depth: 1)
        let groups = MTLSize(
            width: (texture.width + width - 1) / width,
            height: (texture.height + height - 1) / height,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
    }

    private func reusableTexture(
        slot: Int,
        name: String,
        width: Int,
        height: Int
    ) -> MTLTexture {
        let key = TextureKey(name: name, width: width, height: height)
        if let existing = stateLock.withLock({ slotTextures[slot][key] }) {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        stateLock.withLock {
            slotTextures[slot][key] = texture
        }
        return texture
    }

    private func makeOutputPool(width: Int, height: Int) throws -> CVPixelBufferPool {
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: maxInflightFrames,
        ]
        var pool: CVPixelBufferPool?
        let result = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelAttributes as CFDictionary,
            &pool
        )
        guard result == kCVReturnSuccess, let pool else {
            throw Anime4KMetalRuntimeError.outputPoolCreation(result)
        }
        return pool
    }

    private func makeCVTexture(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        error: (CVReturn) -> Anime4KMetalRuntimeError
    ) throws -> CVMetalTexture {
        var reference: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &reference
        )
        guard result == kCVReturnSuccess, let reference else {
            throw error(result)
        }
        return reference
    }

    private func evaluateWhen(
        _ expression: String,
        sizes: [String: (Int, Int)]
    ) throws -> Bool {
        let tokens = expression.split(whereSeparator: { $0.isWhitespace })
        var stack: [Double] = []

        for tokenValue in tokens {
            let token = String(tokenValue)
            if token == "WHEN" { continue }
            if let dot = token.lastIndex(of: ".") {
                let name = String(token[..<dot])
                let component = String(token[token.index(after: dot)...])
                if let size = sizes[name] {
                    if component == "w" { stack.append(Double(size.0)); continue }
                    if component == "h" { stack.append(Double(size.1)); continue }
                }
            }
            if ["+", "-", "*", "/", "<", ">"].contains(token) {
                guard stack.count >= 2 else {
                    throw Anime4KMetalRuntimeError.invalidWhen(expression)
                }
                let rhs = stack.removeLast()
                let lhs = stack.removeLast()
                switch token {
                case "+": stack.append(lhs + rhs)
                case "-": stack.append(lhs - rhs)
                case "*": stack.append(lhs * rhs)
                case "/": stack.append(lhs / rhs)
                case "<": stack.append(lhs < rhs ? 1 : 0)
                case ">": stack.append(lhs > rhs ? 1 : 0)
                default: break
                }
                continue
            }
            guard let value = Double(token) else {
                throw Anime4KMetalRuntimeError.invalidWhen(expression)
            }
            stack.append(value)
        }
        guard stack.count == 1 else {
            throw Anime4KMetalRuntimeError.invalidWhen(expression)
        }
        return stack[0] != 0
    }

    private func failAndThrow<T>(_ error: Anime4KMetalRuntimeError) throws -> T {
        stateLock.withLock {
            compiledGroups = []
            outputPool = nil
            activeConfiguration = nil
            slotTextures = Array(repeating: [:], count: maxInflightFrames)
            slotLedger.advanceEpoch()
            _status = .failed(String(describing: error))
        }
        throw error
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
