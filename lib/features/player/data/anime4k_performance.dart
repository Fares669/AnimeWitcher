import 'anime4k.dart';

/// Renderer/backend currently responsible for Anime4K processing.
enum Anime4kBackend { mpvGlsl, metal, metalEco }

/// Platform-neutral thermal pressure used by the adaptive Apple policy.
///
/// The native Apple layer will map ProcessInfo.ThermalState into this enum;
/// keeping the policy pure makes it deterministic and unit-testable on every
/// CI platform.
enum Anime4kThermalLevel { nominal, fair, serious, critical }

/// The effective work Anime4K should perform for the current conditions.
class Anime4kEffectivePlan {
  const Anime4kEffectivePlan({
    required this.mode,
    required this.effectiveQuality,
    required this.bypass,
    required this.reduceLateStages,
  });

  /// Semantic Anime4K mode. Eco never changes this choice.
  final Anime4kMode mode;

  /// Quality actually allowed by the current policy.
  final Anime4kQuality effectiveQuality;

  /// Whether Anime4K should be temporarily bypassed.
  final bool bypass;

  /// Whether expensive work after the first upscale should be reduced.
  final bool reduceLateStages;
}

/// Debug/diagnostic snapshot for comparing requested and effective work.
///
/// This is intentionally a data object only. It is not analytics and does not
/// upload anything.
class Anime4kPerformanceSnapshot {
  const Anime4kPerformanceSnapshot({
    required this.backend,
    required this.requestedMode,
    required this.requestedQuality,
    required this.effectiveQuality,
    required this.inputWidth,
    required this.inputHeight,
    required this.processingWidth,
    required this.processingHeight,
    required this.averageFrameTimeMs,
    required this.p95FrameTimeMs,
    required this.processedFrames,
    required this.skippedDuplicateFrames,
    required this.droppedOrLateFrames,
    required this.thermalLevel,
    required this.lowPowerMode,
  });

  final Anime4kBackend backend;
  final Anime4kMode requestedMode;
  final Anime4kQuality requestedQuality;
  final Anime4kQuality effectiveQuality;
  final int inputWidth;
  final int inputHeight;
  final int processingWidth;
  final int processingHeight;
  final double averageFrameTimeMs;
  final double p95FrameTimeMs;
  final int processedFrames;
  final int skippedDuplicateFrames;
  final int droppedOrLateFrames;
  final Anime4kThermalLevel thermalLevel;
  final bool lowPowerMode;
}

Anime4kQuality _oneTierLower(Anime4kQuality quality) {
  final index = Anime4kQuality.values.indexOf(quality);
  if (index <= 0) return Anime4kQuality.s;
  return Anime4kQuality.values[index - 1];
}

/// Produces the work ceiling for Anime4K without mutating the viewer's saved
/// mode or quality.
///
/// Manual mode is deliberately boring: it returns exactly what the viewer
/// selected even under thermal pressure. Adaptive behavior exists only behind
/// Apple Eco/Auto. The caller supplies already-smoothed frame timing; later
/// runtime work will own hysteresis/cooldown and feed the stable value here.
Anime4kEffectivePlan planAnime4kPerformance({
  required bool ecoEnabled,
  required Anime4kMode mode,
  required Anime4kQuality requestedQuality,
  required Anime4kThermalLevel thermalLevel,
  required bool lowPowerMode,
  required double rollingFrameTimeMs,
  required double frameBudgetMs,
}) {
  if (!ecoEnabled) {
    return Anime4kEffectivePlan(
      mode: mode,
      effectiveQuality: requestedQuality,
      bypass: false,
      reduceLateStages: false,
    );
  }

  if (thermalLevel == Anime4kThermalLevel.critical) {
    return Anime4kEffectivePlan(
      mode: mode,
      effectiveQuality: Anime4kQuality.s,
      bypass: true,
      reduceLateStages: true,
    );
  }

  if (lowPowerMode || thermalLevel == Anime4kThermalLevel.serious) {
    return Anime4kEffectivePlan(
      mode: mode,
      effectiveQuality: Anime4kQuality.s,
      bypass: false,
      reduceLateStages: true,
    );
  }

  final underFramePressure =
      frameBudgetMs > 0 && rollingFrameTimeMs >= frameBudgetMs * 0.8;
  if (thermalLevel == Anime4kThermalLevel.fair || underFramePressure) {
    return Anime4kEffectivePlan(
      mode: mode,
      effectiveQuality: _oneTierLower(requestedQuality),
      bypass: false,
      reduceLateStages: false,
    );
  }

  return Anime4kEffectivePlan(
    mode: mode,
    effectiveQuality: requestedQuality,
    bypass: false,
    reduceLateStages: false,
  );
}
