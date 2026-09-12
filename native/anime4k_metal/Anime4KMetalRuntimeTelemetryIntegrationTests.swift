import CoreVideo
import Foundation
import Metal

@main
struct Anime4KMetalRuntimeTelemetryIntegrationTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("Apple CI must expose a Metal device")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "anime4k-runtime-telemetry-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let shaderURL = root.appendingPathComponent("identity.glsl")
        try """
        //!DESC Anime4K-Telemetry-Identity
        //!HOOK MAIN
        //!BIND MAIN
        vec4 hook() {
            return MAIN_tex(MAIN_pos);
        }
        """.write(to: shaderURL, atomically: true, encoding: .utf8)

        let runtime = try Anime4KMetalRuntime(device: device, maxInflightFrames: 1)
        try runtime.configure(
            Anime4KMetalRuntimeConfiguration(
                shaderPaths: [shaderURL.path],
                pipelineHash: "telemetry-integration",
                sourceWidth: 32,
                sourceHeight: 18,
                outputWidth: 32,
                outputHeight: 18
            )
        )

        var snapshot = runtime.telemetry
        precondition(snapshot.processedFrames == 0)
        precondition(snapshot.lateOrDroppedFrames == 0)
        precondition(snapshot.inputWidth == 32)
        precondition(snapshot.inputHeight == 18)
        precondition(snapshot.processingWidth == 32)
        precondition(snapshot.processingHeight == 18)
        precondition(runtime.compileGeneration == 1)

        // media_kit's CVPixelBuffer is the authoritative runtime output size.
        // A stale/larger Dart estimate must not make Anime4K allocate/process
        // oversized intermediates or fail the bridge's final same-size blit.
        let input = try makePixelBuffer(width: 16, height: 9)
        let completed = DispatchSemaphore(value: 0)
        let submission = runtime.process(pixelBuffer: input) { output in
            precondition(CVPixelBufferGetWidth(output) == 16)
            precondition(CVPixelBufferGetHeight(output) == 9)
            completed.signal()
        }
        precondition(submission == .submitted)
        precondition(
            completed.wait(timeout: .now() + 5) == .success,
            "telemetry frame must complete asynchronously"
        )
        precondition(
            runtime.compileGeneration == 1,
            "runtime-size retargeting must reuse compiled Metal pipelines"
        )

        snapshot = runtime.telemetry
        precondition(snapshot.processedFrames == 1)
        precondition(snapshot.averageFrameTimeMs >= 0)
        precondition(snapshot.p95FrameTimeMs >= 0)
        precondition(snapshot.inputWidth == 32)
        precondition(snapshot.inputHeight == 18)
        precondition(snapshot.processingWidth == 16)
        precondition(snapshot.processingHeight == 9)

        runtime.recordLateOrDroppedFrame()
        snapshot = runtime.telemetry
        precondition(snapshot.lateOrDroppedFrames == 1)

        print("Anime4KMetalRuntimeTelemetryIntegrationTests: PASS")
    }

    private static func makePixelBuffer(
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw TelemetryIntegrationError.pixelBufferCreation(result)
        }
        return pixelBuffer
    }
}

enum TelemetryIntegrationError: Error {
    case pixelBufferCreation(CVReturn)
}
