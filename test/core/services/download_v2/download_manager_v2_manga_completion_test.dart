import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_file_planner_v2.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_transport_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/manga_image_fixtures.dart';

void main() {
  test('repeated startup repair never reclassifies hashed HTML as legacy', () async {
    final temp = await Directory.systemTemp.createTemp('aw-manga-html-repair-');
    addTearDown(() => temp.delete(recursive: true));
    final good = File('${temp.path}/0001.webp');
    final bad = File('${temp.path}/0002.webp');
    await good.writeAsBytes(tinyMangaPng, flush: true);
    await bad.writeAsString('<html>expired source</html>', flush: true);
    final goodDigest = await MangaChapterManifestV2.pageDigest(good);
    final badDigest = await MangaChapterManifestV2.pageDigest(bad);
    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1', chapterId: '1', pageCount: 2,
      completedIndexes: const <int>{0, 1}, isComplete: true,
      pageDigests: <int, String>{0: goodDigest, 1: badDigest},
    ).writeTo(temp);
    final logicalId = logicalDownloadIdForMangaChapter(mangaId: 'm1', chapterId: '1');
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: logicalId, mediaKind: DownloadMediaKind.mangaChapter,
      mediaId: 'm1', unitKey: '1', variantKey: 'pages', generation: 1,
      taskId: taskIdForGeneration(logicalId, 1), intent: DownloadUserIntent.active,
      destinationPath: temp.path,
      sourceDescriptor: const <String, Object?>{'chapterId': '1'},
      completedAtMillis: 1, updatedAtMillis: 1,
    ));
    for (var reopen = 0; reopen < 2; reopen++) {
      final manager = DownloadManagerV2(store: store, gateway: _Gateway(), sourceResolver: _VideoResolver());
      try {
        await manager.initialize();
        for (var check = 0; check < 3; check++) {
          expect(await manager.hasCompletedDownload(logicalId), isFalse);
        }
        final record = (await store.get(logicalId))!;
        expect(record.completedAtMillis, isNull);
        expect(record.failureCategory, DownloadFailureCategory.integrity);
        final repaired = (await MangaChapterManifestV2.readFrom(temp))!;
        expect(repaired.isComplete, isFalse);
        expect(repaired.completedIndexes, <int>{0});
        expect(repaired.pageDigests, <int, String>{0: goodDigest, 1: badDigest});
        expect(await good.readAsBytes(), tinyMangaPng);
        expect(await bad.readAsString(), '<html>expired source</html>');
      } finally {
        await manager.dispose();
      }
    }
  });

  test('fresh completion callback cannot publish a timestamp for hashed HTML', () async {
    final temp = await Directory.systemTemp.createTemp('aw-manga-html-callback-');
    addTearDown(() => temp.delete(recursive: true));
    final good = File('${temp.path}/0001.webp');
    final bad = File('${temp.path}/0002.webp');
    await good.writeAsBytes(tinyMangaPng, flush: true);
    await bad.writeAsString('<html>expired source</html>', flush: true);
    final goodDigest = await MangaChapterManifestV2.pageDigest(good);
    final badDigest = await MangaChapterManifestV2.pageDigest(bad);
    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1', chapterId: '1', pageCount: 2,
      completedIndexes: const <int>{0, 1}, isComplete: true,
      pageDigests: <int, String>{0: goodDigest, 1: badDigest},
    ).writeTo(temp);
    final gateway = _Gateway();
    final store = InMemoryLogicalDownloadStoreV2();
    final manager = DownloadManagerV2(
      store: store, gateway: gateway, sourceResolver: _VideoResolver(),
      mangaChapterPageResolver: _MangaResolver(),
    );
    addTearDown(manager.dispose);
    final id = logicalDownloadIdForMangaChapter(mangaId: 'm1', chapterId: '1');
    await manager.start(DownloadStartRequestV2(
      logicalId: id, mediaKind: DownloadMediaKind.mangaChapter,
      mediaId: 'm1', unitKey: '1', variantKey: 'pages', destinationPath: temp.path,
      sourceDescriptor: const <String, Object?>{'chapterId': '1'},
      allowPause: true, retries: 1, parallelChunks: 1,
    ));
    gateway.handle.complete();
    for (var attempt = 0; attempt < 100; attempt++) {
      final record = (await store.get(id))!;
      if (record.completedAtMillis != null || record.intent == DownloadUserIntent.failed) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect((await store.get(id))!.completedAtMillis, isNull);
    expect(await manager.hasCompletedDownload(id), isFalse);
    expect((await MangaChapterManifestV2.readFrom(temp))!.pageDigests,
        <int, String>{0: goodDigest, 1: badDigest});
    expect(await good.readAsBytes(), tinyMangaPng);
  });

  test('retry request recomputed by planner retains failed chapter destination', () async {
    final temp = await Directory.systemTemp.createTemp('aw-manga-legacy-retry-');
    addTearDown(() => temp.delete(recursive: true));
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _LegacyPaths(temp.path);
    addTearDown(() => PathProviderPlatform.instance = previous);
    final oldPath = p.join(temp.path, 'manga', 'Foo.', 'Chapter');
    final good = File(p.join(oldPath, '0001.webp'));
    await good.create(recursive: true);
    await good.writeAsBytes(tinyMangaPng, flush: true);
    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1', chapterId: '1', pageCount: 2,
      completedIndexes: const <int>{0}, isComplete: false,
      pageDigests: <int, String>{0: await MangaChapterManifestV2.pageDigest(good)},
    ).writeTo(Directory(oldPath));
    final id = logicalDownloadIdForMangaChapter(mangaId: 'm1', chapterId: '1');
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: id, mediaKind: DownloadMediaKind.mangaChapter,
      mediaId: 'm1', unitKey: '1', variantKey: 'pages', generation: 1,
      taskId: taskIdForGeneration(id, 1), intent: DownloadUserIntent.failed,
      destinationPath: oldPath,
      sourceDescriptor: const <String, Object?>{'chapterId': '1'},
      failureCategory: DownloadFailureCategory.sourceExpired, updatedAtMillis: 1,
    ));
    final recomputed = await mangaChapterDestinationDirectoryV2(
      MultimediaItem(title: 'Foo.', url: '/manga', posterUrl: ''),
      const MangaChapter(id: '1', mangaId: 'm1', url: '/chapter', name: 'Chapter'),
    );
    final manager = DownloadManagerV2(
      store: store, gateway: _Gateway(), sourceResolver: _VideoResolver(),
      mangaChapterPageResolver: _MangaResolver(),
    );
    addTearDown(manager.dispose);
    await manager.start(DownloadStartRequestV2(
      logicalId: id, mediaKind: DownloadMediaKind.mangaChapter,
      mediaId: 'm1', unitKey: '1', variantKey: 'pages', destinationPath: recomputed,
      sourceDescriptor: const <String, Object?>{'chapterId': '1'},
      allowPause: true, retries: 1, parallelChunks: 1,
    ));
    expect((await store.get(id))!.destinationPath, oldPath);
    expect(await good.readAsBytes(), tinyMangaPng);
  });

  test('manga completion validates manifest directory instead of video file', () async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_complete_');
    addTearDown(() => temp.delete(recursive: true));

    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1',
      chapterId: '1',
      pageCount: 2,
      completedIndexes: const <int>{0, 1},
      isComplete: true,
    ).writeTo(temp);
    await File('${temp.path}/0001.webp').writeAsBytes(tinyMangaPng);
    await File('${temp.path}/0002.webp').writeAsBytes(tinyMangaPng);

    final gateway = _Gateway();
    final store = InMemoryLogicalDownloadStoreV2();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: _VideoResolver(),
      mangaChapterPageResolver: _MangaResolver(),
    );
    final logicalId = logicalDownloadIdForMangaChapter(
      mangaId: 'm1',
      chapterId: '1',
    );

    await manager.start(
      DownloadStartRequestV2(
        logicalId: logicalId,
        mediaKind: DownloadMediaKind.mangaChapter,
        mediaId: 'm1',
        unitKey: '1',
        variantKey: 'pages',
        destinationPath: temp.path,
        sourceDescriptor: const <String, Object?>{'chapterId': '1'},
        allowPause: true,
        retries: 1,
        parallelChunks: 16,
      ),
    );

    gateway.handle.complete();
    for (var attempt = 0; attempt < 100; attempt++) {
      final record = await store.get(logicalId);
      if (record?.completedAtMillis != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(await manager.hasCompletedDownload(logicalId), isTrue);
    final record = await store.get(logicalId);
    expect(record?.completedAtMillis, isNotNull);
  });
  test('verified page hash wins over stale same-index extension', () async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_dupe_ext_');
    addTearDown(() => temp.delete(recursive: true));

    await File('${temp.path}/0001.webp').writeAsBytes(<int>[9], flush: true);
    final good = File('${temp.path}/0001.jpg');
    await good.writeAsBytes(tinyMangaPng, flush: true);
    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1',
      chapterId: '1',
      pageCount: 1,
      completedIndexes: const <int>{0},
      isComplete: true,
      pageDigests: <int, String>{
        0: await MangaChapterManifestV2.pageDigest(good),
      },
    ).writeTo(temp);

    final logicalId = logicalDownloadIdForMangaChapter(
      mangaId: 'm1', chapterId: '1',
    );
    final store = InMemoryLogicalDownloadStoreV2();
    await store.put(LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: logicalId,
      mediaKind: DownloadMediaKind.mangaChapter,
      mediaId: 'm1',
      unitKey: '1',
      variantKey: 'pages',
      generation: 1,
      taskId: taskIdForGeneration(logicalId, 1),
      intent: DownloadUserIntent.active,
      destinationPath: temp.path,
      sourceDescriptor: const <String, Object?>{'chapterId': '1'},
      completedAtMillis: 1,
      updatedAtMillis: 1,
    ));
    final manager = DownloadManagerV2(
      store: store,
      gateway: _Gateway(),
      sourceResolver: _VideoResolver(),
    );
    addTearDown(manager.dispose);
    await manager.initialize();

    expect(await manager.hasCompletedDownload(logicalId), isTrue);
    expect(await good.readAsBytes(), tinyMangaPng);
  });

  test('invalid manga completion preserves valid pages and repairs manifest', () async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_preserve_');
    addTearDown(() => temp.delete(recursive: true));

    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm2',
      chapterId: '2',
      pageCount: 2,
      completedIndexes: const <int>{0, 1},
      isComplete: true,
    ).writeTo(temp);
    final firstPage = File('${temp.path}/0001.webp');
    await firstPage.writeAsBytes(tinyMangaPng);

    final gateway = _Gateway();
    final store = InMemoryLogicalDownloadStoreV2();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: _VideoResolver(),
      mangaChapterPageResolver: _MangaResolver(),
    );
    final logicalId = logicalDownloadIdForMangaChapter(
      mangaId: 'm2',
      chapterId: '2',
    );

    await manager.start(
      DownloadStartRequestV2(
        logicalId: logicalId,
        mediaKind: DownloadMediaKind.mangaChapter,
        mediaId: 'm2',
        unitKey: '2',
        variantKey: 'pages',
        destinationPath: temp.path,
        sourceDescriptor: const <String, Object?>{'chapterId': '2'},
        allowPause: true,
        retries: 1,
        parallelChunks: 1,
      ),
    );

    gateway.handle.complete();
    for (var attempt = 0; attempt < 100; attempt++) {
      final record = await store.get(logicalId);
      if (record?.failureCategory == DownloadFailureCategory.integrity) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(await temp.exists(), isTrue);
    expect(await firstPage.exists(), isTrue);
    final repaired = await MangaChapterManifestV2.readFrom(temp);
    expect(repaired, isNotNull);
    expect(repaired!.completedIndexes, <int>{0});
    expect(repaired.isComplete, isFalse);
    final record = await store.get(logicalId);
    expect(record?.completedAtMillis, isNull);
    expect(record?.failureCategory, DownloadFailureCategory.integrity);
  });
}

final class _MangaResolver implements MangaChapterPageResolverV2 {
  @override
  Future<List<MangaPage>> resolve(Map<String, Object?> descriptor) async {
    final chapterId = descriptor['chapterId']?.toString() ?? '1';
    return <MangaPage>[
      MangaPage(index: 0, imageUrl: 'https://cdn.test/$chapterId/0.webp'),
      MangaPage(index: 1, imageUrl: 'https://cdn.test/$chapterId/1.webp'),
    ];
  }
}

final class _VideoResolver implements DownloadSourceResolverV2 {
  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async => const ResolvedDownloadSourceV2(url: 'https://cdn.test/video.mp4');
}

final class _Gateway
    implements BackgroundDownloaderGateway, MangaChapterGatewayV2 {
  final _Handle handle = _Handle('manga-parent');

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async => handle;

  @override
  Future<DownloadTransportHandle> startMangaChapter(
    MangaChapterTransportSpecV2 spec,
  ) async {
    handle.taskIdValue = spec.taskId;
    return handle;
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => null;

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async =>
      const <DownloadTransportHandle>[];

  @override
  Future<void> removeTracking(String taskId) async {}
}

final class _Handle implements DownloadTransportHandle {
  _Handle(this.taskIdValue);

  String taskIdValue;
  DownloadTransportSnapshot? _current;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast();

  @override
  String get taskId => taskIdValue;

  @override
  DownloadTransportSnapshot get current =>
      _current ??
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.running,
        progress: 0,
      );

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  void complete() {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.complete,
      progress: 1,
    );
    _controller.add(_current!);
  }

  @override
  Future<bool> pause() async => true;
  @override
  Future<bool> resume() async => true;
  @override
  Future<bool> cancel() async => true;
}

final class _LegacyPaths extends PathProviderPlatform {
  _LegacyPaths(this.path);
  final String path;

  @override
  Future<String?> getDownloadsPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
