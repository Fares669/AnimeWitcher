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
  });
}
