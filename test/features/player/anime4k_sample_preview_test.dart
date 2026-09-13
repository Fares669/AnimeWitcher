import 'dart:io';

import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/presentation/widgets/anime4k_sample_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Anime4K settings preview one-shot cache', () {
    test(
      'cache identity changes only with mode quality backend or shader hash',
      () {
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
        expect(
          base,
          isNot(
            const Anime4kPreviewCacheKey(
              mode: Anime4kMode.b,
              quality: Anime4kQuality.m,
              backend: Anime4kPreviewBackend.appleMetal,
              pipelineHash: 'pipeline-a',
            ),
          ),
        );
        expect(
          base,
          isNot(
            const Anime4kPreviewCacheKey(
              mode: Anime4kMode.a,
              quality: Anime4kQuality.l,
              backend: Anime4kPreviewBackend.appleMetal,
              pipelineHash: 'pipeline-a',
            ),
          ),
        );
        expect(
          base,
          isNot(
            const Anime4kPreviewCacheKey(
              mode: Anime4kMode.a,
              quality: Anime4kQuality.m,
              backend: Anime4kPreviewBackend.mpv,
              pipelineHash: 'pipeline-a',
            ),
          ),
        );
        expect(
          base,
          isNot(
            const Anime4kPreviewCacheKey(
              mode: Anime4kMode.a,
              quality: Anime4kQuality.m,
              backend: Anime4kPreviewBackend.appleMetal,
              pipelineHash: 'pipeline-b',
            ),
          ),
        );
      },
    );

    test('preview never rasterizes an external video texture through Flutter', () {
      final source = File(
        'lib/features/player/presentation/widgets/anime4k_sample_preview.dart',
      ).readAsStringSync();

      // Flutter RepaintBoundary cannot reliably capture an external iOS/macOS
      // texture; on device this produced an all-black processed half.
      expect(source, isNot(contains('RenderRepaintBoundary')));
      expect(source, isNot(contains('toImage(')));
      expect(source, isNot(contains('_metalCaptureKey')));
    });

    test('mpv fallback captures the processed video once and disposes player', () {
      final source = File(
        'lib/features/player/presentation/widgets/anime4k_sample_preview.dart',
      ).readAsStringSync();
      final fallbackStart = source.indexOf('_startMpvFallback');
      expect(fallbackStart, greaterThanOrEqualTo(0));
      final fallbackPath = source.substring(fallbackStart);

      expect(
        fallbackPath,
        contains("setProperty('glsl-shaders', pipeline.value)"),
      );
      // The external window/texture path is unreliable on iOS/macOS. Ask mpv
      // for its processed video frame before it is published to the texture.
      expect(fallbackPath, contains("'screenshot-to-file'"));
      expect(fallbackPath, contains('captureFile.path'));
      expect(fallbackPath, contains("'video'"));
      expect(fallbackPath, isNot(contains("'window'")));
      expect(fallbackPath, contains('_metalPreviewCache.store(key, bytes)'));
      expect(
        fallbackPath,
        contains('await _disposeSpecificPreviewPlayer(player)'),
      );
      expect(fallbackPath, isNot(contains("setProperty('loop-file', 'inf')")));
    });

    test('Apple preview explicitly falls back until native buffer capture exists', () {
      final source = File(
        'lib/features/player/presentation/widgets/anime4k_sample_preview.dart',
      ).readAsStringSync();
      final startCall = source.indexOf('_startMpvFallback(');
      expect(startCall, greaterThanOrEqualTo(0));
      expect(source, isNot(contains('_startAppleMetalOneShot(')));
    });
  });
}
