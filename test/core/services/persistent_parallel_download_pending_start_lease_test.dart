import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('accepted multipart start with no callback releases stale pending reservation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'parallel-pending-start-lease-',
    );
    final starts = <DownloadTask>[];
    final records = <String, TaskRecord>{};
    final parent = ParallelDownloadTask(
      taskId: 'pending-start-episode',
      url: 'https://cdn.example.test/video.mp4',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 2,
      allowPause: true,
    );
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
      livePartIds: () async => <String>{},
      recoveryDelay: const Duration(milliseconds: 10),
      pendingStartLeaseDelay: const Duration(milliseconds: 40),
      maxActiveConnections: 2,
    );

    try {
      const mib = 1024 * 1024;
      expect(await coordinator.start(parent, 2 * mib), isTrue);
      expect(starts, hasLength(1));
      final first = starts.single;

      // startPart accepted the enqueue but native ownership never appeared and
      // no running/progress/final callback was delivered. The coordinator must
      // not leave this child in the slow-start pending set forever. Another
      // range may use the freed slot while this range observes recovery backoff,
      // but the original immutable Range must itself be retried with a new
      // attempt generation.
      await Future<void>.delayed(const Duration(milliseconds: 250));

      final retriedFirstRange = starts
          .where((task) => task.taskId == first.taskId)
          .skip(1)
          .toList(growable: false);
      expect(retriedFirstRange, isNotEmpty);
      expect(retriedFirstRange.first.metaData, isNot(first.metaData));
      expect(coordinator.isActive(parent.taskId), isTrue);
    } finally {
      await coordinator.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });
}
