import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/parallel_download_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late ParallelDownloadTask parent;
  late PersistentParallelDownload coordinator;
  late List<DownloadTask> starts;
  late List<double> startProgresses;
  late List<String> pauses;
  late List<String> canceledParts;
  late List<TaskStatus> parentStatuses;
  late Map<String, TaskRecord> records;
  late Set<String> livePartIds;

  Future<void> waitUntil(bool Function() predicate) async {
    for (var i = 0; i < 400; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Timed out waiting for automatic multipart recovery');
  }

  PersistentParallelDownload buildCoordinator({
    Duration recoveryDelay = const Duration(milliseconds: 10),
    Duration tailStallDelay = kParallelTailStallDelay,
    int maxActiveConnections = 16,
    bool pauseClearsLive = true,
    bool deleteCanceledFiles = false,
    Future<bool> Function(DownloadTask task, double progress, int size)?
    startPartOverride,
    bool Function(String childTaskId)? shouldRecoverFailedStart,
  }) {
    return PersistentParallelDownload(
      verifyPartSource: verifiedSavedTestRange,
      promoteFile: publishCompletedTestFile,
      startPart: (task, progress, size) async {
        starts.add(task);
        startProgresses.add(progress);
        if (startPartOverride != null) {
          return startPartOverride(task, progress, size);
        }
        return true;
      },
      pausePart: (task) async {
        pauses.add(task.taskId);
        if (pauseClearsLive) livePartIds.remove(task.taskId);
      },
      cancelParts: (ids) async {
        canceledParts.addAll(ids);
        livePartIds.removeAll(ids);
        if (!deleteCanceledFiles) return;
        for (final id in ids) {
          DownloadTask? task;
          for (final candidate in starts.reversed) {
            if (candidate.taskId == id) {
              task = candidate;
              break;
            }
          }
          if (task == null) continue;
          final file = File(await task.filePath());
          if (await file.exists()) await file.delete();
        }
      },
      saveRecord: (record) async {
        records[record.task.taskId] = record;
      },
      recordForId: (id) async => records[id],
      onUpdate: (update) {
        if (update is TaskStatusUpdate && update.task.taskId == parent.taskId) {
          parentStatuses.add(update.status);
        }
      },
      onPartProgress: (_, _, _) {},
      livePartIds: () async => Set<String>.from(livePartIds),
      shouldRecoverFailedStart: shouldRecoverFailedStart,
      recoveryDelay: recoveryDelay,
      tailStallDelay: tailStallDelay,
      maxActiveConnections: maxActiveConnections,
    );
  }

  void clearHarness() {
    starts.clear();
    startProgresses.clear();
    pauses.clear();
    canceledParts.clear();
    parentStatuses.clear();
    records.clear();
    livePartIds.clear();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'parallel-auto-recovery-',
    );
    parent = ParallelDownloadTask(
      taskId: 'episode',
      url: 'https://cdn.example.test/video.mp4',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 1,
      allowPause: true,
    );
    starts = <DownloadTask>[];
    startProgresses = <double>[];
    pauses = <String>[];
    canceledParts = <String>[];
    parentStatuses = <TaskStatus>[];
    records = <String, TaskRecord>{};
    livePartIds = <String>{};
    coordinator = buildCoordinator();
  });

  tearDown(() async {
    await coordinator.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'multipart child uses only AnimeWitcher recovery, not native retries',
    () async {
      expect(await coordinator.start(parent, 32), isTrue);
      expect(starts, hasLength(1));
      expect(starts.single.retries, 0);
    },
  );

  test(
    'terminal failed start parks parent instead of relaunching forever',
    () async {
      await coordinator.dispose();
      clearHarness();
      var attempts = 0;
      coordinator = buildCoordinator(
        recoveryDelay: const Duration(milliseconds: 5),
        shouldRecoverFailedStart: (_) => false,
        startPartOverride: (_, _, _) async {
          attempts++;
          return false;
        },
      );

      expect(await coordinator.start(parent, 32), isTrue);
      await waitUntil(() => parentStatuses.contains(TaskStatus.paused));
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(attempts, 1);
      expect(starts, hasLength(1));
      expect(coordinator.isActive(parent.taskId), isFalse);
      expect(parentStatuses.last, TaskStatus.paused);
    },
  );

  test(
    'repeated system pauses recover the child without pausing the episode',
    () async {
      expect(await coordinator.start(parent, 32), isTrue);
      expect(starts, hasLength(1));
      final child = starts.first;
      var current = child;

      coordinator.handleUpdate(TaskStatusUpdate(current, TaskStatus.running));
      await Future<void>.delayed(Duration.zero);

      // The old implementation stopped the whole parent after the third pause.
      // Exercise well beyond that boundary and require the same child identity
      // to keep recovering automatically. Each pause comes from the current
      // native attempt; older task objects are intentionally stale after retry.
      for (var interruption = 0; interruption < 6; interruption++) {
        final expectedStarts = starts.length + 1;
        coordinator.handleUpdate(TaskStatusUpdate(current, TaskStatus.paused));
        await waitUntil(() => starts.length >= expectedStarts);
        current = starts.last;
        expect(current.taskId, child.taskId);
        coordinator.handleUpdate(TaskStatusUpdate(current, TaskStatus.running));
        await Future<void>.delayed(Duration.zero);
        expect(coordinator.isActive(parent.taskId), isTrue);
        expect(parentStatuses.last, TaskStatus.running);
        expect(pauses, isEmpty);
      }

      expect(parentStatuses, isNot(contains(TaskStatus.waitingToRetry)));
      expect(parentStatuses, isNot(contains(TaskStatus.paused)));
    },
  );

  test(
    'transient connection failure retries only the affected child',
    () async {
      expect(await coordinator.start(parent, 32), isTrue);
      final child = starts.first;
      coordinator.handleUpdate(TaskStatusUpdate(child, TaskStatus.running));
      await Future<void>.delayed(Duration.zero);

      coordinator.handleUpdate(
        TaskStatusUpdate(
          child,
          TaskStatus.failed,
          TaskConnectionException('socket reset'),
        ),
      );

      await waitUntil(() => starts.length >= 2);
      expect(starts.last.taskId, child.taskId);
      expect(coordinator.isActive(parent.taskId), isTrue);
      expect(parentStatuses.last, TaskStatus.running);
      expect(parentStatuses, isNot(contains(TaskStatus.waitingToRetry)));
      expect(parentStatuses, isNot(contains(TaskStatus.paused)));
      expect(pauses, isEmpty);
    },
  );

  test('recovery backoff frees its slot and never bypasses the governor', () async {
    await coordinator.dispose();
    clearHarness();
    parent = ParallelDownloadTask(
      taskId: 'episode-two-connections',
      url: 'https://cdn.example.test/video-2.mp4',
      filename: 'video-2.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 2,
      allowPause: true,
    );
    coordinator = buildCoordinator(
      recoveryDelay: const Duration(milliseconds: 80),
      maxActiveConnections: 2,
    );

    const mib = 1024 * 1024;
    expect(await coordinator.start(parent, 2 * mib), isTrue);
    final first = starts.first;
    coordinator.handleUpdate(TaskStatusUpdate(first, TaskStatus.running));
    await waitUntil(() => starts.length == 2);
    final interrupted = starts[1];
    coordinator.handleUpdate(TaskStatusUpdate(interrupted, TaskStatus.running));
    await waitUntil(() => coordinator.activeConnectionCount == 2);

    // A system interruption used to leave this child counted as an active
    // socket throughout backoff. That eventually parked every connection at
    // once. The slot must be released and immediately used by spare tail work.
    coordinator.handleUpdate(TaskStatusUpdate(interrupted, TaskStatus.paused));
    await waitUntil(() => starts.length == 3);
    expect(starts[2].taskId, isNot(interrupted.taskId));
    expect(coordinator.activeConnectionCount, 2);
    expect(parentStatuses.last, TaskStatus.running);

    // When the interrupted range's timer expires, it must not call startPart
    // directly on top of the two active workers. It waits for the governor to
    // expose a real slot instead.
    final startsWhileFull = starts.length;
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(starts, hasLength(startsWhileFull));
    expect(coordinator.activeConnectionCount, 2);
    expect(parentStatuses, isNot(contains(TaskStatus.waitingToRetry)));
    expect(parentStatuses, isNot(contains(TaskStatus.paused)));
  });

  test(
    'missing native worker during reconcile is recovered, not auto-paused',
    () async {
      expect(await coordinator.start(parent, 32), isTrue);
      final child = starts.first;
      coordinator.handleUpdate(TaskStatusUpdate(child, TaskStatus.running));
      await Future<void>.delayed(Duration.zero);

      await coordinator.reconcile(() async => <String>{});

      await waitUntil(() => starts.length >= 2);
      expect(starts.last.taskId, child.taskId);
      expect(coordinator.isActive(parent.taskId), isTrue);
      expect(parentStatuses.last, TaskStatus.running);
      expect(parentStatuses, isNot(contains(TaskStatus.waitingToRetry)));
      expect(parentStatuses, isNot(contains(TaskStatus.paused)));
    },
  );

  test('0.999 exact-size child finalizes without waiting forever for native complete', () async {
    expect(await coordinator.start(parent, 32), isTrue);
    final child = starts.single;
    livePartIds.add(child.taskId);
    coordinator.handleUpdate(TaskStatusUpdate(child, TaskStatus.running));
    await Future<void>.delayed(Duration.zero);

    final childFile = File(await child.filePath());
    await childFile.parent.create(recursive: true);
    await childFile.writeAsBytes(
      List<int>.generate(32, (index) => index),
      flush: true,
    );

    coordinator.handleUpdate(
      TaskProgressUpdate(child, 0.999, 32, 0, const Duration(seconds: -1)),
    );

    await waitUntil(() => parentStatuses.contains(TaskStatus.complete));
    final target = File(await parent.filePath());
    expect(await target.exists(), isTrue);
    expect(await target.length(), 32);
    expect(
      await target.readAsBytes(),
      List<int>.generate(32, (index) => index),
    );
    expect(pauses, contains(child.taskId));
    expect(records[parent.taskId]?.status, TaskStatus.complete);
  });

  test('restored 32-part manifest assembles when two exact files are stuck at 0.999', () async {
    await coordinator.dispose();
    clearHarness();

    parent = ParallelDownloadTask(
      taskId: 'manifest-episode',
      url: 'https://pixeldrain.example/file',
      filename: 'manifest-video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 16,
      allowPause: true,
    );

    final targetPath = await parent.filePath();
    final partsDirectory = Directory('$targetPath.parts');
    await partsDirectory.create(recursive: true);
    final manifestParts = <Map<String, dynamic>>[];
    final expectedBytes = <int>[];

    for (var index = 0; index < 32; index++) {
      final child = DownloadTask(
        taskId: '${parent.taskId}.part.$index',
        url: parent.url,
        filename: '$index.part',
        directory: partsDirectory.path,
        baseDirectory: BaseDirectory.root,
        headers: <String, String>{
          'Range': 'bytes=$index-$index',
          'Accept-Encoding': 'identity',
        },
        updates: Updates.statusAndProgress,
        retries: 0,
        allowPause: true,
        group: kPersistentDownloadChunkGroup,
        metaData: jsonEncode(<String, String>{'parentTaskId': parent.taskId}),
      );
      await File(await child.filePath())
          .writeAsBytes(<int>[index], flush: true);
      final stuck = index == 11 || index == 12;
      if (stuck) livePartIds.add(child.taskId);
      manifestParts.add(<String, dynamic>{
        'task': child.toJson(),
        'from': index,
        'to': index,
        'progress': stuck ? 0.999 : 1.0,
        'complete': !stuck,
      });
      expectedBytes.add(index);
    }

    await File('$targetPath.parts/manifest.json').writeAsString(
      jsonEncode(<String, dynamic>{'parts': manifestParts}),
      flush: true,
    );

    coordinator = buildCoordinator();
    expect(await coordinator.start(parent, 32), isTrue);
    await waitUntil(() => parentStatuses.contains(TaskStatus.complete));

    final target = File(targetPath);
    expect(await target.exists(), isTrue);
    expect(await target.length(), 32);
    expect(await target.readAsBytes(), expectedBytes);
    expect(pauses.toSet(), <String>{
      '${parent.taskId}.part.11',
      '${parent.taskId}.part.12',
    });
    expect(await partsDirectory.exists(), isFalse);
    expect(records[parent.taskId]?.status, TaskStatus.complete);
  });

  test(
    'live 0.999 tail stall recycles only that range and preserves its prefix',
    () async {
      await coordinator.dispose();
      clearHarness();

      parent = ParallelDownloadTask(
        taskId: 'tail-stall-manifest',
        url: 'https://pixeldrain.example/stalled-file',
        filename: 'tail-stall.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 16,
        allowPause: true,
      );

      final targetPath = await parent.filePath();
      final partsDirectory = Directory('$targetPath.parts');
      await partsDirectory.create(recursive: true);
      final manifestParts = <Map<String, dynamic>>[];
      final expectedBytes = <int>[];
      DownloadTask? stuckChild;

      for (var index = 0; index < 32; index++) {
        final from = index * 4;
        final to = from + 3;
        final child = DownloadTask(
          taskId: '${parent.taskId}.part.$index',
          url: parent.url,
          filename: '$index.part',
          directory: partsDirectory.path,
          baseDirectory: BaseDirectory.root,
          headers: <String, String>{
            'Range': 'bytes=$from-$to',
            'Accept-Encoding': 'identity',
          },
          updates: Updates.statusAndProgress,
          retries: 0,
          allowPause: true,
          group: kPersistentDownloadChunkGroup,
          metaData: jsonEncode(<String, String>{'parentTaskId': parent.taskId}),
        );
        final bytes = <int>[from, from + 1, from + 2, from + 3];
        expectedBytes.addAll(bytes);
        final stuck = index == 9;
        if (stuck) {
          stuckChild = child;
          livePartIds.add(child.taskId);
          // Mirror the real report: progress says 0.999, but the immutable
          // range still lacks its final bytes. Three bytes stand in for the
          // large on-device prefix from the uploaded manifest.
          await File(await child.filePath())
              .writeAsBytes(bytes.take(3).toList(), flush: true);
        } else {
          await File(await child.filePath()).writeAsBytes(bytes, flush: true);
        }
        manifestParts.add(<String, dynamic>{
          'task': child.toJson(),
          'from': from,
          'to': to,
          'progress': stuck ? 0.999 : 1.0,
          'complete': !stuck,
        });
      }

      await File('$targetPath.parts/manifest.json').writeAsString(
        jsonEncode(<String, dynamic>{'parts': manifestParts}),
        flush: true,
      );

      coordinator = buildCoordinator(
        recoveryDelay: const Duration(milliseconds: 10),
        tailStallDelay: const Duration(milliseconds: 20),
        pauseClearsLive: false,
        deleteCanceledFiles: true,
      );
      expect(await coordinator.start(parent, expectedBytes.length), isTrue);
      final stuckId = stuckChild!.taskId;

      await waitUntil(
        () =>
            canceledParts.contains(stuckId) &&
            startProgresses.any((progress) => progress == 0.75),
      );

      expect(canceledParts.toSet(), <String>{stuckId});
      expect(coordinator.isActive(parent.taskId), isTrue);
      expect(parentStatuses, isNot(contains(TaskStatus.paused)));
      expect(pauses, contains(stuckId));
      expect(
        startProgresses, isNot(contains(0.999)),
        reason: 'the unsettled native owner must not be resumed a second time',
      );
      expect(startProgresses, contains(0.75));

      // Every completed sibling remains durable while only part.9 is recycled.
      for (var index = 0; index < 32; index++) {
        if (index == 9) continue;
        final sibling = File('${partsDirectory.path}/$index.part');
        expect(await sibling.exists(), isTrue, reason: 'part $index was lost');
        expect(await sibling.length(), 4);
      }
      final recoveredPrefix = File(await stuckChild.filePath());
      expect(await recoveredPrefix.readAsBytes(), <int>[36, 37, 38]);

      await recoveredPrefix.writeAsBytes(
        <int>[39],
        mode: FileMode.append,
        flush: true,
      );
      coordinator.handleUpdate(
        TaskStatusUpdate(stuckChild, TaskStatus.complete),
      );
      await waitUntil(
        () =>
            parentStatuses.contains(TaskStatus.complete) &&
            !partsDirectory.existsSync(),
      );

      final target = File(targetPath);
      expect(await target.exists(), isTrue);
      expect(await target.length(), expectedBytes.length);
      expect(await target.readAsBytes(), expectedBytes);
      expect(await partsDirectory.exists(), isFalse);
      expect(records[parent.taskId]?.status, TaskStatus.complete);
    },
  );

  test(
    'live 0.999 tail with no accessible bytes re-fetches only its own range',
    () async {
      await coordinator.dispose();
      clearHarness();

      parent = ParallelDownloadTask(
        taskId: 'tail-stall-no-prefix',
        url: 'https://pixeldrain.example/stalled-no-prefix',
        filename: 'tail-stall-no-prefix.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 1,
        allowPause: true,
      );
      final targetPath = await parent.filePath();
      final partsDirectory = Directory('$targetPath.parts');
      await partsDirectory.create(recursive: true);
      final child = DownloadTask(
        taskId: '${parent.taskId}.part.0',
        url: parent.url,
        filename: '0.part',
        directory: partsDirectory.path,
        baseDirectory: BaseDirectory.root,
        headers: const <String, String>{
          'Range': 'bytes=0-31',
          'Accept-Encoding': 'identity',
        },
        updates: Updates.statusAndProgress,
        retries: 0,
        allowPause: true,
        group: kPersistentDownloadChunkGroup,
        metaData: jsonEncode(<String, String>{'parentTaskId': parent.taskId}),
      );
      livePartIds.add(child.taskId);
      await File('$targetPath.parts/manifest.json').writeAsString(
        jsonEncode(<String, dynamic>{
          'parts': <Map<String, dynamic>>[
            <String, dynamic>{
              'task': child.toJson(),
              'from': 0,
              'to': 31,
              'progress': 0.999,
              'complete': false,
            },
          ],
        }),
        flush: true,
      );

      coordinator = buildCoordinator(
        recoveryDelay: const Duration(milliseconds: 10),
        tailStallDelay: const Duration(milliseconds: 20),
        pauseClearsLive: false,
      );
      expect(await coordinator.start(parent, 32), isTrue);

      await waitUntil(
        () =>
            canceledParts.contains(child.taskId) &&
            startProgresses.any((progress) => progress == 0),
      );
      expect(canceledParts.toSet(), <String>{child.taskId});
      expect(starts.every((task) => task.taskId == child.taskId), isTrue);
      expect(parentStatuses, isNot(contains(TaskStatus.paused)));
      expect(coordinator.isActive(parent.taskId), isTrue);
    },
  );

  test(
    'permanent HTTP 403 still parks safely instead of retrying forever',
    () async {
      expect(await coordinator.start(parent, 32), isTrue);
      final child = starts.first;
      coordinator.handleUpdate(TaskStatusUpdate(child, TaskStatus.running));
      await Future<void>.delayed(Duration.zero);

      coordinator.handleUpdate(
        TaskStatusUpdate(
          child,
          TaskStatus.failed,
          TaskHttpException('forbidden', 403),
        ),
      );

      await waitUntil(() => parentStatuses.contains(TaskStatus.paused));
      expect(coordinator.isActive(parent.taskId), isFalse);
      expect(starts, hasLength(1));
      expect(pauses, isEmpty);
    },
  );
}
