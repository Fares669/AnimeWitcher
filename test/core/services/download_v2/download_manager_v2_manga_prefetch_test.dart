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
  DownloadStartRequestV2 chapter(String id, String dir) =>
      DownloadStartRequestV2(
        logicalId: logicalDownloadIdForMangaChapter(
          mangaId: 'm1',
          chapterId: id,
        ),
        mediaKind: DownloadMediaKind.mangaChapter,
        mediaId: 'm1',
        unitKey: id,
        variantKey: 'pages',
        destinationPath: dir,
        sourceDescriptor: <String, Object?>{'chapterId': id},
        allowPause: true,
        retries: 1,
        parallelChunks: 1,
      );

  Future<void> untilSpecs(_Gateway gateway, int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (gateway.mangaSpecs.length < count &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test(
    'a queued chapter resolves its pages at enqueue time, not at promotion',
    () async {
      final temp = await Directory.systemTemp.createTemp('aw-manga-prefetch-');
      addTearDown(() => temp.delete(recursive: true));
      final gateway = _Gateway();
      final resolver = _MangaResolver();
      final manager = DownloadManagerV2(
        store: InMemoryLogicalDownloadStoreV2(),
        gateway: gateway,
        sourceResolver: _VideoResolver(),
        mangaChapterPageResolver: resolver,
        maxConcurrentDownloads: () => 1,
      );
      addTearDown(manager.dispose);

      final first = chapter('1', '${temp.path}/chapter-1');
      final second = chapter('2', '${temp.path}/chapter-2');
      await manager.start(first);
      await untilSpecs(gateway, 1);
      expect(resolver.calls, 1);

      // The second chapter is still queued behind the first, but its page
      // resolution must already be under way: promotion must not pay the
      // multi-second provider chain while holding the admission slot.
      await manager.start(second);
      expect(resolver.calls, 2);
      expect(gateway.mangaSpecs, hasLength(1));

      await manager.cancel(first.logicalId);
      await untilSpecs(gateway, 2);
      expect(gateway.mangaSpecs, hasLength(2));
      // Promotion reused the enqueue-time resolution — no second chain.
      expect(resolver.calls, 2);
    },
  );

  test('queued page resolution is bounded and canceled prefetches free capacity', () async {
    final temp = await Directory.systemTemp.createTemp('aw-prefetch-bound-');
    addTearDown(() => temp.delete(recursive: true));
    final gateway = _Gateway();
    final resolver = _MangaResolver();
    final manager = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(),
      gateway: gateway,
      sourceResolver: _VideoResolver(),
      mangaChapterPageResolver: resolver,
      maxConcurrentDownloads: () => 1,
    );
    addTearDown(manager.dispose);

    final first = chapter('1', '${temp.path}/chapter-1');
    final second = chapter('2', '${temp.path}/chapter-2');
    await manager.start(first);
    await untilSpecs(gateway, 1);
    await manager.start(second);
    await manager.start(chapter('3', '${temp.path}/chapter-3'));
    await manager.start(chapter('4', '${temp.path}/chapter-4'));
    expect(resolver.calls, 2); // The running chapter + one queued prefetch.

    await manager.cancel(second.logicalId);
    await manager.start(chapter('5', '${temp.path}/chapter-5'));
    expect(resolver.calls, 3); // Canceling a queued chapter releases its slot.
  });

  test('promotion re-resolves when the enqueue-time resolution is stale', () async {
    final temp = await Directory.systemTemp.createTemp('aw-manga-stale-');
    addTearDown(() => temp.delete(recursive: true));
    final gateway = _Gateway();
    final resolver = _MangaResolver();
    var nowMillis = 1000000;
    final manager = DownloadManagerV2(
      store: InMemoryLogicalDownloadStoreV2(),
      gateway: gateway,
      sourceResolver: _VideoResolver(),
      mangaChapterPageResolver: resolver,
      maxConcurrentDownloads: () => 1,
      nowMillis: () => nowMillis,
    );
    addTearDown(manager.dispose);

    final first = chapter('1', '${temp.path}/chapter-1');
    final second = chapter('2', '${temp.path}/chapter-2');
    await manager.start(first);
    await untilSpecs(gateway, 1);
    await manager.start(second);
    expect(resolver.calls, 2);

    // The chapter waited in the queue past the freshness window: its
    // enqueue-time page URLs may be expired, so promotion resolves fresh.
    nowMillis += const Duration(minutes: 6).inMilliseconds;
    await manager.cancel(first.logicalId);
    await untilSpecs(gateway, 2);
    expect(gateway.mangaSpecs, hasLength(2));
    expect(resolver.calls, 3);
  });

  test(
    'a failed enqueue-time resolution does not fail the chapter; promotion retries fresh',
    () async {
      final temp = await Directory.systemTemp.createTemp('aw-manga-retry-');
      addTearDown(() => temp.delete(recursive: true));
      final gateway = _Gateway();
      final resolver = _MangaResolver(failFirstAttemptFor: '2');
      final manager = DownloadManagerV2(
        store: InMemoryLogicalDownloadStoreV2(),
        gateway: gateway,
        sourceResolver: _VideoResolver(),
        mangaChapterPageResolver: resolver,
        maxConcurrentDownloads: () => 1,
      );
      addTearDown(manager.dispose);

      final first = chapter('1', '${temp.path}/chapter-1');
      final second = chapter('2', '${temp.path}/chapter-2');
      await manager.start(first);
      await untilSpecs(gateway, 1);
      await manager.start(second);
      // Enqueue-time attempt for chapter 2 happened and failed.
      expect(resolver.attemptsFor('2'), 1);

      await manager.cancel(first.logicalId);
      await untilSpecs(gateway, 2);
      expect(gateway.mangaSpecs, hasLength(2));
      expect(resolver.attemptsFor('2'), 2);
    },
  );
}

final class _MangaResolver implements MangaChapterPageResolverV2 {
  _MangaResolver({this.failFirstAttemptFor});

  final String? failFirstAttemptFor;
  int calls = 0;
  final Map<String, int> _attempts = <String, int>{};

  int attemptsFor(String chapterId) => _attempts[chapterId] ?? 0;

  @override
  Future<List<MangaPage>> resolve(Map<String, Object?> descriptor) async {
    calls++;
    final chapterId = descriptor['chapterId']?.toString() ?? '';
    final attempt = attemptsFor(chapterId) + 1;
    _attempts[chapterId] = attempt;
    if (chapterId == failFirstAttemptFor && attempt == 1) {
      throw StateError('provider unavailable');
    }
    return const <MangaPage>[
      MangaPage(index: 0, imageUrl: 'https://cdn.test/0.webp'),
      MangaPage(index: 1, imageUrl: 'https://cdn.test/1.webp'),
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
  Future<MangaChapterTransportHandleV2?> attachMangaChapterOwnershipV2(
    String parentTaskId, {
    required int configuredConnections,
  }) async => null;

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
