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
    fail('Timed out waiting for tail-balanced download scheduling');
  }

  test(
    'finished connection picks queued tail work without exceeding the configured ceiling',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'parallel-tail-balance-',
      );
      final parent = ParallelDownloadTask(
        taskId: 'tail-balanced-4',
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
        expect(await coordinator.start(parent, 4 * mib), isTrue);
        expect(starts, hasLength(1));
        expect(starts.first.headers['Range'], 'bytes=0-524287');

        await markRunning(starts.take(1));
        await waitUntil(() => starts.length == 3);
        await markRunning(starts.skip(1).take(2));
        await waitUntil(() => starts.length == 4);
        await markRunning(starts.skip(3).take(1));

        expect(coordinator.activeConnectionCount, 4);
        expect(
          starts.map((task) => task.headers['Range']).toList(),
          <String?>[
            'bytes=0-524287',
            'bytes=524288-1048575',
            'bytes=1048576-1572863',
            'bytes=1572864-2097151',
          ],
        );

        final first = starts.first;
        final firstFile = File(await first.filePath());
        await firstFile.parent.create(recursive: true);
        await firstFile.writeAsBytes(
          List<int>.filled(512 * 1024, 7),
          flush: true,
        );
        coordinator.handleUpdate(
          TaskStatusUpdate(first, TaskStatus.complete),
        );

        await waitUntil(() => starts.length == 5);
        expect(coordinator.activeConnectionCount, 4);
        expect(starts[4].taskId, 'tail-balanced-4.part.4');
        expect(starts[4].headers['Range'], 'bytes=2097152-2621439');
      } finally {
        await coordinator.dispose();
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    },
  );
}
