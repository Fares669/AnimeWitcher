import Foundation

@main
struct Anime4KMetalTelemetryTests {
    static func main() {
        testRollingTelemetry()
        testSourceFrameCadence(sourceFrames: 24, displayRefreshFramesPerSourceFrame: 5)
        testSourceFrameCadence(sourceFrames: 30, displayRefreshFramesPerSourceFrame: 4)
        testRuntimeIsolationAndReset()

        print("Anime4KMetalTelemetryTests: PASS")
    }

    private static func testRollingTelemetry() {
        var telemetry = Anime4KMetalTelemetryAccumulator(windowCapacity: 4)

        let empty = telemetry.snapshot
        precondition(empty.averageFrameTimeMs == 0)
        precondition(empty.p95FrameTimeMs == 0)
        precondition(empty.processedFrames == 0)
        precondition(empty.skippedDuplicateFrames == 0)
        precondition(empty.lateOrDroppedFrames == 0)

        telemetry.recordCompletedFrame(milliseconds: 4)
        telemetry.recordCompletedFrame(milliseconds: 7)
        telemetry.recordCompletedFrame(milliseconds: 10)
        telemetry.recordCompletedFrame(milliseconds: 15)

        var snapshot = telemetry.snapshot
        precondition(snapshot.processedFrames == 4)
        precondition(snapshot.skippedDuplicateFrames == 0)
        precondition(abs(snapshot.averageFrameTimeMs - 9.0) < 0.0001)
        precondition(abs(snapshot.p95FrameTimeMs - 15.0) < 0.0001)

        // The rolling window must discard the oldest sample without resetting
        // the lifetime processed-frame counter used by diagnostics.
        telemetry.recordCompletedFrame(milliseconds: 5)
        snapshot = telemetry.snapshot
        precondition(snapshot.processedFrames == 5)
        precondition(abs(snapshot.averageFrameTimeMs - 9.25) < 0.0001)
        precondition(abs(snapshot.p95FrameTimeMs - 15.0) < 0.0001)

        telemetry.recordSkippedDuplicateFrame()
        telemetry.recordSkippedDuplicateFrame()
        telemetry.recordSkippedDuplicateFrame()
        snapshot = telemetry.snapshot
        precondition(snapshot.processedFrames == 5)
        precondition(snapshot.skippedDuplicateFrames == 3)
        precondition(snapshot.lateOrDroppedFrames == 0)

        telemetry.recordLateOrDroppedFrame()
        telemetry.recordLateOrDroppedFrame()
        snapshot = telemetry.snapshot
        precondition(snapshot.skippedDuplicateFrames == 3)
        precondition(snapshot.lateOrDroppedFrames == 2)
    }

    private static func testSourceFrameCadence(
        sourceFrames: Int,
        displayRefreshFramesPerSourceFrame: Int
    ) {
        precondition(sourceFrames > 0)
        precondition(displayRefreshFramesPerSourceFrame > 0)

        var ledger = Anime4KFrameGenerationLedger()
        let runtimeKey: UInt = 0xA14
        var processedFrames = 0
        var skippedDuplicates = 0

        for generation in 1...sourceFrames {
            for _ in 0..<displayRefreshFramesPerSourceFrame {
                if ledger.claim(
                    frameGeneration: UInt64(generation),
                    for: runtimeKey
                ) {
                    processedFrames += 1
                } else {
                    skippedDuplicates += 1
                }
            }
        }

        // 24 fps on 120 Hz presents each produced frame five times and 30 fps
        // presents it four times. Anime4K must still run exactly once per new
        // source generation rather than once per display refresh.
        precondition(processedFrames == sourceFrames)
        precondition(
            skippedDuplicates == sourceFrames * (displayRefreshFramesPerSourceFrame - 1)
        )
    }

    private static func testRuntimeIsolationAndReset() {
        var ledger = Anime4KFrameGenerationLedger()
        let firstRuntime: UInt = 0xA141
        let secondRuntime: UInt = 0xA142

        precondition(ledger.claim(frameGeneration: 7, for: firstRuntime))
        precondition(!ledger.claim(frameGeneration: 7, for: firstRuntime))
        precondition(ledger.claim(frameGeneration: 7, for: secondRuntime))

        ledger.reset(for: firstRuntime)
        precondition(ledger.claim(frameGeneration: 7, for: firstRuntime))
    }
}