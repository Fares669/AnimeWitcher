import 'package:animewitcher/features/player/data/anime4k_performance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K processing dimensions', () {
    test('fits 480p source to an iPhone portrait drawable without oversizing', () {
      final target = resolveAnime4kProcessingDimensions(
        sourceWidth: 854,
        sourceHeight: 480,
        drawableWidth: 1179,
        drawableHeight: 2556,
      );

      expect(target.width, 1178);
      expect(target.height, 662);
      expect(target.width, lessThanOrEqualTo(1179));
      expect(target.height, lessThanOrEqualTo(2556));
      expect(target.aspectRatio, closeTo(854 / 480, 0.01));
    });

    test('fits 720p source to an iPad portrait drawable', () {
      final target = resolveAnime4kProcessingDimensions(
        sourceWidth: 1280,
        sourceHeight: 720,
        drawableWidth: 2048,
        drawableHeight: 2732,
      );

      expect(target.width, 2048);
      expect(target.height, 1152);
      expect(target.aspectRatio, closeTo(16 / 9, 0.001));
    });

    test('fits 1080p source to a landscape iPhone drawable by height', () {
      final target = resolveAnime4kProcessingDimensions(
        sourceWidth: 1920,
        sourceHeight: 1080,
        drawableWidth: 2556,
        drawableHeight: 1179,
      );

      expect(target.width, 2094);
      expect(target.height, 1178);
      expect(target.width, lessThan(2556));
      expect(target.aspectRatio, closeTo(16 / 9, 0.002));
    });

    test('does not keep 4K work when the drawable is materially 720p', () {
      const previous = Anime4kProcessingDimensions(width: 3840, height: 2160);
      final target = resolveAnime4kProcessingDimensions(
        sourceWidth: 1920,
        sourceHeight: 1080,
        drawableWidth: 1280,
        drawableHeight: 720,
        previous: previous,
      );

      expect(target.width, 1280);
      expect(target.height, 720);
    });

    test('keeps the previous target across small layout jitter', () {
      const previous = Anime4kProcessingDimensions(width: 1280, height: 720);
      final target = resolveAnime4kProcessingDimensions(
        sourceWidth: 1920,
        sourceHeight: 1080,
        drawableWidth: 1268,
        drawableHeight: 714,
        previous: previous,
      );

      expect(target.width, 1280);
      expect(target.height, 720);
    });

    test('transient zero-size layout keeps the previous allocation', () {
      const previous = Anime4kProcessingDimensions(width: 1280, height: 720);
      final target = resolveAnime4kProcessingDimensions(
        sourceWidth: 1920,
        sourceHeight: 1080,
        drawableWidth: 0,
        drawableHeight: 0,
        previous: previous,
      );

      expect(target.width, 1280);
      expect(target.height, 720);
    });
  });
}
