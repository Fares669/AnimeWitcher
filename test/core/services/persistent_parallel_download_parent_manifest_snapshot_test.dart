import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('multipart manifest persists a recoverable parent task descriptor', () async {
    final directory = await Directory.systemTemp.createTemp(
      'parallel-parent-manifest-',
    );
    final parent = ParallelDownloadTask(
      taskId: 'manifest-parent',
      url: 'https://example.test/video.mp4?token=one',
      filename: 'episode.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 2,
      allowPause: true,
      metaData: 'https://animewitcher.test/episode/1',
    );
    final coordinator = PersistentParallelDownload(
      startPart: (_, _, _) async => true,
      pausePart: (_) async {},
      cancelParts: (_) async {},
      saveRecord: (_) async {},
      recordForId: (_) async => null,
      onUpdate: (_) {},
      onPartProgress: (_, _, _) {},
      livePartIds: () async => <String>{},
      diskProgressPollInterval: const Duration(seconds: 30),
    );

    try {
      expect(await coordinator.start(parent, 20), isTrue);
      final manifest = File('${await parent.filePath()}.parts/manifest.json');
      final snapshot =
          jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;

      expect(snapshot['schemaVersion'], greaterThanOrEqualTo(6));
      expect(snapshot['parentTaskId'], parent.taskId);
      expect(snapshot['parentTask'], isA<Map>());

      final restored = Task.createFromJson(
        Map<String, dynamic>.from(snapshot['parentTask'] as Map),
      );
      expect(restored, isA<ParallelDownloadTask>());
      final restoredParent = restored as ParallelDownloadTask;
      expect(restoredParent.taskId, parent.taskId);
      expect(restoredParent.url, parent.url);
      expect(restoredParent.filename, parent.filename);
      expect(restoredParent.directory, parent.directory);
      expect(restoredParent.metaData, parent.metaData);
      expect(restoredParent.chunks, parent.chunks);
    } finally {
      await coordinator.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });
}
