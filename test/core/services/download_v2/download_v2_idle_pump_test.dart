import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('duplicate native byte samples do not rewrite the manifest', () async {
    final directory = await Directory.systemTemp.createTemp(
      'parallel-idle-pump-',
    );
    final records = <String, TaskRecord>{};
    final starts = <DownloadTask>[];
    final parent = ParallelDownloadTask(
      taskId: 'native-idle-pump',
      url: 'https://example.com/video',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 5,
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
      livePartIds: () async => starts.map((task) => task.taskId).toSet(),
      maxActiveConnections: 1,
    );

    try {
      expect(await coordinator.start(parent, 25), isTrue);
      final child = starts.single;
      coordinator.handleUpdate(TaskStatusUpdate(child, TaskStatus.running));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final manifest = File('${await parent.filePath()}.parts/manifest.json');
      final before = jsonDecode(await manifest.readAsString()) as Map;

      for (var sample = 0; sample < 5; sample++) {
        await coordinator.handleNativeChunkUpdate(
          parentTaskId: parent.taskId,
          chunkTaskId: child.taskId,
          writtenBytes: 0,
          speedBytesPerSecond: 250000,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final after = jsonDecode(await manifest.readAsString()) as Map;
      expect(
        after['checkpointSequence'],
        before['checkpointSequence'],
        reason: 'duplicate telemetry is not a durable recovery checkpoint',
      );
      expect(starts, hasLength(1));
    } finally {
      await coordinator.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });
}
