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
    recordForId: (id) async => records[id],
    livePartIds: () async => <String>{},
    onUpdate: (_) {},
    onPartProgress: (_, _, _) {},
    recoveryDelay: const Duration(milliseconds: 10),
    diskProgressPollInterval: const Duration(seconds: 30),
  );

  File manifest() => File('${directory.path}/video.mp4.parts/manifest.json');
  Map<String, dynamic> snapshot() =>
      jsonDecode(manifest().readAsStringSync()) as Map<String, dynamic>;
  Map<String, dynamic> part() =>
      (snapshot()['parts'] as List).single as Map<String, dynamic>;
  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 400; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Timed out waiting for multipart retry checkpoint');
  }

  void failHttp(DownloadTask child, String retryAfter) {
    coordinator.handleUpdate(
      TaskStatusUpdate(
        child,
        TaskStatus.failed,
        TaskHttpException('busy', 429),
        null,
        {'Retry-After': retryAfter},
        429,
      ),
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('parallel-retry-policy-');
    parent = ParallelDownloadTask(
      taskId: 'retry-episode',
      url: 'https://example.test/video',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 1,
      allowPause: true,
    );
    starts = [];
    records = {};
    coordinator = create();
  });

  tearDown(() async {
    await coordinator.dispose();
    await directory.delete(recursive: true);
  });

  for (final useDate in [false, true]) {
    test(
      'HTTP ${useDate ? 'date' : 'seconds'} retry deadline survives pause and recreation',
      () async {
        expect(await coordinator.start(parent, 20), isTrue);
        final before = DateTime.now();
        final deadline = before.add(const Duration(seconds: 120));
        failHttp(starts.single, useDate ? HttpDate.format(deadline) : '120');
        await until(() => part()['retryNotBefore'] != null);
        final saved = part()['retryNotBefore'] as int;
        expect(
          saved,
          greaterThanOrEqualTo(deadline.millisecondsSinceEpoch - 1000),
        );
        expect(
          saved,
          lessThanOrEqualTo(deadline.millisecondsSinceEpoch + 1000),
        );
        expect(coordinator.activeConnectionCount, 0);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(starts, hasLength(1));

        expect(await coordinator.pause(parent), isTrue);
        await coordinator.dispose();
        starts.clear();
        coordinator = create();
        expect(await coordinator.start(parent, 20), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(starts, isEmpty);
        expect(part()['retryNotBefore'], saved);
        expect(coordinator.nativeBackgroundPlans(), isEmpty);
      },
    );
  }

  test('restored deadline releases exactly one replacement attempt', () async {
    expect(await coordinator.start(parent, 20), isTrue);
    expect(await coordinator.pause(parent), isTrue);
    await coordinator.dispose();
    final saved = snapshot();
    final child = (saved['parts'] as List).single as Map<String, dynamic>;
    child['retryNotBefore'] = DateTime.now()
        .add(const Duration(milliseconds: 350))
        .millisecondsSinceEpoch;
    child['recoveryAttempts'] = 2;
    await manifest().writeAsString(jsonEncode(saved), flush: true);
    starts.clear();
    coordinator = create();
    expect(await coordinator.start(parent, 20), isTrue);
    expect(starts, isEmpty);
    await until(() => starts.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(starts, hasLength(1));
    expect(await coordinator.pause(parent), isTrue);
    expect(part()['retryNotBefore'], isNull);
    expect(part()['recoveryAttempts'], 2);
  });

  test(
    'pause cancels a due retry and resume rearms its remaining deadline',
    () async {
      expect(await coordinator.start(parent, 20), isTrue);
      failHttp(starts.single, '1');
      await until(() => part()['retryNotBefore'] != null);
      expect(await coordinator.pause(parent), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(starts, hasLength(1));
      expect(await coordinator.start(parent, 20), isTrue);
      await until(() => starts.length == 2);
      expect(starts.last.taskId, starts.first.taskId);
      expect(starts.last.retries, 0);
    },
  );

  test(
    'real progress resets durable retry attempts, running alone does not',
    () async {
      expect(await coordinator.start(parent, 20), isTrue);
      failHttp(starts.single, '0');
      await until(() => starts.length == 2);
      coordinator.handleUpdate(
        TaskStatusUpdate(starts.last, TaskStatus.running),
      );
      expect(await coordinator.pause(parent), isTrue);
      expect(part()['recoveryAttempts'], 1);
      expect(await coordinator.start(parent, 20), isTrue);
      coordinator.handleUpdate(TaskProgressUpdate(starts.last, 0.25));
      expect(await coordinator.pause(parent), isTrue);
      expect(part()['recoveryAttempts'], 0);
    },
  );

  test(
    'simultaneous failed siblings keep independent durable deadlines',
    () async {
      parent = ParallelDownloadTask(
        taskId: parent.taskId,
        url: parent.url,
        filename: parent.filename,
        directory: parent.directory,
        baseDirectory: parent.baseDirectory,
        chunks: 2,
        allowPause: true,
      );
      expect(await coordinator.start(parent, 20), isTrue);
      coordinator.handleUpdate(
        TaskStatusUpdate(starts.single, TaskStatus.running),
      );
      await until(() => starts.length == 2);
      coordinator.handleUpdate(
        TaskStatusUpdate(starts.last, TaskStatus.running),
      );
      failHttp(starts.first, '120');
      failHttp(starts.last, '180');
      await until(
        () => (snapshot()['parts'] as List).every(
          (raw) => (raw as Map)['retryNotBefore'] != null,
        ),
      );
      final saved = (snapshot()['parts'] as List)
          .map((raw) => (raw as Map)['retryNotBefore'] as int)
          .toList();
      expect(saved[1] - saved[0], closeTo(60000, 1000));
      expect(coordinator.activeConnectionCount, 0);
      expect(await coordinator.pause(parent), isTrue);
      expect(await coordinator.start(parent, 20), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(starts, hasLength(2));
      expect(
        (snapshot()['parts'] as List).map(
          (raw) => (raw as Map)['retryNotBefore'],
        ),
        saved,
      );
    },
  );

  test(
    'library waitingToRetry never creates a competing coordinator retry',
    () async {
      expect(await coordinator.start(parent, 20), isTrue);
      coordinator.handleUpdate(
        TaskStatusUpdate(starts.single, TaskStatus.waitingToRetry),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(starts, hasLength(1));
      expect(part()['retryNotBefore'], isNull);
    },
  );
}
