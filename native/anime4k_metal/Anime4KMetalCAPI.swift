import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal

/// Stable integer ABI shared with Dart FFI. Keep existing raw values fixed.
enum Anime4KMetalDartStatus: Int32 {
    case unavailable = 0
    case ready = 1
    case failed = 2
    case unsupportedHdr = 3
    case disabled = 4
}

private struct Anime4KMetalDartConfiguration: Decodable {
    let shaderPaths: [String]
    let pipelineHash: String
    let sourceWidth: Int
    let sourceHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let precision: String
    let upscaleStrategy: String?
}

private struct Anime4KMetalPreviewConfiguration: Decodable {
    let shaderPaths: [String]
    let pipelineHash: String
    let precision: String
    let upscaleStrategy: String?
}

/// A tiny synchronized hand-off for the one-shot preview command-buffer
/// completion. The playback runtime stays fully asynchronous; only the settings
/// preview waits because its result is a single PNG that must exist before Dart
/// can display/cache it.
private final class Anime4KMetalPreviewResultBox {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func store(_ value: CVPixelBuffer) {
        lock.lock()
        buffer = value
        lock.unlock()
    }

    func load() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// Dart-facing per-player configuration API. All malformed/unknown input fails
/// closed and never throws across the C ABI boundary.
enum Anime4KMetalDartAPI {
    private static let lock = NSLock()
    private static var statuses: [UInt64: Anime4KMetalDartStatus] = [:]

    static func configure(
        handleAddress: UInt64,
        configurationJSON: UnsafePointer<CChar>?
    ) -> Int32 {
        guard handleAddress != 0,
              let configurationJSON,
              let handle = OpaquePointer(bitPattern: UInt(handleAddress)) else {
            return record(.failed, for: handleAddress)
        }

        do {
            let payload = try JSONDecoder().decode(
                Anime4KMetalDartConfiguration.self,
                from: Data(String(cString: configurationJSON).utf8)
            )
            guard !payload.shaderPaths.isEmpty,
                  !payload.pipelineHash.isEmpty,
                  payload.sourceWidth > 0,
                  payload.sourceHeight > 0,
                  payload.outputWidth > 0,
                  payload.outputHeight > 0,
                  let precision = Anime4KMetalPrecisionPolicy(rawValue: payload.precision),
                  let upscaleStrategy = Anime4KAppleUpscaleStrategy(
                      rawValue: payload.upscaleStrategy ?? "fullAnime4K"
                  ) else {
                return record(.failed, for: handleAddress)
            }

            let configuration = Anime4KMetalRuntimeConfiguration(
                shaderPaths: payload.shaderPaths,
                pipelineHash: payload.pipelineHash,
                sourceWidth: payload.sourceWidth,
                sourceHeight: payload.sourceHeight,
                outputWidth: payload.outputWidth,
                outputHeight: payload.outputHeight,
                precision: precision,
                upscaleStrategy: upscaleStrategy
            )
            do {
                try Anime4KMediaKitBridge.shared.configure(
                    handle: handle,
                    configuration: configuration
                )
                return record(.ready, for: handleAddress)
            } catch Anime4KMetalRuntimeError.commandQueueUnavailable {
                return record(.unavailable, for: handleAddress)
            } catch {
                return record(.failed, for: handleAddress)
            }
        } catch {
            return record(.failed, for: handleAddress)
        }
    }

    /// Processes the settings sample exactly once with the same native Metal
    /// runtime used by playback. This deliberately does not go through a
    /// Flutter external texture or a second media_kit renderer: either can make
    /// the captured half black or bypass the post-processing stage on Apple.
    static func processPreview(
        inputPath: UnsafePointer<CChar>?,
        outputPath: UnsafePointer<CChar>?,
        configurationJSON: UnsafePointer<CChar>?
    ) -> Int32 {
        guard let inputPath,
              let outputPath,
              let configurationJSON else {
            return 0
        }

        do {
            let payload = try JSONDecoder().decode(
                Anime4KMetalPreviewConfiguration.self,
                from: Data(String(cString: configurationJSON).utf8)
            )
            guard !payload.shaderPaths.isEmpty,
                  !payload.pipelineHash.isEmpty,
                  let precision = Anime4KMetalPrecisionPolicy(rawValue: payload.precision),
                  let upscaleStrategy = Anime4KAppleUpscaleStrategy(
                      rawValue: payload.upscaleStrategy ?? "fullAnime4K"
                  ),
                  let device = MTLCreateSystemDefaultDevice() else {
                return 0
            }

            let sourceURL = URL(fileURLWithPath: String(cString: inputPath))
            let destinationURL = URL(fileURLWithPath: String(cString: outputPath))
            guard let loadedImage = CIImage(
                contentsOf: sourceURL,
                options: [.applyOrientationProperty: true]
            ) else {
                return 0
            }

            let integralExtent = loadedImage.extent.integral
            let width = Int(integralExtent.width)
            let height = Int(integralExtent.height)
            guard width > 0, height > 0 else { return 0 }

            // CVPixelBuffers have a zero-origin coordinate system. Preserve the
            // complete oriented image while normalizing any decoder-provided
            // non-zero Core Image extent origin.
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let image = loadedImage
                .transformed(
                    by: CGAffineTransform(
                        translationX: -integralExtent.origin.x,
                        y: -integralExtent.origin.y
                    )
                )
                .cropped(to: bounds)

            let pixelBufferAttributes: [CFString: Any] = [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var inputBuffer: CVPixelBuffer?
            let createResult = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                pixelBufferAttributes as CFDictionary,
                &inputBuffer
            )
            guard createResult == kCVReturnSuccess, let inputBuffer else {
                return 0
            }

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ??
                CGColorSpaceCreateDeviceRGB()
            let context = CIContext(mtlDevice: device)
            context.render(
                image,
                to: inputBuffer,
                bounds: bounds,
                colorSpace: colorSpace
            )

            let runtime = try Anime4KMetalRuntime(device: device, maxInflightFrames: 1)
            try runtime.configure(
                Anime4KMetalRuntimeConfiguration(
                    shaderPaths: payload.shaderPaths,
                    pipelineHash: payload.pipelineHash,
                    sourceWidth: width,
                    sourceHeight: height,
                    outputWidth: width,
                    outputHeight: height,
                    precision: precision,
                    upscaleStrategy: upscaleStrategy
                )
            )

            let semaphore = DispatchSemaphore(value: 0)
            let resultBox = Anime4KMetalPreviewResultBox()
            let submission = runtime.process(pixelBuffer: inputBuffer) { outputBuffer in
                resultBox.store(outputBuffer)
                semaphore.signal()
            }
            guard submission == .submitted else { return 0 }
            guard semaphore.wait(timeout: .now() + 15) == .success,
                  let outputBuffer = resultBox.load(),
                  runtime.status == .ready,
                  runtime.telemetry.processedFrames >= 1 else {
                return 0
            }

            let outputImage = CIImage(cvPixelBuffer: outputBuffer)
            try? FileManager.default.removeItem(at: destinationURL)
            try context.writePNGRepresentation(
                of: outputImage,
                to: destinationURL,
                format: .RGBA8,
                colorSpace: colorSpace,
                options: [:]
            )
            return 1
        } catch {
            return 0
        }
    }

    static func status(handleAddress: UInt64) -> Int32 {
        let cached: Anime4KMetalDartStatus = {
            lock.lock()
            defer { lock.unlock() }
            return statuses[handleAddress] ?? .unavailable
        }()

        // Explicit disable/unavailable/failure states remain authoritative.
        // Only a cached `ready` result needs reconciliation with the live
        // runtime because GPU/final-blit failures can occur asynchronously.
        guard cached == .ready else { return cached.rawValue }
        guard handleAddress != 0,
              let handle = OpaquePointer(bitPattern: UInt(handleAddress)) else {
            return record(.failed, for: handleAddress)
        }

        switch Anime4KMediaKitBridge.shared.runtimeStatus(handle: handle) {
        case .ready:
            return Anime4KMetalDartStatus.ready.rawValue
        case .failed:
            return record(.failed, for: handleAddress)
        case .disabled, .none:
            // A runtime disappearing while Dart still believes Metal owns the
            // player is an asynchronous backend failure, not an intentional
            // Dart disable. Fail closed so the controller restores mpv GLSL.
            return record(.failed, for: handleAddress)
        }
    }

    /// Two-phase C ABI: call with nil/zero to query the required NUL-terminated
    /// UTF-8 byte count, then call again with a buffer of at least that size.
    /// Returns 0 for invalid/unconfigured handles or serialization failure.
    static func telemetry(
        handleAddress: UInt64,
        buffer: UnsafeMutablePointer<UInt8>?,
        capacity: Int32
    ) -> Int32 {
        let bridge = Anime4KMediaKitBridge.shared
        guard handleAddress != 0,
              let handle = OpaquePointer(bitPattern: UInt(handleAddress)),
              status(handleAddress: handleAddress) == Anime4KMetalDartStatus.ready.rawValue,
              let runtime = bridge.telemetry(handle: handle),
              let configuration = bridge.activeConfiguration(handle: handle) else {
            return 0
        }

        let processInfo = ProcessInfo.processInfo
        let object: [String: Any] = [
            "averageFrameTimeMs": runtime.averageFrameTimeMs,
            "p95FrameTimeMs": runtime.p95FrameTimeMs,
            "processedFrames": runtime.processedFrames,
            "skippedDuplicateFrames": runtime.skippedDuplicateFrames +
                Anime4KFrameDedupRegistry.shared.skippedDuplicateFrames(
                    for: UInt(handleAddress)
                ),
            "lateOrDroppedFrames": runtime.lateOrDroppedFrames,
            "inputWidth": configuration.sourceWidth,
            "inputHeight": configuration.sourceHeight,
            "processingWidth": configuration.outputWidth,
            "processingHeight": configuration.outputHeight,
            "thermalLevel": thermalLevel(processInfo.thermalState),
            "lowPowerMode": processInfo.isLowPowerModeEnabled,
        ]

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              data.count < Int(Int32.max) else {
            return 0
        }

        let required = data.count + 1
        guard required <= Int(Int32.max) else { return 0 }
        let requiredBytes = Int32(required)
        guard let buffer, capacity >= requiredBytes else {
            return requiredBytes
        }

        data.withUnsafeBytes { raw in
            if let baseAddress = raw.baseAddress {
                buffer.initialize(from: baseAddress.assumingMemoryBound(to: UInt8.self), count: data.count)
            }
        }
        buffer[data.count] = 0
        return requiredBytes
    }

    /// Enables/disables a temporary per-player pass-through state without
    /// destroying the configured runtime. This is intentionally separate from
    /// `disable`: Eco needs telemetry to remain alive while critical thermal
    /// pressure cools down so it can observe recovery and resume progressively.
    static func setBypass(handleAddress: UInt64, bypass: Bool) -> Int32 {
        guard handleAddress != 0,
              status(handleAddress: handleAddress) == Anime4KMetalDartStatus.ready.rawValue,
              let handle = OpaquePointer(bitPattern: UInt(handleAddress)) else {
            return 0
        }
        return Anime4KMediaKitBridge.shared.setBypass(
            handle: handle,
            bypass: bypass
        ) ? 1 : 0
    }

    static func disable(handleAddress: UInt64) {
        if let handle = OpaquePointer(bitPattern: UInt(handleAddress)) {
            Anime4KMediaKitBridge.shared.disable(handle: handle)
        }
        Anime4KFrameDedupRegistry.shared.reset(for: UInt(handleAddress))
        _ = record(.disabled, for: handleAddress)
    }

    @discardableResult
    private static func record(
        _ status: Anime4KMetalDartStatus,
        for handleAddress: UInt64
    ) -> Int32 {
        lock.lock()
        statuses[handleAddress] = status
        lock.unlock()
        return status.rawValue
    }

    private static func thermalLevel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            // Unknown future thermal pressure fails conservatively toward the
            // strongest Eco reaction rather than overstressing the device.
            return "critical"
        }
    }
}

@_cdecl("animewitcher_anime4k_metal_configure")
public func animewitcherAnime4KMetalConfigure(
    _ handleAddress: UInt64,
    _ configurationJSON: UnsafePointer<CChar>?
) -> Int32 {
    Anime4KMetalDartAPI.configure(
        handleAddress: handleAddress,
        configurationJSON: configurationJSON
    )
}

@_cdecl("animewitcher_anime4k_metal_process_preview")
public func animewitcherAnime4KMetalProcessPreview(
    _ inputPath: UnsafePointer<CChar>?,
    _ outputPath: UnsafePointer<CChar>?,
    _ configurationJSON: UnsafePointer<CChar>?
) -> Int32 {
    Anime4KMetalDartAPI.processPreview(
        inputPath: inputPath,
        outputPath: outputPath,
        configurationJSON: configurationJSON
    )
}

@_cdecl("animewitcher_anime4k_metal_status")
public func animewitcherAnime4KMetalStatus(_ handleAddress: UInt64) -> Int32 {
    Anime4KMetalDartAPI.status(handleAddress: handleAddress)
}

@_cdecl("animewitcher_anime4k_metal_telemetry")
public func animewitcherAnime4KMetalTelemetry(
    _ handleAddress: UInt64,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int32
) -> Int32 {
    Anime4KMetalDartAPI.telemetry(
        handleAddress: handleAddress,
        buffer: buffer,
        capacity: capacity
    )
}

@_cdecl("animewitcher_anime4k_metal_set_bypass")
public func animewitcherAnime4KMetalSetBypass(
    _ handleAddress: UInt64,
    _ bypass: Int32
) -> Int32 {
    Anime4KMetalDartAPI.setBypass(
        handleAddress: handleAddress,
        bypass: bypass != 0
    )
}

@_cdecl("animewitcher_anime4k_metal_disable")
public func animewitcherAnime4KMetalDisable(_ handleAddress: UInt64) {
    Anime4KMetalDartAPI.disable(handleAddress: handleAddress)
}
