import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every file the Anime4K repository ships that this app can use.
const _fullFolder = <String>[
  'Anime4K_Clamp_Highlights.glsl',
  'Anime4K_Restore_CNN_S.glsl',
  'Anime4K_Restore_CNN_M.glsl',
  'Anime4K_Restore_CNN_L.glsl',
  'Anime4K_Restore_CNN_VL.glsl',
  'Anime4K_Restore_CNN_UL.glsl',
  'Anime4K_Restore_CNN_Soft_S.glsl',
  'Anime4K_Restore_CNN_Soft_M.glsl',
  'Anime4K_Restore_CNN_Soft_L.glsl',
  'Anime4K_Restore_CNN_Soft_VL.glsl',
  'Anime4K_Restore_CNN_Soft_UL.glsl',
  'Anime4K_Upscale_CNN_x2_S.glsl',
  'Anime4K_Upscale_CNN_x2_M.glsl',
  'Anime4K_Upscale_CNN_x2_L.glsl',
  'Anime4K_Upscale_CNN_x2_VL.glsl',
  'Anime4K_Upscale_CNN_x2_UL.glsl',
  'Anime4K_Upscale_Denoise_CNN_x2_S.glsl',
  'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
  'Anime4K_Upscale_Denoise_CNN_x2_L.glsl',
  'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
  'Anime4K_Upscale_Denoise_CNN_x2_UL.glsl',
];

Anime4kChain _chain(
  Anime4kMode mode, {
  Anime4kQuality quality = Anime4kQuality.m,
  List<String> folder = _fullFolder,
}) {
  return resolveAnime4kChain(mode: mode, quality: quality, available: folder);
}

void main() {
  group('mode off', () {
    test('resolves to nothing at all', () {
      final chain = _chain(Anime4kMode.off);
      expect(chain.files, isEmpty);
      expect(chain.missing, isEmpty);
      expect(chain.isEmpty, isTrue);
    });
  });

  group('the documented pipelines', () {
    test('A restores, then upscales twice', () {
      expect(_chain(Anime4kMode.a).files, <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ]);
    });

    test('B is A with the soft restore', () {
      expect(
        _chain(Anime4kMode.b).files,
        contains('Anime4K_Restore_CNN_Soft_M.glsl'),
      );
      expect(
        _chain(Anime4kMode.b).files,
        isNot(contains('Anime4K_Restore_CNN_M.glsl')),
      );
    });

    test('C denoises while upscaling and does not restore', () {
      final files = _chain(Anime4kMode.c).files;
      expect(files, <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
        // Nothing collides in this pipeline, so the upscale runs at the size
        // that was asked for rather than dropping to S the way A's second
        // pass has to.
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ]);
    });

    test('the doubled modes run their restore twice, at two sizes', () {
      final files = _chain(Anime4kMode.aa).files;
      expect(files, <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
        'Anime4K_Restore_CNN_S.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ]);
    });

    test('C+A adds a restore after the denoising upscale', () {
      expect(_chain(Anime4kMode.ca).files, <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ]);
    });
  });

  group('no shader is used twice', () {
    test('across every mode and quality', () {
      // Anime4K states a shader file may appear only once in a pipeline;
      // repeating one makes mpv reject the chain.
      for (final mode in Anime4kMode.values) {
        for (final quality in Anime4kQuality.values) {
          final files = _chain(mode, quality: quality).files;
          expect(
            files.toSet(),
            hasLength(files.length),
            reason: 'mode ${mode.label} at ${quality.suffix} repeats a file',
          );
        }
      }
    });

    test('even at the smallest size, where the obvious choice collides', () {
      // Mode A wants the chosen size and then S. Choosing S already means the
      // second pass has to move, not repeat.
      final files = _chain(Anime4kMode.a, quality: Anime4kQuality.s).files;
      expect(files.toSet(), hasLength(files.length));
      expect(files, contains('Anime4K_Upscale_CNN_x2_S.glsl'));
    });
  });

  group('a folder that is missing files', () {
    test('falls back to a smaller network rather than giving up', () {
      final onlySmall = <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_S.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ];
      final chain = _chain(
        Anime4kMode.a,
        quality: Anime4kQuality.ul,
        folder: onlySmall,
      );
      // UL was asked for and none exists, so each step takes the largest
      // that does: M for the first upscale, S for the second.
      expect(chain.files, <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_S.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ]);
      expect(chain.missing, isEmpty);
      expect(chain.isComplete, isTrue);
    });

    test('reports a family it has nothing for', () {
      final noRestore = _fullFolder
          .where((name) => !name.contains('Restore'))
          .toList();
      final chain = _chain(Anime4kMode.a, folder: noRestore);

      expect(chain.missing, <String>['Anime4K_Restore_CNN_M.glsl']);
      expect(chain.files, isNot(contains('Anime4K_Restore_CNN_M.glsl')));
      expect(chain.isComplete, isFalse);
      // What is left still upscales, so the viewer gets something.
      expect(chain.files, contains('Anime4K_Upscale_CNN_x2_M.glsl'));
    });

    test('an empty folder resolves to nothing rather than a broken chain', () {
      final chain = _chain(Anime4kMode.a, folder: const <String>[]);
      expect(chain.files, isEmpty);
      expect(chain.isEmpty, isTrue);
      expect(chain.missing, isNotEmpty);
    });

    test('a step skipped for the one-use rule is not called missing', () {
      // One upscale file and a mode that wants two: the second pass is
      // dropped because the file is already in the chain, which is the rule
      // working. Reporting it as missing would send the viewer looking for a
      // file sitting in the folder in front of them.
      final chain = _chain(
        Anime4kMode.a,
        folder: const <String>[
          'Anime4K_Clamp_Highlights.glsl',
          'Anime4K_Restore_CNN_M.glsl',
          'Anime4K_Upscale_CNN_x2_M.glsl',
        ],
      );
      expect(chain.files, <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ]);
      expect(chain.missing, isEmpty);
    });

    test('the clamp shader alone is not a pipeline', () {
      // It only guards the passes around it. On its own it would cost a
      // render pass to change nothing.
      final chain = _chain(
        Anime4kMode.a,
        folder: const <String>['Anime4K_Clamp_Highlights.glsl'],
      );
      expect(chain.files, isEmpty);
    });

    test('surrounding whitespace in a listing is ignored', () {
      final chain = _chain(
        Anime4kMode.c,
        folder: const <String>[
          '  Anime4K_Clamp_Highlights.glsl ',
          'Anime4K_Upscale_Denoise_CNN_x2_M.glsl',
          '',
          '   ',
          'Anime4K_Upscale_CNN_x2_S.glsl',
        ],
      );
      expect(chain.files, hasLength(3));
    });
  });

  group('the value handed to mpv', () {
    test('joins with a colon on Unix', () {
      expect(
        anime4kGlslShadersValue(<String>[
          '/home/me/shaders/one.glsl',
          '/home/me/shaders/two.glsl',
        ], onWindows: false),
        '/home/me/shaders/one.glsl:/home/me/shaders/two.glsl',
      );
    });

    test('joins with a semicolon on Windows, leaving the drive alone', () {
      // mpv's manual: file list options use ':' on Unix and ';' on Windows.
      // Joining with a colon there hands mpv one unparseable path, and
      // escaping the drive colon makes it worse — C\:\shaders is not a path
      // anything can open. Neither failure says a word: the picture simply
      // comes out untouched, which reads as "Anime4K does not do much".
      expect(
        anime4kGlslShadersValue(<String>[
          r'C:\shaders\Anime4K_Clamp_Highlights.glsl',
          r'C:\shaders\Anime4K_Upscale_CNN_x2_M.glsl',
        ], onWindows: true),
        r'C:\shaders\Anime4K_Clamp_Highlights.glsl;'
        r'C:\shaders\Anime4K_Upscale_CNN_x2_M.glsl',
      );
    });

    test('the separator is what gets escaped, and only it', () {
      // A colon is legal inside a Unix filename and a semicolon inside a
      // Windows one, so each platform escapes its own separator and nothing
      // else.
      expect(
        anime4kGlslShadersValue(<String>['/od/d:d/one.glsl'], onWindows: false),
        r'/od/d\:d/one.glsl',
      );
      expect(
        anime4kGlslShadersValue(<String>[r'C:\od;d\one.glsl'], onWindows: true),
        r'C:\od\;d\one.glsl',
      );
    });

    test('a single path needs no separator at all', () {
      expect(
        anime4kGlslShadersValue(<String>[
          r'C:\shaders\one.glsl',
        ], onWindows: true),
        r'C:\shaders\one.glsl',
      );
    });

    test('nothing in, nothing out', () {
      expect(anime4kGlslShadersValue(const <String>[], onWindows: true), '');
      expect(anime4kGlslShadersValue(const <String>[], onWindows: false), '');
    });

    test('the separator itself is named per platform', () {
      expect(anime4kListSeparator(onWindows: true), ';');
      expect(anime4kListSeparator(onWindows: false), ':');
    });
  });

  group('names round-trip through storage', () {
    test('modes', () {
      for (final mode in Anime4kMode.values) {
        expect(Anime4kModeName.fromName(mode.name), mode);
      }
      expect(Anime4kModeName.fromName(null), Anime4kMode.off);
      expect(Anime4kModeName.fromName('nonsense'), Anime4kMode.off);
    });

    test('qualities', () {
      for (final quality in Anime4kQuality.values) {
        expect(Anime4kQualitySuffix.fromName(quality.name), quality);
      }
      expect(Anime4kQualitySuffix.fromName(null), Anime4kQuality.m);
      expect(Anime4kQualitySuffix.fromName('XXL'), Anime4kQuality.m);
    });
  });

  group('is the feature on', () {
    test('a stored flag decides it', () {
      expect(
        anime4kEnabledFrom(stored: true, mode: Anime4kMode.off),
        isTrue,
        reason: 'enabled with no pipeline running is a real state now',
      );
      expect(anime4kEnabledFrom(stored: false, mode: Anime4kMode.a), isFalse);
    });

    test('an install from before the flag keeps what it had', () {
      // Mode and feature used to be one value, so "not off" was how being on
      // was recorded. Reading a missing flag as false would switch Anime4K
      // off for everyone already using it.
      expect(anime4kEnabledFrom(stored: null, mode: Anime4kMode.a), isTrue);
      expect(anime4kEnabledFrom(stored: null, mode: Anime4kMode.ca), isTrue);
      expect(anime4kEnabledFrom(stored: null, mode: Anime4kMode.off), isFalse);
    });

    test('stopping the pipeline from the player is not switching off', () {
      // Choosing "off" in the player sets the mode and leaves the flag, so
      // the button that chose it stays on screen to choose again.
      expect(anime4kEnabledFrom(stored: true, mode: Anime4kMode.off), isTrue);
    });
  });

  group('where it is offered at all', () {
    test('desktop on the mpv backend, and nowhere else', () {
      expect(
        anime4kAvailableOn(
          isDesktopPlatform: true,
          usingAdaptiveBackend: false,
        ),
        isTrue,
      );
    });

    test('not on a phone, whatever is playing', () {
      // The shaders are a real load on a GPU, and a phone has neither the
      // thermal room nor a screen big enough to show what the work bought.
      for (final adaptive in <bool>[true, false]) {
        expect(
          anime4kAvailableOn(
            isDesktopPlatform: false,
            usingAdaptiveBackend: adaptive,
          ),
          isFalse,
          reason: 'adaptive backend: $adaptive',
        );
      }
    });

    test('not on the backend that has no shader stage', () {
      expect(
        anime4kAvailableOn(isDesktopPlatform: true, usingAdaptiveBackend: true),
        isFalse,
      );
    });
  });
}
