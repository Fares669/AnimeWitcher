import CoreVideo
import Foundation
import Metal

@main
struct Anime4KMediaKitBridgeTests {
    static func main() throws {
        testPublicationLedgerBoundsEndToEndOwnershipPerPlayer()
        testFrameGenerationDeduplicatesPerPlayer()
        try testActualPixelBufferRetargetsProcessingDimensions()
        print("Anime4KMediaKitBridgeTests: PASS")
    }

    private static func testPublicationLedgerBoundsEndToEndOwnershipPerPlayer() {
        var ledger = Anime4KMetalPublicationLedger(capacity: 2)
        let firstPlayer: UInt = 101
        let secondPlayer: UInt = 202

        precondition(ledger.reserve(for: firstPlayer))
        precondition(ledger.reserve(for: firstPlayer))
        precondition(!ledger.reserve(for: firstPlayer))
        precondition(ledger.inflightCount(for: firstPlayer) == 2)
        precondition(ledger.reserve(for: secondPlayer))
        precondition(ledger.inflightCount(for: secondPlayer) == 1)
        ledger.release(for: firstPlayer)
        precondition(ledger.inflightCount(for: firstPlayer) == 1)
        precondition(ledger.reserve(for: firstPlayer))
        ledger.release(for: firstPlayer)
        ledger.release(for: firstPlayer)
        ledger.release(for: firstPlayer)
        precondition(ledger.inflightCount(for: firstPlayer) == 0)
        ledger.release(for: secondPlayer)
        precondition(ledger.inflightCount(for: secondPlayer) == 0)
    }

    private static func testFrameGenerationDeduplicatesPerPlayer() {
        var ledger = Anime4KFrameGenerationLedger()
        let firstPlayer: UInt = 101
        let secondPlayer: UInt = 202
        precondition(ledger.claim(frameGeneration: 1, for: firstPlayer))
        precondition(!ledger.claim(frameGeneration: 1, for: firstPlayer))
        precondition(ledger.claim(frameGeneration: 2, for: firstPlayer))
        precondition(ledger.claim(frameGeneration: 1, for: secondPlayer))
        precondition(!ledger.claim(frameGeneration: 1, for: secondPlayer))
        ledger.reset(for: firstPlayer)
        precondition(ledger.claim(frameGeneration: 1, for: firstPlayer))
    }

    private static func testActualPixelBufferRetargetsProcessingDimensions() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            preconditionFailure("Apple CI must expose a Metal device")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "anime4k-media-kit-dimensions-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let shaderURL = root.appendingPathComponent("identity.glsl")
        try """
        //!DESC Anime4K-Bridge-Identity
        //!HOOK MAIN
        //!BIND MAIN
        vec4 hook() {
            return MAIN_tex(MAIN_pos);
        }
        """.write(to: shaderURL, atomically: true, encoding: .utf8)

        let handle = OpaquePointer(bitPattern: UInt(0xA411))!
        let bridge = Anime4KMediaKitBridge.shared
        defer { bridge.disable(handle: handle) }

        try bridge.configure(
            handle: handle,
            configuration: Anime4KMetalRuntimeConfiguration(
                shaderPaths: [shaderURL.path],
                pipelineHash: "bridge-dimensions",
                sourceWidth: 32,
                sourceHeight: 18,
                outputWidth: 32,
                outputHeight: 18
            )
        )

        let frame = try makePixelBuffer(width: 16, height: 9)
        CVBufferSetAttachment(frame, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(frame, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        let completed = DispatchSemaphore(value: 0)
        precondition(
            bridge.process(handle: handle, pixelBuffer: frame, completion: { completed.signal() })
        )
        precondition(completed.wait(timeout: .now() + 5) == .success)

        guard let active = bridge.activeConfiguration(handle: handle) else {
            preconditionFailure("configured bridge must expose active dimensions")
        }
        precondition(active.sourceWidth == 32)
        precondition(active.sourceHeight == 18)
        precondition(active.outputWidth == 16)
        precondition(active.outputHeight == 9)
        precondition(bridge.runtimeStatus(handle: handle) == .ready)
        precondition(CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA)
        precondition(
            (CVBufferCopyAttachment(frame, kCVImageBufferColorPrimariesKey, nil) as? String) ==
                (kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        )
        precondition(
            (CVBufferCopyAttachment(frame, kCVImageBufferTransferFunctionKey, nil) as? String) ==
                (kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        )
        precondition(
            (CVBufferCopyAttachment(frame, kCVImageBufferYCbCrMatrixKey, nil) as? String) ==
                (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        )
    }

    private static func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
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
            throw Anime4KMediaKitBridgeTestError.pixelBufferCreation(result)
        }
        return pixelBuffer
    }
}

enum Anime4KMediaKitBridgeTestError: Error {
    case pixelBufferCreation(CVReturn)
}
