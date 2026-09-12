import CoreVideo
import Foundation
import Metal

@main
struct Anime4KMetalRuntimeTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            preconditionFailure("Apple CI must expose a Metal device")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "anime4k-runtime-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let shaderURL = root.appendingPathComponent("identity.glsl")
        try """
        //!DESC Anime4K-Runtime-Identity
        //!HOOK MAIN
        //!BIND MAIN
        vec4 hook() {
            return MAIN_tex(MAIN_pos);
        }
        """.write(to: shaderURL, atomically: true, encoding: .utf8)

        let runtime = try Anime4KMetalRuntime(
            device: device,
            maxInflightFrames: 2
        )
        precondition(runtime.status == .disabled)
        precondition(runtime.compileGeneration == 0)

        let first = Anime4KMetalRuntimeConfiguration(
            shaderPaths: [shaderURL.path],
            pipelineHash: "pipeline-a",
            sourceWidth: 8,
            sourceHeight: 8,
            outputWidth: 8,
            outputHeight: 8
        )
        try runtime.configure(first)
        precondition(runtime.status == .ready)
        precondition(runtime.compileGeneration == 1)

        // An identical pipeline/dimension configuration must reuse compiled
        // Metal pipeline states instead of paying compilation cost per apply.
        try runtime.configure(first)
        precondition(runtime.compileGeneration == 1)

        let changed = Anime4KMetalRuntimeConfiguration(
            shaderPaths: [shaderURL.path],
            pipelineHash: "pipeline-b",
            sourceWidth: 8,
            sourceHeight: 8,
            outputWidth: 16,
            outputHeight: 16
        )
        try runtime.configure(changed)
        precondition(runtime.status == .ready)
        precondition(runtime.compileGeneration == 2)

        // Invalid configuration must fail closed and publish a failed state;
        // callers can then keep/restore the mpv GLSL path.
        let missing = Anime4KMetalRuntimeConfiguration(
            shaderPaths: [root.appendingPathComponent("missing.glsl").path],
            pipelineHash: "missing",
            sourceWidth: 8,
            sourceHeight: 8,
            outputWidth: 8,
            outputHeight: 8
        )
        do {
            try runtime.configure(missing)
            preconditionFailure("missing shader should fail configuration")
        } catch {
            guard case .failed = runtime.status else {
                preconditionFailure("failed configuration must publish failed status")
            }
        }

        // Reconfigure after failure and prove a real CVPixelBuffer can enter the
        // asynchronous Metal path without a steady-state blocking wait.
        try runtime.configure(first)
        let input = try makePixelBuffer(width: 8, height: 8)
        let completed = DispatchSemaphore(value: 0)
        var output: CVPixelBuffer?
        let submission = runtime.process(pixelBuffer: input) { result in
            output = result
            completed.signal()
        }
        precondition(submission == .submitted)
        precondition(
            completed.wait(timeout: .now() + 5) == .success,
            "Metal command buffer should complete asynchronously"
        )
        precondition(output != nil)
        precondition(CVPixelBufferGetWidth(output!) == 8)
        precondition(CVPixelBufferGetHeight(output!) == 8)

        runtime.disable()
        precondition(runtime.status == .disabled)
        precondition(
            runtime.process(pixelBuffer: input) { _ in
                preconditionFailure("disabled runtime must not schedule GPU work")
            } == .bypassed
        )

        print("Anime4KMetalRuntimeTests: PASS")
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
            throw RuntimeTestError.pixelBufferCreation(result)
        }
        return pixelBuffer
    }
}

enum RuntimeTestError: Error {
    case pixelBufferCreation(CVReturn)
}
