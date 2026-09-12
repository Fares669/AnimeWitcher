import 'dart:io';

import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/presentation/widgets/anime4k_sample_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K settings preview one-shot cache', () {
    test('cache identity changes only with mode quality backend or shader hash', () {
      const base = Anime4kPreviewCacheKey(
        mode: Anime4kMode.a,
        quality: Anime4kQuality.m,
        backend: Anime4kPreviewBackend.appleMetal,
        pipelineHash: 'pipeline-a',
      );
      const same = Anime4kPreviewCacheKey(
        mode: Anime4kMode.a,
        quality: Anime4kQuality.m,
        backend: Anime4kPreviewBackend.appleMetal,
        pipelineHash: 'pipeline-a',
      );

      expect(base, same);
      expect(base.hashCode, same.hashCode);
      expect(base, isNot(const Anime4kPreviewCacheKey(mode: Anime4kMode.b, quality: Anime4kQuality.m, backend: Anime4kPreviewBackend.appleMetal, pipelineHash: 'pipeline-a')));
      expect(base, isNot(const Anime4kPreviewCacheKey(mode: Anime4kMode.a, quality: Anime4kQuality.h, backend: Anime4kPreviewBackend.appleMetal, pipelineHash: 'pipeline-a')));
      expect(base, isNot(const Anime4kPreviewCacheKey(mode: Anime4kMode.a, quality: Anime4kQuality.m, backend: Anime4kPreviewBackend.mpv, pipelineHash: 'pipeline-a')));
      expect(base, isNot(const Anime4kPreviewCacheKey(mode: Anime4kMode.a, quality: Anime4kQuality.m, backend: Anime4kPreviewBackend.appleMetal, pipelineHash: 'pipeline-b')));
    });

    test('Apple Metal path checks cache before creating a preview player', () {
      final source = File('lib/features/player/presentation/widgets/anime4k_sample_preview.dart').readAsStringSync();
      final methodStart = source.indexOf('_startAppleMetalOneShot');
      final fallbackStart = source.indexOf('_startMpvFallback');
      expect(methodStart, greaterThanOrEqualTo(0));
      expect(fallbackStart, greaterThan(methodStart));
      final applePath = source.substring(methodStart, fallbackStart);
      final cacheLookup = applePath.indexOf('_metalPreviewCache.lookup(');
      final playerCreation = applePath.indexOf('Player()');
      expect(cacheLookup, greaterThanOrEqualTo(0));
      expect(playerCreation, greaterThan(cacheLookup));
      expect(applePath, isNot(contains("setProperty('loop-file', 'inf')")));
      expect(applePath, contains('Anime4kMetalBridge'));
    });

    test('Apple one-shot captures final rendered frame then disposes player', () {
      final source = File('lib/features/player/presentation/widgets/anime4k_sample_preview.dart').readAsStringSync();
      expect(source, contains('RepaintBoundary'));
      expect(source, contains('toImage('));
      expect(source, contains('toByteData('));
      expect(source, contains('_metalPreviewCache.store('));
      expect(source, contains('await _disposePreviewPlayer()'));
    });

    test('mpv preview remains the explicit fallback path', () {
      final source = File('lib/features/player/presentation/widgets/anime4k_sample_preview.dart').readAsStringSync();
      final fallbackStart = source.indexOf('_startMpvFallback');
      expect(fallbackStart, greaterThanOrEqualTo(0));
      final fallbackPath = source.substring(fallbackStart);
      expect(fallbackPath, contains("setProperty('loop-file', 'inf')"));
      expect(fallbackPath, contains("setProperty('glsl-shaders', pipeline.value)"));
    });
  });
}
