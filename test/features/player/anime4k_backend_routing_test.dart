import 'package:animewitcher/features/player/data/anime4k_performance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K Apple backend routing', () {
    test('ready Metal route never enables mpv GLSL at the same time', () {
      final route = resolveAnime4kBackendRoute(
        isApplePlatform: true,
        anime4kEnabled: true,
        hasResolvedPipeline: true,
        metalState: Anime4kNativeMetalState.ready,
      );

      expect(route.backend, Anime4kBackend.metal);
      expect(route.enableMetal, isTrue);
      expect(route.enableMpvShaders, isFalse);
    });

    for (final state in <Anime4kNativeMetalState>[
      Anime4kNativeMetalState.unavailable,
      Anime4kNativeMetalState.failed,
      Anime4kNativeMetalState.unsupportedHdr,
    ]) {
      test('Apple $state falls back to the exact resolved GLSL pipeline', () {
        final route = resolveAnime4kBackendRoute(
          isApplePlatform: true,
          anime4kEnabled: true,
          hasResolvedPipeline: true,
          metalState: state,
        );

        expect(route.backend, Anime4kBackend.mpvGlsl);
        expect(route.enableMetal, isFalse);
        expect(route.enableMpvShaders, isTrue);
      });
    }

    test('turning Anime4K off clears both processing paths', () {
      final route = resolveAnime4kBackendRoute(
        isApplePlatform: true,
        anime4kEnabled: false,
        hasResolvedPipeline: true,
        metalState: Anime4kNativeMetalState.ready,
      );

      expect(route.enableMetal, isFalse);
      expect(route.enableMpvShaders, isFalse);
    });

    test('non-Apple platforms keep the existing mpv GLSL route', () {
      final route = resolveAnime4kBackendRoute(
        isApplePlatform: false,
        anime4kEnabled: true,
        hasResolvedPipeline: true,
        metalState: Anime4kNativeMetalState.ready,
      );

      expect(route.backend, Anime4kBackend.mpvGlsl);
      expect(route.enableMetal, isFalse);
      expect(route.enableMpvShaders, isTrue);
    });

    test('an empty resolved pipeline cannot claim either backend is active', () {
      final route = resolveAnime4kBackendRoute(
        isApplePlatform: true,
        anime4kEnabled: true,
        hasResolvedPipeline: false,
        metalState: Anime4kNativeMetalState.ready,
      );

      expect(route.enableMetal, isFalse);
      expect(route.enableMpvShaders, isFalse);
    });
  });
}
