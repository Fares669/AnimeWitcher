import 'anime4k.dart';
import 'anime4k_metal_bridge.dart';
import 'anime4k_performance.dart';

/// One low-frequency Eco sample translated into both an actionable plan and a
/// diagnostics snapshot. Native counters are cumulative; [lateOrDroppedDelta]
/// is the new pressure observed since the previous sample only.
class Anime4kEcoDecision {
  const Anime4kEcoDecision({
    required this.plan,
    required this.snapshot,
    required this.lateOrDroppedDelta,
  });

  final Anime4kEffectivePlan plan;
  final Anime4kPerformanceSnapshot snapshot;
  final int lateOrDroppedDelta;
}

/// Converts native Metal telemetry into stable adaptive-policy samples.
///
/// This class deliberately owns no timer and performs no FFI. The player can
/// sample it at a low cadence while all hysteresis/cooldown behavior remains
/// deterministic and unit-testable on every CI platform.
class Anime4kEcoGovernor {
  Anime4kEcoGovernor({Anime4kAdaptivePolicy? policy})
    : _policy = policy ?? Anime4kAdaptivePolicy();

  final Anime4kAdaptivePolicy _policy;
  int? _previousLateOrDroppedFrames;

  Anime4kEcoDecision sample({
    required bool ecoEnabled,
    required Anime4kMode mode,
    required Anime4kQuality requestedQuality,
    required Anime4kMetalTelemetry telemetry,
    required double frameBudgetMs,
    required Anime4kProcessingDimensions source,
    required Anime4kProcessingDimensions output,
  }) {
    final currentLate = telemetry.lateOrDroppedFrames;
    final previousLate = _previousLateOrDroppedFrames;
    final lateDelta = previousLate == null
        ? currentLate
        : currentLate >= previousLate
        ? currentLate - previousLate
        // A newly configured native runtime restarts its cumulative counters.
        // Treat the new value as fresh pressure instead of producing a
        // negative delta or carrying the old runtime's history forward.
        : currentLate;
    _previousLateOrDroppedFrames = currentLate;

    final rollingFrameTime = telemetry.p95FrameTimeMs > 0
        ? telemetry.p95FrameTimeMs
        : telemetry.averageFrameTimeMs;
    final plan = _policy.update(
      ecoEnabled: ecoEnabled,
      mode: mode,
      requestedQuality: requestedQuality,
      thermalLevel: telemetry.thermalLevel,
      lowPowerMode: telemetry.lowPowerMode,
      rollingFrameTimeMs: rollingFrameTime,
      frameBudgetMs: frameBudgetMs,
      lateOrDroppedFrames: lateDelta,
    );

    final snapshot = Anime4kPerformanceSnapshot(
      backend: ecoEnabled ? Anime4kBackend.metalEco : Anime4kBackend.metal,
      requestedMode: mode,
      requestedQuality: requestedQuality,
      effectiveQuality: plan.effectiveQuality,
      inputWidth: source.width,
      inputHeight: source.height,
      processingWidth: output.width,
      processingHeight: output.height,
      averageFrameTimeMs: telemetry.averageFrameTimeMs,
      p95FrameTimeMs: telemetry.p95FrameTimeMs,
      processedFrames: telemetry.processedFrames,
      // AKP-14 will populate native duplicate-frame accounting. Until then,
      // exposing zero is explicit and avoids conflating intentional Eco bypass
      // or backpressure with duplicate display refreshes.
      skippedDuplicateFrames: 0,
      droppedOrLateFrames: telemetry.lateOrDroppedFrames,
      thermalLevel: telemetry.thermalLevel,
      lowPowerMode: telemetry.lowPowerMode,
    );

    return Anime4kEcoDecision(
      plan: plan,
      snapshot: snapshot,
      lateOrDroppedDelta: lateDelta,
    );
  }
}

/// Frame time available to Anime4K at the source cadence.
///
/// mpv may briefly report no FPS while a file is opening or a nonsensical
/// value on broken streams. Eco uses a conservative 60 Hz budget in those
/// cases rather than allowing an invalid value to disable pressure detection.
double anime4kFrameBudgetMsFromFps(double? fps) {
  if (fps == null || !fps.isFinite || fps <= 0 || fps > 240) {
    return 1000 / 60;
  }
  return 1000 / fps;
}
