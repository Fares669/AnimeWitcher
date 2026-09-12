import Foundation

@main
struct Anime4KMetalCAPITests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "anime4k-capi-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let shaderURL = root.appendingPathComponent("identity.glsl")
        try """
        //!DESC Anime4K-CAPI-Identity
        //!HOOK MAIN
        //!BIND MAIN
        vec4 hook() {
            return MAIN_tex(MAIN_pos);
        }
        """.write(to: shaderURL, atomically: true, encoding: .utf8)

        let handleAddress: UInt64 = 0xA41E4
        let configuration: [String: Any] = [
            "shaderPaths": [shaderURL.path],
            "pipelineHash": "capi-test",
            "sourceWidth": 8,
            "sourceHeight": 8,
            "outputWidth": 8,
            "outputHeight": 8,
            "precision": "mixedFP16",
        ]
        let data = try JSONSerialization.data(withJSONObject: configuration)
        let json = String(decoding: data, as: UTF8.self)

        let configured = json.withCString { pointer in
            Anime4KMetalDartAPI.configure(
                handleAddress: handleAddress,
                configurationJSON: pointer
            )
        }
        precondition(
            configured == Anime4KMetalDartStatus.ready.rawValue,
            "valid per-player configuration must become ready"
        )
        precondition(
            Anime4KMetalDartAPI.status(handleAddress: handleAddress)
                == Anime4KMetalDartStatus.ready.rawValue
        )

        precondition(
            Anime4KMetalDartAPI.setBypass(
                handleAddress: handleAddress,
                bypass: true
            ) == 1,
            "Eco critical thermal must be able to bypass processing without disabling the runtime"
        )
        precondition(
            Anime4KMetalDartAPI.status(handleAddress: handleAddress)
                == Anime4KMetalDartStatus.ready.rawValue,
            "temporary Eco bypass must keep runtime status ready for recovery telemetry"
        )

        let requiredBytes = Anime4KMetalDartAPI.telemetry(
            handleAddress: handleAddress,
            buffer: nil,
            capacity: 0
        )
        precondition(
            requiredBytes > 1,
            "temporarily bypassed runtime must keep exposing telemetry for recovery"
        )

        precondition(
            Anime4KMetalDartAPI.setBypass(
                handleAddress: handleAddress,
                bypass: false
            ) == 1,
            "Eco recovery must resume processing on the existing runtime"
        )

        var telemetryBytes = [UInt8](
            repeating: 0,
            count: Int(requiredBytes)
        )
        let writtenBytes = telemetryBytes.withUnsafeMutableBufferPointer { buffer in
            Anime4KMetalDartAPI.telemetry(
                handleAddress: handleAddress,
                buffer: buffer.baseAddress,
                capacity: Int32(buffer.count)
            )
        }
        precondition(writtenBytes == requiredBytes)
        precondition(telemetryBytes.last == 0, "C ABI telemetry must be NUL terminated")

        let telemetryData = Data(telemetryBytes.dropLast())
        let telemetryObject = try JSONSerialization.jsonObject(with: telemetryData)
        guard let telemetry = telemetryObject as? [String: Any] else {
            preconditionFailure("telemetry must decode to a JSON object")
        }
        precondition(telemetry["averageFrameTimeMs"] is NSNumber)
        precondition(telemetry["p95FrameTimeMs"] is NSNumber)
        precondition((telemetry["processedFrames"] as? NSNumber)?.intValue == 0)
        precondition(telemetry["lateOrDroppedFrames"] is NSNumber)
        precondition(telemetry["lowPowerMode"] is Bool)
        let thermal = telemetry["thermalLevel"] as? String
        precondition(
            ["nominal", "fair", "serious", "critical"].contains(thermal ?? ""),
            "native thermal state must use the Dart policy vocabulary"
        )
        precondition(
            Anime4KMetalDartAPI.telemetry(
                handleAddress: 0,
                buffer: nil,
                capacity: 0
            ) == 0,
            "invalid handles must fail closed"
        )
        precondition(
            Anime4KMetalDartAPI.setBypass(
                handleAddress: 0,
                bypass: true
            ) == 0,
            "invalid bypass handles must fail closed"
        )

        Anime4KMetalDartAPI.disable(handleAddress: handleAddress)
        precondition(
            Anime4KMetalDartAPI.status(handleAddress: handleAddress)
                == Anime4KMetalDartStatus.disabled.rawValue,
            "explicit disable must clear the per-player Metal runtime"
        )

        let malformed = "{not-json".withCString { pointer in
            Anime4KMetalDartAPI.configure(
                handleAddress: handleAddress,
                configurationJSON: pointer
            )
        }
        precondition(
            malformed == Anime4KMetalDartStatus.failed.rawValue,
            "malformed configuration must fail closed"
        )
        precondition(
            Anime4KMetalDartAPI.status(handleAddress: handleAddress)
                == Anime4KMetalDartStatus.failed.rawValue
        )

        Anime4KMetalDartAPI.disable(handleAddress: handleAddress)
        print("Anime4KMetalCAPITests: PASS")
    }
}
