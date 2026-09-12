import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:flutter_test/flutter_test.dart';

final _fullFolder = <String>[
  'Anime4K_Clamp_Highlights.glsl',
  for (final suffix in <String>['S', 'M', 'L', 'VL', 'UL']) ...<String>[
    'Anime4K_Restore_CNN_$suffix.glsl',
    'Anime4K_Restore_CNN_Soft_$suffix.glsl',
    'Anime4K_Upscale_CNN_x2_$suffix.glsl',
    'Anime4K_Upscale_Denoise_CNN_x2_$suffix.glsl',
  ],
  'Anime4K_AutoDownscalePre_x2.glsl',
  'Anime4K_AutoDownscalePre_x4.glsl',
];

String _suffix(Anime4kQuality quality) => quality.suffix;

Anime4kQuality _lateQuality(Anime4kQuality requested) {
  final index = Anime4kQuality.values.indexOf(requested);
  final lateIndex = (index - 2).clamp(0, Anime4kQuality.values.length - 1);
  return Anime4kQuality.values[lateIndex];
}

Anime4kChain _resolve(Anime4kMode mode, Anime4kQuality quality) {
  return resolveAnime4kChain(
    mode: mode,
    quality: quality,
    available: _fullFolder,
  );
}

void main() {
  group('stage-aware CNN sizing', () {
    for (final quality in Anime4kQuality.values) {
      test('Mode A keeps first stages at ${quality.suffix} and lowers late work', () {
        final files = _resolve(Anime4kMode.a, quality).files;
        final late = _lateQuality(quality);

        expect(files, contains('Anime4K_Restore_CNN_${_suffix(quality)}.glsl'));
        expect(files, contains('Anime4K_Upscale_CNN_x2_${_suffix(quality)}.glsl'));

        if (late == quality) {
          expect(
            files.where((name) => name.startsWith('Anime4K_Upscale_CNN_x2_')),
            hasLength(1),
            reason: 'S is already the floor, so the same shader must not be reused or upgraded',
          );
        } else {
          expect(files, contains('Anime4K_Upscale_CNN_x2_${_suffix(late)}.glsl'));
        }
      });

      test('Mode A+A lowers second restore and final upscale for ${quality.suffix}', () {
        final files = _resolve(Anime4kMode.aa, quality).files;
        final late = _lateQuality(quality);

        expect(files, contains('Anime4K_Restore_CNN_${_suffix(quality)}.glsl'));
        expect(files, contains('Anime4K_Upscale_CNN_x2_${_suffix(quality)}.glsl'));
        if (late == quality) {
          expect(
            files.where((name) => name.startsWith('Anime4K_Restore_CNN_')),
            hasLength(1),
          );
          expect(
            files.where((name) => name.startsWith('Anime4K_Upscale_CNN_x2_')),
            hasLength(1),
          );
        } else {
          expect(files, contains('Anime4K_Restore_CNN_${_suffix(late)}.glsl'));
          expect(files, contains('Anime4K_Upscale_CNN_x2_${_suffix(late)}.glsl'));
        }
      });

      test('Mode B+B lowers second soft restore and final upscale for ${quality.suffix}', () {
        final files = _resolve(Anime4kMode.bb, quality).files;
        final late = _lateQuality(quality);

        expect(files, contains('Anime4K_Restore_CNN_Soft_${_suffix(quality)}.glsl'));
        expect(files, contains('Anime4K_Upscale_CNN_x2_${_suffix(quality)}.glsl'));
        if (late == quality) {
          expect(
            files.where((name) => name.startsWith('Anime4K_Restore_CNN_Soft_')),
            hasLength(1),
          );
        } else {
          expect(files, contains('Anime4K_Restore_CNN_Soft_${_suffix(late)}.glsl'));
          expect(files, contains('Anime4K_Upscale_CNN_x2_${_suffix(late)}.glsl'));
        }
      });

      test('Mode C+A lowers CNN work after denoise upscale for ${quality.suffix}', () {
        final files = _resolve(Anime4kMode.ca, quality).files;
        final late = _lateQuality(quality);

        expect(
          files,
          contains('Anime4K_Upscale_Denoise_CNN_x2_${_suffix(quality)}.glsl'),
        );
        expect(files, contains('Anime4K_Restore_CNN_${_suffix(late)}.glsl'));
        expect(files, contains('Anime4K_Upscale_CNN_x2_${_suffix(late)}.glsl'));
      });
    }
  });

  group('manual quality is a hard ceiling', () {
    test('requested S never climbs to a larger CNN merely to fill a repeated stage', () {
      final files = _resolve(Anime4kMode.aa, Anime4kQuality.s).files;

      for (final forbidden in <String>['_M.glsl', '_L.glsl', '_VL.glsl', '_UL.glsl']) {
        expect(
          files.where((name) => name.contains('CNN') && name.endsWith(forbidden)),
          isEmpty,
          reason: 'manual S must remain the maximum effective CNN size',
        );
      }
    });

    test('missing requested CNN falls downward only, never upward', () {
      final folder = _fullFolder
          .where((name) => name != 'Anime4K_Restore_CNN_M.glsl')
          .toList();
      final chain = resolveAnime4kChain(
        mode: Anime4kMode.a,
        quality: Anime4kQuality.m,
        available: folder,
      );

      expect(chain.files, contains('Anime4K_Restore_CNN_S.glsl'));
      expect(chain.files, isNot(contains('Anime4K_Restore_CNN_L.glsl')));
      expect(chain.files, isNot(contains('Anime4K_Restore_CNN_VL.glsl')));
      expect(chain.files, isNot(contains('Anime4K_Restore_CNN_UL.glsl')));
    });
  });
}
