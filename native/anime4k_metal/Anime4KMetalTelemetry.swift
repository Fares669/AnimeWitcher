import Foundation

struct Anime4KMetalRuntimeTelemetry: Equatable {
    let averageFrameTimeMs: Double
    let p95FrameTimeMs: Double
    let processedFrames: Int
    let skippedDuplicateFrames: Int
    let lateOrDroppedFrames: Int
}

/// Tracks the last produced-frame generation independently for each player.
/// TextureHW assigns the generation before Anime4K so display refresh repeats
/// cannot multiply native inference work.
struct Anime4KFrameGenerationLedger {
    private var generationByRuntime: [UInt: UInt64] = [:]

    mutating func claim(frameGeneration: UInt64, for runtimeKey: UInt) -> Bool {
        guard generationByRuntime[runtimeKey] != frameGeneration else {
            return false
        }
        generationByRuntime[runtimeKey] = frameGeneration
        return true
    }

    mutating func reset(for runtimeKey: UInt) {
        generationByRuntime.removeValue(forKey: runtimeKey)
    }
}

/// Shared by the media_kit render patch and the C telemetry API. Keeping this
/// bookkeeping outside Anime4KMetalRuntime means a duplicate is rejected before
/// it can reserve a GPU/output slot while runtime ownership remains unchanged.
final class Anime4KFrameDedupRegistry {
    static let shared = Anime4KFrameDedupRegistry()

    private let lock = NSLock()
    private var generations = Anime4KFrameGenerationLedger()
    private var skippedByRuntime: [UInt: Int] = [:]

    private init() {}

    func claim(frameGeneration: UInt64, for runtimeKey: UInt) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generations.claim(
            frameGeneration: frameGeneration,
            for: runtimeKey
        ) else {
            skippedByRuntime[runtimeKey, default: 0] += 1
            return false
        }
        return true
    }

    func recordSkippedDuplicate(for runtimeKey: UInt) {
        lock.lock()
        skippedByRuntime[runtimeKey, default: 0] += 1
        lock.unlock()
    }

    func skippedDuplicateFrames(for runtimeKey: UInt) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return skippedByRuntime[runtimeKey, default: 0]
    }

    func reset(for runtimeKey: UInt) {
        lock.lock()
        generations.reset(for: runtimeKey)
        skippedByRuntime.removeValue(forKey: runtimeKey)
        lock.unlock()
    }
}

/// Thread-confined rolling performance window. Anime4KMetalRuntime owns this
/// value behind its existing state lock, so sampling never adds another lock to
/// the per-frame render path.
struct Anime4KMetalTelemetryAccumulator {
    private let windowCapacity: Int
    private var frameTimesMs: [Double] = []
    private(set) var processedFrames = 0
    private(set) var skippedDuplicateFrames = 0
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

    mutating func recordSkippedDuplicateFrame() {
        skippedDuplicateFrames += 1
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
                skippedDuplicateFrames: skippedDuplicateFrames,
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
            skippedDuplicateFrames: skippedDuplicateFrames,
            lateOrDroppedFrames: lateOrDroppedFrames
        )
    }
}
