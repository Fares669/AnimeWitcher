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
            'final stoppedRange = await _rangeTransfers.stop(taskId);',
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
}
