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
