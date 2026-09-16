import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'critical lifecycle boundaries persist before ownership side effects',
    () {
      final source = File('lib/core/services/download_service.dart')
          .readAsStringSync();

      expect(source, contains('Future<bool> _checkpointLogicalJob('));
      expect(
        source,
        contains('final commit = await commitAuthoritativeDownloadCheckpoint('),
      );
      expect(
        source,
        contains('if (commit != DownloadLifecycleCheckpointCommit.committed)'),
      );
      expect(
        source,
        contains('if (terminal) _terminalJobIds.add(task.taskId);'),
      );

      final pauseStart = source.indexOf(
        'Future<void> pauseDownload(String taskId)',
      );
      final pauseEnd = source.indexOf(
        'Future<void> resumeDownload(String taskId)',
        pauseStart,
      );
      final pause = source.substring(pauseStart, pauseEnd);
      expect(
        pause.indexOf('final checkpointed = await _checkpointLogicalJob('),
        greaterThanOrEqualTo(0),
      );
      expect(
        pause.indexOf('final checkpointed = await _checkpointLogicalJob('),
        lessThan(
          pause.indexOf(
            'await _rangeTransfers.stop(taskId);',
          ),
        ),
      );
      expect(
        pause,
        contains(
          r"throw StateError('Failed to persist pause intent for $taskId')",
        ),
      );

      final resumeStart = source.indexOf(
        'Future<void> _resumeUserPausedUnlocked(String taskId)',
      );
      final resumeEnd = source.indexOf('bool _isOccupyingTaskId(', resumeStart);
      final resume = source.substring(resumeStart, resumeEnd);
      expect(
        resume.indexOf('final checkpointed = await _checkpointLogicalJob('),
        greaterThanOrEqualTo(0),
      );
      expect(
        resume.indexOf('final checkpointed = await _checkpointLogicalJob('),
        lessThan(resume.indexOf('_userPausedIds.remove(taskId);')),
      );
      expect(
        resume,
        contains(
          r"throw StateError('Failed to persist resume intent for $taskId')",
        ),
      );

      final queueStart = source.indexOf(
        'Future<void> _enqueueExistingTaskAsWaiterUnlocked(DownloadTask task)',
      );
      final queueEnd = source.indexOf(
        'Future<DownloadTask> _adaptiveTaskForFreshStart(',
        queueStart,
      );
      final queue = source.substring(queueStart, queueEnd);
      expect(
        queue.indexOf('final checkpointed = await _checkpointLogicalJob('),
        greaterThanOrEqualTo(0),
      );
      expect(
        queue.indexOf('final checkpointed = await _checkpointLogicalJob('),
        lessThan(queue.indexOf('_queueWaitingIds.add(task.taskId);')),
      );
      expect(
        queue,
        contains(
          r"throw StateError('Failed to persist queue intent for ${task.taskId}')",
        ),
      );
    },
  );

  test('parked executor failure persists before paused replica projection', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<void> _preserveDownloadAsPaused(');
    final end = source.indexOf(
      'Future<void> _startNextAfterParkedFailureUnlocked()',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    final checkpoint = body.indexOf(
      'final checkpointed = await _checkpointLogicalJob(',
    );
    final replicaWrite = body.indexOf(
      'await FileDownloader().database.updateRecord(',
    );
    expect(
      checkpoint,
      greaterThanOrEqualTo(0),
      reason:
          'a parked failure must prove the durable interrupted state was committed',
    );
    expect(
      checkpoint,
      lessThan(replicaWrite),
      reason:
          'JobStore authority must commit before executor/UI replicas are projected as paused',
    );
    expect(body, contains('if (!checkpointed) {'));
    expect(
      body,
      contains("diagnosticLog.record('failurePark.checkpointFailed'"),
    );
  });

  test('failed fresh start persists interruption before paused projection', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final enqueue = source.indexOf(
      'final success = await _enqueueTransfer(transferTask, expectedBytes);',
    );
    final start = source.indexOf('if (!success) {', enqueue);
    final end = source.indexOf(
      'await _persistNativeWaitingSnapshot();',
      start,
    );
    expect(enqueue, greaterThanOrEqualTo(0));
    expect(start, greaterThan(enqueue));
    expect(end, greaterThan(start));
    final body = source.substring(start, end);

    final checkpoint = body.indexOf(
      'final failureCheckpointed = await _checkpointLogicalJob(',
    );
    final replicaWrite = body.indexOf(
      'await FileDownloader().database.updateRecord(',
    );
    expect(
      checkpoint,
      greaterThanOrEqualTo(0),
      reason:
          'a rejected fresh executor start must prove interrupted authority before projecting paused replicas',
    );
    expect(checkpoint, lessThan(replicaWrite));
    expect(body, contains('if (!failureCheckpointed) {'));
    expect(
      body,
      contains("diagnosticLog.record('start.failureCheckpointFailed'"),
    );
  });

  test('failed resume persists interruption before paused projection', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final resumeStart = source.indexOf(
      'Future<void> _resumeUserPausedUnlocked(String taskId)',
    );
    final resumeEnd = source.indexOf('bool _isOccupyingTaskId(', resumeStart);
    expect(resumeStart, greaterThanOrEqualTo(0));
    expect(resumeEnd, greaterThan(resumeStart));
    final resume = source.substring(resumeStart, resumeEnd);
    final failedStart = resume.indexOf('if (!started) {');
    final failedEnd = resume.indexOf('\n      } else {', failedStart);
    expect(failedStart, greaterThanOrEqualTo(0));
    expect(failedEnd, greaterThan(failedStart));
    final body = resume.substring(failedStart, failedEnd);

    final checkpoint = body.indexOf(
      'final resumeFailureCheckpointed = await _checkpointLogicalJob(',
    );
    final replicaWrite = body.indexOf(
      'await FileDownloader().database.updateRecord(',
    );
    expect(
      checkpoint,
      greaterThanOrEqualTo(0),
      reason:
          'a rejected resume must prove interrupted authority before projecting paused replicas',
    );
    expect(checkpoint, lessThan(replicaWrite));
    expect(body, contains('if (!resumeFailureCheckpointed) {'));
    expect(
      body,
      contains("diagnosticLog.record('resume.failureCheckpointFailed'"),
    );
  });
}
