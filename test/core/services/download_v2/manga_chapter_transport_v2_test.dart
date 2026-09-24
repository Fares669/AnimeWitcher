import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_transport_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'manga chapter fills 16 page connections and reuses freed slots',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'aw_manga_transport_',
      );
      addTearDown(() => temp.delete(recursive: true));

      final starter = _FakePageStarter();
      final transport = MangaChapterTransportV2(startPage: starter.start);
      final handle = await transport.start(
        MangaChapterTransportSpecV2(
          taskId: 'chapter-parent',
          mangaId: 'm1',
          chapterId: '12.5',
          destinationDirectory: temp.path,
          pages: <MangaPage>[
            for (var index = 0; index < 20; index++)
              MangaPage(index: index, imageUrl: 'https://cdn.test/$index.webp'),
          ],
          retries: 2,
          maxConcurrentPages: 16,
        ),
      );

      expect(starter.startedPageIndexes, List<int>.generate(16, (i) => i));
      expect(starter.maxActive, 16);
      await Future<void>.delayed(Duration.zero);
      expect(handle.current.configuredConnections, 16);
      expect(handle.current.activeConnections, 16);

      await Future.wait(List<Future<void>>.generate(16, starter.complete));
      await _waitUntilStartedCount(starter, 20);
      for (var index = 16; index < 20; index++) {
        await starter.complete(index);
      }

      await _waitForStatus(handle, DownloadTransportStatus.complete);
      expect(starter.startedPageIndexes, List<int>.generate(20, (i) => i));
      expect(starter.maxActive, 16);
      expect(handle.current.status, DownloadTransportStatus.complete);
      expect(handle.current.progress, 1);

      final manifest = await MangaChapterManifestV2.readFrom(temp);
      expect(manifest, isNotNull);
      expect(
        manifest!.completedIndexes,
        Set<int>.from(List<int>.generate(20, (i) => i)),
      );
      expect(manifest.isComplete, isTrue);
    },
  );

  test('manga chapter starts only as many pages as it has', () async {
    final temp = await Directory.systemTemp.createTemp(
      'aw_manga_small_chapter_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final starter = _FakePageStarter();
    final transport = MangaChapterTransportV2(startPage: starter.start);
    final handle = await transport.start(
      MangaChapterTransportSpecV2(
        taskId: 'chapter-small',
        mangaId: 'm1',
        chapterId: '2',
        destinationDirectory: temp.path,
        pages: List<MangaPage>.generate(
          10,
          (index) => MangaPage(
            index: index,
            imageUrl: 'https://cdn.test/$index.webp',
          ),
        ),
        retries: 2,
        maxConcurrentPages: 16,
      ),
    );

    await Future<void>.delayed(Duration.zero);
    expect(starter.maxActive, 10);
    expect(starter.startedPageIndexes, List<int>.generate(10, (i) => i));
    expect(handle.current.configuredConnections, 16);
    expect(handle.current.activeConnections, 10);

    for (var index = 0; index < 10; index++) {
      await starter.complete(index);
    }
    await _waitForStatus(handle, DownloadTransportStatus.complete);
  });

  test('manga page downloads use compatible image request headers', () async {
    final temp = await Directory.systemTemp.createTemp(
      'aw_manga_image_headers_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final starter = _FakePageStarter();
    final transport = MangaChapterTransportV2(startPage: starter.start);
    await transport.start(
      MangaChapterTransportSpecV2(
        taskId: 'chapter-headers',
        mangaId: 'm1',
        chapterId: '18',
        destinationDirectory: temp.path,
        pages: const <MangaPage>[
          MangaPage(
            index: 0,
            imageUrl: 'https://tempsolo.mangalik.net/chapter/1.jpg',
            headers: <String, String>{
              'Referer': 'https://mangalik.net/manga/example/18/',
            },
          ),
        ],
        retries: 2,
        maxConcurrentPages: 1,
      ),
    );

    await starter.waitUntilStarted(0);
    final headers = starter.startedTasks.single.headers;
    expect(
      headers['Referer'],
      'https://mangalik.net/manga/example/18/',
    );
    final userAgents = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'user-agent')
        .map((entry) => entry.value)
        .toList();
    expect(userAgents, hasLength(1));
    expect(userAgents.single, isNot(contains('Dart/')));
  });

  test('failed page pause resumes pages that already paused', () async {
    final temp = await Directory.systemTemp.createTemp(
      'aw_manga_partial_pause_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final starter = _FakePageStarter();
    final transport = MangaChapterTransportV2(startPage: starter.start);
    final handle = await transport.start(
      MangaChapterTransportSpecV2(
        taskId: 'chapter-pause-rollback',
        mangaId: 'm1',
        chapterId: '3',
        destinationDirectory: temp.path,
        pages: const <MangaPage>[
          MangaPage(index: 0, imageUrl: 'https://cdn.test/0.webp'),
          MangaPage(index: 1, imageUrl: 'https://cdn.test/1.webp'),
        ],
        retries: 2,
        maxConcurrentPages: 2,
      ),
    );
    addTearDown(() async {
      await handle.cancel();
    });

    starter.handles[1]!.pauseAccepted = false;

    expect(await handle.pause(), isFalse);
    expect(starter.handles[0]!.current.status, DownloadTransportStatus.running);
    expect(starter.handles[0]!.resumeCalls, 1);
    expect(handle.current.status, DownloadTransportStatus.running);
  });

  test('rejected page cancellation does not cancel the whole chapter', () async {
    final temp = await Directory.systemTemp.createTemp(
      'aw_manga_partial_cancel_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final starter = _FakePageStarter();
    final transport = MangaChapterTransportV2(startPage: starter.start);
    final handle = await transport.start(
      MangaChapterTransportSpecV2(
        taskId: 'chapter-cancel-rollback',
        mangaId: 'm1',
        chapterId: '4',
        destinationDirectory: temp.path,
        pages: const <MangaPage>[
          MangaPage(index: 0, imageUrl: 'https://cdn.test/0.webp'),
          MangaPage(index: 1, imageUrl: 'https://cdn.test/1.webp'),
        ],
        retries: 2,
        maxConcurrentPages: 2,
      ),
    );
    addTearDown(() async {
      await handle.cancel();
    });

    starter.handles[1]!.cancelAccepted = false;

    expect(await handle.cancel(), isFalse);
    expect(handle.current.status, isNot(DownloadTransportStatus.canceled));
    await _waitUntilStartedCount(starter, 3);
    expect(starter.startedPageIndexes, <int>[0, 1, 0]);
    expect(starter.handles[1]!.current.status, DownloadTransportStatus.running);
  });

  test('completed child page never reports the whole chapter complete early', () async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_child_complete_');
    addTearDown(() => temp.delete(recursive: true));

    final starter = _DelayedAlreadyCompleteStarter();
    final transport = MangaChapterTransportV2(startPage: starter.start);
    final handle = await transport.start(
      MangaChapterTransportSpecV2(
        taskId: 'chapter-parent',
        mangaId: 'm1',
        chapterId: '16',
        destinationDirectory: temp.path,
        pages: const <MangaPage>[
          MangaPage(index: 0, imageUrl: 'https://cdn.test/0.webp'),
          MangaPage(index: 1, imageUrl: 'https://cdn.test/1.webp'),
        ],
        retries: 2,
      ),
    );

    final statuses = <DownloadTransportStatus>[];
    final subscription = handle.snapshots.listen(
      (snapshot) => statuses.add(snapshot.status),
    );
    addTearDown(subscription.cancel);

    await starter.firstRequested.future;
    starter.releaseFirst.complete();
    await starter.secondRequested.future;
    await _waitUntilManifestContains(temp, 0);

    expect(statuses, isNot(contains(DownloadTransportStatus.complete)));
    expect(handle.current.status, isNot(DownloadTransportStatus.complete));

    final manifest = await MangaChapterManifestV2.readFrom(temp);
    expect(manifest, isNotNull);
    expect(manifest!.completedIndexes, <int>{0});
    expect(manifest.isComplete, isFalse);
  });

  test('relative manga directory resolves under app documents root', () async {
    final root = await Directory.systemTemp.createTemp('aw_manga_root_');
    addTearDown(() => root.delete(recursive: true));

    final starter = _FakePageStarter();
    final transport = MangaChapterTransportV2(
      startPage: starter.start,
      resolveDirectory: (relativePath) async =>
          Directory(p.join(root.path, relativePath)),
    );

    await transport.start(
      const MangaChapterTransportSpecV2(
        taskId: 'chapter-relative',
        mangaId: 'm1',
        chapterId: '1',
        destinationDirectory: 'manga/m1/1',
        pages: <MangaPage>[
          MangaPage(index: 0, imageUrl: 'https://cdn.test/0.webp'),
        ],
        retries: 2,
      ),
    );

    expect(
      starter.handles[0]!.destinationPath,
      p.join(root.path, 'manga', 'm1', '1', '0001.webp'),
    );
  });

  test('manga transport resumes from first missing manifest page', () async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_resume_');
    addTearDown(() => temp.delete(recursive: true));

    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1',
      chapterId: '20',
      pageCount: 3,
      completedIndexes: const <int>{0},
      isComplete: false,
    ).writeTo(temp);

    await File('${temp.path}/0001.webp').writeAsBytes(<int>[1, 2, 3]);

    final starter = _FakePageStarter();
    final transport = MangaChapterTransportV2(startPage: starter.start);
    await transport.start(
      MangaChapterTransportSpecV2(
        taskId: 'chapter-parent',
        mangaId: 'm1',
        chapterId: '20',
        destinationDirectory: temp.path,
        pages: const <MangaPage>[
          MangaPage(index: 0, imageUrl: 'https://cdn.test/0.webp'),
          MangaPage(index: 1, imageUrl: 'https://cdn.test/1.webp'),
          MangaPage(index: 2, imageUrl: 'https://cdn.test/2.webp'),
        ],
        retries: 2,
      ),
    );

    expect(starter.startedPageIndexes, <int>[1, 2]);
  });

  test('manga page 404 requests a fresh chapter source', () async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_page_404_');
    addTearDown(() => temp.delete(recursive: true));

    final starter = _FakePageStarter();
    final transport = MangaChapterTransportV2(startPage: starter.start);
    final handle = await transport.start(
      MangaChapterTransportSpecV2(
        taskId: 'chapter-parent',
        mangaId: 'm1',
        chapterId: '404',
        destinationDirectory: temp.path,
        pages: const <MangaPage>[
          MangaPage(index: 0, imageUrl: 'https://cdn.test/gone.webp'),
        ],
        retries: 2,
      ),
    );

    starter.handles[0]!.missing();
    await _waitForStatus(handle, DownloadTransportStatus.failed);

    expect(handle.current.failureCategory, DownloadFailureCategory.sourceExpired);
    expect(handle.current.progress, 0.8);
  });

  test('duplicate page completion callbacks cannot corrupt the chapter manifest', () async {
    final temp = await Directory.systemTemp.createTemp(
      'aw_manga_duplicate_complete_',
    );
    addTearDown(() => temp.delete(recursive: true));

    final starter = _FakePageStarter();
    final transport = MangaChapterTransportV2(startPage: starter.start);
    final handle = await transport.start(
      MangaChapterTransportSpecV2(
        taskId: 'chapter-parent',
        mangaId: 'm1',
        chapterId: '1',
        destinationDirectory: temp.path,
        pages: const <MangaPage>[
          MangaPage(index: 0, imageUrl: 'https://cdn.test/0.webp'),
        ],
        retries: 2,
      ),
    );

    await starter.completeTwice(0);
    await _waitForStatus(handle, DownloadTransportStatus.complete);

    final manifest = await MangaChapterManifestV2.readFrom(temp);
    expect(manifest, isNotNull);
    expect(manifest!.isComplete, isTrue);
    expect(manifest.completedIndexes, <int>{0});
  });

}

Future<void> _waitForStatus(
  DownloadTransportHandle handle,
  DownloadTransportStatus status,
) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (handle.current.status == status) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw StateError('parent did not reach $status; current=${handle.current.status}');
}

Future<void> _waitUntilStartedCount(_FakePageStarter starter, int count) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    if (starter.startedPageIndexes.length >= count) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw StateError(
    'expected $count pages to start; started=${starter.startedPageIndexes}',
  );
}

Future<void> _waitUntilManifestContains(Directory directory, int index) async {
  for (var attempt = 0; attempt < 500; attempt++) {
    final manifest = await MangaChapterManifestV2.readFrom(directory);
    if (manifest?.completedIndexes.contains(index) == true) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('manifest did not record completed page $index');
}

final class _DelayedAlreadyCompleteStarter {
  final Completer<void> firstRequested = Completer<void>();
  final Completer<void> releaseFirst = Completer<void>();
  final Completer<void> secondRequested = Completer<void>();

  Future<DownloadTransportHandle> start(MangaChapterPageTaskV2 task) async {
    if (task.pageIndex == 0) {
      if (!firstRequested.isCompleted) firstRequested.complete();
      await releaseFirst.future;
      File(task.destinationPath)
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final handle = _FakePageHandle(
        taskId: task.taskId,
        pageIndex: task.pageIndex,
        destinationPath: task.destinationPath,
        onTerminal: () {},
      );
      handle.complete();
      return handle;
    }

    if (!secondRequested.isCompleted) secondRequested.complete();
    return _FakePageHandle(
      taskId: task.taskId,
      pageIndex: task.pageIndex,
      destinationPath: task.destinationPath,
      onTerminal: () {},
    );
  }
}

final class _FakePageStarter {
  final List<int> startedPageIndexes = <int>[];
  final List<MangaChapterPageTaskV2> startedTasks = <MangaChapterPageTaskV2>[];
  final Map<int, _FakePageHandle> handles = <int, _FakePageHandle>{};
  int active = 0;
  int maxActive = 0;

  Future<DownloadTransportHandle> start(
    MangaChapterPageTaskV2 task,
  ) async {
    startedPageIndexes.add(task.pageIndex);
    startedTasks.add(task);
    active++;
    if (active > maxActive) maxActive = active;
    final handle = _FakePageHandle(
      taskId: task.taskId,
      pageIndex: task.pageIndex,
      destinationPath: task.destinationPath,
      onTerminal: () => active--,
    );
    handles[task.pageIndex] = handle;
    return handle;
  }

  Future<void> complete(int pageIndex) async {
    final handle = handles[pageIndex]!;
    await File(handle.destinationPath).writeAsBytes(<int>[1, 2, 3]);
    handle.complete();
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> completeTwice(int pageIndex) async {
    final handle = handles[pageIndex]!;
    await File(handle.destinationPath).writeAsBytes(<int>[1, 2, 3]);
    handle.complete(times: 2);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> waitUntilStarted(int pageIndex) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (handles.containsKey(pageIndex)) return;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    throw StateError('page $pageIndex did not start');
  }
}

final class _FakePageHandle implements DownloadTransportHandle {
  _FakePageHandle({
    required this.taskId,
    required this.pageIndex,
    required this.destinationPath,
    required this.onTerminal,
  });

  @override
  final String taskId;
  final int pageIndex;
  final void Function() onTerminal;
  final String destinationPath;
  bool pauseAccepted = true;
  bool resumeAccepted = true;
  bool cancelAccepted = true;
  int resumeCalls = 0;

  DownloadTransportSnapshot _current = const DownloadTransportSnapshot(
    taskId: 'placeholder',
    status: DownloadTransportStatus.running,
    progress: 0,
  );
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast();

  @override
  DownloadTransportSnapshot get current =>
      _current.taskId == 'placeholder'
          ? DownloadTransportSnapshot(
              taskId: taskId,
              status: DownloadTransportStatus.running,
              progress: 0,
            )
          : _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;


  void missing() {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.missing,
      progress: 0.8,
    );
    onTerminal();
    _controller.add(_current);
  }

  void complete({int times = 1}) {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.complete,
      progress: 1,
      transferredBytes: 3,
      totalBytes: 3,
    );
    onTerminal();
    for (var index = 0; index < times; index++) {
      _controller.add(_current);
    }
  }

  @override
  Future<bool> pause() async {
    if (!pauseAccepted) return false;
    _setStatus(DownloadTransportStatus.paused);
    return true;
  }

  @override
  Future<bool> resume() async {
    resumeCalls++;
    if (!resumeAccepted) return false;
    _setStatus(DownloadTransportStatus.running);
    return true;
  }

  @override
  Future<bool> cancel() async {
    if (!cancelAccepted) return false;
    _setStatus(DownloadTransportStatus.canceled);
    onTerminal();
    return true;
  }

  void _setStatus(DownloadTransportStatus status) {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: status,
      progress: current.progress,
    );
    _controller.add(_current);
  }
}
