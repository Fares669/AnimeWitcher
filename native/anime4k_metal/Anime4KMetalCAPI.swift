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
                  let precision = Anime4KMetalPrecisionPolicy(rawValue: payload.precision) else {
                return record(.failed, for: handleAddress)
            }

            let configuration = Anime4KMetalRuntimeConfiguration(
                shaderPaths: payload.shaderPaths,
                pipelineHash: payload.pipelineHash,
                sourceWidth: payload.sourceWidth,
                sourceHeight: payload.sourceHeight,
                outputWidth: payload.outputWidth,
                outputHeight: payload.outputHeight,
                precision: precision
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
        lock.lock()
        defer { lock.unlock() }
        return (statuses[handleAddress] ?? .unavailable).rawValue
    }

    static func disable(handleAddress: UInt64) {
        if let handle = OpaquePointer(bitPattern: UInt(handleAddress)) {
            Anime4KMediaKitBridge.shared.disable(handle: handle)
        }
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
}

@_cdecl("animewitcher_anime4k_metal_configure")
func animewitcherAnime4KMetalConfigure(
    _ handleAddress: UInt64,
    _ configurationJSON: UnsafePointer<CChar>?
) -> Int32 {
    Anime4KMetalDartAPI.configure(
        handleAddress: handleAddress,
        configurationJSON: configurationJSON
    )
}

@_cdecl("animewitcher_anime4k_metal_status")
func animewitcherAnime4KMetalStatus(_ handleAddress: UInt64) -> Int32 {
    Anime4KMetalDartAPI.status(handleAddress: handleAddress)
}

@_cdecl("animewitcher_anime4k_metal_disable")
func animewitcherAnime4KMetalDisable(_ handleAddress: UInt64) {
    Anime4KMetalDartAPI.disable(handleAddress: handleAddress)
}
