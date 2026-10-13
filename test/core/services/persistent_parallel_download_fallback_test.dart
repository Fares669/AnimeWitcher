import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/parallel_download_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitUntil(bool Function() predicate) async {
    for (var i = 0; i < 200; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Timed out waiting for parallel fallback');
  }

  test(
    'adopts a full HTTP 200 child without downloading the episode again',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'parallel-full-body-fallback-',
      );
      final parent = ParallelDownloadTask(
        taskId: 'episode-fallback',
        url: 'https://example.com/video',
        filename: 'video.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 4,
        allowPause: true,
      );
      final records = <String, TaskRecord>{};
      final starts = <DownloadTask>[];
      final canceled = <List<String>>[];
      final statuses = <TaskStatus>[];
      final coordinator = PersistentParallelDownload(
        promoteFile: publishCompletedTestFile,
        startPart: (task, progress, size) async {
          starts.add(task);
          return true;
        },
        pausePart: (_) async {},
        cancelParts: (ids) async => canceled.add(List<String>.from(ids)),
        saveRecord: (record) async {
          records[record.task.taskId] = record;
        },
        recordForId: (id) async => records[id],
        onUpdate: (update) {
          if (update is TaskStatusUpdate) statuses.add(update.status);
        },
        onPartProgress: (_, _, _) {},
      );

      try {
        expect(await coordinator.start(parent, 20), isTrue);
        expect(starts.length, 1);
        final first = starts.single;
        expect(first.headers['Range'], 'bytes=0-4');

        final child = File(await first.filePath());
        await child.parent.create(recursive: true);
        final payload = List<int>.generate(20, (index) => index);
        await child.writeAsBytes(payload, flush: true);

        coordinator.handleUpdate(
          TaskStatusUpdate(
            first,
            TaskStatus.complete,
          ).copyWith(responseStatusCode: 200),
        );

        final target = File(await parent.filePath());
        final manifest = File('${target.path}.parts/manifest.json');
        await waitUntil(
          () =>
              target.existsSync() &&
              records[parent.taskId]?.status == TaskStatus.complete &&
              !manifest.existsSync(),
        );

        expect(await target.readAsBytes(), payload);
        expect(
          statuses.where((status) => status == TaskStatus.complete).length,
          1,
        );
        expect(
          starts.length,
          1,
          reason: 'must not start a replacement full GET',
        );
        expect(canceled, hasLength(1));
        expect(canceled.single.toSet(), {
          'episode-fallback.part.1',
          'episode-fallback.part.2',
          'episode-fallback.part.3',
        });
        expect(await manifest.exists(), isFalse);
      } finally {
        await coordinator.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );

  test(
    'does not promote an oversized ranged 206 as a sequential fallback',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'parallel-invalid-full-body-',
      );
      final parent = ParallelDownloadTask(
        taskId: 'episode-invalid',
        url: 'https://example.com/video',
        filename: 'video.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 4,
        allowPause: true,
      );
      final records = <String, TaskRecord>{};
      final starts = <DownloadTask>[];
      final coordinator = PersistentParallelDownload(
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

      try {
        expect(await coordinator.start(parent, 20), isTrue);
        final first = starts.single;
        final child = File(await first.filePath());
        await child.parent.create(recursive: true);
        await child.writeAsBytes(List<int>.generate(20, (i) => i), flush: true);

        coordinator.handleUpdate(
          TaskStatusUpdate(
            first,
            TaskStatus.complete,
          ).copyWith(responseStatusCode: 206),
        );
        await waitUntil(
          () => records[parent.taskId]?.status == TaskStatus.paused,
        );

        expect(await File(await parent.filePath()).exists(), isFalse);
        expect(
          await child.exists(),
          isTrue,
          reason: 'keep bytes for diagnosis/resume',
        );
      } finally {
        await coordinator.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );

  test(
    'automatic fallback never overwrites an unexpected existing target',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'parallel-existing-target-',
      );
      final parent = ParallelDownloadTask(
        taskId: 'episode-existing',
        url: 'https://example.com/video',
        filename: 'video.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 4,
        allowPause: true,
      );
      final records = <String, TaskRecord>{};
      final starts = <DownloadTask>[];
      final coordinator = PersistentParallelDownload(
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

      try {
        final target = File(await parent.filePath());
        await target.parent.create(recursive: true);
        await target.writeAsBytes([9, 9, 9], flush: true);

        expect(await coordinator.start(parent, 20), isTrue);
        final first = starts.single;
        final child = File(await first.filePath());
        await child.parent.create(recursive: true);
        await child.writeAsBytes(List<int>.generate(20, (i) => i), flush: true);

        coordinator.handleUpdate(
          TaskStatusUpdate(
            first,
            TaskStatus.complete,
          ).copyWith(responseStatusCode: 200),
        );
        await waitUntil(
          () => records[parent.taskId]?.status == TaskStatus.paused,
        );

        expect(await target.readAsBytes(), [9, 9, 9]);
        expect(await child.exists(), isTrue);
      } finally {
        await coordinator.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );

  test(
    'rejects exact-size child bytes when native Content-Range is wrong',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'parallel-content-range-mismatch-',
      );
      final parent = ParallelDownloadTask(
        taskId: 'episode-range-mismatch',
        url: 'https://example.com/video',
        filename: 'video.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 4,
        allowPause: true,
      );
      final records = <String, TaskRecord>{};
      final starts = <DownloadTask>[];
      final coordinator = PersistentParallelDownload(
        promoteFile: publishCompletedTestFile,
        startPart: (task, progress, size) async {
          starts.add(task);
          return true;
        },
        pausePart: (_) async {},
        cancelParts: (_) async {},
        saveRecord: (record) async => records[record.task.taskId] = record,
        recordForId: (id) async => records[id],
        onUpdate: (_) {},
        onPartProgress: (_, _, _) {},
      );

      try {
        expect(await coordinator.start(parent, 20), isTrue);
        final first = starts.single;
        final child = File(await first.filePath());
        await child.parent.create(recursive: true);
        await child.writeAsBytes(List<int>.filled(5, 7), flush: true);

        coordinator.handleUpdate(
          TaskStatusUpdate(first, TaskStatus.complete).copyWith(
            responseStatusCode: 206,
            responseHeaders: const {
              'content-range': 'bytes 5-9/20',
              'etag': '"v1"',
            },
          ),
        );
        await waitUntil(
          () => records[parent.taskId]?.status == TaskStatus.paused,
        );

        expect(await child.exists(), isFalse);
        expect(await File(await parent.filePath()).exists(), isFalse);
        expect(records[first.taskId]?.progress, 0);
      } finally {
        await coordinator.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );

  test(
    'pins first validator onto later ranges and rejects a changed entity',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'parallel-validator-pin-',
      );
      final parent = ParallelDownloadTask(
        taskId: 'episode-validator-pin',
        url: 'https://example.com/video',
        filename: 'video.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 4,
        allowPause: true,
      );
      final records = <String, TaskRecord>{};
      final starts = <DownloadTask>[];
      final coordinator = PersistentParallelDownload(
        promoteFile: publishCompletedTestFile,
        startPart: (task, progress, size) async {
          starts.add(task);
          return true;
        },
        pausePart: (_) async {},
        cancelParts: (_) async {},
        saveRecord: (record) async => records[record.task.taskId] = record,
        recordForId: (id) async => records[id],
        onUpdate: (_) {},
        onPartProgress: (_, _, _) {},
      );

      try {
        expect(await coordinator.start(parent, 20), isTrue);
        final first = starts.single;
        final firstFile = File(await first.filePath());
        await firstFile.parent.create(recursive: true);
        await firstFile.writeAsBytes(List<int>.filled(5, 1), flush: true);
        coordinator.handleUpdate(
          TaskStatusUpdate(first, TaskStatus.complete).copyWith(
            responseStatusCode: 206,
            responseHeaders: const {
              'content-range': 'bytes 0-4/20',
              'etag': '"v1"',
            },
          ),
        );

        await waitUntil(() => starts.length >= 3);
        expect(starts[1].headers['If-Range'], '"v1"');
        expect(starts[2].headers['If-Range'], '"v1"');

        final second = starts[1];
        expect(second.headers['Range'], 'bytes=5-9');
        final secondFile = File(await second.filePath());
        await secondFile.parent.create(recursive: true);
        await secondFile.writeAsBytes(List<int>.filled(5, 2), flush: true);
        coordinator.handleUpdate(
          TaskStatusUpdate(second, TaskStatus.complete).copyWith(
            responseStatusCode: 206,
            responseHeaders: const {
              'content-range': 'bytes 5-9/20',
              'etag': '"v2"',
            },
          ),
        );

        await waitUntil(
          () => records[parent.taskId]?.status == TaskStatus.paused,
        );
        expect(await firstFile.exists(), isTrue);
        expect(await secondFile.exists(), isFalse);
        expect(records[second.taskId]?.progress, 0);

        final manifest = File('${await parent.filePath()}.parts/manifest.json');
        final manifestText = await manifest.readAsString();
        expect(manifestText, contains('resourceValidator'));
        expect(manifestText, contains(r'\"v1\"'));
      } finally {
        await coordinator.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );
}
