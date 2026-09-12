import 'anime4k.dart';

/// Renderer/backend currently responsible for Anime4K processing.
enum Anime4kBackend { mpvGlsl, metal, metalEco }

/// Native Apple Metal availability/result used to decide whether mpv must own
/// the Anime4K pipeline instead. HDR is kept explicit so AKP-15 can fail closed
/// without ever allowing both backends to process the same frame.
enum Anime4kNativeMetalState { unavailable, ready, failed, unsupportedHdr }

class Anime4kBackendRoute {
  const Anime4kBackendRoute({
    required this.backend,
    required this.enableMetal,
    required this.enableMpvShaders,
  });

  final Anime4kBackend backend;
  final bool enableMetal;
  final bool enableMpvShaders;
}

/// Selects exactly one Anime4K backend for a resolved pipeline.
///
/// Apple may use native Metal only while that backend is explicitly ready.
/// Any unavailable/failed/unsupported-HDR state falls back to the already
/// resolved mpv GLSL pipeline. Other platforms retain the existing mpv path.
Anime4kBackendRoute resolveAnime4kBackendRoute({
  required bool isApplePlatform,
  required bool anime4kEnabled,
  required bool hasResolvedPipeline,
  required Anime4kNativeMetalState metalState,
}) {
  if (!anime4kEnabled || !hasResolvedPipeline) {
    return const Anime4kBackendRoute(
      backend: Anime4kBackend.mpvGlsl,
      enableMetal: false,
      enableMpvShaders: false,
    );
  }

  if (isApplePlatform && metalState == Anime4kNativeMetalState.ready) {
    return const Anime4kBackendRoute(
      backend: Anime4kBackend.metal,
      enableMetal: true,
      enableMpvShaders: false,
    );
  }

  return const Anime4kBackendRoute(
    backend: Anime4kBackend.mpvGlsl,
    enableMetal: false,
    enableMpvShaders: true,
  );
}

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

Anime4kQuality _oneTierHigher(Anime4kQuality quality) {
  final index = Anime4kQuality.values.indexOf(quality);
  if (index < 0 || index >= Anime4kQuality.values.length - 1) {
    return Anime4kQuality.ul;
  }
  return Anime4kQuality.values[index + 1];
}

/// Stateful Apple Eco/Auto governor.
///
/// Manual mode bypasses this state entirely. Eco requires sustained pressure
/// before lowering quality, then enforces a cooldown so one bad burst cannot
/// cascade through several tiers. Recovery is intentionally slower and moves
/// one tier at a time, never above the viewer's requested quality ceiling.
class Anime4kAdaptivePolicy {
  Anime4kAdaptivePolicy({
    this.downgradeSamples = 3,
    this.recoverySamples = 8,
    this.cooldownSamples = 4,
  }) {
    if (downgradeSamples <= 0 || recoverySamples <= 0 || cooldownSamples < 0) {
      throw ArgumentError('Anime4K adaptive sample windows must be positive');
    }
  }

  final int downgradeSamples;
  final int recoverySamples;
  final int cooldownSamples;

  Anime4kQuality _effectiveQuality = Anime4kQuality.s;
  bool _initialized = false;
  bool _bypass = false;
  int _unhealthyStreak = 0;
  int _healthyStreak = 0;
  int _cooldownRemaining = 0;

  Anime4kQuality get effectiveQuality => _effectiveQuality;
  bool get bypass => _bypass;

  Anime4kEffectivePlan update({
    required bool ecoEnabled,
    required Anime4kMode mode,
    required Anime4kQuality requestedQuality,
    required Anime4kThermalLevel thermalLevel,
    required bool lowPowerMode,
    required double rollingFrameTimeMs,
    required double frameBudgetMs,
    required int lateOrDroppedFrames,
  }) {
    if (!_initialized) {
      _effectiveQuality = requestedQuality;
      _initialized = true;
    }

    // A viewer lowering the manual ceiling takes effect immediately. Raising
    // it while Eco is active still recovers gradually through the normal path.
    if (Anime4kQuality.values.indexOf(_effectiveQuality) >
        Anime4kQuality.values.indexOf(requestedQuality)) {
      _effectiveQuality = requestedQuality;
    }

    if (!ecoEnabled) {
      _effectiveQuality = requestedQuality;
      _bypass = false;
      _unhealthyStreak = 0;
      _healthyStreak = 0;
      _cooldownRemaining = 0;
      return Anime4kEffectivePlan(
        mode: mode,
        effectiveQuality: requestedQuality,
        bypass: false,
        reduceLateStages: false,
      );
    }

    if (thermalLevel == Anime4kThermalLevel.critical) {
      _effectiveQuality = Anime4kQuality.s;
      _bypass = true;
      _unhealthyStreak = 0;
      _healthyStreak = 0;
      _cooldownRemaining = 0;
      return Anime4kEffectivePlan(
        mode: mode,
        effectiveQuality: _effectiveQuality,
        bypass: true,
        reduceLateStages: true,
      );
    }

    final forcedLowWork =
        lowPowerMode || thermalLevel == Anime4kThermalLevel.serious;
    if (forcedLowWork) {
      _effectiveQuality = Anime4kQuality.s;
      _unhealthyStreak = 0;
      _healthyStreak = 0;
      _cooldownRemaining = 0;
      return Anime4kEffectivePlan(
        mode: mode,
        effectiveQuality: _effectiveQuality,
        // If critical thermal already forced a bypass, serious/low-power is
        // not yet healthy enough to declare recovery. Fresh serious/LP entry
        // runs S rather than bypassing.
        bypass: _bypass,
        reduceLateStages: true,
      );
    }

    final framePressure =
        frameBudgetMs > 0 && rollingFrameTimeMs >= frameBudgetMs * 0.8;
    final underPressure =
        thermalLevel == Anime4kThermalLevel.fair ||
        framePressure ||
        lateOrDroppedFrames > 0;

    if (_bypass) {
      if (underPressure) {
        _healthyStreak = 0;
      } else {
        _healthyStreak += 1;
        if (_healthyStreak >= recoverySamples) {
          _bypass = false;
          _healthyStreak = 0;
          _cooldownRemaining = 0;
        }
      }
      return Anime4kEffectivePlan(
        mode: mode,
        effectiveQuality: _effectiveQuality,
        bypass: _bypass,
        reduceLateStages: true,
      );
    }

    if (_cooldownRemaining > 0) {
      _cooldownRemaining -= 1;
      _unhealthyStreak = 0;
      _healthyStreak = 0;
    } else if (underPressure) {
      _healthyStreak = 0;
      _unhealthyStreak += 1;
      if (_unhealthyStreak >= downgradeSamples) {
        _effectiveQuality = _oneTierLower(_effectiveQuality);
        _unhealthyStreak = 0;
        _cooldownRemaining = cooldownSamples;
      }
    } else {
      _unhealthyStreak = 0;
      if (_effectiveQuality != requestedQuality) {
        _healthyStreak += 1;
        if (_healthyStreak >= recoverySamples) {
          final recovered = _oneTierHigher(_effectiveQuality);
          final recoveredIndex = Anime4kQuality.values.indexOf(recovered);
          final requestedIndex = Anime4kQuality.values.indexOf(requestedQuality);
          _effectiveQuality = recoveredIndex > requestedIndex
              ? requestedQuality
              : recovered;
          _healthyStreak = 0;
          _cooldownRemaining = cooldownSamples;
        }
      } else {
        _healthyStreak = 0;
      }
    }

    final reduceLateStages =
        _effectiveQuality == Anime4kQuality.s && underPressure;
    return Anime4kEffectivePlan(
      mode: mode,
      effectiveQuality: _effectiveQuality,
      bypass: false,
      reduceLateStages: reduceLateStages,
    );
  }
}

/// Produces the immediate work ceiling for Anime4K without mutating the
/// viewer's saved mode or quality.
///
/// Manual mode is deliberately boring: it returns exactly what the viewer
/// selected even under thermal pressure. [Anime4kAdaptivePolicy] owns the
/// stateful hysteresis/cooldown used by Apple Eco/Auto across samples.
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
