import CoreVideo
import Foundation
import Metal

@main
struct Anime4KMediaKitBridgeTests {
    static func main() throws {
        testPublicationLedgerBoundsEndToEndOwnershipPerPlayer()
        try testActualPixelBufferRetargetsProcessingDimensions()
        print("Anime4KMediaKitBridgeTests: PASS")
    }

    private static func testPublicationLedgerBoundsEndToEndOwnershipPerPlayer() {
        var ledger = Anime4KMetalPublicationLedger(capacity: 2)
        let firstPlayer: UInt = 101
        let secondPlayer: UInt = 202

        precondition(ledger.reserve(for: firstPlayer))
        precondition(ledger.reserve(for: firstPlayer))
        precondition(
            !ledger.reserve(for: firstPlayer),
            "a player must bypass instead of growing beyond its publication capacity"
        )
        precondition(ledger.inflightCount(for: firstPlayer) == 2)

        // Capacity is per player/runtime handle. One saturated player must not
        // disable Anime4K for another independent player.
        precondition(ledger.reserve(for: secondPlayer))
        precondition(ledger.inflightCount(for: secondPlayer) == 1)

        ledger.release(for: firstPlayer)
        precondition(ledger.inflightCount(for: firstPlayer) == 1)
        precondition(ledger.reserve(for: firstPlayer))
        precondition(ledger.inflightCount(for: firstPlayer) == 2)

        ledger.release(for: firstPlayer)
        ledger.release(for: firstPlayer)
        ledger.release(for: firstPlayer)
        precondition(
            ledger.inflightCount(for: firstPlayer) == 0,
            "duplicate/stale publication completion must never underflow"
        )

        ledger.release(for: secondPlayer)
        precondition(ledger.inflightCount(for: secondPlayer) == 0)
    }

    private static func testActualPixelBufferRetargetsProcessingDimensions() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            preconditionFailure("Apple CI must expose a Metal device")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "anime4k-media-kit-dimensions-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
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

        // The CVPixelBuffer produced by media_kit is the authoritative runtime
        // processing size. A stale/larger Dart estimate must be retargeted
        // before Anime4K allocates output textures and performs the final blit.
        let frame = try makePixelBuffer(width: 16, height: 9)
        let completed = DispatchSemaphore(value: 0)
        precondition(
            bridge.process(
                handle: handle,
                pixelBuffer: frame,
                completion: { completed.signal() }
            ),
            "configured bridge should own frame publication"
        )
        precondition(
            completed.wait(timeout: .now() + 5) == .success,
            "retargeted Anime4K frame must publish asynchronously"
        )

        guard let active = bridge.activeConfiguration(handle: handle) else {
            preconditionFailure("configured bridge must expose active dimensions")
        }
        precondition(active.sourceWidth == 32)
        precondition(active.sourceHeight == 18)
        precondition(active.outputWidth == 16)
        precondition(active.outputHeight == 9)
        precondition(
            bridge.runtimeStatus(handle: handle) == .ready,
            "actual output-size retargeting must not disable the Metal backend"
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
            throw Anime4KMediaKitBridgeTestError.pixelBufferCreation(result)
        }
        return pixelBuffer
    }
}

enum Anime4KMediaKitBridgeTestError: Error {
    case pixelBufferCreation(CVReturn)
}
