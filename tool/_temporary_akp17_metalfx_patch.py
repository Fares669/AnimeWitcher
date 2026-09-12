from pathlib import Path


def replace_exact(path: str, old: str, new: str, expected: int = 1) -> None:
    file = Path(path)
    source = file.read_text()
    count = source.count(old)
    if count != expected:
        raise SystemExit(f'{path}: expected {expected} exact matches, found {count}')
    file.write_text(source.replace(old, new, expected))


# Dart -> native strategy transport. The default remains the existing full
# Anime4K path; the experimental strategy is opt-in only.
replace_exact(
    'lib/features/player/data/anime4k_metal_bridge.dart',
    """    required Anime4kProcessingDimensions output,\n    String precision = 'mixedFP16',\n  }) {\n""",
    """    required Anime4kProcessingDimensions output,\n    String precision = 'mixedFP16',\n    String upscaleStrategy = 'fullAnime4K',\n  }) {\n""",
)
replace_exact(
    'lib/features/player/data/anime4k_metal_bridge.dart',
    """        'outputHeight': output.height,\n        'precision': precision,\n      });\n""",
    """        'outputHeight': output.height,\n        'precision': precision,\n        'upscaleStrategy': upscaleStrategy,\n      });\n""",
)

replace_exact(
    'lib/features/player/presentation/player_controller_base.dart',
    """      final settings = ref.read(playerSettingsProvider).asData?.value;\n      final anime4kEnabled = settings?.anime4kEnabled ?? false;\n""",
    """      final settings = ref.read(playerSettingsProvider).asData?.value;\n      final useMetalFxExperiment =\n          bool.fromEnvironment('ANIME4K_METALFX_EXPERIMENT') &&\n          (settings?.anime4kEcoEnabled ?? false);\n      final upscaleStrategy = useMetalFxExperiment\n          ? 'restoreDenoiseMetalFXSpatial'\n          : 'fullAnime4K';\n      final anime4kEnabled = settings?.anime4kEnabled ?? false;\n""",
)
replace_exact(
    'lib/features/player/presentation/player_controller_base.dart',
    """              source: dimensions.source,\n              output: dimensions.output,\n            );\n""",
    """              source: dimensions.source,\n              output: dimensions.output,\n              upscaleStrategy: upscaleStrategy,\n            );\n""",
)

replace_exact(
    'native/anime4k_metal/Anime4KMetalCAPI.swift',
    """    let outputHeight: Int\n    let precision: String\n}\n""",
    """    let outputHeight: Int\n    let precision: String\n    let upscaleStrategy: String?\n}\n""",
)
replace_exact(
    'native/anime4k_metal/Anime4KMetalCAPI.swift',
    """                  payload.outputWidth > 0,\n                  payload.outputHeight > 0,\n                  let precision = Anime4KMetalPrecisionPolicy(rawValue: payload.precision) else {\n                return record(.failed, for: handleAddress)\n            }\n""",
    """                  payload.outputWidth > 0,\n                  payload.outputHeight > 0,\n                  let precision = Anime4KMetalPrecisionPolicy(rawValue: payload.precision),\n                  let upscaleStrategy = Anime4KAppleUpscaleStrategy(\n                      rawValue: payload.upscaleStrategy ?? \"fullAnime4K\"\n                  ) else {\n                return record(.failed, for: handleAddress)\n            }\n""",
)
replace_exact(
    'native/anime4k_metal/Anime4KMetalCAPI.swift',
    """                outputWidth: payload.outputWidth,\n                outputHeight: payload.outputHeight,\n                precision: precision\n            )\n""",
    """                outputWidth: payload.outputWidth,\n                outputHeight: payload.outputHeight,\n                precision: precision,\n                upscaleStrategy: upscaleStrategy\n            )\n""",
)

runtime = 'native/anime4k_metal/Anime4KMetalRuntime.swift'
replace_exact(
    runtime,
    """import Metal\n\nstruct Anime4KMetalRuntimeConfiguration: Equatable {\n""",
    """import Metal\n\nenum Anime4KAppleUpscaleStrategy: String, Equatable {\n    case fullAnime4K\n    case restoreDenoiseMetalFXSpatial\n}\n\nstruct Anime4KMetalRuntimeConfiguration: Equatable {\n""",
)
replace_exact(
    runtime,
    """    let outputHeight: Int\n    let precision: Anime4KMetalPrecisionPolicy\n\n    init(\n""",
    """    let outputHeight: Int\n    let precision: Anime4KMetalPrecisionPolicy\n    let upscaleStrategy: Anime4KAppleUpscaleStrategy\n\n    init(\n""",
)
replace_exact(
    runtime,
    """        outputWidth: Int,\n        outputHeight: Int,\n        precision: Anime4KMetalPrecisionPolicy = .mixedFP16\n    ) {\n""",
    """        outputWidth: Int,\n        outputHeight: Int,\n        precision: Anime4KMetalPrecisionPolicy = .mixedFP16,\n        upscaleStrategy: Anime4KAppleUpscaleStrategy = .fullAnime4K\n    ) {\n""",
)
replace_exact(
    runtime,
    """        self.outputHeight = outputHeight\n        self.precision = precision\n    }\n}\n""",
    """        self.outputHeight = outputHeight\n        self.precision = precision\n        self.upscaleStrategy = upscaleStrategy\n    }\n}\n""",
)
replace_exact(
    runtime,
    """    case encoderUnavailable(String)\n    case invalidWhen(String)\n\n    var errorDescription: String? {\n""",
    """    case encoderUnavailable(String)\n    case invalidWhen(String)\n    case metalFXUnavailable\n    case metalFXPipeline(String)\n\n    var errorDescription: String? {\n""",
)
replace_exact(
    runtime,
    """        case .invalidWhen(let expression):\n            return \"Anime4K Metal WHEN expression is invalid: \\(expression)\"\n        }\n    }\n}\n""",
    """        case .invalidWhen(let expression):\n            return \"Anime4K Metal WHEN expression is invalid: \\(expression)\"\n        case .metalFXUnavailable:\n            return \"Anime4K MetalFX spatial scaler is unavailable\"\n        case .metalFXPipeline(let detail):\n            return \"Anime4K MetalFX spatial scaler failed: \\(detail)\"\n        }\n    }\n}\n""",
)
replace_exact(
    runtime,
    """    private let finalCopyPipeline: MTLComputePipelineState\n    private let maxInflightFrames: Int\n""",
    """    private let finalCopyPipeline: MTLComputePipelineState\n    private let metalFXScaler: Anime4KMetalFXScaler\n    private let maxInflightFrames: Int\n""",
)
replace_exact(
    runtime,
    """        self.linearSampler = linear\n        self.finalCopyPipeline = copyPipeline\n        self.maxInflightFrames = maxInflightFrames\n""",
    """        self.linearSampler = linear\n        self.finalCopyPipeline = copyPipeline\n        self.metalFXScaler = Anime4KMetalFXScaler(device: device)\n        self.maxInflightFrames = maxInflightFrames\n""",
)
replace_exact(
    runtime,
    """        do {\n            var nextGroups: [CompiledGroup] = []\n            nextGroups.reserveCapacity(configuration.shaderPaths.count)\n\n            for path in configuration.shaderPaths {\n""",
    """        do {\n            let shaderPaths: [String]\n            switch configuration.upscaleStrategy {\n            case .fullAnime4K:\n                shaderPaths = configuration.shaderPaths\n            case .restoreDenoiseMetalFXSpatial:\n                guard metalFXScaler.isAvailable else {\n                    throw Anime4KMetalRuntimeError.metalFXUnavailable\n                }\n                shaderPaths = experimentalShaderPaths(configuration.shaderPaths)\n                guard !shaderPaths.isEmpty else {\n                    throw Anime4KMetalRuntimeError.metalFXPipeline(\n                        \"no restore/denoise stages remain after filtering\"\n                    )\n                }\n            }\n\n            var nextGroups: [CompiledGroup] = []\n            nextGroups.reserveCapacity(shaderPaths.count)\n\n            for path in shaderPaths {\n""",
)
replace_exact(
    runtime,
    """            for group in snapshot.groups {\n                currentMain = try encode(\n                    group: group,\n                    main: currentMain,\n                    native: nativeTexture,\n                    outputWidth: snapshot.configuration.outputWidth,\n                    outputHeight: snapshot.configuration.outputHeight,\n                    slot: snapshot.lease.slot,\n                    commandBuffer: commandBuffer\n                )\n            }\n            try encodeFinalCopy(\n""",
    """            for group in snapshot.groups {\n                currentMain = try encode(\n                    group: group,\n                    main: currentMain,\n                    native: nativeTexture,\n                    outputWidth: snapshot.configuration.outputWidth,\n                    outputHeight: snapshot.configuration.outputHeight,\n                    slot: snapshot.lease.slot,\n                    commandBuffer: commandBuffer\n                )\n            }\n            if snapshot.configuration.upscaleStrategy == .restoreDenoiseMetalFXSpatial &&\n                (currentMain.width < snapshot.configuration.outputWidth ||\n                 currentMain.height < snapshot.configuration.outputHeight) {\n                do {\n                    currentMain = try metalFXScaler.encode(\n                        input: currentMain,\n                        outputWidth: snapshot.configuration.outputWidth,\n                        outputHeight: snapshot.configuration.outputHeight,\n                        slot: snapshot.lease.slot,\n                        commandBuffer: commandBuffer\n                    )\n                } catch {\n                    throw Anime4KMetalRuntimeError.metalFXPipeline(\n                        String(describing: error)\n                    )\n                }\n            }\n            try encodeFinalCopy(\n""",
)
replace_exact(
    runtime,
    """    private func encode(\n        group: CompiledGroup,\n""",
    """    private func experimentalShaderPaths(_ shaderPaths: [String]) -> [String] {\n        // The benchmark route keeps Anime4K restore/denoise work but removes\n        // Anime4K's own resize stages so MetalFX is the only spatial upscaler.\n        // Keep the concrete v4 names here as a source-level regression guard.\n        let knownUpscaleStages = [\n            \"Anime4K_Upscale_CNN_x2_\",\n            \"Anime4K_Upscale_Denoise_CNN_x2_\",\n            \"Anime4K_AutoDownscalePre_x2.glsl\",\n            \"Anime4K_AutoDownscalePre_x4.glsl\",\n        ]\n        let restoreStagePrefix = \"Anime4K_Restore_CNN_\"\n\n        return shaderPaths.filter { path in\n            let name = URL(fileURLWithPath: path).lastPathComponent\n            if name.contains(restoreStagePrefix) { return true }\n            if knownUpscaleStages.contains(where: { name.contains($0) }) {\n                return false\n            }\n            return !name.contains(\"Anime4K_Upscale_\") &&\n                !name.contains(\"Anime4K_AutoDownscalePre_\")\n        }\n    }\n\n    private func encode(\n        group: CompiledGroup,\n""",
)

# Preserve the strategy when media_kit's live drawable size retargets the
# runtime. Otherwise the first real frame would silently revert to fullAnime4K.
replace_exact(
    'native/anime4k_metal/Anime4KMediaKitBridge.swift',
    """                outputWidth: frameWidth,\n                outputHeight: frameHeight,\n                precision: prepared.configuration.precision\n            )\n""",
    """                outputWidth: frameWidth,\n                outputHeight: frameHeight,\n                precision: prepared.configuration.precision,\n                upscaleStrategy: prepared.configuration.upscaleStrategy\n            )\n""",
)

# Ship the adapter inside the patched media_kit Apple target.
replace_exact(
    'scripts/anime4k_media_kit_patch.rb',
    """  Anime4KMetalTelemetry.swift\n  Anime4KMetalRuntime.swift\n""",
    """  Anime4KMetalTelemetry.swift\n  Anime4KMetalFXScaler.swift\n  Anime4KMetalRuntime.swift\n""",
)

# Native CI compiles the same support file list explicitly. Add the framework
# and adapter to every focused swiftc invocation that includes the runtime.
replace_exact(
    '.github/workflows/anime4k-platform-build.yml',
    """            -framework Metal \\\n            native/anime4k_metal/Anime4KMetalShader.swift \\\n            native/anime4k_metal/Anime4KMetalTelemetry.swift \\\n            native/anime4k_metal/Anime4KMetalRuntime.swift \\\n""",
    """            -framework Metal \\\n            -framework MetalFX \\\n            native/anime4k_metal/Anime4KMetalShader.swift \\\n            native/anime4k_metal/Anime4KMetalTelemetry.swift \\\n            native/anime4k_metal/Anime4KMetalFXScaler.swift \\\n            native/anime4k_metal/Anime4KMetalRuntime.swift \\\n""",
    expected=4,
)

adapter = Path('native/anime4k_metal/Anime4KMetalFXScaler.swift')
if adapter.exists():
    raise SystemExit(f'{adapter}: expected new file, but it already exists')
adapter.write_text(r'''// Copyright 2026 AnimeWitcher contributors
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

import Foundation
import Metal
#if canImport(MetalFX)
import MetalFX
#endif

enum Anime4KMetalFXScalerError: Error, LocalizedError {
    case unavailable
    case invalidDimensions
    case scalerCreation
    case textureCreation
    case blitEncoderUnavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "MetalFX spatial scaling is unavailable on this device"
        case .invalidDimensions:
            return "MetalFX spatial scaling received invalid dimensions"
        case .scalerCreation:
            return "MetalFX spatial scaler creation failed"
        case .textureCreation:
            return "MetalFX compatible texture creation failed"
        case .blitEncoderUnavailable:
            return "MetalFX input blit encoder is unavailable"
        }
    }
}

/// Isolated optional MetalFX adapter used only by the hidden AKP-17 benchmark
/// route. The normal Anime4K runtime never instantiates MetalFX objects unless
/// the experimental strategy is explicitly selected.
final class Anime4KMetalFXScaler {
    private let device: MTLDevice
    private var implementation: AnyObject?

    init(device: MTLDevice) {
        self.device = device
#if canImport(MetalFX)
        if #available(iOS 16.0, macOS 13.0, *),
           MTLFXSpatialScalerDescriptor.supportsDevice(device) {
            implementation = AvailableImplementation(device: device)
        }
#endif
    }

    static func isAvailable(device: MTLDevice) -> Bool {
#if canImport(MetalFX)
        if #available(iOS 16.0, macOS 13.0, *) {
            return MTLFXSpatialScalerDescriptor.supportsDevice(device)
        }
#endif
        return false
    }

    var isAvailable: Bool {
        implementation != nil && Self.isAvailable(device: device)
    }

    func encode(
        input: MTLTexture,
        outputWidth: Int,
        outputHeight: Int,
        slot: Int,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        guard outputWidth > 0, outputHeight > 0,
              outputWidth >= input.width,
              outputHeight >= input.height else {
            throw Anime4KMetalFXScalerError.invalidDimensions
        }
#if canImport(MetalFX)
        if #available(iOS 16.0, macOS 13.0, *),
           let implementation = implementation as? AvailableImplementation {
            return try implementation.encode(
                input: input,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                slot: slot,
                commandBuffer: commandBuffer
            )
        }
#endif
        throw Anime4KMetalFXScalerError.unavailable
    }
}

#if canImport(MetalFX)
@available(iOS 16.0, macOS 13.0, *)
private final class AvailableImplementation {
    private struct Key: Equatable {
        let inputWidth: Int
        let inputHeight: Int
        let outputWidth: Int
        let outputHeight: Int
        let pixelFormat: MTLPixelFormat
    }

    private struct SlotState {
        let key: Key
        let scaler: any MTLFXSpatialScaler
        let inputTexture: MTLTexture
        let outputTexture: MTLTexture
    }

    private let device: MTLDevice
    private let lock = NSLock()
    private var states: [Int: SlotState] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func encode(
        input: MTLTexture,
        outputWidth: Int,
        outputHeight: Int,
        slot: Int,
        commandBuffer: MTLCommandBuffer
    ) throws -> MTLTexture {
        let key = Key(
            inputWidth: input.width,
            inputHeight: input.height,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            pixelFormat: input.pixelFormat
        )
        let state = try state(for: slot, key: key)

        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw Anime4KMetalFXScalerError.blitEncoderUnavailable
        }
        blit.label = "Anime4K MetalFX input copy"
        blit.copy(
            from: input,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: input.width, height: input.height, depth: 1),
            to: state.inputTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        state.scaler.colorTexture = state.inputTexture
        state.scaler.inputContentWidth = input.width
        state.scaler.inputContentHeight = input.height
        state.scaler.outputTexture = state.outputTexture
        state.scaler.encode(commandBuffer: commandBuffer)
        return state.outputTexture
    }

    private func state(for slot: Int, key: Key) throws -> SlotState {
        lock.lock()
        defer { lock.unlock() }
        if let existing = states[slot], existing.key == key {
            return existing
        }

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = key.inputWidth
        descriptor.inputHeight = key.inputHeight
        descriptor.outputWidth = key.outputWidth
        descriptor.outputHeight = key.outputHeight
        descriptor.colorTextureFormat = key.pixelFormat
        descriptor.outputTextureFormat = key.pixelFormat
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            throw Anime4KMetalFXScalerError.scalerCreation
        }

        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: key.pixelFormat,
            width: key.inputWidth,
            height: key.inputHeight,
            mipmapped: false
        )
        inputDescriptor.storageMode = .private
        inputDescriptor.usage = scaler.colorTextureUsage.union(.shaderRead)

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: key.pixelFormat,
            width: key.outputWidth,
            height: key.outputHeight,
            mipmapped: false
        )
        // MetalFX requires outputTexture to use private storage. Keep shaderRead
        // because Anime4K's existing final-copy kernel samples this texture.
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = scaler.outputTextureUsage.union(.shaderRead)

        guard let compatibleInput = device.makeTexture(descriptor: inputDescriptor),
              let compatibleOutput = device.makeTexture(descriptor: outputDescriptor) else {
            throw Anime4KMetalFXScalerError.textureCreation
        }
        compatibleInput.label = "Anime4K MetalFX input slot \\(slot)"
        compatibleOutput.label = "Anime4K MetalFX output slot \\(slot)"

        let created = SlotState(
            key: key,
            scaler: scaler,
            inputTexture: compatibleInput,
            outputTexture: compatibleOutput
        )
        states[slot] = created
        return created
    }
}
#endif
''')

# The workflow and helper are scaffolding only. The generated production commit
# must leave neither file behind.
Path('.github/workflows/_temporary_akp17_metalfx_patch.yml').unlink()
Path('tool/_temporary_akp17_metalfx_patch.py').unlink()
