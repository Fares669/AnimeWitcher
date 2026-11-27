import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../support/manga_image_fixtures.dart';

void main() {
  for (final image in tinyMangaImages.entries) {
    test('digest-bearing extensionless ${image.key} page is valid', () async {
      final directory = await Directory.systemTemp.createTemp('aw-image-header-');
      addTearDown(() => directory.delete(recursive: true));
      final page = File(p.join(directory.path, 'page'));
      await page.writeAsBytes(image.value, flush: true);
      final manifest = _singlePageManifest(
        digest: await MangaChapterManifestV2.pageDigest(page),
      );
      expect(await manifest.isPageValid(0, page), isTrue);
    });
  }

  for (final brand in <String>['avif', 'avis']) {
    test('digest-bearing AVIF compatible $brand brand is recognized', () async {
      final directory = await Directory.systemTemp.createTemp('aw-avif-brand-');
      addTearDown(() => directory.delete(recursive: true));
      final bytes = List<int>.from(tinyMangaAvif)
        ..setRange(8, 12, ascii.encode('mif1'))
        ..setRange(16, 20, ascii.encode(brand));
      final page = File(p.join(directory.path, 'page'));
      await page.writeAsBytes(bytes, flush: true);
      final manifest = _singlePageManifest(
        digest: await MangaChapterManifestV2.pageDigest(page),
      );
      expect(await manifest.isPageValid(0, page), isTrue);
    });
  }

  for (final body in <String, List<int>>{
    'HTML': utf8.encode('<html><body>Session expired</body></html>'),
    'unknown': <int>[1, 2, 3, 4],
    'non-WebP RIFF': ascii.encode('RIFFxxxxAVI '),
    'non-AVIF ftyp': <int>[0, 0, 0, 20, ...ascii.encode('ftypheic'), 0, 0, 0, 0, ...ascii.encode('mif1')],
    'AVIF brand outside ftyp box': <int>[0, 0, 0, 16, ...ascii.encode('ftypmif1'), 0, 0, 0, 0, ...ascii.encode('avif')],
    'AVIF compatible brand beyond the 64-byte header cap': <int>[
      0, 0, 0, 68,
      ...ascii.encode('ftypmif1'),
      ...List<int>.filled(52, 0),
      ...ascii.encode('avif'),
    ],
    'truncated PNG signature': tinyMangaPng.take(7).toList(),
    'empty': <int>[],
  }.entries) {
    test('digest-bearing ${body.key} page fails even with a matching hash', () async {
      final directory = await Directory.systemTemp.createTemp('aw-image-reject-');
      addTearDown(() => directory.delete(recursive: true));
      final page = File(p.join(directory.path, '0001.webp'));
      await page.writeAsBytes(body.value, flush: true);
      final manifest = _singlePageManifest(
        digest: await MangaChapterManifestV2.pageDigest(page),
      );
      await manifest.writeTo(directory);
      final restored = (await MangaChapterManifestV2.readFrom(directory))!;
      expect(restored.version, 1);
      expect(await restored.isPageValid(0, page), isFalse);
    });
  }

  test('digest-bearing validation checks the header and hashes on one open', () async {
    final directory = await Directory.systemTemp.createTemp('aw-bounded-header-');
    addTearDown(() => directory.delete(recursive: true));
    final page = File(p.join(directory.path, 'page'));
    await page.writeAsBytes(tinyMangaJpeg, flush: true);
    final manifest = _singlePageManifest(
      digest: await MangaChapterManifestV2.pageDigest(page),
    );
    final counted = _CountedPageFile(page);
    expect(await manifest.isPageValid(0, counted), isTrue);
    expect(counted.opens, 1);
    expect(counted.closes, 1);
    expect(counted.stats, 2);
    expect(counted.reads.first, 64);
    expect(
      counted.readRequests.skip(1),
      everyElement(lessThanOrEqualTo(64 * 1024)),
    );
    expect(counted.reads.reduce((a, b) => a + b), tinyMangaJpeg.length);
    expect(counted.digestStreams, 0);
  });

  test('unsupported image header is rejected without reading the body', () async {
    final directory = await Directory.systemTemp.createTemp('aw-no-html-hash-');
    addTearDown(() => directory.delete(recursive: true));
    final page = File(p.join(directory.path, 'page'));
    await page.writeAsString('<html>${'a' * 100000}</html>', flush: true);
    final manifest = _singlePageManifest(
      digest: await MangaChapterManifestV2.pageDigest(page),
    );
    final counted = _CountedPageFile(page);
    expect(await manifest.isPageValid(0, counted), isFalse);
    expect(counted.opens, 1);
    expect(counted.closes, 1);
    expect(counted.stats, 1);
    expect(counted.readRequests, <int>[64]);
    expect(counted.reads, <int>[64]);
    expect(counted.digestStreams, 0);
  });

  test('verifies the whole page again after a same-length body edit', () async {
    final directory = await Directory.systemTemp.createTemp('aw-page-hash-body-');
    addTearDown(() => directory.delete(recursive: true));
    final page = File(p.join(directory.path, 'page'));
    final bytes = Uint8List(3 * 64 * 1024 + 17)
      ..setRange(0, tinyMangaJpeg.length, tinyMangaJpeg);
    await page.writeAsBytes(bytes, flush: true);
    final manifest = _singlePageManifest(
      digest: await MangaChapterManifestV2.pageDigest(page),
    );
    expect(await manifest.isPageValid(0, page), isTrue);
    bytes[bytes.length - 1] = 1;
    await page.writeAsBytes(bytes, flush: true);
    expect(await manifest.isPageValid(0, page), isFalse);
    await page.delete();
    expect(await manifest.isPageValid(0, page), isFalse);
  });

  test('body read failure rejects the page and closes the handle', () async {
    final directory = await Directory.systemTemp.createTemp('aw-page-read-fail-');
    addTearDown(() => directory.delete(recursive: true));
    final page = File(p.join(directory.path, 'page'));
    await page.writeAsBytes(tinyMangaJpeg, flush: true);
    final manifest = _singlePageManifest(
      digest: await MangaChapterManifestV2.pageDigest(page),
    );
    final failing = _CountedPageFile(page, failBodyRead: true);
    expect(await manifest.isPageValid(0, failing), isFalse);
    expect(failing.opens, 1);
    expect(failing.reads, <int>[64]);
    expect(failing.closes, 1);
  });

  for (final delete in [false, true]) {
    test('in-flight ${delete ? 'deletion' : 'replacement'} after reading the header is rejected', () async {
      final directory = await Directory.systemTemp.createTemp('aw-page-race-');
      addTearDown(() => directory.delete(recursive: true));
      final page = File(p.join(directory.path, 'page'));
      await page.writeAsBytes(tinyMangaJpeg, flush: true);
      final manifest = _singlePageManifest(
        digest: await MangaChapterManifestV2.pageDigest(page),
      );
      final counted = _CountedPageFile(page, afterHeaderRead: () async {
        if (delete) {
          await page.delete();
        } else {
          final replacement = File(p.join(directory.path, 'replacement'));
          final edited = Uint8List.fromList(tinyMangaJpeg);
          edited[edited.length - 1] ^= 1;
          await replacement.writeAsBytes(edited, flush: true);
          await replacement.setLastModified(DateTime.utc(2000));
          await replacement.rename(page.path);
        }
      });
      expect(await manifest.isPageValid(0, counted), isFalse);
      expect(counted.opens, 1);
      expect(counted.closes, 1);
      expect(counted.stats, 2);
    }, skip: Platform.isWindows);
  }

  test('incomplete checkpoint retains expected digests for rejected pages', () async {
    final directory = await Directory.systemTemp.createTemp('aw-invalid-provenance-');
    addTearDown(() => directory.delete(recursive: true));
    final page = File(p.join(directory.path, '0001.webp'));
    await page.writeAsString('<html>expired source</html>', flush: true);
    final digest = await MangaChapterManifestV2.pageDigest(page);
    await _singlePageManifest(digest: digest)
        .copyWith(completedIndexes: <int>{}, isComplete: false)
        .writeTo(directory);
    final restored = (await MangaChapterManifestV2.readFrom(directory))!;
    expect(restored.completedIndexes, isEmpty);
    expect(restored.pageDigests, <int, String>{0: digest});
    expect(await restored.isPageValid(0, page), isFalse);
  });

  test('uncompleted digest provenance stays bounded and malformed hashes stay invalid', () {
    final hash = List<String>.filled(64, 'a').join();
    final raw = _singlePageManifest().copyWith(completedIndexes: <int>{}, isComplete: false).toJson()
      ..['pageDigests'] = <String, Object?>{'-1': hash, '0': 'bad-hash', '1': hash, '9999': hash};
    final restored = MangaChapterManifestV2.fromJson(raw)!;
    expect(restored.completedIndexes, isEmpty);
    expect(restored.pageDigests, <int, String>{0: 'invalid'});
  });

  test('legacy pages without digests keep nonempty offline compatibility', () async {
    final directory = await Directory.systemTemp.createTemp('aw-legacy-page-');
    addTearDown(() => directory.delete(recursive: true));
    final page = File(p.join(directory.path, '0001.webp'));
    await page.writeAsString('<html>old nonempty artifact</html>', flush: true);
    final manifest = _singlePageManifest();
    expect(await manifest.isPageValid(0, page), isTrue);
    await page.writeAsBytes(<int>[], flush: true);
    expect(await manifest.isPageValid(0, page), isFalse);
  });

  test(
    'failed manifest rename preserves the last durable chapter checkpoint',
    () async {
      final directory = await Directory.systemTemp.createTemp('aw_manifest_');
      addTearDown(() => directory.delete(recursive: true));
      final file = File(
        p.join(directory.path, MangaChapterManifestV2.fileName),
      );
      const original = MangaChapterManifestV2(
        version: MangaChapterManifestV2.currentVersion,
        mangaId: 'manga',
        chapterId: 'chapter',
        pageCount: 2,
        completedIndexes: <int>{0},
        isComplete: false,
      );
      await original.writeTo(directory);
      final replacement = original.copyWith(
        completedIndexes: <int>{0, 1},
        isComplete: true,
      );

      final realFiles = <String, File>{
        file.path: file,
        '${file.path}.tmp': File('${file.path}.tmp'),
      };
      await IOOverrides.runZoned(
        () => expectLater(
          replacement.writeTo(directory),
          throwsA(isA<FileSystemException>()),
        ),
        createFile: (path) => _RenameFailingFile(realFiles[path]!),
      );

      expect(await file.exists(), isTrue);
      expect(jsonDecode(await file.readAsString()), original.toJson());
      expect(
        (await MangaChapterManifestV2.readFrom(directory))!.completedIndexes,
        <int>{0},
      );
    },
  );


  test('recorded page hash rejects nonempty truncated files', () async {
    final directory = await Directory.systemTemp.createTemp('aw_hash_page_');
    addTearDown(() => directory.delete(recursive: true));
    final page = File(p.join(directory.path, '0001.webp'));
    await page.writeAsBytes(tinyMangaPng, flush: true);
    final hash = await MangaChapterManifestV2.pageDigest(page);
    const original = MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1',
      chapterId: 'c1',
      pageCount: 1,
      completedIndexes: <int>{0},
      isComplete: true,
    );
    await original.copyWith(pageDigests: <int, String>{0: hash}).writeTo(directory);

    final verified = (await MangaChapterManifestV2.readFrom(directory))!;
    expect(await verified.isPageValid(0, page), isTrue);
    await page.writeAsBytes(<int>[10], flush: true);
    expect(await verified.isPageValid(0, page), isFalse);
  });

  test('manifest replacement publishes the complete new checkpoint', () async {
    final directory = await Directory.systemTemp.createTemp(
      'aw_manifest_replace_',
    );
    addTearDown(() => directory.delete(recursive: true));
    const original = MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'manga',
      chapterId: 'chapter',
      pageCount: 2,
      completedIndexes: <int>{0},
      isComplete: false,
    );
    await original.writeTo(directory);
    await original
        .copyWith(completedIndexes: <int>{0, 1}, isComplete: true)
        .writeTo(directory);

    final restored = await MangaChapterManifestV2.readFrom(directory);
    expect(restored!.isComplete, isTrue);
    expect(restored.completedIndexes, <int>{0, 1});
    expect(
      await File(p.join(directory.path, 'manifest.json.tmp')).exists(),
      isFalse,
    );
  });
}

final class _RenameFailingFile implements File {
  _RenameFailingFile(this.file);
  final File file;

  @override
  String get path => file.path;

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => file.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );

  @override
  Future<File> rename(String newPath) async =>
      throw FileSystemException('Simulated rename failure', path);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MangaChapterManifestV2 _singlePageManifest({String? digest}) => MangaChapterManifestV2(
  version: MangaChapterManifestV2.currentVersion,
  mangaId: 'm1',
  chapterId: 'c1',
  pageCount: 1,
  completedIndexes: const <int>{0},
  isComplete: true,
  pageDigests: digest == null ? const <int, String>{} : <int, String>{0: digest},
);

final class _CountedPageFile implements File {
  _CountedPageFile(
    this.file, {
    this.failBodyRead = false,
    this.afterHeaderRead,
  });
  final File file;
  final bool failBodyRead;
  final Future<void> Function()? afterHeaderRead;
  final List<int> readRequests = <int>[];
  final List<int> reads = <int>[];
  int stats = 0;
  int opens = 0;
  int closes = 0;
  int digestStreams = 0;

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<int> length() => file.length();

  @override
  Future<FileStat> stat() {
    stats++;
    return file.stat();
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    opens++;
    return _CountedOpenFile(await file.open(mode: mode), this);
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    digestStreams++;
    return file.openRead(start, end);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CountedOpenFile implements RandomAccessFile {
  _CountedOpenFile(this.file, this.owner);
  final RandomAccessFile file;
  final _CountedPageFile owner;

  @override
  Future<Uint8List> read(int count) async {
    owner.readRequests.add(count);
    if (owner.failBodyRead && owner.reads.isNotEmpty) {
      throw FileSystemException('Simulated body read failure', owner.file.path);
    }
    final result = await file.read(count);
    owner.reads.add(result.length);
    if (owner.reads.length == 1) {
      await owner.afterHeaderRead?.call();
    }
    return result;
  }

  @override
  Future<void> close() async {
    owner.closes++;
    await file.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
