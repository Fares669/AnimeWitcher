import CoreGraphics
import CoreImage
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

        func configureReady() {
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
        }

        configureReady()

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
        precondition((telemetry["inputWidth"] as? NSNumber)?.intValue == 8)
        precondition((telemetry["inputHeight"] as? NSNumber)?.intValue == 8)
        precondition((telemetry["processingWidth"] as? NSNumber)?.intValue == 8)
        precondition((telemetry["processingHeight"] as? NSNumber)?.intValue == 8)
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

        // The settings preview must exercise the same native Metal runtime as
        // playback without creating a Flutter external texture or second video
        // renderer. Use an actual PNG so this covers decode -> CVPixelBuffer ->
        // Metal -> CVPixelBuffer -> PNG end to end on Apple CI.
        let previewInputURL = root.appendingPathComponent("preview-input.png")
        let previewOutputURL = root.appendingPathComponent("preview-output.png")
        let previewContext = CIContext(options: nil)
        let previewBounds = CGRect(x: 0, y: 0, width: 16, height: 12)
        let previewSource = CIImage(
            color: CIColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        ).cropped(to: previewBounds)
        let previewColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ??
            CGColorSpaceCreateDeviceRGB()
        try previewContext.writePNGRepresentation(
            of: previewSource,
            to: previewInputURL,
            format: .RGBA8,
            colorSpace: previewColorSpace,
            options: [:]
        )
        let previewConfiguration: [String: Any] = [
            "shaderPaths": [shaderURL.path],
            "pipelineHash": "preview-capi-test",
            "precision": "mixedFP16",
            "upscaleStrategy": "fullAnime4K",
        ]
        let previewData = try JSONSerialization.data(
            withJSONObject: previewConfiguration
        )
        let previewJSON = String(decoding: previewData, as: UTF8.self)
        let previewResult = previewInputURL.path.withCString { inputPointer in
            previewOutputURL.path.withCString { outputPointer in
                previewJSON.withCString { jsonPointer in
                    animewitcherAnime4KMetalProcessPreview(
                        inputPointer,
                        outputPointer,
                        jsonPointer
                    )
                }
            }
        }
        precondition(previewResult == 1, "native one-shot preview must succeed")
        let previewAttributes = try FileManager.default.attributesOfItem(
            atPath: previewOutputURL.path
        )
        precondition(
            (previewAttributes[.size] as? NSNumber)?.intValue ?? 0 > 0,
            "native one-shot preview must write a non-empty PNG"
        )
        guard let previewOutput = CIImage(contentsOf: previewOutputURL) else {
            preconditionFailure("native one-shot preview PNG must be decodable")
        }
        precondition(Int(previewOutput.extent.width) == 16)
        precondition(Int(previewOutput.extent.height) == 12)
        let missingInputResult = root.appendingPathComponent("missing.png").path
            .withCString { inputPointer in
                previewOutputURL.path.withCString { outputPointer in
                    previewJSON.withCString { jsonPointer in
                        animewitcherAnime4KMetalProcessPreview(
                            inputPointer,
                            outputPointer,
                            jsonPointer
                        )
                    }
                }
            }
        precondition(
            missingInputResult == 0,
            "one-shot preview must fail closed for an unreadable source"
        )

        // Simulate a post-configure native failure/removal. The C API must not
        // keep reporting its cached configure-time `ready` value because Dart
        // relies on status polling to restore the exact mpv GLSL pipeline.
        guard let nativeHandle = OpaquePointer(bitPattern: UInt(handleAddress)) else {
            preconditionFailure("test handle must be representable")
        }
        Anime4KMediaKitBridge.shared.disable(handle: nativeHandle)
        precondition(
            Anime4KMetalDartAPI.status(handleAddress: handleAddress)
                == Anime4KMetalDartStatus.failed.rawValue,
            "runtime disappearing asynchronously must invalidate cached ready status"
        )

        // A subsequent explicit configuration can recover the same player.
        configureReady()

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
