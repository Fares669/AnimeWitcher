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
  test('manga chapter starts exactly one page writer at a time', () async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_transport_');
    addTearDown(() => temp.delete(recursive: true));

    final starter = _FakePageStarter();
    final transport = MangaChapterTransportV2(startPage: starter.start);
    final handle = await transport.start(
      MangaChapterTransportSpecV2(
        taskId: 'chapter-parent',
        mangaId: 'm1',
        chapterId: '12.5',
        destinationDirectory: temp.path,
        pages: const <MangaPage>[
          MangaPage(index: 0, imageUrl: 'https://cdn.test/0.webp'),
          MangaPage(index: 1, imageUrl: 'https://cdn.test/1.webp'),
          MangaPage(index: 2, imageUrl: 'https://cdn.test/2.webp'),
          MangaPage(index: 3, imageUrl: 'https://cdn.test/3.webp'),
        ],
        retries: 2,
      ),
    );

    expect(starter.startedPageIndexes, <int>[0]);
    expect(starter.maxActive, 1);

    for (var index = 0; index < 4; index++) {
      await starter.complete(index);
      if (index + 1 < 4) {
        await starter.waitUntilStarted(index + 1);
      }
    }

    await _waitForStatus(handle, DownloadTransportStatus.complete);
    expect(starter.startedPageIndexes, <int>[0, 1, 2, 3]);
    expect(starter.maxActive, 1);
    expect(handle.current.status, DownloadTransportStatus.complete);
    expect(handle.current.progress, 1);

    final manifest = await MangaChapterManifestV2.readFrom(temp);
    expect(manifest, isNotNull);
    expect(manifest!.completedIndexes, <int>{0, 1, 2, 3});
    expect(manifest.isComplete, isTrue);
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

    expect(starter.startedPageIndexes, <int>[1]);
  });
}

Future<void> _waitForStatus(
  DownloadTransportHandle handle,
  DownloadTransportStatus status,
) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (handle.current.status == status) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw StateError('parent did not reach $status; current=${handle.current.status}');
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
  final Map<int, _FakePageHandle> handles = <int, _FakePageHandle>{};
  int active = 0;
  int maxActive = 0;

  Future<DownloadTransportHandle> start(
    MangaChapterPageTaskV2 task,
  ) async {
    startedPageIndexes.add(task.pageIndex);
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


  void complete() {
    _current = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.complete,
      progress: 1,
      transferredBytes: 3,
      totalBytes: 3,
    );
    onTerminal();
    _controller.add(_current);
  }

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async {
    onTerminal();
    return true;
  }
}
