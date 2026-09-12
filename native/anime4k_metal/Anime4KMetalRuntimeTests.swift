import CoreVideo
import Foundation
import Metal

@main
struct Anime4KMetalRuntimeTests {
    static func main() throws {
        try testSlotLedgerAcrossReconfiguration()

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

        try testPrecisionIsPartOfConfigurationAndNumericallyBounded(
            device: device,
            root: root
        )
        try testRuntimeLifetimeUntilGPUCompletion(
            device: device,
            shaderPath: shaderURL.path
        )

        print("Anime4KMetalRuntimeTests: PASS")
    }

    private static func testSlotLedgerAcrossReconfiguration() throws {
        var ledger = Anime4KMetalSlotLedger(capacity: 2)
        let first = ledger.reserve()
        let second = ledger.reserve()
        precondition(first != nil && second != nil)
        precondition(ledger.reserve() == nil, "in-flight capacity must be bounded")
        precondition(ledger.inflightCount == 2)
        precondition(ledger.availableCount == 0)

        // A new configuration must not make old GPU-owned slots available.
        ledger.advanceEpoch()
        precondition(ledger.reserve() == nil)
        precondition(ledger.inflightCount == 2)

        ledger.release(first!)
        precondition(ledger.inflightCount == 1)
        precondition(ledger.availableCount == 1)
        let newEpochLease = ledger.reserve()
        precondition(newEpochLease != nil)
        precondition(newEpochLease!.epoch == ledger.epoch)

        // A duplicate/stale completion cannot duplicate the same slot.
        ledger.release(first!)
        precondition(ledger.inflightCount == 2)
        precondition(ledger.availableCount == 0)

        ledger.release(second!)
        ledger.release(newEpochLease!)
        precondition(ledger.inflightCount == 0)
        precondition(ledger.availableCount == 2)
    }

    private static func testPrecisionIsPartOfConfigurationAndNumericallyBounded(
        device: MTLDevice,
        root: URL
    ) throws {
        let shaderURL = root.appendingPathComponent("precision.glsl")
        try """
        //!DESC Anime4K-Runtime-Precision
        //!HOOK MAIN
        //!BIND MAIN
        vec4 hook() {
            vec4 color = MAIN_tex(MAIN_pos);
            return color * vec4(0.731, 0.617, 0.853, 1.0)
                + vec4(0.017, 0.029, 0.011, 0.0);
        }
        """.write(to: shaderURL, atomically: true, encoding: .utf8)

        let runtime = try Anime4KMetalRuntime(device: device, maxInflightFrames: 1)
        let input = try makePixelBuffer(width: 16, height: 16)
        fillGradient(input)

        let fp32 = Anime4KMetalRuntimeConfiguration(
            shaderPaths: [shaderURL.path],
            pipelineHash: "precision",
            sourceWidth: 16,
            sourceHeight: 16,
            outputWidth: 16,
            outputHeight: 16,
            precision: .fp32
        )
        try runtime.configure(fp32)
        let fp32Output = try processAndWait(runtime: runtime, input: input)
        let fp32Bytes = pixelBytes(fp32Output)
        precondition(runtime.compileGeneration == 1)

        let mixed = Anime4KMetalRuntimeConfiguration(
            shaderPaths: [shaderURL.path],
            pipelineHash: "precision",
            sourceWidth: 16,
            sourceHeight: 16,
            outputWidth: 16,
            outputHeight: 16,
            precision: .mixedFP16
        )
        try runtime.configure(mixed)
        let mixedOutput = try processAndWait(runtime: runtime, input: input)
        let mixedBytes = pixelBytes(mixedOutput)
        precondition(
            runtime.compileGeneration == 2,
            "precision must participate in the compiled pipeline cache key"
        )
        precondition(fp32Bytes.count == mixedBytes.count)

        var maxDelta = 0
        for index in fp32Bytes.indices {
            maxDelta = max(
                maxDelta,
                abs(Int(fp32Bytes[index]) - Int(mixedBytes[index]))
            )
        }
        precondition(
            maxDelta <= 2,
            "mixed FP16 drift exceeded the 2/255 BGRA acceptance bound: \(maxDelta)"
        )
    }

    private static func testRuntimeLifetimeUntilGPUCompletion(
        device: MTLDevice,
        shaderPath: String
    ) throws {
        var runtime: Anime4KMetalRuntime? = try Anime4KMetalRuntime(
            device: device,
            maxInflightFrames: 1
        )
        let configuration = Anime4KMetalRuntimeConfiguration(
            shaderPaths: [shaderPath],
            pipelineHash: "lifetime",
            sourceWidth: 2048,
            sourceHeight: 2048,
            outputWidth: 2048,
            outputHeight: 2048
        )
        try runtime!.configure(configuration)
        let input = try makePixelBuffer(width: 2048, height: 2048)
        let completed = DispatchSemaphore(value: 0)
        let submission = runtime!.process(pixelBuffer: input) { result in
            precondition(CVPixelBufferGetWidth(result) == 2048)
            completed.signal()
        }
        precondition(submission == .submitted)

        // The bridge may drop its last strong reference on disable/reconfigure.
        // The command-buffer completion must still keep the runtime and input /
        // output IOSurfaces alive long enough to deliver publication callback.
        runtime = nil
        precondition(
            completed.wait(timeout: .now() + 10) == .success,
            "in-flight Metal work must deliver completion after owner release"
        )
    }

    private static func processAndWait(
        runtime: Anime4KMetalRuntime,
        input: CVPixelBuffer
    ) throws -> CVPixelBuffer {
        let completed = DispatchSemaphore(value: 0)
        var output: CVPixelBuffer?
        let submission = runtime.process(pixelBuffer: input) { result in
            output = result
            completed.signal()
        }
        precondition(submission == .submitted)
        precondition(completed.wait(timeout: .now() + 5) == .success)
        guard let output else { throw RuntimeTestError.missingOutput }
        return output
    }

    private static func fillGradient(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let offset = x * 4
                row[offset] = UInt8((x * 13 + y * 7) % 256)
                row[offset + 1] = UInt8((x * 5 + y * 17) % 256)
                row[offset + 2] = UInt8((x * 19 + y * 3) % 256)
                row[offset + 3] = 255
            }
        }
    }

    private static func pixelBytes(_ pixelBuffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        return Array(
            UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self),
                count: height * stride
            )
        )
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
    case missingOutput
}
