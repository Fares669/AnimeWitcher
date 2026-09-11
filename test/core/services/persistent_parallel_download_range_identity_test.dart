import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'restore canonicalizes child Range header from manifest bounds',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'parallel-range-identity-',
      );
      final starts = <DownloadTask>[];
      final records = <String, TaskRecord>{};
      final parent = ParallelDownloadTask(
        taskId: 'episode',
        url: 'https://example.com/video',
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
      );

      try {
        final childDirectory = '${directory.path}/video.mp4.parts';
        DownloadTask child(int index, int from, int to, String range) =>
            DownloadTask(
              taskId: 'episode.part.$index',
              url: parent.url,
              filename: '$index.part',
              directory: childDirectory,
              baseDirectory: BaseDirectory.root,
              headers: <String, String>{
                'Range': range,
                'Accept-Encoding': 'identity',
              },
              updates: Updates.statusAndProgress,
              retries: kDownloadPartRetries,
              allowPause: true,
              group: kPersistentDownloadChunkGroup,
              metaData: jsonEncode(<String, Object>{
                'parentTaskId': parent.taskId,
              }),
            );

        final first = child(0, 0, 499, 'bytes=0-9');
        final second = child(1, 500, 999, 'bytes=500-999');
        final manifest = File('${await parent.filePath()}.parts/manifest.json');
        await manifest.parent.create(recursive: true);
        await manifest.writeAsString(
          jsonEncode(<String, Object?>{
            'schemaVersion': kParallelManifestSchemaVersion,
            'parentTaskId': parent.taskId,
            'generation': 1,
            'checkpointSequence': 1,
            'expectedBytes': 1000,
            'totalBytes': 1000,
            'resourceValidator': null,
            'parts': <Map<String, Object?>>[
              <String, Object?>{
                'task': first.toJson(),
                'from': 0,
                'to': 499,
                'progress': 0.0,
                'credibleProgress': 0.0,
                'durableBytes': 0,
                'complete': false,
                'attemptGeneration': 1,
                'sourceValidationRequired': false,
              },
              <String, Object?>{
                'task': second.toJson(),
                'from': 500,
                'to': 999,
                'progress': 0.0,
                'credibleProgress': 0.0,
                'durableBytes': 0,
                'complete': false,
                'attemptGeneration': 1,
                'sourceValidationRequired': false,
              },
            ],
          }),
          flush: true,
        );

        expect(await coordinator.start(parent, 1000), isTrue);
        expect(starts, hasLength(1));
        expect(starts.single.headers['Range'], 'bytes=0-499');
      } finally {
        await coordinator.dispose();
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    },
  );
}
