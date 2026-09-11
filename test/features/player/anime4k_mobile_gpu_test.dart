import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K mobile GPU availability', () {
    test('native mobile playback can offer Anime4K', () {
      expect(
        anime4kAvailableOn(isNativePlatform: true, usingAdaptiveBackend: false),
        isTrue,
        reason:
            'Android/iOS use media_kit NativePlayer/libmpv GPU rendering, so '
            'mobile must not be rejected only because it is not desktop.',
      );
    });

    test('adaptive video_view playback still cannot offer Anime4K', () {
      expect(
        anime4kAvailableOn(isNativePlatform: true, usingAdaptiveBackend: true),
        isFalse,
      );
    });

    test('native Apple Metal renderer is shader-capable', () {
      expect(
        anime4kGpuRendererSupportsShaders('metal'),
        isTrue,
        reason:
            'The Apple backend executes Anime4K as Metal compute passes, so '
            'it must be treated as a real GPU shader renderer rather than a '
            'no-op or software fallback.',
      );
    });
  });
}
