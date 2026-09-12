import Foundation

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