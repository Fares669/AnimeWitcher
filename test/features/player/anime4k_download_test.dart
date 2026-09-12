import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/features/player/data/anime4k_download.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Builds a zip in memory with the given entry names.
Uint8List _zip(Map<String, String> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = Uint8List.fromList(utf8.encode(entry.value));
    archive.add(ArchiveFile.bytes(entry.key, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Serves [bytes] for any request, or fails when [bytes] is null.
Dio _serving(Uint8List? bytes) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (bytes == null) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
              message: 'offline',
            ),
          );
          return;
        }
        handler.resolve(
          Response<List<int>>(
            requestOptions: options,
            statusCode: 200,
            data: bytes,
          ),
        );
      },
    ),
  );
  return dio;
}

String _gitBlobSha1(String content) {
  final bytes = utf8.encode(content);
  final header = utf8.encode('blob ${bytes.length}\u0000');
  return sha1.convert(<int>[...header, ...bytes]).toString();
}

Map<String, Anime4kExpectedShader> _expected(Map<String, String> contents) {
  return <String, Anime4kExpectedShader>{
    for (final entry in contents.entries)
      entry.key: Anime4kExpectedShader(
        size: utf8.encode(entry.value).length,
        gitBlobSha1: _gitBlobSha1(entry.value),
      ),
  };
}

Anime4kDownloader _downloader(
  Uint8List? bytes, {
  required Map<String, String> expectedContents,
}) {
  return Anime4kDownloader(
    _serving(bytes),
    expectedManifest: _expected(expectedContents),
  );
}

void main() {
  group('choosing what to extract', () {
    test('takes glsl files under their bare name', () {
      expect(
        anime4kExtractName('Anime4K_Clamp_Highlights.glsl'),
        'Anime4K_Clamp_Highlights.glsl',
      );
      expect(
        anime4kExtractName('glsl/Restore/Anime4K_Restore_CNN_M.glsl'),
        'Anime4K_Restore_CNN_M.glsl',
      );
      expect(
        anime4kExtractName(r'glsl\Upscale\Anime4K_Upscale_CNN_x2_M.glsl'),
        'Anime4K_Upscale_CNN_x2_M.glsl',
      );
    });

    test('matches the extension whatever its case', () {
      expect(anime4kExtractName('Anime4K_Restore_CNN_M.GLSL'), isNotNull);
    });

    test('skips everything that is not a shader', () {
      for (final name in <String>[
        'README.md',
        'input.conf',
        'glsl/',
        '',
        '   ',
        'LICENSE',
        'shaders.glsl.txt',
      ]) {
        expect(anime4kExtractName(name), isNull, reason: name);
      }
    });

    test('an entry cannot steer where it lands', () {
      // The public helper flattens paths; the downloader adds a stricter
      // traversal check before accepting archive-controlled names.
      expect(
        anime4kExtractName('../../../evil.glsl'),
        'evil.glsl',
        reason: 'flattened, not escaped',
      );
      expect(anime4kExtractName('../..'), isNull);
      expect(anime4kExtractName(r'C:\Windows\System32\x.glsl'), 'x.glsl');
      expect(anime4kExtractName('C:x.glsl'), isNull);
    });
  });

  group('verified atomic downloading', () {
    late Directory target;

    setUp(() {
      target = Directory.systemTemp.createTempSync('anime4k_dl');
    });

    tearDown(() {
      if (target.existsSync()) target.deleteSync(recursive: true);
    });

    test('writes only verified shaders and atomically replaces the old set', () async {
      const expected = <String, String>{
        'Anime4K_Restore_CNN_M.glsl': '// restore',
        'Anime4K_Upscale_CNN_x2_M.glsl': '// upscale',
        'Anime4K_Clamp_Highlights.glsl': '// clamp',
      };
      File(p.join(target.path, 'old.glsl')).writeAsStringSync('// old');
      final downloader = _downloader(
        _zip(<String, String>{
          'glsl/Restore/Anime4K_Restore_CNN_M.glsl': '// restore',
          'glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl': '// upscale',
          'glsl/Anime4K_Clamp_Highlights.glsl': '// clamp',
          'README.md': 'not a shader',
          'glsl/Experimental-Effects/Unused.glsl': '// unrelated',
        }),
        expectedContents: expected,
      );

      final result = await downloader.download(into: target);

      expect(result.written, 3);
      expect(result.directory, target.path);
      expect(File(p.join(target.path, 'old.glsl')).existsSync(), isFalse);
      expect(
        File(p.join(target.path, 'Anime4K_Restore_CNN_M.glsl')).readAsStringSync(),
        '// restore',
      );
      expect(File(p.join(target.path, 'README.md')).existsSync(), isFalse);
      expect(File(p.join(target.path, 'Unused.glsl')).existsSync(), isFalse);
      expect(Directory(p.join(target.path, 'glsl')).existsSync(), isFalse);
    });

    test('tampered shader content is rejected without touching the active set', () async {
      const name = 'Anime4K_Restore_CNN_M.glsl';
      File(p.join(target.path, 'active.glsl')).writeAsStringSync('// keep me');
      final downloader = _downloader(
        _zip(<String, String>{name: '// tampered'}),
        expectedContents: const <String, String>{name: '// official'},
      );

      await expectLater(
        downloader.download(into: target),
        throwsA(isA<Anime4kDownloadException>()),
      );

      expect(
        File(p.join(target.path, 'active.glsl')).readAsStringSync(),
        '// keep me',
      );
      expect(File(p.join(target.path, name)).existsSync(), isFalse);
    });

    test('partial archive is rejected without touching the active set', () async {
      const restore = 'Anime4K_Restore_CNN_M.glsl';
      const upscale = 'Anime4K_Upscale_CNN_x2_M.glsl';
      File(p.join(target.path, 'active.glsl')).writeAsStringSync('// keep me');
      final downloader = _downloader(
        _zip(const <String, String>{restore: '// restore'}),
        expectedContents: const <String, String>{
          restore: '// restore',
          upscale: '// upscale',
        },
      );

      await expectLater(
        downloader.download(into: target),
        throwsA(isA<Anime4kDownloadException>()),
      );

      expect(
        File(p.join(target.path, 'active.glsl')).readAsStringSync(),
        '// keep me',
      );
      expect(File(p.join(target.path, restore)).existsSync(), isFalse);
    });

    test('duplicate normalized shader names are rejected', () async {
      const name = 'Anime4K_Restore_CNN_M.glsl';
      final downloader = _downloader(
        _zip(<String, String>{
          'a/$name': '// official',
          'b/$name': '// official',
        }),
        expectedContents: const <String, String>{name: '// official'},
      );

      await expectLater(
        downloader.download(into: target),
        throwsA(isA<Anime4kDownloadException>()),
      );
      expect(target.listSync(), isEmpty);
    });

    test('path traversal is rejected before flattening an expected filename', () async {
      const name = 'Anime4K_Restore_CNN_M.glsl';
      final downloader = _downloader(
        _zip(<String, String>{'../$name': '// official'}),
        expectedContents: const <String, String>{name: '// official'},
      );

      await expectLater(
        downloader.download(into: target),
        throwsA(isA<Anime4kDownloadException>()),
      );
      expect(target.listSync(), isEmpty);
    });

    test('an unreachable release is an error and preserves the active set', () async {
      const name = 'Anime4K_Restore_CNN_M.glsl';
      File(p.join(target.path, 'active.glsl')).writeAsStringSync('// keep me');
      final downloader = _downloader(
        null,
        expectedContents: const <String, String>{name: '// official'},
      );

      await expectLater(
        downloader.download(into: target),
        throwsA(isA<Anime4kDownloadException>()),
      );
      expect(
        File(p.join(target.path, 'active.glsl')).readAsStringSync(),
        '// keep me',
      );
    });

    test('something that is not an archive is an error and preserves active set', () async {
      const name = 'Anime4K_Restore_CNN_M.glsl';
      File(p.join(target.path, 'active.glsl')).writeAsStringSync('// keep me');
      final downloader = _downloader(
        Uint8List.fromList(utf8.encode('this is not a zip')),
        expectedContents: const <String, String>{name: '// official'},
      );

      await expectLater(
        downloader.download(into: target),
        throwsA(isA<Anime4kDownloadException>()),
      );
      expect(
        File(p.join(target.path, 'active.glsl')).readAsStringSync(),
        '// keep me',
      );
    });

    test('reports progress while it comes down', () async {
      const name = 'Anime4K_Restore_CNN_M.glsl';
      final seen = <double?>[];
      final downloader = _downloader(
        _zip(const <String, String>{name: '// official'}),
        expectedContents: const <String, String>{name: '// official'},
      );

      await downloader.download(into: target, onProgress: seen.add);

      expect(seen, anyOf(isEmpty, everyElement(anyOf(isNull, isA<double>()))));
    });

    test('the production release manifest is pinned to the shader set we use', () {
      expect(anime4kV401ExpectedManifest, hasLength(23));
      expect(
        anime4kV401ExpectedManifest,
        contains('Anime4K_AutoDownscalePre_x2.glsl'),
      );
      expect(
        anime4kV401ExpectedManifest,
        contains('Anime4K_AutoDownscalePre_x4.glsl'),
      );
      expect(
        anime4kV401ExpectedManifest,
        contains('Anime4K_Restore_CNN_UL.glsl'),
      );
      expect(
        anime4kV401ExpectedManifest,
        contains('Anime4K_Upscale_Denoise_CNN_x2_UL.glsl'),
      );
    });

    test('the release is pinned rather than tracking latest', () {
      expect(anime4kDownloadUrl, contains(anime4kReleaseTag));
      expect(anime4kDownloadUrl, isNot(contains('latest')));
      expect(anime4kDownloadUrl, startsWith('https://'));
    });
  });
}
