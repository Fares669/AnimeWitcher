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
      );

      expect(inventory.records, isEmpty);
      expect(inventory.nativeOnlyTaskIds, isEmpty);
    });

    test('sorts native-only discoveries by task id for deterministic recovery', () {
      final inventory = buildDownloadRecoveryInventory(
        persistedRecords: const <TaskRecord>[],
        runtimeTasks: <Task>[_task('zeta'), _task('alpha'), _task('mid')],
      );

      expect(
        inventory.records.map((record) => record.task.taskId),
        <String>['alpha', 'mid', 'zeta'],
      );
      expect(inventory.nativeOnlyTaskIds, {'alpha', 'mid', 'zeta'});
    });
  });
}
