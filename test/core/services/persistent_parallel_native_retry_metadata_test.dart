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
  late PersistentParallelDownload coordinator;
  late List<DownloadTask> starts;
  late Map<String, TaskRecord> records;
  Future<TaskStatusUpdate> Function(TaskStatusUpdate)? resolver;
  var inventoryAvailable = true;
  var recordReads = 0;
  var recoveryDelay = const Duration(milliseconds: 5);
  PersistentParallelDownload create() => PersistentParallelDownload(
    startPart: (task, _, _) async {
      starts.add(task);
      return true;
    },
    pausePart: (_) async {},
    cancelParts: (_) async {},
    saveRecord: (record) async {
      records[record.task.taskId] = record;
    },
    recordForId: (id) async {
      recordReads++;
      return records[id];
    },
    livePartIds: () async {
      if (!inventoryAvailable) throw StateError('inventory unavailable');
      return <String>{};
    },
    failureMetadataResolver: (update) async =>
        await resolver?.call(update) ?? update,
    onUpdate: (_) {},
    onPartProgress: (_, _, _) {},
    recoveryDelay: recoveryDelay,
    pendingStartLeaseDelay: const Duration(seconds: 30),
    diskProgressPollInterval: const Duration(seconds: 30),
  );
  File manifest() => File('${directory.path}/video.mp4.parts/manifest.json');
  Map<String, dynamic> part() => Map<String, dynamic>.from(
    ((jsonDecode(manifest().readAsStringSync()) as Map)['parts'] as List).single
        as Map,
  );
  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 400; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Timed out waiting for native retry metadata');
  }

  TaskStatusUpdate delayed(TaskStatusUpdate update) => update.copyWith(
    responseStatusCode: 429,
    responseHeaders: {'retry-after': '120'},
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('parallel-native-retry-');
    parent = ParallelDownloadTask(
      taskId: 'aw_v2_retry_g1',
      url: 'https://example.test/video',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 1,
      allowPause: true,
    );
    starts = [];
    records = {};
    resolver = null;
    inventoryAvailable = true;
    recordReads = 0;
    recoveryDelay = const Duration(milliseconds: 5);
    coordinator = create();
  });
  tearDown(() async {
    await coordinator.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'failed callback waits for native headers before choosing a retry',
    () async {
      expect(await coordinator.start(parent, 20), isTrue);
      final child = starts.single;
      final ack = Completer<TaskStatusUpdate>();
      var queried = false;
      resolver = (update) {
        queried = true;
        expect(update.task, child);
        return ack.future;
      };
      coordinator.handleUpdate(
        TaskStatusUpdate(
          child,
          TaskStatus.failed,
          TaskHttpException('busy', 429),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final queriedBeforeReply = queried;
      final startsBeforeReply = starts.length;
      ack.complete(delayed(TaskStatusUpdate(child, TaskStatus.failed)));
      expect(queriedBeforeReply, isTrue);
      expect(startsBeforeReply, 1);
      await until(() => part()['retryNotBefore'] != null);
      expect(
        part()['retryNotBefore'],
        greaterThan(
          DateTime.now()
              .add(const Duration(seconds: 119))
              .millisecondsSinceEpoch,
        ),
      );
      expect(coordinator.activeConnectionCount, 0);
    },
  );

  test(
    'reconciliation honors cached headers when the failure callback was lost',
    () async {
      expect(await coordinator.start(parent, 20), isTrue);
      resolver = (update) async => delayed(update);
      await coordinator.reconcile(() async => <String>{});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(starts, hasLength(1));
      expect(
        part()['retryNotBefore'],
        greaterThan(
          DateTime.now()
              .add(const Duration(seconds: 119))
              .millisecondsSinceEpoch,
        ),
      );
    },
  );

  test(
    'cold restart resolves the persisted attempt before a replacement launch',
    () async {
      expect(await coordinator.start(parent, 20), isTrue);
      final oldGeneration = jsonDecode(
        starts.single.metaData,
      )['attemptGeneration'];
      await coordinator.dispose();
      starts.clear();
      resolver = (update) async =>
          jsonDecode(update.task.metaData)['attemptGeneration'] == oldGeneration
          ? delayed(update)
          : update;
      coordinator = create();
      expect(await coordinator.start(parent, 20), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(starts, isEmpty);
      expect(
        part()['retryNotBefore'],
        greaterThan(
          DateTime.now()
              .add(const Duration(seconds: 119))
              .millisecondsSinceEpoch,
        ),
      );
    },
  );

  test(
    'unavailable native metadata parks without losing saved range bytes',
    () async {
      expect(await coordinator.start(parent, 20), isTrue);
      final child = starts.single;
      final file = File(await child.filePath());
      await file.writeAsBytes([1, 2, 3, 4, 5]);
      resolver = (_) async => throw TimeoutException('native lookup');
      coordinator.handleUpdate(
        TaskStatusUpdate(
          child,
          TaskStatus.failed,
          TaskHttpException('busy', 429),
        ),
      );
      await until(() => !coordinator.isActive(parent.taskId));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(starts, hasLength(1));
      expect(await file.readAsBytes(), [1, 2, 3, 4, 5]);
      expect(part()['retryNotBefore'], isNull);
    },
  );

  test(
    'disk-full child failure parks instead of retrying an unfixable write',
    () async {
      expect(await coordinator.start(parent, 20), isTrue);
      coordinator.handleUpdate(
        TaskStatusUpdate(
          starts.single,
          TaskStatus.failed,
          TaskFileSystemException(
            'Insufficient space to store the file to be downloaded for taskId ...',
          ),
        ),
      );
      await until(() => !coordinator.isActive(parent.taskId));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(starts, hasLength(1));
      expect(part()['retryNotBefore'], isNull);
    },
  );
  test(
    'lookup timeout keeps the failed generation across pause and recreation',
    () async {
      expect(await coordinator.start(parent, 20), isTrue);
      final child = starts.single;
      final oldGeneration = jsonDecode(child.metaData)['attemptGeneration'];
      resolver = (_) async => throw TimeoutException('native lookup');
      coordinator.handleUpdate(
        TaskStatusUpdate(
          child,
          TaskStatus.failed,
          TaskHttpException('busy', 429),
        ),
      );
      await until(() => !coordinator.isActive(parent.taskId));
      await coordinator.dispose();
      starts.clear();
      resolver = (update) async =>
          jsonDecode(update.task.metaData)['attemptGeneration'] == oldGeneration
          ? delayed(update)
          : update;
      coordinator = create();
      expect(await coordinator.start(parent, 20), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(starts, isEmpty);
      expect(
        part()['retryNotBefore'],
        greaterThan(
          DateTime.now()
              .add(const Duration(seconds: 119))
              .millisecondsSinceEpoch,
        ),
      );
    },
  );

  test('pause during native lookup saves the resolved deadline before invalidating', () async {
    expect(await coordinator.start(parent, 20), isTrue);
    final child = starts.single;
    final oldGeneration = jsonDecode(child.metaData)['attemptGeneration'];
    final ack = Completer<TaskStatusUpdate>();
    var queried = false;
    resolver = (update) {
      queried = true;
      return ack.future;
    };
    coordinator.handleUpdate(
      TaskStatusUpdate(
        child,
        TaskStatus.failed,
        TaskHttpException('busy', 429),
      ),
    );
    await until(() => queried);
    final paused = coordinator.pause(parent);
    ack.complete(delayed(TaskStatusUpdate(child, TaskStatus.failed)));
    expect(await paused, isTrue);
    await coordinator.dispose();
    starts.clear();
    resolver = (update) async =>
        jsonDecode(update.task.metaData)['attemptGeneration'] == oldGeneration
        ? delayed(update)
        : update;
    coordinator = create();
    expect(await coordinator.start(parent, 20), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(starts, isEmpty);
    expect(
      part()['retryNotBefore'],
      greaterThan(
        DateTime.now().add(const Duration(seconds: 119)).millisecondsSinceEpoch,
      ),
    );
  });

  test(
    'pause before a lost failure callback preserves its lookup identity',
    () async {
      expect(await coordinator.start(parent, 20), isTrue);
      final oldGeneration = jsonDecode(
        starts.single.metaData,
      )['attemptGeneration'];
      expect(await coordinator.pause(parent), isTrue);
      await coordinator.dispose();
      starts.clear();
      resolver = (update) async =>
          jsonDecode(update.task.metaData)['attemptGeneration'] == oldGeneration
          ? delayed(update)
          : update;
      coordinator = create();
      expect(await coordinator.start(parent, 20), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(starts, isEmpty);
      expect(part()['retryNotBefore'], isNotNull);
    },
  );

  test(
    'pause during a resumed old-token lookup still persists its server wait',
    () async {
      expect(await coordinator.start(parent, 20), isTrue);
      final child = starts.single;
      final oldGeneration = jsonDecode(child.metaData)['attemptGeneration'];
      expect(await coordinator.pause(parent), isTrue);
      starts.clear();
      final ack = Completer<TaskStatusUpdate>();
      var queried = false;
      resolver = (update) {
        queried = true;
        return ack.future;
      };
      final resumed = coordinator.start(parent, 20);
      await until(() => queried);
      final pausedAgain = coordinator.pause(parent);
      ack.complete(delayed(TaskStatusUpdate(child, TaskStatus.failed)));
      await resumed;
      expect(await pausedAgain, isTrue);
      await coordinator.dispose();
      resolver = (update) async =>
          jsonDecode(update.task.metaData)['attemptGeneration'] == oldGeneration
          ? delayed(update)
          : update;
      coordinator = create();
      expect(await coordinator.start(parent, 20), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(starts, isEmpty);
      expect(part()['retryNotBefore'], isNotNull);
    },
  );

  test(
    'resolved expired-source metadata cannot poison the refreshed URL attempt',
    () async {
      expect(await coordinator.start(parent, 20), isTrue);
      final child = starts.single;
      final oldGeneration = jsonDecode(child.metaData)['attemptGeneration'];
      resolver = (update) async =>
          jsonDecode(update.task.metaData)['attemptGeneration'] == oldGeneration
          ? update.copyWith(responseStatusCode: 403)
          : update;
      coordinator.handleUpdate(
        TaskStatusUpdate(
          child,
          TaskStatus.failed,
          TaskHttpException('expired', 403),
        ),
      );
      await until(() => !coordinator.isActive(parent.taskId));
      final fresh = await coordinator.replaceSource(
        parent,
        url: 'https://example.test/fresh',
        headers: {},
      );
      expect(fresh, isNotNull);
      expect(await coordinator.start(fresh!, 20), isTrue);
      await until(() => starts.length == 2);
      expect(starts.last.url, 'https://example.test/fresh');
    },
  );

  test('uncommitted retry checkpoints fence replacement writers until storage recovers', () async {
    await coordinator.dispose();
    recoveryDelay = const Duration(milliseconds: 40);
    coordinator = create();
    expect(await coordinator.start(parent, 20), isTrue);
    final readsBeforeFailure = recordReads;
    final obstruction = await Directory('${manifest().path}.tmp').create();
    coordinator.handleUpdate(
      TaskStatusUpdate(
        starts.single,
        TaskStatus.failed,
        TaskHttpException('busy', 429),
        null,
        {'Retry-After': '0'},
        429,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final startsWhileUnwritable = starts.length;
    final readsWhileUnwritable = recordReads - readsBeforeFailure;
    await obstruction.delete();
    expect(startsWhileUnwritable, 1);
    expect(
      readsWhileUnwritable,
      lessThanOrEqualTo(8),
      reason: 'failed checkpoint writes must use bounded coordinator recovery',
    );
    await until(() => starts.length == 2);
    expect(
      part()['attemptGeneration'],
      jsonDecode(starts.last.metaData)['attemptGeneration'],
    );
  });

  test('metadata and ownership outages hold admission without a microtask retry loop', () async {
    expect(await coordinator.start(parent, 20), isTrue);
    final child = starts.single;
    final oldGeneration = jsonDecode(child.metaData)['attemptGeneration'];
    var lookups = 0;
    resolver = (_) async {
      lookups++;
      throw TimeoutException('native lookup');
    };
    inventoryAvailable = false;
    coordinator.handleUpdate(
      TaskStatusUpdate(
        child,
        TaskStatus.failed,
        TaskHttpException('busy', 429),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final lookupCountWhileUnavailable = lookups;
    inventoryAvailable = true;
    resolver = (update) async =>
        jsonDecode(update.task.metaData)['attemptGeneration'] == oldGeneration
        ? delayed(update)
        : update;
    expect(lookupCountWhileUnavailable, lessThanOrEqualTo(2));
    expect(starts, hasLength(1));
    expect(await coordinator.pause(parent), isTrue);
    expect(await coordinator.start(parent, 20), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(starts, hasLength(1));
    expect(part()['retryNotBefore'], isNotNull);
  });
}
