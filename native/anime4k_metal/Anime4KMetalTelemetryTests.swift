import Foundation

@main
struct Anime4KMetalTelemetryTests {
    static func main() {
        var telemetry = Anime4KMetalTelemetryAccumulator(windowCapacity: 4)

        let empty = telemetry.snapshot
        precondition(empty.averageFrameTimeMs == 0)
        precondition(empty.p95FrameTimeMs == 0)
        precondition(empty.processedFrames == 0)
        precondition(empty.lateOrDroppedFrames == 0)

        telemetry.recordCompletedFrame(milliseconds: 4)
        telemetry.recordCompletedFrame(milliseconds: 7)
        telemetry.recordCompletedFrame(milliseconds: 10)
        telemetry.recordCompletedFrame(milliseconds: 15)

        var snapshot = telemetry.snapshot
        precondition(snapshot.processedFrames == 4)
        precondition(abs(snapshot.averageFrameTimeMs - 9.0) < 0.0001)
        precondition(abs(snapshot.p95FrameTimeMs - 15.0) < 0.0001)

        // The rolling window must discard the oldest sample without resetting
        // the lifetime processed-frame counter used by diagnostics.
        telemetry.recordCompletedFrame(milliseconds: 5)
        snapshot = telemetry.snapshot
        precondition(snapshot.processedFrames == 5)
        precondition(abs(snapshot.averageFrameTimeMs - 9.25) < 0.0001)
        precondition(abs(snapshot.p95FrameTimeMs - 15.0) < 0.0001)

        telemetry.recordLateOrDroppedFrame()
        telemetry.recordLateOrDroppedFrame()
        snapshot = telemetry.snapshot
        precondition(snapshot.lateOrDroppedFrames == 2)

        print("Anime4KMetalTelemetryTests: PASS")
    }
}
