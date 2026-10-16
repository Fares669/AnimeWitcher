import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final validator in ['unquoted-v1', 'Wed, 21 Oct 2015 07:28:00 GMT']) {
    for (final sameBytes in [false, true]) {
      for (final refresh in [false, true]) {
        for (final prefixKind in ['none', 'hidden', 'visible']) {
          for (final currentValidator in <String?>[null, '"current"']) {
            final hiddenPrefix = prefixKind == 'hidden';
            test(
              'legacy $validator ${sameBytes ? 'verifies before continuing' : 'preserves changed same-size source'} (prefix: $prefixKind, refresh: $refresh, current: $currentValidator)',
              () async {
                final directory = await Directory.systemTemp.createTemp(
                  'legacy-validator-',
                );
                final starts = <DownloadTask>[];
                final probes = <DownloadTask>[];
                final records = <String, TaskRecord>{};
                final parent = ParallelDownloadTask(
                  taskId: 'legacy-validator',
                  url: 'https://example.test/video',
                  filename: 'video.mp4',
                  directory: directory.path,
                  baseDirectory: BaseDirectory.root,
                  chunks: 2,
                  allowPause: true,
                );
                PersistentParallelDownload create() =>
                    PersistentParallelDownload(
                      startPart: (task, _, _) async {
                        starts.add(task);
                        return true;
                      },
                      pausePart: (_) async {},
                      cancelParts: (_) async {},
                      saveRecord: (record) async {
                        records[record.task.taskId] = record;
                      },
                      recordForId: (id) async => records[id],
                      livePartIds: () async => {},
                      onUpdate: (_) {},
                      onPartProgress: (_, _, _) {},
                      verifyPartSource: (task, file, bytes, size) async {
                        probes.add(task);
                        expect(
                          task.headers.keys.map((key) => key.toLowerCase()),
                          isNot(contains('if-range')),
                        );
                        expect(
                          await file.readAsBytes(),
                          task.headers['Range'] == 'bytes=0-3'
                              ? [1, 2, 3, 4]
                              : [9, 10],
                        );
                        expect(
                          bytes,
                          task.headers['Range'] == 'bytes=0-3' ? 4 : 2,
                        );
                        expect(size, 8);
                        return (
                          matches: sameBytes,
                          validator: currentValidator,
                        );
                      },
                    );
                var coordinator = create();
                try {
                  expect(await coordinator.start(parent, 8), isTrue);
                  expect(await coordinator.pause(parent), isTrue);
                  await coordinator.dispose();
                  final manifest = File(
                    '${await parent.filePath()}.parts/manifest.json',
                  );
                  final saved = jsonDecode(
                    await manifest.readAsString(),
                  ) as Map<String, dynamic>;
                  saved['resourceValidator'] = validator;
                  saved.remove('resourceValidatorQualified');
                  final first =
                      (saved['parts'] as List).first as Map<String, dynamic>;
                  first['complete'] = true;
                  first['progress'] = 1;
                  first['credibleProgress'] = 1;
                  first['durableBytes'] = 4;
                  if (hiddenPrefix) {
                    final unfinished = (saved['parts'] as List).last as Map;
                    unfinished['progress'] = 0.5;
                    unfinished['credibleProgress'] = 0.5;
                  }
                  for (final raw in saved['parts'] as List) {
                    ((raw as Map)['task'] as Map)['headers']['If-Range'] =
                        validator;
                  }
                  final child = DownloadTask.fromJson(
                    Map<String, dynamic>.from(first['task'] as Map),
                  );
                  final file = File(await child.filePath());
                  await file.writeAsBytes([1, 2, 3, 4], flush: true);
                  if (prefixKind == 'visible') {
                    final last = (saved['parts'] as List).last as Map;
                    final partial = DownloadTask.fromJson(
                      Map<String, dynamic>.from(last['task'] as Map),
                    );
                    await File(await partial.filePath())
                        .writeAsBytes([9, 10], flush: true);
                  }
                  await manifest.writeAsString(jsonEncode(saved), flush: true);
                  starts.clear();
                  coordinator = create();
                  if (refresh) {
                    final updated = await coordinator.replaceSource(
                      parent,
                      url: 'https://example.test/refreshed',
                      headers: {},
                    );
                    expect(updated != null, sameBytes);
                    if (updated != null) {
                      expect(await coordinator.start(updated, 8), isTrue);
                    }
                  } else {
                    expect(await coordinator.start(parent, 8), sameBytes);
                  }
                  expect(
                    probes,
                    hasLength(sameBytes && prefixKind == 'visible' ? 2 : 1),
                  );
                  expect(await file.readAsBytes(), [1, 2, 3, 4]);
                  if (sameBytes) {
                    expect(starts, hasLength(1));
                    expect(starts.single.headers['Range'], 'bytes=4-7');
                    expect(starts.single.headers['If-Range'], currentValidator);
                    final metadata = jsonDecode(starts.single.metaData) as Map;
                    expect(metadata['sourceValidationRequired'], isTrue);
                  } else {
                    expect(starts, isEmpty);
                    expect(coordinator.isActive(parent.taskId), isFalse);
                  }
                } finally {
                  await coordinator.dispose();
                  await directory.delete(recursive: true);
                }
              },
            );
          }
        }
      }
    }
  }
}
