import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/persistent_parallel_download.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

class _RangeHarness {
  _RangeHarness(this.directory, {this.hasLiveness = true, int maxConnections = 1}) {
    parent = ParallelDownloadTask(
      taskId: 'range-audit',
      url: 'https://example.com/video',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 4,
      allowPause: true,
    );
    coordinator = PersistentParallelDownload(
      startPart: (task, progress, size) async {
        starts.add(task);
        live.add(task.taskId);
        return true;
      },
      pausePart: (task) async {
        pauseCalls++;
        if (rejectPause) throw StateError('pause rejected');
        if (!keepPausedLive) live.remove(task.taskId);
      },
      cancelParts: (ids) async {
        cancelCalls++;
        await cancelGate?.future;
        if (rejectCancel) throw StateError('cancel rejected');
        live.removeAll(ids);
      },
      livePartIds: hasLiveness
          ? () async {
              lookupCalls++;
              if (failedLookups.contains(lookupCalls)) {
                throw StateError('liveness unavailable');
              }
              return Set<String>.from(live);
            }
          : null,
      saveRecord: (record) async {
        records[record.task.taskId] = record;
      },
      recordForId: (id) async => records[id],
      onUpdate: (update) {
        if (update is TaskStatusUpdate) statuses.add(update.status);
      },
      onPartProgress: (_, _, _) {},
      onSourceRefreshNeeded: (_) => refreshRequests++,
      recoveryDelay: const Duration(milliseconds: 10),
      tailStallDelay: const Duration(days: 1),
      pendingStartLeaseDelay: const Duration(days: 1),
      diskProgressPollInterval: const Duration(days: 1),
      maxActiveConnections: maxConnections,
    );
  }

  final Directory directory;
  final bool hasLiveness;
  late final ParallelDownloadTask parent;
  late final PersistentParallelDownload coordinator;
  final starts = <DownloadTask>[];
  final live = <String>{};
  final records = <String, TaskRecord>{};
  final statuses = <TaskStatus>[];
  final failedLookups = <int>{};
  var rejectCancel = false;
  var rejectPause = false;
  var keepPausedLive = false;
  var lookupCalls = 0;
  var pauseCalls = 0;
  var cancelCalls = 0;
  var refreshRequests = 0;
  Completer<void>? cancelGate;

  Future<File> writePart(DownloadTask child, List<int> bytes) async {
    final file = File(await child.filePath());
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<File> get manifest async =>
      File('${await parent.filePath()}.parts/manifest.json');

  Future<void> barrier() => coordinator.reconcile(() async => Set.from(live));

  Future<void> close() async {
    await coordinator.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _RangeHarness harness;

  setUp(() async {
    harness = _RangeHarness(
      await Directory.systemTemp.createTemp('range-audit-'),
    );
  });
  tearDown(() async => harness.close());

  test('failed_cancel_retains_session_ownership and accepts later callbacks', () async {
    expect(await harness.coordinator.start(harness.parent, 20), isTrue);
    final child = harness.starts.single;
    final bytes = await harness.writePart(child, <int>[1, 2]);
    harness.rejectCancel = true;

    await expectLater(harness.coordinator.cancel(harness.parent), throwsStateError);

    expect(harness.coordinator.isActive(harness.parent.taskId), isTrue);
    expect(harness.coordinator.activeConnectionCount, 1);
    expect(await bytes.readAsBytes(), <int>[1, 2]);
    expect(await (await harness.manifest).exists(), isTrue);
    harness.coordinator.handleUpdate(TaskProgressUpdate(child, 0.4, 5));
    await harness.barrier();
    expect(harness.coordinator.progressFor(harness.parent.taskId), greaterThan(0));
    expect(harness.starts, hasLength(1));

    harness.rejectCancel = false;
    await harness.coordinator.cancel(harness.parent);
    expect(harness.coordinator.activeConnectionCount, 0);
    expect(await bytes.exists(), isFalse);
    expect(await (await harness.manifest).exists(), isFalse);
  });

  test('pending_cancel_holds_live_reservation until settlement', () async {
    expect(await harness.coordinator.start(harness.parent, 20), isTrue);
    harness.cancelGate = Completer<void>();
    final pending = harness.coordinator.cancel(harness.parent);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    try {
      expect(harness.cancelCalls, 1);
      expect(harness.coordinator.activeConnectionCount, 1);
      expect(await (await harness.manifest).exists(), isTrue);
    } finally {
      harness.cancelGate!.complete();
      await pending;
    }
  });

  test('pause rejection with first liveness failure retains launched owner', () async {
    expect(await harness.coordinator.start(harness.parent, 20), isTrue);
    harness.rejectPause = true;
    harness.failedLookups.add(harness.lookupCalls + 1);

    expect(await harness.coordinator.pause(harness.parent), isFalse);
    expect(harness.coordinator.isActive(harness.parent.taskId), isTrue);
    expect(harness.coordinator.activeConnectionCount, 1);
    expect(harness.starts, hasLength(1));
    expect(harness.statuses.last, TaskStatus.running);
  });

  test('pause rejection with second liveness failure retains launched owner', () async {
    expect(await harness.coordinator.start(harness.parent, 20), isTrue);
    harness.rejectPause = true;
    harness.failedLookups.add(harness.lookupCalls + 2);

    expect(await harness.coordinator.pause(harness.parent), isFalse);
    expect(harness.coordinator.activeConnectionCount, 1);
    expect(harness.starts, hasLength(1));
    expect(harness.statuses.last, TaskStatus.running);
  });

  test('pause rejection without liveness callback retains launched owner', () async {
    await harness.close();
    harness = _RangeHarness(
      await Directory.systemTemp.createTemp('range-audit-no-lookup-'),
      hasLiveness: false,
    );
    expect(await harness.coordinator.start(harness.parent, 20), isTrue);
    harness.rejectPause = true;

    expect(await harness.coordinator.pause(harness.parent), isFalse);
    expect(harness.coordinator.activeConnectionCount, 1);
    expect(harness.starts, hasLength(1));
  });

  test('exact_size_requires_range_entity_evidence before sentinel adoption', () async {
    expect(await harness.coordinator.start(harness.parent, 20), isTrue);
    final child = harness.starts.single;
    final file = await harness.writePart(child, <int>[1, 2, 3, 4, 5]);

    harness.coordinator.handleUpdate(TaskProgressUpdate(child, 0.999, 5));
    await harness.barrier();

    expect(harness.records[child.taskId]?.status, isNot(TaskStatus.complete));
    expect(harness.coordinator.durableBytesFor(harness.parent.taskId), isNot(5));
    expect(await file.readAsBytes(), <int>[1, 2, 3, 4, 5]);
    harness.coordinator.handleUpdate(
      TaskStatusUpdate(child, TaskStatus.complete).copyWith(
        responseStatusCode: 206,
        responseHeaders: <String, String>{'content-range': 'bytes 5-9/20'},
      ),
    );
    await harness.barrier();
    expect(harness.records[child.taskId]?.status, isNot(TaskStatus.complete));
    expect(harness.statuses, isNot(contains(TaskStatus.complete)));
  });

  test('incomplete_exact_size_checkpoint_without_verifier_parks_saved_bytes', () async {
    expect(await harness.coordinator.start(harness.parent, 20), isTrue);
    final original = harness.starts.single;
    final file = await harness.writePart(original, <int>[1, 2, 3, 4, 5]);
    expect(await harness.coordinator.pause(harness.parent), isTrue);
    await harness.coordinator.dispose();
    final restarted = _RangeHarness(harness.directory);
    try {
      expect(await restarted.coordinator.start(restarted.parent, 20), isFalse);
      expect(restarted.starts, isEmpty);
      expect(restarted.records[original.taskId]?.status, isNot(TaskStatus.complete));
      expect(await file.readAsBytes(), <int>[1, 2, 3, 4, 5]);
      final checkpoint = jsonDecode(await (await restarted.manifest).readAsString()) as Map;
      expect((checkpoint['parts'] as List).first['complete'], isFalse);
    } finally {
      await restarted.coordinator.dispose();
    }
  });

  test('http404_uses_bounded_renewal instead of retrying unchanged range', () async {
    expect(await harness.coordinator.start(harness.parent, 20), isTrue);
    final child = harness.starts.single;
    harness.live.remove(child.taskId);
    harness.coordinator.handleUpdate(
      TaskStatusUpdate(child, TaskStatus.notFound).copyWith(responseStatusCode: 404),
    );
    await harness.barrier();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(harness.refreshRequests, 1);
    expect(harness.starts, hasLength(1));
    expect(harness.coordinator.activeConnectionCount, 0);
    expect(harness.coordinator.isActive(harness.parent.taskId), isFalse);
  });

  test('source_renewal_waits_for_unresolved_sibling_settlement', () async {
    await harness.close();
    harness = _RangeHarness(
      await Directory.systemTemp.createTemp('range-audit-renewal-settlement-'),
      maxConnections: 2,
    );
    expect(await harness.coordinator.start(harness.parent, 20), isTrue);
    final expired = harness.starts.single;
    harness.coordinator.handleUpdate(TaskStatusUpdate(expired, TaskStatus.running));
    for (var i = 0; i < 200 && harness.starts.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(harness.starts, hasLength(2));
    final sibling = harness.starts.last;
    harness.live.remove(expired.taskId);
    harness.rejectPause = true;
    harness.failedLookups.add(harness.lookupCalls + 1);
    harness.coordinator.handleUpdate(
      TaskStatusUpdate(expired, TaskStatus.notFound).copyWith(responseStatusCode: 404),
    );
    await harness.barrier();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(harness.refreshRequests, 0);
    expect(harness.coordinator.activeConnectionCount, 1);
    expect(harness.starts, hasLength(2));

    harness.rejectPause = false;
    harness.live.remove(sibling.taskId);
    harness.coordinator.handleUpdate(TaskStatusUpdate(sibling, TaskStatus.paused));
    await harness.barrier();
    for (var i = 0; i < 200 && harness.refreshRequests == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(harness.refreshRequests, 1);
    expect(harness.coordinator.activeConnectionCount, 0);
    expect(harness.coordinator.isActive(harness.parent.taskId), isFalse);
    expect(harness.starts, hasLength(2));
  });

  test('full_body_fallback_negative_cancel_preserves_source_and_sibling_ownership', () async {
    await harness.close();
    harness = _RangeHarness(
      await Directory.systemTemp.createTemp('range-audit-full-body-'),
      maxConnections: 2,
    );
    expect(await harness.coordinator.start(harness.parent, 20), isTrue);
    final source = harness.starts.single;
    harness.coordinator.handleUpdate(TaskStatusUpdate(source, TaskStatus.running));
    for (var i = 0; i < 200 && harness.starts.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(harness.starts, hasLength(2));
    final sibling = harness.starts.last;
    final siblingFile = await harness.writePart(sibling, <int>[99]);
    final payload = List<int>.generate(20, (i) => i);
    final file = await harness.writePart(source, payload);
    harness.live.remove(source.taskId);
    harness.rejectCancel = true;
    harness.coordinator.handleUpdate(
      TaskStatusUpdate(source, TaskStatus.complete).copyWith(responseStatusCode: 200),
    );
    await harness.barrier();

    expect(harness.cancelCalls, 1);
    expect(harness.coordinator.activeConnectionCount, 1);
    expect(await siblingFile.readAsBytes(), <int>[99]);
    expect(harness.statuses, isNot(contains(TaskStatus.complete)));
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), payload);
    expect(await (await harness.manifest).exists(), isTrue);
    expect(await File(await harness.parent.filePath()).exists(), isFalse);
  });
}
