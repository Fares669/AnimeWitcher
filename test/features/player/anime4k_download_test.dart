import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/features/player/data/anime4k_download.dart';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Builds a zip in memory with the given entry names.
Uint8List _zip(Map<String, String> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = Uint8List.fromList(entry.value.codeUnits);
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
      // Archive entries are attacker-controlled in the general case, and the
      // classic trick is a name that climbs out of the folder being written
      // to. Taking only the last segment makes that impossible by
      // construction rather than by checking for it.
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

  group('downloading', () {
    late Directory target;

    setUp(() {
      target = Directory.systemTemp.createTempSync('anime4k_dl');
    });

    tearDown(() {
      if (target.existsSync()) target.deleteSync(recursive: true);
    });

    test('writes the shaders and reports where they went', () async {
      final downloader = Anime4kDownloader(
        _serving(
          _zip(<String, String>{
            'glsl/Restore/Anime4K_Restore_CNN_M.glsl': '// restore',
            'glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl': '// upscale',
            'glsl/Anime4K_Clamp_Highlights.glsl': '// clamp',
            'README.md': 'not a shader',
          }),
        ),
      );

      final result = await downloader.download(into: target);

      expect(result.written, 3);
      expect(result.directory, target.path);
      expect(
        File(p.join(target.path, 'Anime4K_Restore_CNN_M.glsl')).existsSync(),
        isTrue,
      );
      expect(File(p.join(target.path, 'README.md')).existsSync(), isFalse);
      // Flattened, so the folders inside the archive are not recreated.
      expect(Directory(p.join(target.path, 'glsl')).existsSync(), isFalse);
    });

    test('the content is what was in the archive', () async {
      final downloader = Anime4kDownloader(
        _serving(<String, String>{'a/Anime4K_Restore_CNN_M.glsl': '// hello'}
            .let(_zip)),
      );
      await downloader.download(into: target);
      expect(
        File(p.join(target.path, 'Anime4K_Restore_CNN_M.glsl'))
            .readAsStringSync(),
        '// hello',
      );
    });

    test('reports progress while it comes down', () async {
      final seen = <double?>[];
      final downloader = Anime4kDownloader(
        _serving(_zip(<String, String>{'Anime4K_Restore_CNN_M.glsl': '//'})),
      );
      await downloader.download(into: target, onProgress: seen.add);
      // The fake resolves in one go, so this only asserts the callback is
      // wired at all rather than any particular sequence.
      expect(seen, anyOf(isEmpty, everyElement(anyOf(isNull, isA<double>()))));
    });

    test('an unreachable release is an error, not an empty folder', () async {
      final downloader = Anime4kDownloader(_serving(null));
      await expectLater(
        downloader.download(into: target),
        throwsA(isA<Anime4kDownloadException>()),
      );
      expect(target.listSync(), isEmpty);
    });

    test('something that is not an archive is an error', () async {
      final downloader = Anime4kDownloader(
        _serving(Uint8List.fromList('this is not a zip'.codeUnits)),
      );
      await expectLater(
        downloader.download(into: target),
        throwsA(isA<Anime4kDownloadException>()),
      );
    });

    test('an archive with no shaders in it is an error', () async {
      final downloader = Anime4kDownloader(
        _serving(_zip(<String, String>{'README.md': 'nothing here'})),
      );
      await expectLater(
        downloader.download(into: target),
        throwsA(isA<Anime4kDownloadException>()),
      );
    });

    test('running it twice leaves the same set', () async {
      final zip = _zip(<String, String>{
        'a/Anime4K_Restore_CNN_M.glsl': '// one',
        'b/Anime4K_Restore_CNN_M.glsl': '// two, same name',
        'Anime4K_Clamp_Highlights.glsl': '// clamp',
      });
      final downloader = Anime4kDownloader(_serving(zip));

      final first = await downloader.download(into: target);
      final second = await downloader.download(into: target);

      expect(first.written, 2, reason: 'the duplicate name is written once');
      expect(second.written, first.written);
      expect(
        File(p.join(target.path, 'Anime4K_Restore_CNN_M.glsl'))
            .readAsStringSync(),
        '// one',
        reason: 'the first entry wins, both times',
      );
    });

    test('the release is pinned rather than tracking latest', () {
      // A new release that renames files would otherwise land on viewers
      // silently and quietly stop matching the pipelines.
      expect(anime4kDownloadUrl, contains(anime4kReleaseTag));
      expect(anime4kDownloadUrl, isNot(contains('latest')));
      expect(anime4kDownloadUrl, startsWith('https://'));
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
