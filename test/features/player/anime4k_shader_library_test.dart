import 'dart:io';

import 'package:animewitcher/features/player/data/anime4k.dart';
import 'package:animewitcher/features/player/data/anime4k_shader_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

late Directory _folder;

/// Writes a file with the given name into the temporary shader folder.
void _touch(String name) {
  File(p.join(_folder.path, name)).writeAsStringSync('// not a real shader');
}

void main() {
  const library = Anime4kShaderLibrary();

  setUp(() {
    _folder = Directory.systemTemp.createTempSync('anime4k_test');
  });

  tearDown(() {
    if (_folder.existsSync()) _folder.deleteSync(recursive: true);
  });

  group('reading the folder', () {
    test('finds the glsl files and ignores everything else', () async {
      _touch('Anime4K_Clamp_Highlights.glsl');
      _touch('Anime4K_Upscale_CNN_x2_M.glsl');
      _touch('readme.txt');
      _touch('input.conf');

      expect(await library.listShaders(_folder.path), <String>[
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ]);
    });

    test('matches the extension whatever its case', () async {
      _touch('Anime4K_Restore_CNN_M.GLSL');
      expect(await library.listShaders(_folder.path), hasLength(1));
    });

    test('a folder that is not there is empty, not an error', () async {
      final gone = p.join(_folder.path, 'no', 'such', 'place');
      expect(await library.listShaders(gone), isEmpty);
      expect(await library.listShaders(''), isEmpty);
      expect(await library.listShaders('   '), isEmpty);
    });

    test('does not descend into subfolders', () async {
      // mpv is given one path per shader; a nested file would resolve to a
      // path that is not where the file is.
      Directory(p.join(_folder.path, 'Restore')).createSync();
      _touch(p.join('Restore', 'Anime4K_Restore_CNN_M.glsl'));
      _touch('Anime4K_Clamp_Highlights.glsl');

      expect(await library.listShaders(_folder.path), <String>[
        'Anime4K_Clamp_Highlights.glsl',
      ]);
    });
  });

  group('building the pipeline', () {
    Future<Anime4kPipeline> pipeline({
      Anime4kMode mode = Anime4kMode.a,
      Anime4kQuality quality = Anime4kQuality.m,
      String? directory,
    }) {
      return library.pipeline(
        mode: mode,
        quality: quality,
        directory: directory ?? _folder.path,
      );
    }

    test('turns a mode into absolute paths mpv can open', () async {
      _touch('Anime4K_Clamp_Highlights.glsl');
      _touch('Anime4K_Restore_CNN_M.glsl');
      _touch('Anime4K_Upscale_CNN_x2_M.glsl');
      _touch('Anime4K_Upscale_CNN_x2_S.glsl');

      final result = await pipeline();

      expect(result.files, hasLength(4));
      expect(result.missing, isEmpty);
      expect(result.isEmpty, isFalse);
      // Every path points at a file that exists, in the order given.
      for (final name in result.files) {
        expect(File(p.join(_folder.path, name)).existsSync(), isTrue);
      }
      // The value mpv gets holds every chosen path, joined the way mpv
      // splits them on this platform.
      final separator = anime4kListSeparator(onWindows: Platform.isWindows);
      // A plain split is safe here: the temp folder holds no separator
      // character, so nothing in these paths is escaped.
      final parts = result.value.split(separator);
      expect(parts, hasLength(result.files.length));
      for (final name in result.files) {
        expect(parts, contains(p.join(_folder.path, name)));
      }
    });

    test('mode off asks for nothing, whatever is in the folder', () async {
      _touch('Anime4K_Clamp_Highlights.glsl');
      _touch('Anime4K_Upscale_CNN_x2_M.glsl');

      final result = await pipeline(mode: Anime4kMode.off);
      expect(result.value, isEmpty);
      expect(result.isEmpty, isTrue);
    });

    test('no folder chosen means no shaders', () async {
      final result = await pipeline(directory: '');
      expect(result.isEmpty, isTrue);
      expect(result.missing, isEmpty);
    });

    test('an empty folder reports what it wanted', () async {
      final result = await pipeline();
      expect(result.isEmpty, isTrue);
      expect(result.missing, isNotEmpty);
    });

    test('a partial folder runs what it can and names the rest', () async {
      _touch('Anime4K_Clamp_Highlights.glsl');
      _touch('Anime4K_Upscale_CNN_x2_M.glsl');
      // No restore shader and no S shader for the cheaper late upscale.

      final result = await pipeline();
      expect(result.files, contains('Anime4K_Upscale_CNN_x2_M.glsl'));
      expect(result.missing, <String>[
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ]);
      expect(result.value, isNotEmpty, reason: 'it still upscales once');
    });
  });
}
