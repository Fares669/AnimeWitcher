import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'DM-27 assembly disk-full preserves verified parts and can resume',
    () async {
      final rootPath = Platform.environment['DM27_TEST_ROOT'];
      if (!Platform.isLinux || rootPath == null || rootPath.isEmpty) return;
      final root = Directory(rootPath);
      if (!await root.exists()) return;

      final directory = await root.createTemp('animewitcher-dm27-');
      final records = <String, TaskRecord>{};
      final starts = <DownloadTask>[];
      final statuses = <TaskStatus>[];
      const totalBytes = 8192;
      final parent = ParallelDownloadTask(
        taskId: 'dm27-parent',
        url: 'https://storage.example/video',
        filename: 'video.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 5,
        allowPause: true,
      );

      late final PersistentParallelDownload coordinator;
      coordinator = PersistentParallelDownload(
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
        onUpdate: (update) {
          if (update is TaskStatusUpdate) statuses.add(update.status);
        },
        onPartProgress: (_, _, _) {},
        livePartIds: () async => <String>{},
        recoveryDelay: const Duration(milliseconds: 25),
        diskProgressPollInterval: const Duration(seconds: 30),
      );

      addTearDown(() async {
        await coordinator.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      Future<void> waitUntil(
        String stage,
        bool Function() predicate,
      ) async {
        for (var i = 0; i < 400; i++) {
          if (predicate()) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        fail(
          'timed out during $stage; starts=${starts.length}, '
          'parent=${records[parent.taskId]?.status}, statuses=$statuses',
        );
      }

      Future<void> markRunning(Iterable<DownloadTask> tasks) async {
        for (final task in tasks) {
          coordinator.handleUpdate(TaskStatusUpdate(task, TaskStatus.running));
        }
        await Future<void>.delayed(Duration.zero);
      }

      Future<void> expandFreshTo(int target) async {
        final acknowledged = <String>{};
        while (starts.length < target) {
          final before = starts.length;
          final batch = starts
              .where((task) => acknowledged.add(task.taskId))
              .toList(growable: false);
          expect(
            batch,
            isNotEmpty,
            reason: 'ramp must expose a new batch before waiting for promotion',
          );
          await markRunning(batch);
          await waitUntil(
            'initial connection ramp $before->$target',
            () => starts.length > before || starts.length >= target,
          );
        }
        final finalBatch = starts
            .where((task) => acknowledged.add(task.taskId))
            .toList(growable: false);
        if (finalBatch.isNotEmpty) await markRunning(finalBatch);
      }

      int rangeSize(DownloadTask task) {
        final raw = task.headers['Range'];
        expect(raw, isNotNull);
        final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(raw!);
        expect(match, isNotNull);
        final from = int.parse(match!.group(1)!);
        final to = int.parse(match.group(2)!);
        return to - from + 1;
      }

      expect(await coordinator.start(parent, totalBytes), isTrue);
      await expandFreshTo(5);
      expect(starts, hasLength(5));

      // Materialize and acknowledge the first four ranges. Keep the final
      // range absent until storage pressure is in place so exact-size disk
      // adoption cannot race ahead and assemble before the ENOSPC boundary.
      for (final task in starts.take(4)) {
        final file = File(await task.filePath());
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          List<int>.filled(rangeSize(task), 7),
          flush: true,
        );
        coordinator.handleUpdate(TaskStatusUpdate(task, TaskStatus.complete));
        await Future<void>.delayed(Duration.zero);
      }

      final df = await Process.run('df', <String>['-Pk', directory.path]);
      expect(df.exitCode, 0, reason: '${df.stderr}');
      final lines = (df.stdout as String)
          .trim()
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList(growable: false);
      expect(lines.length, greaterThanOrEqualTo(2));
      final columns = lines.last.trim().split(RegExp(r'\s+'));
      final availableKiB = int.parse(columns[3]);
      const leaveBeforeFinalPartKiB = 8;
      expect(
        availableKiB,
        greaterThan(leaveBeforeFinalPartKiB + 16),
        reason: 'CI bounded tmpfs must have enough room for verified parts',
      );

      final filler = File('${directory.path}.filler');
      final output = await filler.open(mode: FileMode.write);
      try {
        var remaining = (availableKiB - leaveBeforeFinalPartKiB) * 1024;
        final block = List<int>.filled(1024 * 1024, 3);
        while (remaining > 0) {
          final count = math.min(remaining, block.length);
          await output.writeFrom(block, 0, count);
          remaining -= count;
        }
        await output.flush();
      } finally {
        await output.close();
      }

      final lastTask = starts.last;
      final lastFile = File(await lastTask.filePath());
      await lastFile.parent.create(recursive: true);
      await lastFile.writeAsBytes(
        List<int>.filled(rangeSize(lastTask), 7),
        flush: true,
      );

      final partFiles = <File>[
        for (final task in starts) File(await task.filePath()),
      ];
      final target = File(await parent.filePath());
      expect(
        await target.exists(),
        isFalse,
        reason: 'assembly must not happen before the final completion signal',
      );

      coordinator.handleUpdate(
        TaskStatusUpdate(lastTask, TaskStatus.complete),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(
        await target.exists(),
        isFalse,
        reason: 'assembly must not claim success when staging cannot fit',
      );
      for (final file in partFiles) {
        expect(
          await file.exists(),
          isTrue,
          reason: 'verified range bytes must survive assembly ENOSPC',
        );
      }
      expect(statuses, isNot(contains(TaskStatus.complete)));

      await filler.delete();

      // The same durable ranges must be reusable once storage is available;
      // no range should need to be redownloaded just because staging failed.
      final startsBeforeResume = starts.length;
      expect(await coordinator.start(parent, totalBytes), isTrue);
      await waitUntil('post-ENOSPC assembly retry', () => target.existsSync());
      await waitUntil(
        'post-ENOSPC completion checkpoint',
        () => records[parent.taskId]?.status == TaskStatus.complete,
      );
      expect(starts.length, startsBeforeResume);
      expect(await target.length(), totalBytes);
    },
    skip: !Platform.isLinux,
  );
}
