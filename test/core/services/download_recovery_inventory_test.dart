import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_parallel.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadTask _task(
  String id, {
  String group = kLogicalDownloadGroup,
  String metadata = '',
}) => DownloadTask(
  taskId: id,
  url: 'https://cdn.example/$id.mp4',
  filename: '$id.mp4',
  group: group,
  metaData: metadata,
);

void main() {
  group('buildDownloadRecoveryInventory', () {
    test('adds a native-only logical task when the plugin DB row is missing', () {
      final live = _task('native-only');

      final inventory = buildDownloadRecoveryInventory(
        persistedRecords: const <TaskRecord>[],
        runtimeTasks: <Task>[live],
      );

      expect(inventory.records, hasLength(1));
      expect(inventory.records.single.task.taskId, 'native-only');
      expect(inventory.records.single.status, TaskStatus.running);
      expect(inventory.nativeOnlyTaskIds, {'native-only'});
      expect(inventory.durableOnlyTaskIds, isEmpty);
    });

    test('keeps the persisted projection when runtime reports the same task', () {
      final task = _task('same');
      final persisted = TaskRecord(task, TaskStatus.waitingToRetry, 0.42, 1000);

      final inventory = buildDownloadRecoveryInventory(
        persistedRecords: <TaskRecord>[persisted],
        runtimeTasks: <Task>[task],
      );

      expect(inventory.records, hasLength(1));
      expect(inventory.records.single.status, TaskStatus.waitingToRetry);
      expect(inventory.records.single.progress, 0.42);
      expect(inventory.records.single.expectedFileSize, 1000);
      expect(inventory.nativeOnlyTaskIds, isEmpty);
      expect(inventory.durableOnlyTaskIds, isEmpty);
    });

    test('recovers a durable logical task when both DB and runtime are missing', () {
      final durable = _task('job-only');
      final durableRecord = TaskRecord(durable, TaskStatus.paused, 0.4, 1000);

      final inventory = buildDownloadRecoveryInventory(
        persistedRecords: const <TaskRecord>[],
        runtimeTasks: const <Task>[],
        durableRecords: <TaskRecord>[durableRecord],
      );

      expect(inventory.records, hasLength(1));
      expect(inventory.records.single.task.taskId, 'job-only');
      expect(inventory.records.single.status, TaskStatus.paused);
      expect(inventory.nativeOnlyTaskIds, isEmpty);
      expect(inventory.durableOnlyTaskIds, {'job-only'});
    });

    test('persisted/native evidence wins over duplicate durable snapshot', () {
      final task = _task('same');
      final persisted = TaskRecord(task, TaskStatus.waitingToRetry, 0.5, 1000);
      final durable = TaskRecord(task, TaskStatus.paused, 0.4, 1000);

      final inventory = buildDownloadRecoveryInventory(
        persistedRecords: <TaskRecord>[persisted],
        runtimeTasks: <Task>[task],
        durableRecords: <TaskRecord>[durable],
      );

      expect(inventory.records, hasLength(1));
      expect(inventory.records.single.status, TaskStatus.waitingToRetry);
      expect(inventory.durableOnlyTaskIds, isEmpty);
    });

    test('never promotes multipart children to logical episode rows', () {
      final child = _task(
        'child',
        group: kPersistentDownloadChunkGroup,
        metadata: '{"parentTaskId":"parent"}',
      );

      final inventory = buildDownloadRecoveryInventory(
        persistedRecords: <TaskRecord>[
          TaskRecord(child, TaskStatus.running, 0.2, 500),
        ],
        runtimeTasks: <Task>[child],
        durableRecords: <TaskRecord>[
          TaskRecord(child, TaskStatus.paused, 0.2, 500),
        ],
      );

      expect(inventory.records, isEmpty);
      expect(inventory.nativeOnlyTaskIds, isEmpty);
      expect(inventory.durableOnlyTaskIds, isEmpty);
    });

    test('orders union evidence by durable FIFO timestamp then task id', () {
      final inventory = buildDownloadRecoveryInventory(
        persistedRecords: <TaskRecord>[
          TaskRecord(_task('late-db'), TaskStatus.paused, 0, 100),
        ],
        runtimeTasks: <Task>[_task('native')],
        durableRecords: <TaskRecord>[
          TaskRecord(_task('middle-job'), TaskStatus.paused, 0, 100),
          TaskRecord(_task('early-job'), TaskStatus.paused, 0, 100),
        ],
        orderByTaskId: const <String, int>{
          'early-job': 10,
          'middle-job': 20,
          'late-db': 30,
          'native': 40,
        },
      );

      expect(
        inventory.records.map((record) => record.task.taskId),
        <String>['early-job', 'middle-job', 'late-db', 'native'],
      );
    });

    test('sorts native-only discoveries by task id without FIFO evidence', () {
      final inventory = buildDownloadRecoveryInventory(
        persistedRecords: const <TaskRecord>[],
        runtimeTasks: <Task>[_task('zeta'), _task('alpha'), _task('mid')],
      );

      expect(
        inventory.records.map((record) => record.task.taskId),
        <String>['alpha', 'mid', 'zeta'],
      );
      expect(inventory.nativeOnlyTaskIds, {'alpha', 'mid', 'zeta'});
      expect(inventory.durableOnlyTaskIds, isEmpty);
    });
  });
}
