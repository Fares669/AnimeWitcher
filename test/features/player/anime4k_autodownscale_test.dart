import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:flutter_test/flutter_test.dart';

const _officialFastFolder = <String>[
  'Anime4K_Clamp_Highlights.glsl',
  'Anime4K_Restore_CNN_S.glsl',
  'Anime4K_Restore_CNN_M.glsl',
  'Anime4K_Restore_CNN_Soft_S.glsl',
  'Anime4K_Restore_CNN_Soft_M.glsl',
  'Anime4K_Upscale_CNN_x2_S.glsl',
  'Anime4K_Upscale_CNN_x2_M.glsl',
  'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
  'Anime4K_AutoDownscalePre_x2.glsl',
  'Anime4K_AutoDownscalePre_x4.glsl',
];

Anime4kChain _resolve(Anime4kMode mode) => resolveAnime4kChain(
  mode: mode,
  quality: Anime4kQuality.m,
  available: _officialFastFolder,
);

void main() {
  group('official optimized AutoDownscale ordering', () {
    test('Mode A inserts AutoDownscale before the final upscale', () {
      expect(_resolve(Anime4kMode.a).files, <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
        'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ]);
    });

    test('Mode C inserts AutoDownscale before its final upscale', () {
      expect(_resolve(Anime4kMode.c).files, <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
        'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl',
        // AKP-02 defines the AutoDownscale placement only. Stage-aware
        // post-upscale quality reduction (M -> S here) belongs to AKP-03.
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ]);
    });

    test('Mode A+A keeps second restore before AutoDownscale stages', () {
      expect(_resolve(Anime4kMode.aa).files, <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
        'Anime4K_Restore_CNN_S.glsl',
        'Anime4K_AutoDownscalePre_x2.glsl',
        'Anime4K_AutoDownscalePre_x4.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ]);
    });

    test('missing AutoDownscale shaders do not destroy a usable pipeline', () {
      final chain = resolveAnime4kChain(
        mode: Anime4kMode.a,
        quality: Anime4kQuality.m,
        available: _officialFastFolder.where(
          (name) => !name.contains('AutoDownscalePre'),
        ),
      );

      expect(chain.files, <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ]);
      expect(chain.isEmpty, isFalse);
      expect(
        chain.missing,
        containsAll(<String>[
          'Anime4K_AutoDownscalePre_x2.glsl',
          'Anime4K_AutoDownscalePre_x4.glsl',
        ]),
      );
    });
  });
}
