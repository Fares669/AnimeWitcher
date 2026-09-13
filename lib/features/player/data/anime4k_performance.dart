/// Renderer/backend currently responsible for Anime4K processing.
enum Anime4kBackend { mpvGlsl, metal }

/// Native Apple Metal availability/result used to decide whether mpv must own
/// the Anime4K pipeline instead. HDR stays explicit so the Apple safety gate
/// can fail closed without allowing both backends to process one frame.
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

/// Platform-neutral thermal state exposed by optional native telemetry.
enum Anime4kThermalLevel { nominal, fair, serious, critical }

class Anime4kProcessingDimensions {
  const Anime4kProcessingDimensions({
    required this.width,
    required this.height,
  });

  final int width;
  final int height;

  double get aspectRatio => width / height;
}

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
