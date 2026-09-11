import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ParallelDownloadTask parent;
  late Map<String, TaskRecord> records;
  late List<DownloadTask> starts;
  late List<String> pauses;
  late List<TaskStatus> statuses;
  late PersistentParallelDownload coordinator;
  var acceptStarts = true;
  var throwStarts = false;
  Completer<void>? pauseGate;
  Set<String> liveIds = {};

  PersistentParallelDownload create({
    int maxActiveConnections = 16,
    Duration diskProgressPollInterval = const Duration(seconds: 1),
    bool preserveNativeParts = false,
    void Function(String parentTaskId)? onPausedDrainSettled,
  }) => PersistentParallelDownload(
    startPart: (task, progress, size) async {
      starts.add(task);
      if (throwStarts) throw StateError('native enqueue failed');
      return acceptStarts;
    },
    pausePart: (task) async {
      pauses.add(task.taskId);
      await pauseGate?.future;
    },
    cancelParts: (ids) async {},
    saveRecord: (record) async {
      records[record.task.taskId] = record;
    },
    recordForId: (id) async => records[id],
    onUpdate: (update) {
      if (update is TaskStatusUpdate) statuses.add(update.status);
    },
    onPartProgress: (_, _, _) {},
    maxActiveConnections: maxActiveConnections,
    livePartIds: () async => liveIds,
    shouldDrainPartOnPause: preserveNativeParts ? (_) => true : null,
    onPausedDrainSettled: onPausedDrainSettled,
    recoveryDelay: const Duration(milliseconds: 10),
    diskProgressPollInterval: diskProgressPollInterval,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('parallel-recovery-');
    parent = ParallelDownloadTask(
      taskId: 'episode',
      url: 'https://example.com/video',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 5,
      allowPause: true,
    );
    records = {};
    starts = [];
    pauses = [];
    statuses = [];
    acceptStarts = true;
    throwStarts = false;
    pauseGate = null;
    liveIds = {};
    coordinator = create();
  });

  tearDown(() async {
    // Drain response-gated pump/update microtasks before deleting the durable
    // checkpoint directory. This mirrors a ProviderScope shutdown and catches
    // scheduler work that would otherwise escape after test completion.
    await coordinator.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> waitUntil(bool Function() predicate) async {
    for (var i = 0; i < 200; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Timed out waiting for async connection controller');
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
      expect(batch, isNotEmpty);
      await markRunning(batch);
      await waitUntil(() => starts.length > before || starts.length >= target);
    }

    // Reaching the target means the final slow-start batch was only enqueued;
    // it has not necessarily acknowledged running yet. Mark that last batch as
    // healthy too so tests that follow with recovery/reconcile start from the
    // same fully-established connection level as a real transfer.
    final finalBatch = starts
        .where((task) => acknowledged.add(task.taskId))
        .toList(growable: false);
    if (finalBatch.isNotEmpty) {
      await markRunning(finalBatch);
    }
  }

  Future<void> completePart(DownloadTask task, List<int> bytes) async {
    final file = File(await task.filePath());
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    coordinator.handleUpdate(TaskStatusUpdate(task, TaskStatus.complete));
    await Future<void>.delayed(Duration.zero);
  }



  test('missing multipart manifest is reported as not restorable', () async {
    final manifest = File('${await parent.filePath()}.parts/manifest.json');
    expect(await manifest.exists(), isFalse);
    expect(await coordinator.restore(parent), isFalse);
    expect(
      starts,
      isEmpty,
      reason: 'restore must not create a writer when no manifest exists',
    );
  });
  test('five parts cover each byte once', () async {
    expect(await coordinator.start(parent, 23), isTrue);
    await expandFreshTo(5);
    expect(starts.map((task) => task.headers['Range']), [
      'bytes=0-3',
      'bytes=4-8',
      'bytes=9-12',
      'bytes=13-17',
      'bytes=18-22',
    ]);
    expect(starts.map((task) => task.taskId).toSet().length, 5);
  });

  test(
    'visible part bytes wake a parent when native callbacks are missing',
    () async {
      await coordinator.dispose();
      coordinator = create(
        diskProgressPollInterval: const Duration(milliseconds: 10),
      );

      expect(await coordinator.start(parent, 100), isTrue);
      expect(starts.length, 1);
      final first = starts.single;
      final file = File(await first.filePath());
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.filled(10, 7), flush: true);

      await waitUntil(() => (records[parent.taskId]?.progress ?? 0) > 0);
      final parentRecord = records[parent.taskId]!;
      expect(parentRecord.status, TaskStatus.running);
      expect(parentRecord.progress, closeTo(.1, .001));
      expect(statuses, contains(TaskStatus.running));
      await waitUntil(() => starts.length >= 3);
    },
  );

  test(
    'exact visible part is adopted when native completion callback is lost',
    () async {
      await coordinator.dispose();
      coordinator = create(
        diskProgressPollInterval: const Duration(milliseconds: 10),
      );

      expect(await coordinator.start(parent, 100), isTrue);
      final first = starts.single;
      final file = File(await first.filePath());
      await file.parent.create(recursive: true);
      await file.writeAsBytes(List<int>.filled(20, 9), flush: true);

      await waitUntil(
        () => records[first.taskId]?.status == TaskStatus.complete,
      );
      expect(coordinator.progressFor(parent.taskId), greaterThanOrEqualTo(.2));
      expect(pauses, contains(first.taskId));
      await waitUntil(() => starts.length >= 3);
    },
  );

  test(
    'native iOS byte bridge advances parent before final part file exists',
    () async {
      expect(await coordinator.start(parent, 100), isTrue);
      expect(starts.length, 1);
      final first = starts.single;

      await coordinator.handleNativeChunkUpdate(
        parentTaskId: parent.taskId,
        chunkTaskId: first.taskId,
        writtenBytes: 10,
        expectedBytes: 20,
        speedBytesPerSecond: 500000,
      );

      final parentRecord = records[parent.taskId]!;
      expect(parentRecord.status, TaskStatus.running);
      expect(parentRecord.progress, closeTo(.1, .001));
      expect(statuses, contains(TaskStatus.running));
      await waitUntil(() => starts.length >= 3);
    },
  );

  test('native iOS completion bridge adopts the exact moved part', () async {
    expect(await coordinator.start(parent, 100), isTrue);
    final first = starts.single;
    final file = File(await first.filePath());
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List<int>.filled(20, 4), flush: true);

    await coordinator.handleNativeChunkUpdate(
      parentTaskId: parent.taskId,
      chunkTaskId: first.taskId,
      writtenBytes: 20,
      expectedBytes: 20,
      completed: true,
    );

    expect(records[first.taskId]?.status, TaskStatus.complete);
    expect(coordinator.progressFor(parent.taskId), greaterThanOrEqualTo(.2));
    await waitUntil(() => starts.length >= 3);
  });

  test('repeated system pauses recover only the affected identity', () async {
    await coordinator.start(parent, 25);
    await expandFreshTo(5);
    final original = List<DownloadTask>.from(starts);
    var current = original[1];
    for (var attempt = 0; attempt < 6; attempt++) {
      final expectedStarts = starts.length + 1;
      coordinator.handleUpdate(TaskStatusUpdate(current, TaskStatus.paused));
      await waitUntil(() => starts.length >= expectedStarts);
      final recovered = starts.last;
      expect(recovered.taskId, original[1].taskId);
      // Each interruption must come from the currently owned native attempt.
      // Reusing the original task would intentionally exercise the stale-token
      // fence rather than repeated real system pauses.
      await markRunning([recovered]);
      current = recovered;
      expect(coordinator.activeConnectionCount, 5);
      expect(pauses, isEmpty);
      expect(coordinator.isActive(parent.taskId), isTrue);
      expect(statuses.last, TaskStatus.running);
    }
    expect(statuses, isNot(contains(TaskStatus.waitingToRetry)));
    expect(statuses, isNot(contains(TaskStatus.paused)));
  });

  test(
    'iOS user pause drains launched native range without destructive pause',
    () async {
      final settled = <String>[];
      await coordinator.dispose();
      coordinator = create(
        preserveNativeParts: true,
        onPausedDrainSettled: settled.add,
      );

      expect(await coordinator.start(parent, 25), isTrue);
      expect(starts.length, 1);
      final first = starts.single;
      liveIds = <String>{first.taskId};
      await markRunning(<DownloadTask>[first]);

      expect(await coordinator.pause(parent, preserveLiveParts: true), isTrue);
      final startsAfterPause = starts.length;
      expect(pauses, isEmpty);
      expect(coordinator.isActive(parent.taskId), isFalse);
      expect(coordinator.activeConnectionCount, 1);
      expect(statuses.last, TaskStatus.paused);

      await completePart(first, <int>[0, 1, 2, 3, 4]);
      await waitUntil(() => coordinator.activeConnectionCount == 0);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(records[first.taskId]?.status, TaskStatus.complete);
      expect(settled, contains(parent.taskId));
      expect(
        starts.length,
        startsAfterPause,
        reason: 'inactive paused parent must not schedule tail work',
      );
    },
  );

  test(
    'resume during iOS pause drain reuses the same native child identity',
    () async {
      await coordinator.dispose();
      coordinator = create(preserveNativeParts: true);

      expect(await coordinator.start(parent, 25), isTrue);
      final first = starts.single;
      liveIds = <String>{first.taskId};
      await markRunning(<DownloadTask>[first]);
      expect(await coordinator.pause(parent, preserveLiveParts: true), isTrue);
      expect(coordinator.activeConnectionCount, 1);

      expect(await coordinator.start(parent, 25), isTrue);
      expect(
        starts.where((task) => task.taskId == first.taskId).length,
        1,
        reason: 'the still-owned URLSession range must not be enqueued twice',
      );
      expect(coordinator.isActive(parent.taskId), isTrue);
    },
  );

  test(
    'failed child while parent is pause-draining releases slot without retry',
    () async {
      final settled = <String>[];
      await coordinator.dispose();
      coordinator = create(
        preserveNativeParts: true,
        onPausedDrainSettled: settled.add,
      );

      expect(await coordinator.start(parent, 25), isTrue);
      final first = starts.single;
      liveIds = <String>{first.taskId};
      await markRunning(<DownloadTask>[first]);
      expect(await coordinator.pause(parent, preserveLiveParts: true), isTrue);
      final startsAtPause = starts.length;

      coordinator.handleUpdate(TaskStatusUpdate(first, TaskStatus.failed));
      await waitUntil(() => coordinator.activeConnectionCount == 0);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(starts.length, startsAtPause);
      expect(coordinator.isActive(parent.taskId), isFalse);
      expect(settled, contains(parent.taskId));
      expect(statuses.last, TaskStatus.paused);
    },
  );

  test('user pause cancels a pending automatic part recovery', () async {
    await coordinator.start(parent, 25);
    final first = starts.first;
    coordinator.handleUpdate(TaskStatusUpdate(first, TaskStatus.paused));
    await coordinator.pause(parent);
    final startsAfterUserPause = starts.length;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    // Recovery is allowed to hand the just-freed slot to healthy queued work
    // before the user's pause is serialized. Once the user pause completes,
    // however, no pending recovery timer may launch anything else.
    expect(starts.length, startsAfterUserPause);
    expect(coordinator.isActive(parent.taskId), isFalse);
    expect(coordinator.activeConnectionCount, 0);
    expect(statuses.last, TaskStatus.paused);
  });

  test(
    'a pump enqueue exception recovers without pausing the logical parent',
    () async {
      await coordinator.start(parent, 25);
      throwStarts = true;
      await markRunning(starts.take(1));
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(coordinator.isActive(parent.taskId), isTrue);
      expect(statuses, isNot(contains(TaskStatus.paused)));

      throwStarts = false;
      final beforeRecovery = starts.length;
      await waitUntil(() => starts.length > beforeRecovery);
      await markRunning(starts.skip(beforeRecovery));
      expect(coordinator.isActive(parent.taskId), isTrue);
      expect(statuses, isNot(contains(TaskStatus.paused)));
    },
  );

  test(
    'completed parts ignore duplicate and late nonfinal callbacks',
    () async {
      await coordinator.start(parent, 25);
      await expandFreshTo(5);
      final first = starts.first;
      await completePart(first, [0, 1, 2, 3, 4]);
      await waitUntil(() => coordinator.activeConnectionCount == 4);
      for (final status in [
        TaskStatus.complete,
        TaskStatus.running,
        TaskStatus.waitingToRetry,
        TaskStatus.failed,
      ]) {
        coordinator.handleUpdate(TaskStatusUpdate(first, status));
      }
      coordinator.handleUpdate(TaskProgressUpdate(first, .5, 5));
      await coordinator.reconcile(
        () async => starts.skip(1).map((t) => t.taskId).toSet(),
      );
      expect(coordinator.isActive(parent.taskId), isTrue);
      expect(coordinator.activeConnectionCount, 4);
      expect(statuses, isNot(contains(TaskStatus.paused)));
    },
  );

  test(
    'pause requests every connection before waiting for callbacks',
    () async {
      await coordinator.start(parent, 25);
      await expandFreshTo(5);
      final gate = Completer<void>();
      pauseGate = gate;
      final pausing = coordinator.pause(parent);
      try {
        await waitUntil(() => pauses.length == 5);
        expect(coordinator.isActive(parent.taskId), isFalse);
      } finally {
        gate.complete();
        await pausing;
      }
      expect(coordinator.activeConnectionCount, 0);
    },
  );

  test(
    'pause after recreation does not pause children with no native owner',
    () async {
      await coordinator.start(parent, 25);
      await expandFreshTo(5);
      await coordinator.dispose();
      pauses.clear();
      liveIds = <String>{};
      coordinator = create();
      await coordinator.pause(parent);
      expect(pauses, isEmpty);
      expect(coordinator.activeConnectionCount, 0);
    },
  );

  test(
    'restored live native children count against the global budget',
    () async {
      await coordinator.start(parent, 25);
      await expandFreshTo(5);
      liveIds = starts.map((task) => task.taskId).toSet();
      await coordinator.dispose();
      starts.clear();
      coordinator = create(maxActiveConnections: 5);
      expect(await coordinator.restore(parent), isTrue);
      expect(coordinator.activeConnectionCount, 5);
      expect(await coordinator.start(parent, 25), isTrue);
      expect(starts, isEmpty);
      final second = ParallelDownloadTask(
        taskId: 'second',
        url: parent.url,
        filename: 'second.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 5,
      );
      await coordinator.start(second, 25);
      expect(starts, isEmpty);
      expect(coordinator.activeConnectionCount, 5);
    },
  );

  test(
    'missing worker callbacks begin governed recovery without pausing parent',
    () async {
      await coordinator.start(parent, 25);
      await expandFreshTo(5);
      final original = List<DownloadTask>.from(starts);
      await File(await original.first.filePath()).writeAsBytes([0, 1, 2, 3, 4]);

      await coordinator.reconcile(() async => <String>{});

      expect(coordinator.isActive(parent.taskId), isTrue);
      expect(statuses.last, TaskStatus.running);
      expect(statuses, isNot(contains(TaskStatus.waitingToRetry)));
      expect(statuses, isNot(contains(TaskStatus.paused)));

      // Recovery now re-enters the normal pump/governor instead of calling
      // startPart directly for every ghost worker. The scheduler may therefore
      // keep some ghosts queued until an already re-enqueued worker reports
      // running/completes. Reconcile only needs to prove that governed recovery
      // starts, never retries the durable complete range, and never parks the
      // logical episode while those workers are being recovered.
      await waitUntil(() => starts.length > 5);
      final recoverableIds = original
          .skip(1)
          .map((task) => task.taskId)
          .toSet();
      final retriedIds = starts.skip(5).map((task) => task.taskId).toSet();
      expect(retriedIds, isNotEmpty);
      expect(retriedIds.difference(recoverableIds), isEmpty);
      expect(retriedIds, isNot(contains(original.first.taskId)));
      expect(coordinator.isActive(parent.taskId), isTrue);
      expect(statuses, isNot(contains(TaskStatus.waitingToRetry)));
      expect(statuses, isNot(contains(TaskStatus.paused)));
    },
  );

  test(
    'complete temp part is recovered at canonical path without a request',
    () async {
      await coordinator.start(parent, 25);
      final first = starts.first;
      await coordinator.pause(parent);
      await File('${await first.filePath()}.download')
          .writeAsBytes([0, 1, 2, 3, 4]);
      starts.clear();
      expect(await coordinator.start(parent, 25), isTrue);
      await expandFreshTo(4);
      expect(starts.map((t) => t.taskId), isNot(contains(first.taskId)));
      expect(await File(await first.filePath()).readAsBytes(), [0, 1, 2, 3, 4]);
    },
  );

  test(
    'pause and process recreation retain a complete part and resume only four',
    () async {
      expect(await coordinator.start(parent, 25), isTrue);
      await expandFreshTo(5);
      final original = List<DownloadTask>.from(starts);
      await completePart(original.first, [0, 1, 2, 3, 4]);
      await coordinator.pause(parent);
      expect(pauses, isNot(contains(original.first.taskId)));
      starts.clear();
      await coordinator.dispose();
      coordinator = create();
      expect(await coordinator.start(parent, 25), isTrue);
      await expandFreshTo(4);
      expect(
        starts.map((task) => task.taskId),
        original.skip(1).map((task) => task.taskId),
      );
      expect(await File(await original.first.filePath()).readAsBytes(), [
        0,
        1,
        2,
        3,
        4,
      ]);
    },
  );

  test(
    'a permanent failed part pauses siblings without deleting completed bytes',
    () async {
      await coordinator.start(parent, 25);
      await expandFreshTo(5);
      final original = List<DownloadTask>.from(starts);
      await completePart(original.first, [0, 1, 2, 3, 4]);
      coordinator.handleUpdate(
        TaskStatusUpdate(
          original[1],
          TaskStatus.failed,
          TaskHttpException('forbidden', 403),
        ),
      );
      await waitUntil(
        () => records[parent.taskId]?.status == TaskStatus.paused,
      );
      expect(await File(await original.first.filePath()).exists(), isTrue);
      expect(records[parent.taskId]!.status, TaskStatus.paused);
      starts.clear();
      expect(await coordinator.start(parent, 25), isTrue);
      await expandFreshTo(4);
      expect(starts.length, 4);
    },
  );

  test(
    'merges out-of-order completions in byte order before marking complete',
    () async {
      await coordinator.start(parent, 25);
      await expandFreshTo(5);
      final original = List<DownloadTask>.from(starts);
      for (var i = 4; i >= 0; i--) {
        await completePart(original[i], List.generate(5, (j) => i * 5 + j));
      }
      await waitUntil(() => statuses.contains(TaskStatus.complete));
      await waitUntil(
        () =>
            !File('${directory.path}/video.mp4.parts/manifest.json')
                .existsSync(),
      );
      expect(
        await File(await parent.filePath()).readAsBytes(),
        List.generate(25, (i) => i),
      );
      expect(records[parent.taskId]!.status, TaskStatus.complete);
    },
  );

  test('a truncated completed part never marks the episode complete', () async {
    await coordinator.start(parent, 25);
    await completePart(starts.first, [0, 1]);
    await coordinator.pause(parent);
    expect(statuses, isNot(contains(TaskStatus.complete)));
    expect(await File(await parent.filePath()).exists(), isFalse);
  });

  test(
    'legacy checkpoint keeps complete children instead of resuming them',
    () async {
      final child = DownloadTask(
        taskId: 'legacy.0',
        url: parent.url,
        filename: 'legacy.part',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
      );
      await File(await child.filePath()).writeAsBytes([1, 2, 3]);
      await coordinator.importLegacy(
        parent,
        jsonEncode([
          {
            'task': child.toJson(),
            'fromByte': 0,
            'toByte': 2,
            'progress': 1,
            'status': TaskStatus.complete.index,
          },
        ]),
      );
      expect(await coordinator.start(parent, 3), isTrue);
      expect(starts, isEmpty);
      expect(await File(await parent.filePath()).readAsBytes(), [1, 2, 3]);
    },
  );

  test(
    'schema-v4 0.999 progress has zero durable authority after restore',
    () async {
      expect(await coordinator.start(parent, 25), isTrue);
      await coordinator.pause(parent);
      await coordinator.dispose();

      final manifest = File('${await parent.filePath()}.parts/manifest.json');
      final snapshot = Map<String, dynamic>.from(
        jsonDecode(await manifest.readAsString()) as Map,
      );
      snapshot['schemaVersion'] = 4;
      final parts = (snapshot['parts'] as List)
          .map((raw) => Map<String, dynamic>.from(raw as Map))
          .toList();
      parts.first['complete'] = false;
      parts.first['progress'] = 0.999;
      parts.first['credibleProgress'] = 0.999;
      for (final part in parts) {
        part.remove('durableBytes');
      }
      snapshot['parts'] = parts;
      await manifest.writeAsString(jsonEncode(snapshot), flush: true);

      starts.clear();
      coordinator = create();
      expect(await coordinator.start(parent, 25), isTrue);
      expect(coordinator.durableBytesFor(parent.taskId), 0);
      expect(starts, isNotEmpty);
    },
  );

  test(
    'recovers a durable temp manifest left by process termination',
    () async {
      expect(await coordinator.start(parent, 25), isTrue);
      await coordinator.pause(parent);
      await coordinator.dispose();

      final manifest = File('${await parent.filePath()}.parts/manifest.json');
      final temp = File('${manifest.path}.tmp');
      expect(await manifest.exists(), isTrue);
      await manifest.rename(temp.path);

      starts.clear();
      coordinator = create();
      expect(await coordinator.start(parent, 25), isTrue);
      expect(await manifest.exists(), isTrue);
      expect(await temp.exists(), isFalse);
      expect(starts.length, 1);
    },
  );

  test(
    'adopts an already assembled target after a crash without redownloading',
    () async {
      expect(await coordinator.start(parent, 25), isTrue);
      await coordinator.pause(parent);
      await coordinator.dispose();

      final target = File(await parent.filePath());
      await target.writeAsBytes(List<int>.generate(25, (i) => i), flush: true);

      starts.clear();
      statuses.clear();
      coordinator = create();
      expect(await coordinator.start(parent, 25), isTrue);
      expect(starts, isEmpty);
      expect(statuses, contains(TaskStatus.complete));
      expect(records[parent.taskId]!.status, TaskStatus.complete);
      expect(
        await File('${target.path}.parts/manifest.json').exists(),
        isFalse,
      );
    },
  );

  test('sixteen connections expand only after each batch is ready', () async {
    parent = ParallelDownloadTask(
      taskId: 'episode-16',
      url: 'https://example.com/video16',
      filename: 'video16.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 16,
      allowPause: true,
    );

    expect(await coordinator.start(parent, 160), isTrue);
    expect(starts.length, 1);

    await markRunning(starts.take(1));
    await waitUntil(() => starts.length == 3);
    await markRunning(starts.skip(1).take(2));
    await waitUntil(() => starts.length == 7);
    await markRunning(starts.skip(3).take(4));
    await waitUntil(() => starts.length == 15);
    await markRunning(starts.skip(7).take(8));
    await waitUntil(() => starts.length == 16);

    expect(coordinator.activeConnectionCount, 16);
    expect(starts.map((task) => task.headers['Range']).last, 'bytes=150-159');
  });

  test(
    'global budget never hands more than sixteen children to native IO',
    () async {
      final first = ParallelDownloadTask(
        taskId: 'first-16',
        url: 'https://example.com/first',
        filename: 'first.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 16,
        allowPause: true,
      );
      final second = ParallelDownloadTask(
        taskId: 'second-16',
        url: 'https://example.com/second',
        filename: 'second.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 16,
        allowPause: true,
      );

      expect(await coordinator.start(first, 160), isTrue);
      await expandFreshTo(16);
      expect(coordinator.activeConnectionCount, 16);

      final beforeSecond = starts.length;
      expect(await coordinator.start(second, 160), isTrue);
      expect(starts.length, beforeSecond);
      expect(coordinator.activeConnectionCount, 16);

      final firstPart = starts.firstWhere(
        (task) => task.taskId.startsWith('first-16.part.'),
      );
      await completePart(firstPart, List<int>.generate(10, (i) => i));
      await waitUntil(
        () => starts.any((task) => task.taskId.startsWith('second-16.part.')),
      );
      expect(coordinator.activeConnectionCount, 16);
      expect(
        starts
            .where((task) => task.taskId.startsWith('second-16.part.'))
            .length,
        1,
      );
    },
  );

  test(
    '429 during slow start falls back to last healthy level and teaches host',
    () async {
      final pressured = ParallelDownloadTask(
        taskId: 'pressured-16',
        url: 'https://cdn.example.com/episode-a',
        filename: 'pressured.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 16,
        allowPause: true,
      );

      expect(await coordinator.start(pressured, 160), isTrue);
      expect(starts.length, 1);
      await markRunning(starts.take(1));
      await waitUntil(() => starts.length == 3);
      await markRunning(starts.skip(1).take(2));
      await waitUntil(() => starts.length == 7);

      final fourthBatch = starts.skip(3).take(4).toList(growable: false);
      coordinator.handleUpdate(
        TaskStatusUpdate(
          fourthBatch.first,
          TaskStatus.waitingToRetry,
          TaskHttpException('rate limited', 429),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await markRunning(fourthBatch);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The 1 + 2 batch was healthy (3 total). The failing 4-connection batch
      // may keep retrying, but it must not unlock the 8-connection expansion.
      expect(starts.length, 7);

      // Drain below the learned cap. Only one replacement should start to keep
      // exactly three connections active for this host.
      for (var i = 0; i < 5; i++) {
        await completePart(starts[i], List<int>.filled(10, i));
      }
      await waitUntil(() => starts.length == 8);
      expect(coordinator.activeConnectionCount, 3);

      final sibling = ParallelDownloadTask(
        taskId: 'sibling-16',
        url: 'https://cdn.example.com/episode-b',
        filename: 'sibling.mp4',
        directory: directory.path,
        baseDirectory: BaseDirectory.root,
        chunks: 16,
        allowPause: true,
      );
      final beforeSibling = starts.length;
      expect(await coordinator.start(sibling, 160), isTrue);
      await waitUntil(() => starts.length == beforeSibling + 1);
      await markRunning(starts.skip(beforeSibling).take(1));
      await waitUntil(() => starts.length == beforeSibling + 3);
      await markRunning(starts.skip(beforeSibling + 1).take(2));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Host memory prevents the sibling from trying 7/15/16 again.
      expect(
        starts
            .where((task) => task.taskId.startsWith('sibling-16.part.'))
            .length,
        3,
      );
    },
  );
}
