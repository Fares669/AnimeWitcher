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
    void Function(String event, Map<String, Object?> fields)? diagnosticEvent,
    Future<int?> Function(String path)? availableStorageBytes,
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
    diagnosticEvent: diagnosticEvent,
    availableStorageBytes: availableStorageBytes,
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


  test('fresh multipart start cannot adopt an unrelated same-size final file', () async {
    final target = File(await parent.filePath());
    await target.writeAsBytes(List<int>.filled(25, 77), flush: true);

    expect(await coordinator.start(parent, 25), isTrue);
    expect(starts, isNotEmpty);
    expect(statuses, isNot(contains(TaskStatus.complete)));
    expect(await target.readAsBytes(), List<int>.filled(25, 77));
  });

  test('incomplete checkpoint never adopts an unrelated same-size target', () async {
    expect(await coordinator.start(parent, 25), isTrue);
    await coordinator.pause(parent);
    final target = File(await parent.filePath());
    await target.writeAsBytes(List<int>.filled(25, 77), flush: true);
    await coordinator.dispose();
    starts.clear();
    statuses.clear();
    coordinator = create();

    expect(await coordinator.start(parent, 25), isFalse);
    expect(starts, isEmpty);
    expect(statuses, isNot(contains(TaskStatus.complete)));
    expect(await target.readAsBytes(), List<int>.filled(25, 77));
  });

  test('complete checkpoint does not adopt foreign same-size bytes', () async {
    expect(await coordinator.start(parent, 25), isTrue);
    await expandFreshTo(5);
    await coordinator.pause(parent);
    final original = List<DownloadTask>.from(starts);
    await coordinator.dispose();

    for (var i = 0; i < original.length; i++) {
      await File(await original[i].filePath()).writeAsBytes(
        List<int>.generate(5, (j) => i * 5 + j),
        flush: true,
      );
    }
    final target = File(await parent.filePath());
    final manifest = File('${target.path}.parts/manifest.json');
    final checkpoint =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    for (final raw in checkpoint['parts'] as List) {
      final part = raw as Map<String, dynamic>;
      part['complete'] = true;
      part['progress'] = 1.0;
      part['credibleProgress'] = 1.0;
      part['durableBytes'] = (part['to'] as int) - (part['from'] as int) + 1;
    }
    await manifest.writeAsString(jsonEncode(checkpoint), flush: true);
    await target.writeAsBytes(List<int>.filled(25, 77), flush: true);
    starts.clear();
    statuses.clear();
    coordinator = create();

    expect(await coordinator.start(parent, 25), isFalse);
    expect(starts, isEmpty);
    expect(statuses, isNot(contains(TaskStatus.complete)));
    expect(await target.readAsBytes(), List<int>.filled(25, 77));
    for (final part in original) {
      expect(await File(await part.filePath()).length(), 5);
    }
  });

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
  test('one connection checkpoints a large file into bounded ranges', () async {
    const mib = 1024 * 1024;
    parent = ParallelDownloadTask(
      taskId: 'episode-single',
      url: 'https://example.com/video-single',
      filename: 'video-single.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 1,
      allowPause: true,
    );

    expect(await coordinator.start(parent, 64 * mib), isTrue);
    expect(starts, hasLength(1));
    expect(
      starts.single.headers['Range'],
      'bytes=0-4194303',
      reason:
          'a one-connection iOS download still uses bounded immutable '
          'checkpoints so Pause and process recreation never depend on '
          'URLSession resumeData for one giant file',
    );
  });

  test('fresh child launches do not rewrite an unchanged manifest', () async {
    expect(await coordinator.start(parent, 100), isTrue);
    await waitUntil(() => starts.isNotEmpty);

    final manifest = File('${await parent.filePath()}.parts/manifest.json');
    Map<String, dynamic> snapshot() =>
        jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;

    final sequenceBeforeExpansion = (snapshot()['checkpointSequence'] as num)
        .toInt();
    expect(sequenceBeforeExpansion, greaterThan(0));

    await markRunning(<DownloadTask>[starts.first]);
    await waitUntil(() => starts.length >= 3);
    expect(
      snapshot()['checkpointSequence'],
      sequenceBeforeExpansion,
      reason:
          'slow-start expansion must reuse the attempt metadata persisted '
          'before native IO instead of rewriting the whole manifest per child',
    );
  });

  test('intermediate child completion does not fsync the full manifest', () async {
    expect(await coordinator.start(parent, 100), isTrue);
    await expandFreshTo(5);

    final manifest = File('${await parent.filePath()}.parts/manifest.json');
    Map<String, dynamic> snapshot() =>
        jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
    final sequenceBeforeCompletion = (snapshot()['checkpointSequence'] as num)
        .toInt();

    final first = starts.first;
    await completePart(first, List<int>.filled(20, 7));
    await waitUntil(() => records[first.taskId]?.status == TaskStatus.complete);

    expect(
      snapshot()['checkpointSequence'],
      sequenceBeforeCompletion,
      reason:
          'the complete part file and TaskRecord are already durable; '
          'intermediate children should join the coalesced manifest checkpoint',
    );
  });

  test(
    'slow-start child running callbacks publish parent running once',
    () async {
      expect(await coordinator.start(parent, 23), isTrue);
      await expandFreshTo(5);

      expect(
        statuses.where((status) => status == TaskStatus.running),
        hasLength(1),
        reason:
            'child readiness must not fan out duplicate parent status writes '
            'or UI notifications',
      );
    },
  );

  test('tiny file emits one valid Range for each byte', () async {
    parent = ParallelDownloadTask(
      taskId: 'tiny',
      url: parent.url,
      filename: 'tiny.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 16,
      allowPause: true,
    );
    expect(await coordinator.start(parent, 3), isTrue);
    await expandFreshTo(3);
    expect(starts.map((task) => task.headers['Range']), [
      'bytes=0-0',
      'bytes=1-1',
      'bytes=2-2',
    ]);
    final original = List<DownloadTask>.from(starts);
    for (var i = 0; i < original.length; i++) {
      await completePart(original[i], [i]);
    }
    await waitUntil(() => statuses.contains(TaskStatus.complete));
    expect(await File(await parent.filePath()).readAsBytes(), [0, 1, 2]);
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

  test('disk fallback probes only native-owned ranges', () async {
    await coordinator.dispose();
    coordinator = create(
      diskProgressPollInterval: const Duration(milliseconds: 10),
    );

    expect(await coordinator.start(parent, 100), isTrue);
    expect(starts.length, 1);

    final queuedFile = File(
      '${directory.path}${Platform.pathSeparator}video.mp4.parts'
      '${Platform.pathSeparator}1.part',
    );
    await queuedFile.parent.create(recursive: true);
    await queuedFile.writeAsBytes(List<int>.filled(10, 3), flush: true);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
      coordinator.progressFor(parent.taskId),
      0,
      reason:
          'an unlaunched range has no writer and cannot change during an '
          'active session, so polling it only adds filesystem work',
    );
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
    'native iOS temp bytes never advance durable recovery progress',
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
      expect(
        parentRecord.progress,
        closeTo(.1, .001),
        reason: 'live telemetry may still show URLSession temp bytes',
      );
      expect(
        coordinator.durableProgressFor(parent.taskId),
        0,
        reason:
            'V2 recovery must ignore bytes that exist only in URLSession temp '
            'storage because iOS may discard them on process termination',
      );
      expect(coordinator.durableBytesFor(parent.taskId), 0);
      expect(statuses, contains(TaskStatus.running));
      await waitUntil(() => starts.length >= 3);
    },
  );

  test(
    'aggregate diagnostic heartbeat separates live and durable bytes',
    () async {
      final diagnosticEvents =
          <({String event, Map<String, Object?> fields})>[];
      await coordinator.dispose();
      coordinator = create(
        diagnosticEvent: (event, fields) {
          diagnosticEvents.add((
            event: event,
            fields: Map<String, Object?>.from(fields),
          ));
        },
      );

      expect(await coordinator.start(parent, 100), isTrue);
      final first = starts.single;
      await coordinator.handleNativeChunkUpdate(
        parentTaskId: parent.taskId,
        chunkTaskId: first.taskId,
        writtenBytes: 10,
        expectedBytes: 20,
        speedBytesPerSecond: 500000,
      );

      await waitUntil(
        () => diagnosticEvents.any(
          (entry) => entry.event == 'parallel.heartbeat',
        ),
      );
      final heartbeat = diagnosticEvents
          .lastWhere((entry) => entry.event == 'parallel.heartbeat')
          .fields;
      expect(heartbeat['taskId'], parent.taskId);
      expect(heartbeat['liveBytes'], 10);
      expect(heartbeat['durableBytes'], 0);
      expect(heartbeat['nativeWrittenBytes'], 10);
      expect(heartbeat['configuredConnections'], parent.chunks);
      expect(heartbeat['activeConnections'], greaterThanOrEqualTo(1));
      expect(heartbeat['checkpointSequence'], greaterThanOrEqualTo(1));
    },
  );

  test(
    'package progress heartbeat does not invent native byte evidence',
    () async {
      final diagnosticEvents =
          <({String event, Map<String, Object?> fields})>[];
      await coordinator.dispose();
      coordinator = create(
        diagnosticEvent: (event, fields) {
          diagnosticEvents.add((
            event: event,
            fields: Map<String, Object?>.from(fields),
          ));
        },
      );

      expect(await coordinator.start(parent, 100), isTrue);
      final first = starts.single;
      coordinator.handleUpdate(
        TaskProgressUpdate(first, .5, 20, 0.5, const Duration(seconds: 1)),
      );

      await waitUntil(
        () => diagnosticEvents.any(
          (entry) => entry.event == 'parallel.heartbeat',
        ),
      );
      final heartbeat = diagnosticEvents
          .lastWhere((entry) => entry.event == 'parallel.heartbeat')
          .fields;

      expect(heartbeat['liveBytes'], 10);
      expect(
        heartbeat.containsKey('nativeWrittenBytes'),
        isFalse,
        reason:
            'package/Dart progress is live byte evidence but must not be mislabeled '
            'as native URLSession bridge bytes',
      );
      expect(heartbeat['lastByteAgeMs'], isNotNull);
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
      await waitUntil(() => settled.contains(parent.taskId));
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
      await waitUntil(() => settled.contains(parent.taskId));
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

  test('legacy import rejects a zero-byte range without saving it', () async {
    final child = DownloadTask(
      taskId: 'legacy.empty',
      url: parent.url,
      filename: 'empty.part',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
    );
    await expectLater(
      coordinator.importLegacy(
        parent,
        jsonEncode([
          {
            'task': child.toJson(),
            'fromByte': 0,
            'toByte': -1,
            'progress': 0,
            'status': TaskStatus.paused.index,
          },
        ]),
      ),
      throwsFormatException,
    );
    expect(coordinator.progressFor(parent.taskId), isNull);
    expect(
      await File('${await parent.filePath()}.parts/manifest.json').exists(),
      isFalse,
    );
  });

  for (final blockStaging in [false, true]) {
    test('${blockStaging ? 'blocked staging write' : 'blocked final rename'} '
        'parks and preserves parts for retry', () async {
      await coordinator.dispose();
      final target = File(await parent.filePath());
      final staging = File('${target.path}.assembling');
      final obstruction = Directory(blockStaging ? staging.path : target.path);
      var blocked = false;
      coordinator = create(
        availableStorageBytes: (_) async {
          if (!blocked) {
            blocked = true;
            await obstruction.create();
          }
          return 100 * 1024 * 1024;
        },
      );
      expect(await coordinator.start(parent, 25), isTrue);
      await expandFreshTo(5);
      final original = List<DownloadTask>.from(starts);
      for (var i = 0; i < original.length; i++) {
        await completePart(
          original[i],
          List<int>.generate(5, (j) => i * 5 + j),
        );
      }
      await waitUntil(
        () => records[parent.taskId]?.status == TaskStatus.paused,
      );
      expect(statuses, isNot(contains(TaskStatus.complete)));
      expect(await obstruction.exists(), isTrue);
      if (!blockStaging) {
        expect(await staging.readAsBytes(), List<int>.generate(25, (i) => i));
      }
      for (final part in original) {
        expect(await File(await part.filePath()).length(), 5);
      }
      await obstruction.delete();
      starts.clear();
      expect(await coordinator.start(parent, 25), isTrue);
      expect(starts, isEmpty);
      expect(await target.readAsBytes(), List<int>.generate(25, (i) => i));
    });
  }

  test(
    'restart rebuilds a preallocated staging file from verified parts',
    () async {
      expect(await coordinator.start(parent, 25), isTrue);
      await expandFreshTo(5);
      await coordinator.pause(parent);
      final original = List<DownloadTask>.from(starts);
      for (var i = 0; i < original.length; i++) {
        final file = File(await original[i].filePath());
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          List<int>.generate(5, (j) => i * 5 + j),
          flush: true,
        );
      }
      final target = File(await parent.filePath());
      final staging = File('${target.path}.assembling');
      await staging.writeAsBytes(List<int>.filled(25, 0), flush: true);
      await coordinator.dispose();
      starts.clear();
      var checkedHeadroom = false;
      coordinator = create(
        availableStorageBytes: (_) async {
          if (!checkedHeadroom) {
            checkedHeadroom = true;
            // The old staging allocation must be released before measuring room
            // for a replacement; retaining it would require a third full copy.
            if (await staging.exists()) return 0;
          }
          return 100 * 1024 * 1024;
        },
      );
      expect(await coordinator.start(parent, 25), isTrue);
      expect(checkedHeadroom, isTrue);
      expect(starts, isEmpty);
      expect(await target.readAsBytes(), List<int>.generate(25, (i) => i));
    },
  );

  test(
    'restart recovers an interrupted exclusive final-file reservation',
    () async {
      expect(await coordinator.start(parent, 25), isTrue);
      await expandFreshTo(5);
      await coordinator.pause(parent);
      final original = List<DownloadTask>.from(starts);
      for (var i = 0; i < original.length; i++) {
        final file = File(await original[i].filePath());
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          List<int>.generate(5, (j) => i * 5 + j),
          flush: true,
        );
      }
      await coordinator.dispose();

      final target = File(await parent.filePath());
      final staging = File('${target.path}.assembling');
      final marker = File('${target.path}.promoting');
      await staging.writeAsBytes(List<int>.generate(25, (i) => i), flush: true);
      await target.create(exclusive: true);
      await marker.writeAsString(
        jsonEncode({
          'parentTaskId': parent.taskId,
          'expectedBytes': 25,
          'sourcePath': staging.path,
        }),
        flush: true,
      );

      starts.clear();
      coordinator = create();
      expect(await coordinator.start(parent, 25), isTrue);
      await waitUntil(() => target.existsSync() && target.lengthSync() == 25);

      expect(starts, isEmpty);
      expect(await target.readAsBytes(), List<int>.generate(25, (i) => i));
      expect(await marker.exists(), isFalse);
    },
  );

  test('exclusive destination is reserved before the promotion marker is published', () {
    final source = File('lib/core/services/persistent_parallel_download.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<bool> _promoteCompletedFile(');
    final end = source.indexOf('Future<void> _assemble(', start);
    expect(start, greaterThanOrEqualTo(0));
    final promotion = source.substring(start, end);
    expect(
      promotion.indexOf('await target.create(exclusive: true)'),
      lessThan(promotion.indexOf('await pending.rename(marker.path)')),
      reason: 'a marker alone must not authorize overwriting a foreign empty target',
    );
  });

  test(
    'a marker that cannot be written leaves no reservation behind',
    () async {
      expect(await coordinator.start(parent, 25), isTrue);
      await expandFreshTo(5);
      await coordinator.pause(parent);
      final original = List<DownloadTask>.from(starts);
      for (var i = 0; i < original.length; i++) {
        final file = File(await original[i].filePath());
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          List<int>.generate(5, (j) => i * 5 + j),
          flush: true,
        );
      }
      await coordinator.dispose();

      // The marker's write fails, as on a full disk.
      final target = File(await parent.filePath());
      final blocker = Directory('${target.path}.promoting.tmp');
      await blocker.create(recursive: true);
      starts.clear();
      coordinator = create();
      await coordinator.start(parent, 25);
      await waitUntil(
        () => records[parent.taskId]?.status == TaskStatus.paused,
      );
      expect(await target.exists(), isFalse);
      expect(await File('${target.path}.promoting').exists(), isFalse);

      // With room again, the next start finishes the file.
      await coordinator.dispose();
      await blocker.delete();
      starts.clear();
      coordinator = create();
      expect(await coordinator.start(parent, 25), isTrue);
      await waitUntil(() => target.existsSync() && target.lengthSync() == 25);
      expect(starts, isEmpty);
      expect(await target.readAsBytes(), List<int>.generate(25, (i) => i));
      expect(await File('${target.path}.promoting').exists(), isFalse);
    },
  );

  test(
    'foreign replacement of a reserved destination preserves parts',
    () async {
      await coordinator.dispose();
      final target = File(await parent.filePath());
      var replaced = false;
      coordinator = create(
        diagnosticEvent: (event, fields) {
          if (event == 'assembly.destinationReserved') {
            replaced = true;
            target.writeAsBytesSync(List<int>.filled(25, 77), flush: true);
          }
        },
      );
      expect(await coordinator.start(parent, 25), isTrue);
      await expandFreshTo(5);
      final original = List<DownloadTask>.from(starts);
      for (var i = 0; i < original.length; i++) {
        await completePart(
          original[i],
          List<int>.generate(5, (j) => i * 5 + j),
        );
      }
      await waitUntil(
        () => records[parent.taskId]?.status == TaskStatus.paused,
      );
      expect(replaced, isTrue);
      expect(statuses, isNot(contains(TaskStatus.complete)));
      expect(await target.readAsBytes(), List<int>.filled(25, 77));
      expect(
        await File('${target.path}.assembling').readAsBytes(),
        List<int>.generate(25, (i) => i),
      );
      for (final part in original) {
        expect(await File(await part.filePath()).length(), 5);
      }
      await coordinator.dispose();
      starts.clear();
      statuses.clear();
      coordinator = create();
      expect(await coordinator.start(parent, 25), isFalse);
      expect(starts, isEmpty);
      expect(statuses, isNot(contains(TaskStatus.complete)));
      expect(await target.readAsBytes(), List<int>.filled(25, 77));
      expect(
        await File('${target.path}.assembling').readAsBytes(),
        List<int>.generate(25, (i) => i),
      );
      for (final part in original) {
        expect(await File(await part.filePath()).length(), 5);
      }
    },
  );

  test(
    'exclusive reservation rejects a competing final-file creator',
    () async {
      await coordinator.dispose();
      final target = File(await parent.filePath());
      var competingCreatorRejected = false;
      coordinator = create(
        diagnosticEvent: (event, fields) {
          if (event == 'assembly.destinationReserved') {
            try {
              target.createSync(exclusive: true);
            } on FileSystemException {
              competingCreatorRejected = true;
            }
          }
        },
      );
      expect(await coordinator.start(parent, 25), isTrue);
      await expandFreshTo(5);
      final original = List<DownloadTask>.from(starts);
      for (var i = 0; i < original.length; i++) {
        await completePart(
          original[i],
          List<int>.generate(5, (j) => i * 5 + j),
        );
      }
      await waitUntil(() => statuses.contains(TaskStatus.complete));
      expect(competingCreatorRejected, isTrue);
      expect(await target.readAsBytes(), List<int>.generate(25, (i) => i));
      expect(await File('${target.path}.promoting').exists(), isFalse);
    },
  );

  for (final markerKind in ['owned', 'foreign', 'torn']) {
    test(
      'cancel clears only an owned interrupted promotion ($markerKind)',
      () async {
        final ownedMarker = markerKind == 'owned';
        expect(await coordinator.start(parent, 25), isTrue);
        await coordinator.pause(parent);
        final target = File(await parent.filePath());
        final marker = File('${target.path}.promoting');
        await target.create(exclusive: true);
        await marker.writeAsString(
          markerKind == 'torn'
              ? '{'
              : jsonEncode({
                  'parentTaskId': ownedMarker
                      ? parent.taskId
                      : 'foreign-parent',
                  'expectedBytes': 25,
                  'sourcePath': '${target.path}.assembling',
                }),
          flush: true,
        );
        await coordinator.cancel(parent);
        expect(await target.exists(), !ownedMarker);
        expect(await marker.exists(), !ownedMarker);
      },
    );
  }

  test('unmarked empty final target remains untouched on restart', () async {
    expect(await coordinator.start(parent, 25), isTrue);
    await expandFreshTo(5);
    await coordinator.pause(parent);
    final original = List<DownloadTask>.from(starts);
    for (var i = 0; i < original.length; i++) {
      final file = File(await original[i].filePath());
      await file.writeAsBytes(
        List<int>.generate(5, (j) => i * 5 + j),
        flush: true,
      );
    }
    await coordinator.dispose();
    final target = File(await parent.filePath());
    await target.create(exclusive: true);
    starts.clear();
    coordinator = create();
    expect(await coordinator.start(parent, 25), isTrue);
    expect(starts, isEmpty);
    expect(records[parent.taskId]?.status, TaskStatus.paused);
    expect(await target.length(), 0);
    for (final part in original) {
      expect(await File(await part.filePath()).length(), 5);
    }
  });

  for (final markerPayload in ['{', '{"parentTaskId":"foreign-parent"}']) {
    test(
      'unknown marker prevents adopting a same-size foreign target ($markerPayload)',
      () async {
        expect(await coordinator.start(parent, 25), isTrue);
        await expandFreshTo(5);
        await coordinator.pause(parent);
        final original = List<DownloadTask>.from(starts);
        for (var i = 0; i < original.length; i++) {
          await File(
            await original[i].filePath(),
          ).writeAsBytes(List<int>.generate(5, (j) => i * 5 + j), flush: true);
        }
        final target = File(await parent.filePath());
        final marker = File('${target.path}.promoting');
        await target.writeAsBytes(List<int>.filled(25, 77), flush: true);
        await marker.writeAsString(markerPayload, flush: true);
        await coordinator.dispose();
        starts.clear();
        statuses.clear();
        coordinator = create();
        expect(await coordinator.start(parent, 25), isFalse);
        expect(starts, isEmpty);
        expect(statuses, isNot(contains(TaskStatus.complete)));
        expect(await target.readAsBytes(), List<int>.filled(25, 77));
        expect(await marker.readAsString(), markerPayload);
        for (final part in original) {
          expect(await File(await part.filePath()).length(), 5);
        }
      },
    );
  }

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

  for (final committedMarker in [false, true]) {
    test(
      'adopts an already assembled target after a crash without redownloading '
      '(committed marker: $committedMarker)',
      () async {
        expect(await coordinator.start(parent, 25), isTrue);
        await expandFreshTo(5);
        await coordinator.pause(parent);
        final parts = List<DownloadTask>.from(starts);
        await coordinator.dispose();

        // Emulate an interrupted *completed* assembly: all verified Range
        // files and their durable manifest existed before the final rename.
        for (var i = 0; i < parts.length; i++) {
          await File(await parts[i].filePath()).writeAsBytes(
            List<int>.generate(5, (j) => i * 5 + j),
            flush: true,
          );
        }
        final target = File(await parent.filePath());
        final manifest = File('${target.path}.parts/manifest.json');
        final checkpoint = jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
        for (final raw in checkpoint['parts'] as List) {
          final part = raw as Map<String, dynamic>;
          part['complete'] = true;
          part['progress'] = 1.0;
          part['credibleProgress'] = 1.0;
          part['durableBytes'] = (part['to'] as int) - (part['from'] as int) + 1;
        }
        await manifest.writeAsString(jsonEncode(checkpoint), flush: true);
        await target.writeAsBytes(List<int>.generate(25, (i) => i), flush: true);
        final marker = File('${target.path}.promoting');
        if (committedMarker) {
          await marker.writeAsString(
            jsonEncode({
              'parentTaskId': parent.taskId,
              'expectedBytes': 25,
              'sourcePath': '${target.path}.assembling',
            }),
            flush: true,
          );
        }

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
        expect(await marker.exists(), isFalse);
      },
    );
  }

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
