import 'dart:async';
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

void main() {
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
    await File('${temp.path}/0001.webp').writeAsBytes(<int>[1]);
    await File('${temp.path}/0002.webp').writeAsBytes(<int>[2]);

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
    await firstPage.writeAsBytes(<int>[1, 2, 3]);

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
