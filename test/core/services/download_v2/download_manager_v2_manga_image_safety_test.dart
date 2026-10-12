import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_transport_v2.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/manga_image_fixtures.dart';

void main() {
  test('increasing HTML byte progress cannot replenish manga source renewal budget', () async {
    final temp = await Directory.systemTemp.createTemp('aw-html-renewal-budget-');
    addTearDown(() => temp.delete(recursive: true));
    final gateway = _PageGateway();
    final resolver = _PagesResolver(1);
    final store = InMemoryLogicalDownloadStoreV2();
    final manager = DownloadManagerV2(
      store: store, gateway: gateway, sourceResolver: _UnusedVideoResolver(),
      mangaChapterPageResolver: resolver,
    );
    addTearDown(() async {
      await gateway.settle();
      await manager.dispose();
    });
    final request = _request(temp.path);
    await manager.start(request);
    for (var generation = 0; generation < 4; generation++) {
      await _until(() async => gateway.pageHandles.length >= generation + 1);
      final page = gateway.pageHandles.last;
      page.progress(0.25);
      page.progress(0.50);
      await Future<void>.delayed(Duration.zero);
      await page.complete(utf8.encode('<html>expired source</html>'));
      if (generation < 3) {
        await _until(() async => gateway.startedSpecs.length >= generation + 2);
      }
    }
    await _until(() async =>
        (await store.get(request.logicalId))?.intent == DownloadUserIntent.failed ||
        gateway.startedSpecs.length > 4);
    expect(gateway.startedSpecs, hasLength(4));
    expect(resolver.calls, 4);
    final record = (await store.get(request.logicalId))!;
    expect(record.intent, DownloadUserIntent.failed);
    expect(record.failureCategory, DownloadFailureCategory.sourceExpired);
    expect(record.completedAtMillis, isNull);
    final manifest = (await MangaChapterManifestV2.readFrom(temp))!;
    expect(manifest.isComplete, isFalse);
    expect(manifest.completedIndexes, isEmpty);
    expect(manifest.pageDigests, isEmpty);
  });

  test('new verified pages replenish manga renewal budget for long chapters', () async {
    final temp = await Directory.systemTemp.createTemp('aw-valid-renewal-budget-');
    addTearDown(() => temp.delete(recursive: true));
    final gateway = _PageGateway();
    final resolver = _PagesResolver(8);
    final store = InMemoryLogicalDownloadStoreV2();
    final manager = DownloadManagerV2(
      store: store, gateway: gateway, sourceResolver: _UnusedVideoResolver(),
      mangaChapterPageResolver: resolver,
    );
    addTearDown(() async {
      await gateway.settle();
      await manager.dispose();
    });
    final request = _request(temp.path);
    await manager.start(request);
    for (var pageIndex = 0; pageIndex < 5; pageIndex++) {
      await _until(() async => gateway.hasCurrentPage(pageIndex));
      await gateway.currentPage(pageIndex).complete(tinyMangaPng);
      await _until(() async =>
          (await MangaChapterManifestV2.readFrom(temp))!.completedIndexes.contains(pageIndex));
      await _until(() async => gateway.hasCurrentPage(pageIndex + 1));
      await gateway.currentPage(pageIndex + 1).complete(utf8.encode('<html>expired source</html>'));
      await _until(() async => gateway.startedSpecs.length >= pageIndex + 2);
    }
    expect(gateway.startedSpecs, hasLength(6));
    expect(resolver.calls, 6);
    expect((await store.get(request.logicalId))?.intent, DownloadUserIntent.active);
    // Once valid progress stops, repeated HTML still exhausts the renewed budget.
    for (var stalled = 0; stalled < 3; stalled++) {
      await _until(() async => gateway.hasCurrentPage(5));
      final before = gateway.startedSpecs.length;
      gateway.currentPage(5).progress(0.25);
      gateway.currentPage(5).progress(0.50);
      await Future<void>.delayed(Duration.zero);
      await gateway.currentPage(5).complete(utf8.encode('<html>expired source</html>'));
      await _until(() async => gateway.startedSpecs.length > before ||
          (await store.get(request.logicalId))?.intent == DownloadUserIntent.failed);
    }
    expect(gateway.startedSpecs, hasLength(8));
    expect((await store.get(request.logicalId))?.failureCategory, DownloadFailureCategory.sourceExpired);
    for (var pageIndex = 0; pageIndex < 5; pageIndex++) {
      expect(await File('${temp.path}/${(pageIndex + 1).toString().padLeft(4, '0')}.webp').readAsBytes(), tinyMangaPng);
    }
    await manager.restart(request.logicalId);
    for (var pageIndex = 5; pageIndex < 8; pageIndex++) {
      await _until(() async => gateway.hasCurrentPage(pageIndex));
      await gateway.currentPage(pageIndex).complete(tinyMangaPng);
    }
    await _until(() async => (await store.get(request.logicalId))?.completedAtMillis != null);
    expect(await manager.hasCompletedDownload(request.logicalId), isTrue);
  });
}

DownloadStartRequestV2 _request(String path) => DownloadStartRequestV2(
  logicalId: logicalDownloadIdForMangaChapter(mangaId: 'm1', chapterId: 'c1'),
  mediaKind: DownloadMediaKind.mangaChapter, mediaId: 'm1', unitKey: 'c1',
  variantKey: 'pages', destinationPath: path,
  sourceDescriptor: const <String, Object?>{'chapterId': 'c1'},
  allowPause: true, retries: 1, parallelChunks: 1,
);

Future<void> _until(Future<bool> Function() done) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('expected manga transport condition was not reached');
}

final class _PagesResolver implements MangaChapterPageResolverV2 {
  _PagesResolver(this.pageCount);
  final int pageCount;
  int calls = 0;

  @override
  Future<List<MangaPage>> resolve(Map<String, Object?> descriptor) async {
    calls++;
    return <MangaPage>[
      for (var index = 0; index < pageCount; index++)
        MangaPage(index: index, imageUrl: 'https://cdn.test/$index.webp?generation=$calls'),
    ];
  }
}

final class _UnusedVideoResolver implements DownloadSourceResolverV2 {
  @override
  Future<ResolvedDownloadSourceV2> resolve(Map<String, Object?> descriptor) =>
      throw StateError('manga must not resolve a video source');
}

final class _PageGateway implements BackgroundDownloaderGateway, MangaChapterGatewayV2 {
  final List<MangaChapterTransportSpecV2> startedSpecs = <MangaChapterTransportSpecV2>[];
  final List<_PageHandle> pageHandles = <_PageHandle>[];
  final Map<String, DownloadTransportHandle> parents = <String, DownloadTransportHandle>{};
  final List<Future<DownloadTransportHandle>> pendingStarts = <Future<DownloadTransportHandle>>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) =>
      throw StateError('manga must not start a video task');

  @override
  Future<DownloadTransportHandle> startMangaChapter(MangaChapterTransportSpecV2 spec) async {
    startedSpecs.add(spec);
    final start = MangaChapterTransportV2(startPage: (task) async {
      final page = _PageHandle(task);
      pageHandles.add(page);
      return page;
    }).start(spec);
    pendingStarts.add(start);
    final parent = await start;
    parents[parent.taskId] = parent;
    return parent;
  }

  Future<void> settle() async {
    for (final parent in await Future.wait(pendingStarts)) {
      await parent.cancel();
    }
  }

  bool hasCurrentPage(int index) => pageHandles.any((page) =>
      page.task.pageIndex == index && page.task.taskId.startsWith('${startedSpecs.last.taskId}_'));

  _PageHandle currentPage(int index) => pageHandles.lastWhere((page) =>
      page.task.pageIndex == index && page.task.taskId.startsWith('${startedSpecs.last.taskId}_'));

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => parents[taskId];

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => parents.values.toList();

  @override
  Future<void> removeTracking(String taskId) async {
    parents.remove(taskId);
  }
}

final class _PageHandle implements DownloadTransportHandle {
  _PageHandle(this.task);
  final MangaChapterPageTaskV2 task;
  DownloadTransportSnapshot? value;
  final StreamController<DownloadTransportSnapshot> controller =
      StreamController<DownloadTransportSnapshot>.broadcast();

  @override
  String get taskId => task.taskId;

  @override
  DownloadTransportSnapshot get current => value ?? DownloadTransportSnapshot(
    taskId: taskId, status: DownloadTransportStatus.running, progress: 0,
  );

  @override
  Stream<DownloadTransportSnapshot> get snapshots => controller.stream;

  void progress(double progress) => _emit(DownloadTransportSnapshot(
    taskId: taskId, status: DownloadTransportStatus.running, progress: progress,
    transferredBytes: (progress * 100).toInt(), totalBytes: 100,
  ));

  Future<void> complete(List<int> bytes) async {
    await File(task.destinationPath).writeAsBytes(bytes, flush: true);
    _emit(DownloadTransportSnapshot(
      taskId: taskId, status: DownloadTransportStatus.complete, progress: 1,
      transferredBytes: bytes.length, totalBytes: bytes.length,
    ));
  }

  void _emit(DownloadTransportSnapshot snapshot) {
    value = snapshot;
    controller.add(snapshot);
  }

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async {
    _emit(DownloadTransportSnapshot(
      taskId: taskId, status: DownloadTransportStatus.canceled, progress: current.progress,
    ));
    return true;
  }
}
