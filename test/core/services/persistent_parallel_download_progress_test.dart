import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitUntil(bool Function() predicate) async {
    for (var i = 0; i < 240; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Timed out waiting for parallel download state');
  }

  test(
    'coalesces child progress into one parent update with aggregate ETA',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'parallel-progress-aggregate-',
      );
      final parent = ParallelDownloadTask(
        taskId: 'parallel-progress',
        url: 'https://example.com/video',
        filename: 'video.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 4,
        allowPause: true,
      );
      final records = <String, TaskRecord>{};
      final starts = <DownloadTask>[];
      final updates = <TaskUpdate>[];
      final coordinator = PersistentParallelDownload(
        startPart: (task, progress, size) async {
          starts.add(task);
          return true;
        },
        pausePart: (_) async {},
        cancelParts: (_) async {},
        saveRecord: (record) async {
          records[record.task.taskId] = record;
        },
        recordForId: (id) async => records[id],
        onUpdate: updates.add,
        onPartProgress: (_, _, _) {},
      );

      try {
        // Below 4 * 512 KiB, the tail-work helper intentionally preserves four
        // work units, making this a precise four-connection aggregation test.
        const totalBytes = 2000000;
        expect(await coordinator.start(parent, totalBytes), isTrue);
        expect(starts.length, 1);

        coordinator.handleUpdate(
          TaskStatusUpdate(starts[0], TaskStatus.running),
        );
        await waitUntil(() => starts.length >= 3);
        coordinator.handleUpdate(
          TaskStatusUpdate(starts[1], TaskStatus.running),
        );
        coordinator.handleUpdate(
          TaskStatusUpdate(starts[2], TaskStatus.running),
        );
        await waitUntil(() => starts.length >= 4);
        coordinator.handleUpdate(
          TaskStatusUpdate(starts[3], TaskStatus.running),
        );
        await waitUntil(() => coordinator.activeConnectionCount == 4);

        updates.clear();
        for (final child in starts.take(4)) {
          coordinator.handleUpdate(
            TaskProgressUpdate(
              child,
              0.25,
              500000,
              0.125,
              const Duration(seconds: 99),
            ),
          );
        }

        // Child callbacks arrive as one burst. The card must not repaint its
        // bytes/speed four times for that one native progress interval.
        await Future<void>.delayed(
          kParallelProgressCoalesceDelay - const Duration(milliseconds: 50),
        );
        expect(updates.whereType<TaskProgressUpdate>(), isEmpty);

        await waitUntil(
          () => updates.whereType<TaskProgressUpdate>().isNotEmpty,
        );
        final progressUpdates = updates
            .whereType<TaskProgressUpdate>()
            .toList();
        expect(progressUpdates, hasLength(1));

        final aggregate = progressUpdates.single;
        expect(aggregate.task.taskId, parent.taskId);
        expect(aggregate.progress, closeTo(0.25, 0.000001));
        expect(aggregate.expectedFileSize, totalBytes);
        expect(
          aggregate.networkSpeed,
          0,
          reason: 'a sub-second multipart callback burst is not a stable speed',
        );
        expect(aggregate.timeRemaining, Duration.zero);
      } finally {
        await coordinator.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );

  for (final bridgeCount in [1, 2]) {
    test(
      'large range snapshot keeps $bridgeCount native bridge inputs',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'parallel-snapshot-',
        );
        final parent = ParallelDownloadTask(
          taskId: 'large-aggregate-$bridgeCount',
          url: 'https://fixture.invalid/episode',
          filename: 'episode.bin',
          directory: directory.path,
          baseDirectory: BaseDirectory.root,
          chunks: 16,
        );
        final records = <String, TaskRecord>{};
        final starts = <DownloadTask>[];
        final parentUpdates = <TaskProgressUpdate>[];
        final heartbeats = <Map<String, Object?>>[];
        const expectedSize = 512 * 1024 * 1024; // 128 persistent ranges.
        const firstBytes = 525313;
        const secondBytes = 777219;
        const firstSpeed = 256000.0;
        const secondSpeed = 384000.0;
        final coordinator = PersistentParallelDownload(
          startPart: (task, progress, size) async {
            starts.add(task);
            return true;
          },
          pausePart: (_) async {},
          cancelParts: (_) async {},
          saveRecord: (record) async => records[record.task.taskId] = record,
          recordForId: (id) async => records[id],
          onUpdate: (update) {
            if (update is TaskProgressUpdate &&
                update.task.taskId == parent.taskId) {
              parentUpdates.add(update);
            }
          },
          onPartProgress: (_, _, _) {},
          diagnosticEvent: (event, fields) {
            if (event == 'parallel.heartbeat') heartbeats.add(fields);
          },
        );
        try {
          expect(await coordinator.start(parent, expectedSize), isTrue);
          expect(starts, hasLength(1));
          await coordinator.handleNativeChunkUpdate(
            parentTaskId: parent.taskId,
            chunkTaskId: starts.first.taskId,
            writtenBytes: firstBytes,
            speedBytesPerSecond: firstSpeed,
          );
          if (bridgeCount == 2) {
            await waitUntil(() => starts.length >= 2);
            await coordinator.handleNativeChunkUpdate(
              parentTaskId: parent.taskId,
              chunkTaskId: starts[1].taskId,
              writtenBytes: secondBytes,
              speedBytesPerSecond: secondSpeed,
            );
          }

          await waitUntil(() => parentUpdates.isNotEmpty);
          final aggregate = parentUpdates.single;
          final liveBytes = firstBytes + (bridgeCount == 2 ? secondBytes : 0);
          expect(aggregate.progress, liveBytes / expectedSize);
          expect(aggregate.expectedFileSize, expectedSize);
          // Both inputs arrived before the first estimator sample. One native
          // callback can supply its speed; two need a measured byte window.
          expect(aggregate.networkSpeed, bridgeCount == 1 ? 0.256 : 0.0);
          expect(
            aggregate.timeRemaining,
            bridgeCount == 1
                ? Duration(
                    milliseconds:
                        ((expectedSize - liveBytes) / firstSpeed * 1000).ceil(),
                  )
                : Duration.zero,
          );
          final fields = heartbeats.single;
          expect(fields['liveBytes'], liveBytes);
          expect(fields['nativeWrittenBytes'], liveBytes);
          expect(fields['durableBytes'], 0);
          expect(fields['totalBytes'], expectedSize);
          expect(fields['configuredConnections'], 16);
          expect(fields['activeConnections'], inInclusiveRange(1, 16));
        } finally {
          await coordinator.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test('parent progress is not blocked by slow record persistence', () async {
    final directory = await Directory.systemTemp.createTemp(
      'parallel-progress-nonblocking-',
    );
    final parent = ParallelDownloadTask(
      taskId: 'parallel-progress-nonblocking',
      url: 'https://example.com/video',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 1,
      allowPause: true,
    );
    final records = <String, TaskRecord>{};
    final starts = <DownloadTask>[];
    final updates = <TaskUpdate>[];
    final blockedWrite = Completer<void>();
    var blockRunningParentWrite = false;
    final coordinator = PersistentParallelDownload(
      startPart: (task, progress, size) async {
        starts.add(task);
        return true;
      },
      pausePart: (_) async {},
      cancelParts: (_) async {},
      saveRecord: (record) async {
        if (blockRunningParentWrite &&
            record.task.taskId == parent.taskId &&
            record.status == TaskStatus.running) {
          await blockedWrite.future;
        }
        records[record.task.taskId] = record;
      },
      recordForId: (id) async => records[id],
      onUpdate: updates.add,
      onPartProgress: (_, _, _) {},
    );

    try {
      expect(await coordinator.start(parent, 1000000), isTrue);
      final child = starts.single;
      coordinator.handleUpdate(TaskStatusUpdate(child, TaskStatus.running));
      await waitUntil(() => coordinator.activeConnectionCount == 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      updates.clear();
      blockRunningParentWrite = true;

      coordinator.handleUpdate(
        TaskProgressUpdate(
          child,
          0.25,
          1000000,
          0.5,
          const Duration(seconds: 2),
        ),
      );

      await Future<void>.delayed(
        kParallelProgressCoalesceDelay + const Duration(milliseconds: 150),
      );
      expect(
        updates.whereType<TaskProgressUpdate>(),
        isNotEmpty,
        reason: 'UI telemetry must publish before the DB write completes',
      );
    } finally {
      if (!blockedWrite.isCompleted) blockedWrite.complete();
      await coordinator.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });

  test(
    'lost native checkpoint can reset only its immutable part to disk bytes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'parallel-progress-lost-checkpoint-',
      );
      final parent = ParallelDownloadTask(
        taskId: 'parallel-lost-checkpoint',
        url: 'https://example.com/video',
        filename: 'video.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 1,
        allowPause: true,
      );
      final records = <String, TaskRecord>{};
      final starts = <DownloadTask>[];
      final coordinator = PersistentParallelDownload(
        startPart: (task, progress, size) async {
          starts.add(task);
          return true;
        },
        pausePart: (_) async {},
        cancelParts: (_) async {},
        saveRecord: (record) async {
          records[record.task.taskId] = record;
        },
        recordForId: (id) async => records[id],
        onUpdate: (_) {},
        onPartProgress: (_, _, _) {},
      );

      try {
        expect(await coordinator.start(parent, 1000000), isTrue);
        final child = starts.single;
        coordinator.handleUpdate(
          TaskProgressUpdate(
            child,
            0.30,
            1000000,
            0.5,
            const Duration(seconds: 2),
          ),
        );
        await waitUntil(
          () => (coordinator.progressFor(parent.taskId) ?? 0) >= 0.30,
        );

        expect(
          coordinator.resetUndurablePartProgress(child.taskId, durableBytes: 0),
          isTrue,
        );
        expect(coordinator.progressFor(parent.taskId), 0);
      } finally {
        await coordinator.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );

  test('pause cancels a pending aggregate progress emission', () async {
    final directory = await Directory.systemTemp.createTemp(
      'parallel-progress-pause-',
    );
    final parent = ParallelDownloadTask(
      taskId: 'parallel-progress-pause',
      url: 'https://example.com/video',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 1,
      allowPause: true,
    );
    final records = <String, TaskRecord>{};
    final starts = <DownloadTask>[];
    final updates = <TaskUpdate>[];
    final coordinator = PersistentParallelDownload(
      startPart: (task, progress, size) async {
        starts.add(task);
        return true;
      },
      pausePart: (_) async {},
      cancelParts: (_) async {},
      saveRecord: (record) async {
        records[record.task.taskId] = record;
      },
      recordForId: (id) async => records[id],
      onUpdate: updates.add,
      onPartProgress: (_, _, _) {},
    );

    try {
      expect(await coordinator.start(parent, 1000000), isTrue);
      final child = starts.single;
      coordinator.handleUpdate(TaskStatusUpdate(child, TaskStatus.running));
      await waitUntil(() => coordinator.activeConnectionCount == 1);
      updates.clear();

      coordinator.handleUpdate(
        TaskProgressUpdate(
          child,
          0.2,
          1000000,
          1.0,
          const Duration(seconds: 1),
        ),
      );
      await coordinator.pause(parent);
      updates.clear();

      await Future<void>.delayed(
        kParallelProgressCoalesceDelay + const Duration(milliseconds: 100),
      );
      expect(updates.whereType<TaskProgressUpdate>(), isEmpty);
    } finally {
      await coordinator.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });
}
