import 'dart:io';

import 'package:animewitcher/features/player/data/anime4k_shader_manifest.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

late Directory _folder;

File _write(String name, String content) {
  final file = File(p.join(_folder.path, name));
  file.writeAsStringSync(content, flush: true);
  return file;
}

void main() {
  setUp(() {
    _folder = Directory.systemTemp.createTempSync('anime4k_manifest_test');
  });

  tearDown(() {
    if (_folder.existsSync()) _folder.deleteSync(recursive: true);
  });

  group('Anime4kShaderManifestCache', () {
    test('builds sorted entries with byte size and SHA-256', () async {
      final z = _write('z.glsl', '// z');
      final a = _write('a.glsl', '// alpha');
      _write('README.md', 'ignored');

      final cache = Anime4kShaderManifestCache();
      final manifest = await cache.load(_folder.path);

      expect(manifest.names, <String>['a.glsl', 'z.glsl']);
      expect(manifest.entries, hasLength(2));
      expect(manifest.entries.first.name, 'a.glsl');
      expect(manifest.entries.first.size, a.lengthSync());
      expect(
        manifest.entries.first.sha256,
        sha256.convert(a.readAsBytesSync()).toString(),
      );
      expect(manifest.entries.last.size, z.lengthSync());
    });

    test('reuses an unchanged directory manifest', () async {
      _write('one.glsl', '// one');
      final cache = Anime4kShaderManifestCache();

      final first = await cache.load(_folder.path);
      final second = await cache.load(_folder.path);

      expect(identical(second, first), isTrue);
    });

    test('changed shader content invalidates the cached manifest', () async {
      final shader = _write('one.glsl', '// one');
      final cache = Anime4kShaderManifestCache();
      final first = await cache.load(_folder.path);

      // A different byte length makes invalidation deterministic even on
      // filesystems whose modification-time resolution is coarse.
      shader.writeAsStringSync('// one changed and longer', flush: true);
      final second = await cache.load(_folder.path);

      expect(identical(second, first), isFalse);
      expect(second.entries.single.sha256, isNot(first.entries.single.sha256));
    });

    test('adding or removing a shader invalidates the cache', () async {
      final one = _write('one.glsl', '// one');
      final cache = Anime4kShaderManifestCache();
      final first = await cache.load(_folder.path);

      _write('two.glsl', '// two');
      final withTwo = await cache.load(_folder.path);
      expect(withTwo.names, <String>['one.glsl', 'two.glsl']);
      expect(identical(withTwo, first), isFalse);

      one.deleteSync();
      final withoutOne = await cache.load(_folder.path);
      expect(withoutOne.names, <String>['two.glsl']);
      expect(identical(withoutOne, withTwo), isFalse);
    });

    test('pipeline hash is stable but intentionally order-sensitive', () async {
      _write('a.glsl', '// alpha');
      _write('b.glsl', '// beta');
      final manifest = await Anime4kShaderManifestCache().load(_folder.path);

      final first = manifest.pipelineHash(<String>['a.glsl', 'b.glsl']);
      final again = manifest.pipelineHash(<String>['a.glsl', 'b.glsl']);
      final reversed = manifest.pipelineHash(<String>['b.glsl', 'a.glsl']);

      expect(first, isNotEmpty);
      expect(again, first);
      expect(reversed, isNot(first));
    });

    test('pipeline hash fails closed for a file outside the manifest', () async {
      _write('a.glsl', '// alpha');
      final manifest = await Anime4kShaderManifestCache().load(_folder.path);

      expect(
        () => manifest.pipelineHash(<String>['missing.glsl']),
        throwsArgumentError,
      );
    });

    test('missing and blank directories produce an empty manifest', () async {
      final cache = Anime4kShaderManifestCache();
      final missing = p.join(_folder.path, 'not-there');

      expect((await cache.load(missing)).isEmpty, isTrue);
      expect((await cache.load('')).isEmpty, isTrue);
      expect((await cache.load('   ')).isEmpty, isTrue);
    });

    test('explicit invalidation forces a rebuild', () async {
      _write('one.glsl', '// one');
      final cache = Anime4kShaderManifestCache();
      final first = await cache.load(_folder.path);

      cache.invalidate(_folder.path);
      final second = await cache.load(_folder.path);

      expect(identical(second, first), isFalse);
      expect(second.entries.single.sha256, first.entries.single.sha256);
    });
  });
}
