import Foundation

struct Anime4KMetalRuntimeTelemetry: Equatable {
    let averageFrameTimeMs: Double
    let p95FrameTimeMs: Double
    let processedFrames: Int
    let lateOrDroppedFrames: Int
}

/// Thread-confined rolling performance window. Anime4KMetalRuntime owns this
/// value behind its existing state lock, so sampling never adds another lock to
/// the per-frame render path.
struct Anime4KMetalTelemetryAccumulator {
    private let windowCapacity: Int
    private var frameTimesMs: [Double] = []
    private(set) var processedFrames = 0
    private(set) var lateOrDroppedFrames = 0

    init(windowCapacity: Int = 120) {
        precondition(windowCapacity > 0)
        self.windowCapacity = windowCapacity
        frameTimesMs.reserveCapacity(windowCapacity)
    }

    mutating func recordCompletedFrame(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        processedFrames += 1
        frameTimesMs.append(milliseconds)
        if frameTimesMs.count > windowCapacity {
            frameTimesMs.removeFirst(frameTimesMs.count - windowCapacity)
        }
    }

    mutating func recordLateOrDroppedFrame() {
        lateOrDroppedFrames += 1
    }

    var snapshot: Anime4KMetalRuntimeTelemetry {
        guard !frameTimesMs.isEmpty else {
            return Anime4KMetalRuntimeTelemetry(
                averageFrameTimeMs: 0,
                p95FrameTimeMs: 0,
                processedFrames: processedFrames,
                lateOrDroppedFrames: lateOrDroppedFrames
            )
        }

        let average = frameTimesMs.reduce(0, +) / Double(frameTimesMs.count)
        let sorted = frameTimesMs.sorted()
        let p95Index = max(
            0,
            min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        )
        return Anime4KMetalRuntimeTelemetry(
            averageFrameTimeMs: average,
            p95FrameTimeMs: sorted[p95Index],
            processedFrames: processedFrames,
            lateOrDroppedFrames: lateOrDroppedFrames
        )
    }
}
