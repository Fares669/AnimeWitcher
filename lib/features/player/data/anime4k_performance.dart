import 'anime4k.dart';

/// Renderer/backend currently responsible for Anime4K processing.
enum Anime4kBackend { mpvGlsl, metal, metalEco }

/// Platform-neutral thermal pressure used by the adaptive Apple policy.
///
/// The native Apple layer will map ProcessInfo.ThermalState into this enum;
/// keeping the policy pure makes it deterministic and unit-testable on every
/// CI platform.
enum Anime4kThermalLevel { nominal, fair, serious, critical }

/// Pixel dimensions used by the Anime4K processing graph.
class Anime4kProcessingDimensions {
  const Anime4kProcessingDimensions({
    required this.width,
    required this.height,
  });

  final int width;
  final int height;

  double get aspectRatio => width / height;
}

/// Resolves the smallest stable Anime4K target that covers the visible video.
///
/// The target aspect ratio always follows the source rather than the widget,
/// because letterboxing/pillarboxing must not stretch Anime4K's intermediate
/// textures. Dimensions are rounded down to even pixels so common video/GPU
/// surfaces remain friendly to subsequent encoders and texture copies.
///
/// A small drawable-size wobble is treated as layout jitter: when the newly
/// resolved target is within 2% of the previous target and both represent the
/// same source aspect, the previous allocation is reused. Material changes
/// (for example fullscreen 4K -> a 720p window) rebuild immediately. A
/// transient zero-size layout similarly preserves the previous target instead
/// of tearing down/rebuilding the Metal working set.
Anime4kProcessingDimensions resolveAnime4kProcessingDimensions({
  required int sourceWidth,
  required int sourceHeight,
  required int drawableWidth,
  required int drawableHeight,
  Anime4kProcessingDimensions? previous,
}) {
  if (sourceWidth <= 0 || sourceHeight <= 0) {
    throw ArgumentError('Anime4K source dimensions must be positive');
  }

  if (drawableWidth <= 0 || drawableHeight <= 0) {
    return previous ??
        Anime4kProcessingDimensions(
          width: _floorEven(sourceWidth),
          height: _floorEven(sourceHeight),
        );
  }

  final sourceAspect = sourceWidth / sourceHeight;
  final drawableAspect = drawableWidth / drawableHeight;
  final maxWidth = _floorEven(drawableWidth);
  final maxHeight = _floorEven(drawableHeight);

  final Anime4kProcessingDimensions candidate;
  if (sourceAspect >= drawableAspect) {
    final width = maxWidth;
    final height = _floorEven((width / sourceAspect).floor());
    candidate = Anime4kProcessingDimensions(width: width, height: height);
  } else {
    final height = maxHeight;
    final width = _floorEven((height * sourceAspect).floor());
    candidate = Anime4kProcessingDimensions(width: width, height: height);
  }

  if (previous != null &&
      _sameSourceAspect(previous.aspectRatio, sourceAspect) &&
      _withinLayoutJitter(previous.width, candidate.width) &&
      _withinLayoutJitter(previous.height, candidate.height)) {
    return previous;
  }

  return candidate;
}

int _floorEven(int value) {
  final positive = value < 2 ? 2 : value;
  return positive.isEven ? positive : positive - 1;
}

bool _sameSourceAspect(double previous, double source) {
  return (previous - source).abs() / source <= 0.01;
}

bool _withinLayoutJitter(int previous, int candidate) {
  return (previous - candidate).abs() / previous <= 0.02;
}

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
