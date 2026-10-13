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

  test('digest-bearing validation reads at most 64 header bytes and hashes once', () async {
    final directory = await Directory.systemTemp.createTemp('aw-bounded-header-');
    addTearDown(() => directory.delete(recursive: true));
    final page = File(p.join(directory.path, 'page'));
    await page.writeAsBytes(tinyMangaJpeg, flush: true);
    final manifest = _singlePageManifest(
      digest: await MangaChapterManifestV2.pageDigest(page),
    );
    final counted = _CountedPageFile(page);
    expect(await manifest.isPageValid(0, counted), isTrue);
    expect(counted.headerReads, <int>[64]);
    expect(counted.digestReads, 1);
  });

  test('unsupported image header is rejected before hashing the body', () async {
    final directory = await Directory.systemTemp.createTemp('aw-no-html-hash-');
    addTearDown(() => directory.delete(recursive: true));
    final page = File(p.join(directory.path, 'page'));
    await page.writeAsString('<html>expired</html>', flush: true);
    final manifest = _singlePageManifest(
      digest: await MangaChapterManifestV2.pageDigest(page),
    );
    final counted = _CountedPageFile(page);
    expect(await manifest.isPageValid(0, counted), isFalse);
    expect(counted.headerReads, <int>[64]);
    expect(counted.digestReads, 0);
  });

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
  _CountedPageFile(this.file);
  final File file;
  final List<int> headerReads = <int>[];
  int digestReads = 0;

  @override
  Future<bool> exists() => file.exists();

  @override
  Future<int> length() => file.length();

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _CountedHeaderFile(await file.open(mode: mode), headerReads);

  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    digestReads++;
    return file.openRead(start, end);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CountedHeaderFile implements RandomAccessFile {
  _CountedHeaderFile(this.file, this.reads);
  final RandomAccessFile file;
  final List<int> reads;

  @override
  Future<Uint8List> read(int count) {
    reads.add(count);
    return file.read(count);
  }

  @override
  Future<void> close() => file.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
