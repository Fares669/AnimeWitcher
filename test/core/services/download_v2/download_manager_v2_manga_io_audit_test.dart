import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../support/manga_image_fixtures.dart';
import 'download_v2_test_support.dart';

void main() {
  test('200-page completed manga verification lists once and hashes each selected file once', () async {
    final directory = await Directory.systemTemp.createTemp('aw-manga-io-');
    addTearDown(() => directory.delete(recursive: true));
    final digest = sha256.convert(tinyMangaPng).toString();
    for (var index = 0; index < 200; index++) {
      await File(p.join(directory.path, '${(index + 1).toString().padLeft(4, '0')}.png'))
          .writeAsBytes(tinyMangaPng);
    }
    await MangaChapterManifestV2(
      version: 1, mangaId: 'manga-io', chapterId: 'chapter-io', pageCount: 200,
      completedIndexes: {for (var index = 0; index < 200; index++) index},
      pageDigests: {for (var index = 0; index < 200; index++) index: digest},
      isComplete: true,
    ).writeTo(directory);
    final store = InMemoryLogicalDownloadStoreV2();
    final record = _completedRecord(directory.path);
    await store.put(record);
    final manager = _manager(store);
    addTearDown(manager.dispose);
    await manager.initialize();
    final io = _CountingIO(directory.path);
    expect(await IOOverrides.runWithIOOverrides(
      () => manager.hasCompletedDownload(record.logicalId), io,
    ), isTrue);
    expect(<String, Object>{
      'directoryListings': io.listings,
      'pageHashStreams': io.pageReads.values.fold<int>(0, (sum, count) => sum + count),
      'distinctPagesHashed': io.pageReads.length,
      'everyPageHashedOnce': io.pageReads.values.every((count) => count == 1),
    }, <String, Object>{
      'directoryListings': 1, 'pageHashStreams': 200,
      'distinctPagesHashed': 200, 'everyPageHashedOnce': true,
    });
  });

  test('manga alternate extension selection validates its digest and notices later edits', () async {
    final directory = await Directory.systemTemp.createTemp('aw-manga-alternate-');
    addTearDown(() => directory.delete(recursive: true));
    final stale = File(p.join(directory.path, '0001.webp'));
    final valid = File(p.join(directory.path, '0001.png'));
    await stale.writeAsBytes(tinyMangaJpeg);
    await valid.writeAsBytes(tinyMangaPng);
    final expected = sha256.convert(tinyMangaPng).toString();
    await MangaChapterManifestV2(
      version: 1, mangaId: 'manga-io', chapterId: 'chapter-io', pageCount: 1,
      completedIndexes: const {0}, pageDigests: {0: expected}, isComplete: true,
    ).writeTo(directory);
    final store = InMemoryLogicalDownloadStoreV2();
    final record = _completedRecord(directory.path);
    await store.put(record);
    final manager = _manager(store);
    addTearDown(manager.dispose);
    expect(await manager.hasCompletedDownload(record.logicalId), isTrue);
    expect(await stale.readAsBytes(), tinyMangaJpeg);
    await valid.writeAsBytes(tinyMangaGif89a);
    expect(await manager.hasCompletedDownload(record.logicalId), isFalse);
    final repaired = (await MangaChapterManifestV2.readFrom(directory))!;
    expect(repaired.completedIndexes, isEmpty);
    expect(repaired.pageDigests, {0: expected});
    expect(await valid.readAsBytes(), tinyMangaGif89a);
  });

  test('giant corrupted manga count repairs from actual files without unbounded scans', () async {
    final directory = await Directory.systemTemp.createTemp('aw-manga-count-');
    addTearDown(() => directory.delete(recursive: true));
    final good = File(p.join(directory.path, '0001.png'));
    final bad = File(p.join(directory.path, '0002.webp'));
    final html = utf8.encode('<html>source expired</html>');
    await good.writeAsBytes(tinyMangaPng);
    await bad.writeAsBytes(html);
    final digests = <int, String>{
      0: sha256.convert(tinyMangaPng).toString(), 1: sha256.convert(html).toString(),
    };
    await MangaChapterManifestV2(
      version: 1, mangaId: 'manga-io', chapterId: 'chapter-io',
      pageCount: 2147483647, completedIndexes: const {0, 1},
      pageDigests: digests, isComplete: true,
    ).writeTo(directory);
    final store = InMemoryLogicalDownloadStoreV2();
    final record = _completedRecord(directory.path);
    await store.put(record);
    final manager = _manager(store);
    addTearDown(manager.dispose);
    // Abort the old billion-page traversal without leaking its async startup.
    final io = _CountingIO(directory.path, listingLimit: 8);
    await IOOverrides.runWithIOOverrides(manager.initialize, io);
    expect(io.listings, lessThanOrEqualTo(3));
    final saved = (await store.get(record.logicalId))!;
    expect(saved.intent, DownloadUserIntent.failed);
    expect(saved.failureCategory, DownloadFailureCategory.integrity);
    expect(saved.completedAtMillis, isNull);
    final repaired = (await MangaChapterManifestV2.readFrom(directory))!;
    expect(repaired.pageCount, 2147483647);
    expect(repaired.completedIndexes, {0});
    expect(repaired.pageDigests, digests);
    expect(repaired.isComplete, isFalse);
    expect(await good.readAsBytes(), tinyMangaPng);
    expect(await bad.readAsBytes(), html);
  });
}

LogicalDownloadRecordV2 _completedRecord(String directory) {
  final logicalId = logicalDownloadIdForMangaChapter(mangaId: 'manga-io', chapterId: 'chapter-io');
  return LogicalDownloadRecordV2(
    schemaVersion: kLogicalDownloadSchemaVersionV2,
    logicalId: logicalId, mediaKind: DownloadMediaKind.mangaChapter,
    mediaId: 'manga-io', unitKey: 'chapter-io', variantKey: 'pages',
    generation: 1, taskId: taskIdForGeneration(logicalId, 1),
    intent: DownloadUserIntent.active, destinationPath: directory,
    sourceDescriptor: const {}, updatedAtMillis: 1, completedAtMillis: 1,
  );
}

DownloadManagerV2 _manager(LogicalDownloadStoreV2 store) => DownloadManagerV2(
  store: store, gateway: _NoTransportGateway(), sourceResolver: StaticSourceResolverV2(),
);

final class _NoTransportGateway implements BackgroundDownloaderGateway {
  @override
  Future<void> initialize() async {}
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) =>
      throw StateError('completed verification must not start transport');
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => null;
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => [];
  @override
  Future<void> removeTracking(String taskId) async {}
}

final class _CountingIO extends IOOverrides {
  _CountingIO(this.chapterPath, {this.listingLimit});
  final String chapterPath;
  final int? listingLimit;
  int listings = 0;
  final pageReads = <String, int>{};
  @override
  Directory createDirectory(String path) => _CountedDirectory(super.createDirectory(path), this);
  @override
  File createFile(String path) => _CountedFile(super.createFile(path), this);
  File wrap(File file) => file is _CountedFile ? file : _CountedFile(file, this);
}

final class _CountedDirectory implements Directory {
  _CountedDirectory(this.delegate, this.io);
  final Directory delegate;
  final _CountingIO io;
  @override
  String get path => delegate.path;
  @override
  Uri get uri => delegate.uri;
  @override
  Directory get absolute => io.createDirectory(delegate.absolute.path);
  @override
  Directory get parent => io.createDirectory(p.dirname(path));
  @override
  Future<bool> exists() => delegate.exists();
  @override
  Future<String> resolveSymbolicLinks() => delegate.resolveSymbolicLinks();
  @override
  Future<Directory> create({bool recursive = false}) async {
    await delegate.create(recursive: recursive);
    return this;
  }
  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) {
    if (p.normalize(path) == p.normalize(io.chapterPath)) {
      io.listings++;
      if (io.listingLimit != null && io.listings > io.listingLimit!) {
        throw StateError('test-only directory traversal limit exceeded');
      }
    }
    return delegate.list(recursive: recursive, followLinks: followLinks).map((entity) =>
        entity is File ? io.wrap(entity) : entity);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CountedFile implements File {
  _CountedFile(this.delegate, this.io);
  final File delegate;
  final _CountingIO io;
  @override
  String get path => delegate.path;
  @override
  Uri get uri => delegate.uri;
  @override
  File get absolute => io.wrap(delegate.absolute);
  @override
  Directory get parent => io.createDirectory(p.dirname(path));
  @override
  Future<bool> exists() => delegate.exists();
  @override
  Future<int> length() => delegate.length();
  @override
  Future<String> resolveSymbolicLinks() => delegate.resolveSymbolicLinks();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) => delegate.open(mode: mode);
  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    if (RegExp(r'^\d+\.').hasMatch(p.basename(path))) {
      io.pageReads.update(path, (count) => count + 1, ifAbsent: () => 1);
    }
    return delegate.openRead(start, end);
  }
  @override
  Future<String> readAsString({Encoding encoding = utf8}) => delegate.readAsString(encoding: encoding);
  @override
  Future<File> writeAsString(String contents, {
    FileMode mode = FileMode.write, Encoding encoding = utf8, bool flush = false,
  }) async {
    await delegate.writeAsString(contents, mode: mode, encoding: encoding, flush: flush);
    return this;
  }
  @override
  Future<File> rename(String newPath) async => io.wrap(await delegate.rename(newPath));
  @override
  Future<File> delete({bool recursive = false}) async {
    await delegate.delete(recursive: recursive);
    return this;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
