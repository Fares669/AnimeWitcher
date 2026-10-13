import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/parallel_download_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitUntil(bool Function() predicate) async {
    for (var i = 0; i < 300; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Timed out waiting for tail recovery scheduling');
  }

  test(
    'tail-balanced checkpoint survives relaunch without re-downloading a completed unit',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'parallel-tail-recovery-',
      );
      final parent = ParallelDownloadTask(
        taskId: 'tail-recovery-4',
        url: 'https://example.com/video',
        filename: 'video.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 4,
        allowPause: true,
      );
      final records = <String, TaskRecord>{};
      final starts = <DownloadTask>[];
      final pauses = <String>[];

      PersistentParallelDownload buildCoordinator() =>
          PersistentParallelDownload(
            verifyPartSource: verifiedSavedTestRange,
            promoteFile: publishCompletedTestFile,
            startPart: (task, progress, size) async {
              starts.add(task);
              return true;
            },
            pausePart: (task) async {
              pauses.add(task.taskId);
            },
            cancelParts: (_) async {},
            saveRecord: (record) async {
              records[record.task.taskId] = record;
            },
            recordForId: (id) async => records[id],
            onUpdate: (_) {},
            onPartProgress: (_, _, _) {},
          );

      var coordinator = buildCoordinator();

      Future<void> markRunning(Iterable<DownloadTask> tasks) async {
        for (final task in tasks) {
          coordinator.handleUpdate(TaskStatusUpdate(task, TaskStatus.running));
        }
        await Future<void>.delayed(Duration.zero);
      }

      Future<void> expandTo(int target) async {
        final acknowledged = <String>{};
        while (starts.length < target) {
          final before = starts.length;
          final batch = starts
              .where((task) => acknowledged.add(task.taskId))
              .toList(growable: false);
          expect(batch, isNotEmpty);
          await markRunning(batch);
          await waitUntil(
            () => starts.length > before || starts.length >= target,
          );
        }
      }

      try {
        const mib = 1024 * 1024;
        expect(await coordinator.start(parent, 4 * mib), isTrue);
        await expandTo(4);

        final first = starts.first;
        expect(first.taskId, 'tail-recovery-4.part.0');
        final firstFile = File(await first.filePath());
        await firstFile.parent.create(recursive: true);
        await firstFile.writeAsBytes(
          List<int>.filled(512 * 1024, 3),
          flush: true,
        );
        coordinator.handleUpdate(
          TaskStatusUpdate(first, TaskStatus.complete),
        );
        await waitUntil(
          () => records[parent.taskId]?.progress != null &&
              File('${directory.path}/video.mp4.parts/manifest.json').existsSync(),
        );

        await coordinator.pause(parent);
        expect(pauses, isNot(contains(first.taskId)));
        expect(await firstFile.length(), 512 * 1024);
        await coordinator.dispose();

        starts.clear();
        pauses.clear();
        coordinator = buildCoordinator();
        expect(await coordinator.start(parent, 4 * mib), isTrue);
        await expandTo(4);

        expect(
          starts.map((task) => task.taskId),
          isNot(contains('tail-recovery-4.part.0')),
        );
        expect(starts.first.taskId, 'tail-recovery-4.part.1');
        expect(await firstFile.length(), 512 * 1024);
        expect(coordinator.activeConnectionCount, 4);
      } finally {
        await coordinator.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );

  test(
    'thirty-two queued work units still expose at most sixteen native connections',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'parallel-tail-16-',
      );
      final parent = ParallelDownloadTask(
        taskId: 'tail-16',
        url: 'https://example.com/video16',
        filename: 'video16.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 16,
        allowPause: true,
      );
      final records = <String, TaskRecord>{};
      final starts = <DownloadTask>[];
      final coordinator = PersistentParallelDownload(
        verifyPartSource: verifiedSavedTestRange,
            promoteFile: publishCompletedTestFile,
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

      Future<void> markRunning(Iterable<DownloadTask> tasks) async {
        for (final task in tasks) {
          coordinator.handleUpdate(TaskStatusUpdate(task, TaskStatus.running));
        }
        await Future<void>.delayed(Duration.zero);
      }

      try {
        const mib = 1024 * 1024;
        expect(await coordinator.start(parent, 16 * mib), isTrue);
        expect(starts.length, 1);

        // Follow the production 1, 2, 4, 8, 1 response-gated ramp explicitly.
        await markRunning(starts.take(1));
        await waitUntil(() => starts.length == 3);
        await markRunning(starts.skip(1).take(2));
        await waitUntil(() => starts.length == 7);
        await markRunning(starts.skip(3).take(4));
        await waitUntil(() => starts.length == 15);
        await markRunning(starts.skip(7).take(8));
        await waitUntil(() => starts.length == 16);

        // The last +1 connection is itself a response-gated batch. Mark it
        // healthy before freeing an earlier slot; otherwise the scheduler is
        // correctly waiting for that response and must not launch tail work.
        await markRunning(starts.skip(15).take(1));
        await waitUntil(() => coordinator.activeConnectionCount == 16);

        expect(starts, hasLength(16));
        expect(coordinator.activeConnectionCount, 16);

        final first = starts.first;
        final firstFile = File(await first.filePath());
        await firstFile.parent.create(recursive: true);
        await firstFile.writeAsBytes(
          List<int>.filled(512 * 1024, 5),
          flush: true,
        );
        coordinator.handleUpdate(
          TaskStatusUpdate(first, TaskStatus.complete),
        );

        await waitUntil(() => starts.length == 17);
        expect(starts.last.taskId, 'tail-16.part.16');
        expect(coordinator.activeConnectionCount, 16);
      } finally {
        await coordinator.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );
}
