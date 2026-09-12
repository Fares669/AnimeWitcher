import 'dart:async';
import 'dart:io';

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
      final assemblyFailures = <ParallelAssemblyFailure>[];
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
        availableStorageBytes: (path) async {
          final result = await Process.run('df', <String>['-Pk', path]);
          if (result.exitCode != 0) return null;
          final lines = (result.stdout as String).trim().split('\n');
          final columns = lines.last.trim().split(RegExp(r'\s+'));
          return int.parse(columns[3]) * 1024;
        },
        assemblyStorageReserveBytes: 4 * 1024,
        onAssemblyFailure: assemblyFailures.add,
        recoveryDelay: const Duration(milliseconds: 25),
        diskProgressPollInterval: const Duration(seconds: 30),
      );

      addTearDown(() async {
        await coordinator.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      });

      Future<void> waitUntil(String stage, bool Function() predicate) async {
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

      // Fill the bounded tmpfs until the kernel itself reports ENOSPC instead
      // of estimating free space from df. Then release exactly two 4 KiB
      // pages: the final part consumes one page, leaving at most one page for
      // an 8 KiB staging file. This makes the assembly failure deterministic
      // despite sparse-file and filesystem-accounting differences.
      final filler = File('${directory.path}.filler');
      final output = await filler.open(mode: FileMode.write);
      final block = List<int>.filled(4096, 3);
      var hitEnospc = false;
      try {
        while (true) {
          try {
            await output.writeFrom(block);
          } on FileSystemException catch (error) {
            expect(
              error.osError?.errorCode,
              28,
              reason: 'bounded Linux tmpfs must fail with ENOSPC',
            );
            hitEnospc = true;
            break;
          }
        }
      } finally {
        try {
          await output.close();
        } on FileSystemException {
          // Closing a descriptor after ENOSPC may surface the same writeback
          // error; the file length below is the authoritative allocation.
        }
      }
      expect(hitEnospc, isTrue);
      final fillerLength = await filler.length();
      expect(fillerLength, greaterThan(16 * 1024));
      final trimmer = await filler.open(mode: FileMode.append);
      try {
        await trimmer.truncate(fillerLength - 8192);
      } finally {
        await trimmer.close();
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

      coordinator.handleUpdate(TaskStatusUpdate(lastTask, TaskStatus.complete));
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
      await waitUntil(
        'typed storage failure projection',
        () => assemblyFailures.isNotEmpty || target.existsSync(),
      );
      expect(await target.exists(), isFalse);
      expect(assemblyFailures, hasLength(1));
      expect(
        assemblyFailures.single.reason,
        ParallelAssemblyFailureReason.insufficientStorage,
      );

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
