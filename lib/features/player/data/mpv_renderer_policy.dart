/// The mpv video-output policy used by AnimeWitcher.
///
/// mpv v0.41 recommends gpu-next and accepts a comma-separated priority list
/// for output-driver fallback. Android's media_kit controller owns a real mpv
/// video-output surface, so it can use that list directly. Native media_kit
/// controllers on desktop and Apple render through the libmpv render API;
/// keeping vo=libmpv there is required for the texture/Metal bridge and is
/// intentionally not replaced by a windowed VO.
class MpvRendererPolicy {
  MpvRendererPolicy._();

  static const String primary = 'gpu-next';
  static const String fallback = 'gpu';
  static const String androidVideoOutput = '$primary,$fallback';
  static const String mediaKitRenderApiVideoOutput = 'libmpv';

  static String outputForPlatform({required bool isAndroid}) {
    return isAndroid ? androidVideoOutput : mediaKitRenderApiVideoOutput;
  }

  /// Explicit A/B output for diagnostics and rollback on direct-VO platforms.
  static String diagnosticOutput({required bool useFallback}) {
    return useFallback ? fallback : primary;
  }
}
