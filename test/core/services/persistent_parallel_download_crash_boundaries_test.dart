import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/parallel_download_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CheckpointCrashFixture fixture;
  setUp(() async => fixture = await _CheckpointCrashFixture.create());
  tearDown(() async => fixture.dispose());

  test(
    'torn temporary write leaves the committed checkpoint authoritative',
    () async {
      final committed = await fixture.manifest.readAsBytes();
      await fixture.temp.writeAsString(
        '{"checkpointSequence":101,"parts":[',
        flush: true,
      );

      expect(await fixture.coordinator.restore(fixture.parent), isTrue);
      expect(fixture.coordinator.progressFor(fixture.parent.taskId), 0.25);
      expect(await fixture.manifest.readAsBytes(), committed);
      expect(await fixture.part.readAsBytes(), [0, 1]);
      expect(fixture.starts, isEmpty);
    },
  );

  test(
    'valid temporary checkpoint recovers a torn primary without a writer',
    () async {
      final newer = await fixture.snapshot(sequence: 101, progress: 0.5);
      await fixture.part.writeAsBytes([0, 1, 2, 3], flush: true);
      await fixture.temp.writeAsString(jsonEncode(newer), flush: true);
      await fixture.manifest.writeAsString(
        '{"checkpointSequence":100,',
        flush: true,
      );

      expect(await fixture.coordinator.restore(fixture.parent), isTrue);
      expect(fixture.coordinator.progressFor(fixture.parent.taskId), 0.5);
      expect(jsonDecode(await fixture.manifest.readAsString()), newer);
      expect(await fixture.temp.exists(), isFalse);
      expect(await fixture.part.readAsBytes(), [0, 1, 2, 3]);
      expect(fixture.starts, isEmpty);
    },
  );

  test(
    'two torn checkpoints fence fresh start and preserve recoverable bytes',
    () async {
      const primary = '{"checkpointSequence":100,';
      const temporary = '{"checkpointSequence":101,"parts":[';
      await fixture.manifest.writeAsString(primary, flush: true);
      await fixture.temp.writeAsString(temporary, flush: true);

      expect(await fixture.coordinator.restore(fixture.parent), isFalse);
      expect(await fixture.coordinator.start(fixture.parent, 8), isFalse);
      expect(fixture.starts, isEmpty);
      expect(await fixture.manifest.readAsString(), primary);
      expect(await fixture.temp.readAsString(), temporary);
      expect(await fixture.part.readAsBytes(), [0, 1]);
      expect(await File(await fixture.parent.filePath()).exists(), isFalse);
    },
  );

  test(
    'older temporary checkpoint cannot roll back a committed rename',
    () async {
      final committed = await fixture.manifest.readAsBytes();
      final older = await fixture.snapshot(sequence: 99, progress: 0.125);
      await fixture.temp.writeAsString(jsonEncode(older), flush: true);
      await fixture.manifest.setLastModified(DateTime.utc(2020));
      await fixture.temp.setLastModified(DateTime.utc(2021));

      expect(await fixture.coordinator.restore(fixture.parent), isTrue);
      expect(fixture.coordinator.progressFor(fixture.parent.taskId), 0.25);
      expect(await fixture.manifest.readAsBytes(), committed);
      expect(await fixture.part.readAsBytes(), [0, 1]);
      expect(fixture.starts, isEmpty);
    },
  );

  test(
    'newer structurally invalid temporary checkpoint falls back to primary',
    () async {
      final committed = await fixture.manifest.readAsBytes();
      final invalid = await fixture.snapshot(sequence: 101, progress: 0.5);
      ((invalid['parts'] as List).single as Map)['from'] = 1;
      await fixture.temp.writeAsString(jsonEncode(invalid), flush: true);

      expect(await fixture.coordinator.restore(fixture.parent), isTrue);
      expect(fixture.coordinator.progressFor(fixture.parent.taskId), 0.25);
      expect(await fixture.manifest.readAsBytes(), committed);
      expect(await fixture.part.readAsBytes(), [0, 1]);
      expect(fixture.starts, isEmpty);
    },
  );

  test(
    'failed checkpoint rename retains temporary authority until retry',
    () async {
      final committed = await fixture.manifest.readAsBytes();
      await fixture.manifest.rename(fixture.temp.path);
      final obstruction = await Directory(fixture.manifest.path).create();
      final sentinel = File('${obstruction.path}/foreign');
      await sentinel.writeAsString('do not remove', flush: true);

      expect(await fixture.coordinator.restore(fixture.parent), isTrue);
      expect(await fixture.coordinator.start(fixture.parent, 8), isFalse);
      expect(fixture.starts, isEmpty);
      expect(await fixture.temp.readAsBytes(), committed);
      expect(await sentinel.readAsString(), 'do not remove');
      expect(await fixture.part.readAsBytes(), [0, 1]);

      await obstruction.delete(recursive: true);
      expect(await fixture.coordinator.start(fixture.parent, 8), isTrue);
      expect(fixture.starts, hasLength(1));
      expect(await fixture.manifest.exists(), isTrue);
      expect(await fixture.temp.exists(), isFalse);
      expect(await fixture.part.readAsBytes(), [0, 1]);
      expect(fixture.coordinator.progressFor(fixture.parent.taskId), 0.25);
    },
  );
}

class _CheckpointCrashFixture {
  _CheckpointCrashFixture(this.directory) {
    parent = ParallelDownloadTask(
      taskId: 'checkpoint-crash',
      url: 'https://example.test/video',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 1,
      allowPause: true,
    );
  }

  final Directory directory;
  late final ParallelDownloadTask parent;
  late final File manifest;
  late final File part;
  late PersistentParallelDownload coordinator;
  final starts = <DownloadTask>[];
  final records = <String, TaskRecord>{};
  File get temp => File('${manifest.path}.tmp');

  static Future<_CheckpointCrashFixture> create() async {
    final fixture = _CheckpointCrashFixture(
      await Directory.systemTemp.createTemp('parallel-crash-boundary-'),
    );
    fixture.rebuild();
    expect(await fixture.coordinator.start(fixture.parent, 8), isTrue);
    fixture.part = File(await fixture.starts.single.filePath());
    await fixture.part.writeAsBytes([0, 1], flush: true);
    expect(await fixture.coordinator.pause(fixture.parent), isTrue);
    await fixture.coordinator.dispose();
    fixture.manifest = File(
      '${await fixture.parent.filePath()}.parts/manifest.json',
    );
    final committed = await fixture.snapshot(sequence: 100, progress: 0.25);
    await fixture.manifest.writeAsString(jsonEncode(committed), flush: true);
    fixture.starts.clear();
    fixture.rebuild();
    return fixture;
  }

  Future<Map<String, dynamic>> snapshot({
    required int sequence,
    required double progress,
  }) async {
    final snapshot =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    snapshot['checkpointSequence'] = sequence;
    final part = (snapshot['parts'] as List).single as Map<String, dynamic>;
    part['progress'] = progress;
    part['credibleProgress'] = progress;
    part['durableBytes'] = (progress * 8).toInt();
    part['complete'] = false;
    return snapshot;
  }

  void rebuild() {
    coordinator = PersistentParallelDownload(
      verifyPartSource: verifiedSavedTestRange,
      promoteFile: publishCompletedTestFile,
      startPart: (task, _, _) async {
        starts.add(task);
        return true;
      },
      pausePart: (_) async {},
      cancelParts: (_) async {},
      saveRecord: (record) async {
        records[record.taskId] = record;
      },
      recordForId: (id) async => records[id],
      onUpdate: (_) {},
      onPartProgress: (_, _, _) {},
      livePartIds: () async => <String>{},
      recoveryDelay: const Duration(days: 1),
      diskProgressPollInterval: const Duration(days: 1),
      pendingStartLeaseDelay: const Duration(days: 1),
      tailStallDelay: const Duration(days: 1),
    );
  }

  Future<void> dispose() async {
    await coordinator.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
