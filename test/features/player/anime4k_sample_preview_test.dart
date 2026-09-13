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

    test('Apple preview uses native Metal one-shot before mpv fallback', () {
      final preview = File(
        'lib/features/player/presentation/widgets/anime4k_sample_preview.dart',
      ).readAsStringSync();
      final ffi = File(
        'lib/features/player/data/anime4k_metal_ffi.dart',
      ).readAsStringSync();
      final capi = File(
        'native/anime4k_metal/Anime4KMetalCAPI.swift',
      ).readAsStringSync();
      final installer = File(
        'scripts/anime4k_metal_capi_install.rb',
      ).readAsStringSync();

      final nativeCall = preview.indexOf('_startAppleMetalOneShot(');
      final fallbackCall = preview.indexOf(
        '_startMpvFallback(',
        nativeCall < 0 ? 0 : nativeCall + 1,
      );
      expect(
        nativeCall,
        greaterThanOrEqualTo(0),
        reason: 'Apple settings preview must have a native one-shot path.',
      );
      expect(
        fallbackCall,
        greaterThan(nativeCall),
        reason: 'mpv must remain a fallback after the Apple one-shot attempt.',
      );
      expect(preview, contains('Anime4kPreviewBackend.appleMetal'));
      expect(preview, contains('Anime4kMetalFfiBindings.tryCreate()'));
      expect(ffi, contains('animewitcher_anime4k_metal_process_preview'));
      expect(capi, contains('@_cdecl("animewitcher_anime4k_metal_process_preview")'));
      expect(installer, contains('animewitcher_anime4k_metal_process_preview'));
    });

    test('Apple native preview resolves FFI on the player isolate', () {
      final preview = File(
        'lib/features/player/presentation/widgets/anime4k_sample_preview.dart',
      ).readAsStringSync();

      expect(
        preview,
        isNot(contains("import 'dart:isolate';")),
        reason:
            'Playback resolves the Apple C ABI from the main player isolate. '
            'The preview must use the same process-symbol lookup context.',
      );
      expect(
        preview,
        isNot(contains('Isolate.run')),
        reason:
            'The native one-shot already owns its Metal command-buffer wait; '
            'moving FFI symbol resolution to a secondary Dart isolate adds a '
            'different failure path that playback does not use.',
      );
      final binding = preview.indexOf('Anime4kMetalFfiBindings.tryCreate()');
      final processing = preview.indexOf('.processPreview(', binding);
      expect(binding, greaterThanOrEqualTo(0));
      expect(processing, greaterThan(binding));
    });
  });
}
