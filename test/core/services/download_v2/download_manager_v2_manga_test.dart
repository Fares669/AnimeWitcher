import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_transport_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manga start resolves pages and never uses video parallelism', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _Gateway();
    final videoResolver = _VideoResolver();
    final mangaResolver = _MangaResolver();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: videoResolver,
      mangaChapterPageResolver: mangaResolver,
    );
    final logicalId = logicalDownloadIdForMangaChapter(
      mangaId: 'm1',
      chapterId: '12.5',
    );

    await manager.start(
      DownloadStartRequestV2(
        logicalId: logicalId,
        mediaKind: DownloadMediaKind.mangaChapter,
        mediaId: 'm1',
        unitKey: '12.5',
        variantKey: 'pages',
        destinationPath: 'manga/m1/12.5',
        sourceDescriptor: const <String, Object?>{
          'providerId': 'animewitcher.native',
          'mangaUrl': 'https://animewitcher.com/manga/m1',
          'chapterId': '12.5',
        },
        allowPause: true,
        retries: 2,
        parallelChunks: 16,
      ),
    );

    expect(videoResolver.calls, 0);
    expect(mangaResolver.calls, 1);
    expect(gateway.mangaSpecs, hasLength(1));
    expect(gateway.videoSpecs, isEmpty);
    expect(gateway.mangaSpecs.single.pages, hasLength(2));
    expect(gateway.mangaSpecs.single.maxConcurrentPages, 16);

    final record = await store.get(logicalId);
    expect(record, isNotNull);
    expect(record!.parallelChunks, 16);
    expect(record.mediaKind, DownloadMediaKind.mangaChapter);
  });

  test('multiple manga chapters keep configured page connection counts', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _Gateway();
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: _VideoResolver(),
      mangaChapterPageResolver: _MangaResolver(),
      maxConcurrentDownloads: () => 5,
    );

    DownloadStartRequestV2 request(int index) {
      final mangaId = 'm$index';
      final chapterId = '$index';
      return DownloadStartRequestV2(
        logicalId: logicalDownloadIdForMangaChapter(
          mangaId: mangaId,
          chapterId: chapterId,
        ),
        mediaKind: DownloadMediaKind.mangaChapter,
        mediaId: mangaId,
        unitKey: chapterId,
        variantKey: 'pages',
        destinationPath: 'manga/$mangaId/$chapterId',
        sourceDescriptor: <String, Object?>{
          'providerId': 'animewitcher.native',
          'mangaUrl': 'manga://$mangaId',
          'chapterId': chapterId,
        },
        allowPause: true,
        retries: 2,
        parallelChunks: 16,
      );
    }

    final requests = <DownloadStartRequestV2>[
      for (var index = 1; index <= 5; index++) request(index),
    ];

    for (final item in requests) {
      final snapshot = await manager.start(item);
      expect(snapshot.status, DownloadTransportStatus.running);
    }

    expect(gateway.mangaSpecs, hasLength(5));
    expect(gateway.videoSpecs, isEmpty);

    for (final item in requests) {
      final record = await store.get(item.logicalId);
      expect(record, isNotNull);
      expect(record!.awaitingAdmission, isFalse);
      expect(record.parallelChunks, 16);
    }
  });

  test('paused manga relaunch resumes the same generation from manifest', () async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_paused_');
    addTearDown(() => temp.delete(recursive: true));

    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _Gateway();
    final logicalId = logicalDownloadIdForMangaChapter(
      mangaId: 'm1',
      chapterId: '12.5',
    );
    final taskId = taskIdForGeneration(logicalId, 3);
    await store.put(
      LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: logicalId,
        mediaKind: DownloadMediaKind.mangaChapter,
        mediaId: 'm1',
        unitKey: '12.5',
        variantKey: 'pages',
        generation: 3,
        taskId: taskId,
        intent: DownloadUserIntent.paused,
        destinationPath: temp.path,
        sourceDescriptor: const <String, Object?>{
          'providerId': 'animewitcher.native',
          'mangaUrl': 'manga://m1',
          'mangaId': 'm1',
          'chapterId': '12.5',
          'chapterUrl': 'chapter://12.5',
          'chapterName': 'Chapter 12.5',
        },
        parallelChunks: 1,
        updatedAtMillis: 1,
      ),
    );

    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: _VideoResolver(),
      mangaChapterPageResolver: _MangaResolver(),
    );
    await manager.initialize();
    final snapshot = await manager.resume(logicalId);

    expect(snapshot.taskId, taskId);
    expect(gateway.mangaSpecs.single.taskId, taskId);
    final record = await store.get(logicalId);
    expect(record?.generation, 3);
    expect(record?.intent, DownloadUserIntent.active);
  });

  test('active manga relaunch keeps generation instead of duplicating writer', () async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_active_');
    addTearDown(() => temp.delete(recursive: true));

    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _Gateway();
    final logicalId = logicalDownloadIdForMangaChapter(
      mangaId: 'm2',
      chapterId: '7',
    );
    final taskId = taskIdForGeneration(logicalId, 4);
    await store.put(
      LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: logicalId,
        mediaKind: DownloadMediaKind.mangaChapter,
        mediaId: 'm2',
        unitKey: '7',
        variantKey: 'pages',
        generation: 4,
        taskId: taskId,
        intent: DownloadUserIntent.active,
        destinationPath: temp.path,
        sourceDescriptor: const <String, Object?>{
          'providerId': 'animewitcher.native',
          'mangaUrl': 'manga://m2',
          'mangaId': 'm2',
          'chapterId': '7',
          'chapterUrl': 'chapter://7',
          'chapterName': 'Chapter 7',
        },
        parallelChunks: 1,
        updatedAtMillis: 1,
      ),
    );

    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: _VideoResolver(),
      mangaChapterPageResolver: _MangaResolver(),
    );
    await manager.initialize();

    expect(gateway.mangaSpecs.single.taskId, taskId);
    final record = await store.get(logicalId);
    expect(record?.generation, 4);
  });

  test('video start preserves requested parallel width', () async {
    final gateway = _Gateway();
    final manager = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(),
      gateway: gateway,
      sourceResolver: _VideoResolver(),
      mangaChapterPageResolver: _MangaResolver(),
    );
    final logicalId = logicalDownloadIdFor(
      animeId: 'a1',
      episodeKey: '1',
      variantKey: 'sub',
    );

    await manager.start(
      DownloadStartRequestV2(
        logicalId: logicalId,
        animeId: 'a1',
        episodeKey: '1',
        variantKey: 'sub',
        destinationPath: 'downloads/a1/1.mp4',
        sourceDescriptor: const <String, Object?>{'providerId': 'p'},
        allowPause: true,
        retries: 2,
        parallelChunks: 8,
      ),
    );

    expect(gateway.videoSpecs, hasLength(1));
    expect(gateway.videoSpecs.single.parallelChunks, 8);
    expect(gateway.mangaSpecs, isEmpty);
  });
}

final class _MangaResolver implements MangaChapterPageResolverV2 {
  int calls = 0;

  @override
  Future<List<MangaPage>> resolve(Map<String, Object?> descriptor) async {
    calls++;
    return const <MangaPage>[
      MangaPage(index: 0, imageUrl: 'https://cdn.test/0.webp'),
      MangaPage(index: 1, imageUrl: 'https://cdn.test/1.webp'),
    ];
  }
}

final class _VideoResolver implements DownloadSourceResolverV2 {
  int calls = 0;

  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    calls++;
    return const ResolvedDownloadSourceV2(
      url: 'https://cdn.test/video.mp4',
    );
  }
}

final class _Gateway
    implements BackgroundDownloaderGateway, MangaChapterGatewayV2 {
  final List<DownloadTaskSpecV2> videoSpecs = <DownloadTaskSpecV2>[];
  final List<MangaChapterTransportSpecV2> mangaSpecs =
      <MangaChapterTransportSpecV2>[];
  final Map<String, _Handle> handles = <String, _Handle>{};

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    videoSpecs.add(spec);
    return handles.putIfAbsent(spec.taskId, () => _Handle(spec.taskId));
  }

  @override
  Future<DownloadTransportHandle> startMangaChapter(
    MangaChapterTransportSpecV2 spec,
  ) async {
    mangaSpecs.add(spec);
    return handles.putIfAbsent(spec.taskId, () => _Handle(spec.taskId));
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async =>
      handles[taskId];

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async =>
      handles.values.toList(growable: false);

  @override
  Future<void> removeTracking(String taskId) async {
    handles.remove(taskId);
  }
}

final class _Handle implements DownloadTransportHandle {
  _Handle(this.taskId)
      : _current = DownloadTransportSnapshot(
          taskId: taskId,
          status: DownloadTransportStatus.running,
          progress: 0,
        );

  @override
  final String taskId;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast();
  DownloadTransportSnapshot _current;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  void _emit(DownloadTransportStatus status) {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: status,
      progress: 0,
    );
    _controller.add(_current);
  }

  @override
  Future<bool> pause() async {
    _emit(DownloadTransportStatus.paused);
    return true;
  }

  @override
  Future<bool> resume() async {
    _emit(DownloadTransportStatus.running);
    return true;
  }

  @override
  Future<bool> cancel() async {
    _emit(DownloadTransportStatus.canceled);
    return true;
  }
}
