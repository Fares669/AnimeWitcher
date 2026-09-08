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
  late List<String> pauses;
  late List<TaskStatus> parentStatuses;
  late Map<String, TaskRecord> records;

  Future<void> waitUntil(bool Function() predicate) async {
    for (var i = 0; i < 400; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Timed out waiting for automatic multipart recovery');
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('parallel-auto-recovery-');
    parent = ParallelDownloadTask(
      taskId: 'episode',
      url: 'https://cdn.example.test/video.mp4',
      filename: 'video.mp4',
      directory: directory.path,
      baseDirectory: BaseDirectory.root,
      chunks: 1,
      allowPause: true,
    );
    starts = <DownloadTask>[];
    pauses = <String>[];
    parentStatuses = <TaskStatus>[];
    records = <String, TaskRecord>{};

    coordinator = PersistentParallelDownload(
      startPart: (task, progress, size) async {
        starts.add(task);
        return true;
      },
      pausePart: (task) async {
        pauses.add(task.taskId);
      },
      cancelParts: (_) async {},
      saveRecord: (record) async {
        records[record.task.taskId] = record;
      },
      recordForId: (id) async => records[id],
      onUpdate: (update) {
        if (update is TaskStatusUpdate && update.task.taskId == parent.taskId) {
          parentStatuses.add(update.status);
        }
      },
      onPartProgress: (_, _, _) {},
      livePartIds: () async => <String>{},
      recoveryDelay: const Duration(milliseconds: 50),
    );
  });

  tearDown(() async {
    await coordinator.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('multipart child uses app-owned recovery instead of native retries', () async {
    expect(await coordinator.start(parent, 32), isTrue);
    expect(starts, hasLength(1));
    expect(starts.single.retries, 0);
  });

  test('repeated system pauses recover the child without pausing the episode', () async {
    expect(await coordinator.start(parent, 32), isTrue);
    expect(starts, hasLength(1));
    final child = starts.first;

    coordinator.handleUpdate(TaskStatusUpdate(child, TaskStatus.running));
    await Future<void>.delayed(Duration.zero);

    for (var interruption = 0; interruption < 6; interruption++) {
      final expectedStarts = starts.length + 1;
      coordinator.handleUpdate(TaskStatusUpdate(child, TaskStatus.paused));
      await waitUntil(() => starts.length >= expectedStarts);
      expect(starts.last.taskId, child.taskId);
      expect(coordinator.isActive(parent.taskId), isTrue);
      expect(parentStatuses.last, TaskStatus.running);
      expect(pauses, isEmpty);
    }

    expect(parentStatuses, isNot(contains(TaskStatus.paused)));
    expect(parentStatuses, isNot(contains(TaskStatus.waitingToRetry)));
  });

  test('transient failure releases its slot during backoff and retries only that child', () async {
    expect(await coordinator.start(parent, 32), isTrue);
    final child = starts.first;
    coordinator.handleUpdate(TaskStatusUpdate(child, TaskStatus.running));
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.activeConnectionCount, 1);

    coordinator.handleUpdate(
      TaskStatusUpdate(
        child,
        TaskStatus.failed,
        TaskConnectionException('socket reset'),
      ),
    );

    await waitUntil(() => coordinator.activeConnectionCount == 0);
    expect(starts, hasLength(1));
    expect(parentStatuses.last, TaskStatus.running);

    await waitUntil(() => starts.length >= 2);
    expect(starts.last.taskId, child.taskId);
    expect(coordinator.activeConnectionCount, 1);
    expect(coordinator.isActive(parent.taskId), isTrue);
    expect(parentStatuses.last, TaskStatus.running);
    expect(parentStatuses, isNot(contains(TaskStatus.waitingToRetry)));
    expect(parentStatuses, isNot(contains(TaskStatus.paused)));
    expect(pauses, isEmpty);
  });

  test('missing native worker during reconcile is recovered, not auto-paused', () async {
    expect(await coordinator.start(parent, 32), isTrue);
    final child = starts.first;
    coordinator.handleUpdate(TaskStatusUpdate(child, TaskStatus.running));
    await Future<void>.delayed(Duration.zero);

    await coordinator.reconcile(() async => <String>{});

    await waitUntil(() => starts.length >= 2);
    expect(starts.last.taskId, child.taskId);
    expect(coordinator.isActive(parent.taskId), isTrue);
    expect(parentStatuses.last, TaskStatus.running);
    expect(parentStatuses, isNot(contains(TaskStatus.waitingToRetry)));
    expect(parentStatuses, isNot(contains(TaskStatus.paused)));
  });

  test('legacy imported child disables native retries but keeps its identity', () async {
    final legacy = DownloadTask(
      taskId: 'episode.part.0',
      url: parent.url,
      filename: '0.part',
      directory: '${directory.path}/video.mp4.parts',
      baseDirectory: BaseDirectory.root,
      headers: const {'Range': 'bytes=0-31'},
      updates: Updates.statusAndProgress,
      retries: 2,
      allowPause: true,
    );
    final resumeData = jsonEncode([
      {
        'task': legacy.toJson(),
        'fromByte': 0,
        'toByte': 31,
        'progress': 0.0,
        'status': TaskStatus.paused.index,
      },
    ]);

    await coordinator.importLegacy(parent, resumeData);
    expect(await coordinator.start(parent, 32), isTrue);
    expect(starts, hasLength(1));
    expect(starts.single.taskId, legacy.taskId);
    expect(starts.single.retries, 0);
    expect(starts.single.headers['Range'], 'bytes=0-31');
  });

  test('permanent HTTP 403 still parks safely instead of retrying forever', () async {
    expect(await coordinator.start(parent, 32), isTrue);
    final child = starts.first;
    coordinator.handleUpdate(TaskStatusUpdate(child, TaskStatus.running));
    await Future<void>.delayed(Duration.zero);

    coordinator.handleUpdate(
      TaskStatusUpdate(
        child,
        TaskStatus.failed,
        TaskHttpException('forbidden', 403),
      ),
    );

    await waitUntil(() => parentStatuses.contains(TaskStatus.paused));
    expect(coordinator.isActive(parent.taskId), isFalse);
    expect(starts, hasLength(1));
    expect(pauses, contains(child.taskId));
  });
}
