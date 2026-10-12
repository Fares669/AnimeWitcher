import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ParallelDownloadTask parent;
  late PersistentParallelDownload coordinator;
  late Map<String, TaskRecord> records;

  PersistentParallelDownload create() => PersistentParallelDownload(
    startPart: (_, _, _) async => true,
    pausePart: (_) async {},
    cancelParts: (_) async {},
    livePartIds: () async => <String>{},
    saveRecord: (record) async {
      records[record.task.taskId] = record;
    },
    recordForId: (id) async => records[id],
    onUpdate: (_) {},
    onPartProgress: (_, _, _) {},
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('checkpoint-audit-');
    parent = ParallelDownloadTask(
      taskId: 'checkpoint-audit',
      url: 'https://example.com/video?token=checkpoint-secret',
      headers: <String, String>{'Cookie': 'session=checkpoint-secret'},
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 2,
      allowPause: true,
    );
    records = <String, TaskRecord>{};
    coordinator = create();
  });

  tearDown(() async {
    await coordinator.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<({File target, File staging, List<File> parts})>
  legacyEmptyReservation() async {
    expect(await coordinator.start(parent, 8), isTrue);
    expect(await coordinator.pause(parent), isTrue);
    await coordinator.dispose();
    final target = File(await parent.filePath());
    final manifest = File('${target.path}.parts/manifest.json');
    final checkpoint = jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    final parts = <File>[];
    for (final raw in checkpoint['parts'] as List) {
      final part = raw as Map<String, dynamic>;
      final task = Task.createFromJson(Map<String, dynamic>.from(part['task'] as Map));
      final file = File(await task.filePath());
      await file.writeAsBytes(
        List<int>.generate((part['to'] as int) - (part['from'] as int) + 1,
            (i) => (part['from'] as int) + i),
        flush: true,
      );
      part['complete'] = true;
      part['progress'] = 1.0;
      part['credibleProgress'] = 1.0;
      part['durableBytes'] = (part['to'] as int) - (part['from'] as int) + 1;
      parts.add(file);
    }
    await manifest.writeAsString(jsonEncode(checkpoint), flush: true);
    final staging = File('${target.path}.assembling');
    await staging.writeAsBytes(List<int>.generate(8, (i) => i), flush: true);
    await target.writeAsBytes(<int>[], flush: true);
    await File('${target.path}.promoting').writeAsString(
      jsonEncode(<String, Object>{
        'parentTaskId': parent.taskId,
        'expectedBytes': 8,
        'sourcePath': staging.path,
      }),
      flush: true,
    );
    coordinator = create();
    return (target: target, staging: staging, parts: parts);
  }

  test('legacy_ambiguous_empty_reservation_parks_and_preserves_verified_sources', () async {
    final saved = await legacyEmptyReservation();

    expect(await coordinator.start(parent, 8), isFalse);

    expect(await saved.target.exists(), isTrue);
    expect(await saved.target.length(), 0);
    expect(await saved.staging.readAsBytes(), List<int>.generate(8, (i) => i));
    for (final part in saved.parts) {
      expect(await part.exists(), isTrue);
      expect(await part.length(), 4);
    }
    expect(records[parent.taskId]?.status, isNot(TaskStatus.complete));
  });

  test('cancel_does_not_delete_legacy_empty_final_without_inode_ownership', () async {
    final saved = await legacyEmptyReservation();

    await coordinator.cancel(parent);

    expect(await saved.target.exists(), isTrue);
    expect(await saved.target.length(), 0);
  });
}
