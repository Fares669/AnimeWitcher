from pathlib import Path
import sys

SERVICE = Path('lib/core/services/download_service.dart')
PLAN = Path('DOWNLOAD_MANAGER_PLAN.md')
TEST = Path('test/core/services/download_lifecycle_checkpoint_guard_test.dart')

mode = sys.argv[1]

TEST_CONTENT = r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('critical lifecycle boundaries persist before ownership side effects', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();

    expect(source, contains('Future<bool> _checkpointLogicalJob('));
    expect(source, contains("return false;\n    }\n    try {\n      final accepted = await _jobStore.checkpoint("));
    expect(source, contains("return true;\n    } catch (error)"));

    final pauseStart = source.indexOf('Future<void> pauseDownload(String taskId)');
    final pauseEnd = source.indexOf('Future<void> resumeDownload(String taskId)', pauseStart);
    final pause = source.substring(pauseStart, pauseEnd);
    expect(pause.indexOf('final checkpointed = await _checkpointLogicalJob('), greaterThanOrEqualTo(0));
    expect(pause.indexOf('final checkpointed = await _checkpointLogicalJob('), lessThan(pause.indexOf('final stoppedRange = await _rangeTransfers.stop(taskId);')));
    expect(pause, contains("throw StateError('Failed to persist pause intent for $taskId')"));

    final resumeStart = source.indexOf('Future<void> _resumeUserPausedUnlocked(String taskId)');
    final resumeEnd = source.indexOf('bool _isOccupyingTaskId(', resumeStart);
    final resume = source.substring(resumeStart, resumeEnd);
    expect(resume.indexOf('final checkpointed = await _checkpointLogicalJob('), greaterThanOrEqualTo(0));
    expect(resume.indexOf('final checkpointed = await _checkpointLogicalJob('), lessThan(resume.indexOf('_userPausedIds.remove(taskId);')));
    expect(resume, contains("throw StateError('Failed to persist resume intent for $taskId')"));

    final queueStart = source.indexOf('Future<void> _enqueueExistingTaskAsWaiterUnlocked(DownloadTask task)');
    final queueEnd = source.indexOf('Future<DownloadTask> _adaptiveTaskForFreshStart(', queueStart);
    final queue = source.substring(queueStart, queueEnd);
    expect(queue.indexOf('final checkpointed = await _checkpointLogicalJob('), greaterThanOrEqualTo(0));
    expect(queue.indexOf('final checkpointed = await _checkpointLogicalJob('), lessThan(queue.indexOf('_queueWaitingIds.add(task.taskId);')));
    expect(queue, contains("throw StateError('Failed to persist queue intent for ${task.taskId}')"));
  });
}
'''

def add_tests():
    TEST.write_text(TEST_CONTENT)


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected 1 match, got {count}')
    return text.replace(old, new, 1)


def apply():
    text = SERVICE.read_text()

    old_helper = '''  Future<void> _checkpointLogicalJob(
    DownloadTask task, {
    required DownloadJobState state,
    int? durableBytes,
    DownloadDurableByteProvenance? durableByteProvenance,
    int? expectedBytes,
    bool? userPaused,
    bool? queueWaiting,
  }) async {
    final terminal =
        state == DownloadJobState.completed ||
        state == DownloadJobState.canceled ||
        state == DownloadJobState.orphaned;
    if (_terminalJobIds.contains(task.taskId) && !terminal) {
      diagnosticLog.record('job.checkpointRejected', {
        'taskId': task.taskId,
        'status': state.name,
        'reason': 'terminalTombstone',
      });
      return;
    }
    try {
      final accepted = await _jobStore.checkpoint(
        taskId: task.taskId,
        trackingUrl: downloadTrackingUrl(task),
        state: state,
        durableBytes: durableBytes,
        durableByteProvenance: durableByteProvenance,
        expectedBytes: expectedBytes,
        userPaused: userPaused,
        queueWaiting: queueWaiting,
        fingerprint: DownloadResourceFingerprint(
          expectedBytes: expectedBytes ?? -1,
          finalUrl: task.url,
        ),
      );
      if (!accepted) {
        diagnosticLog.record('job.checkpointRejected', {
          'taskId': task.taskId,
          'status': state.name,
        });
        return;
      }
      if (terminal) _terminalJobIds.add(task.taskId);
    } catch (error) {
      diagnosticLog.record('job.checkpointError', {
        'taskId': task.taskId,
        'status': state.name,
        'errorType': error.runtimeType.toString(),
      });
    }
  }
'''
    new_helper = '''  Future<bool> _checkpointLogicalJob(
    DownloadTask task, {
    required DownloadJobState state,
    int? durableBytes,
    DownloadDurableByteProvenance? durableByteProvenance,
    int? expectedBytes,
    bool? userPaused,
    bool? queueWaiting,
  }) async {
    final terminal =
        state == DownloadJobState.completed ||
        state == DownloadJobState.canceled ||
        state == DownloadJobState.orphaned;
    if (_terminalJobIds.contains(task.taskId) && !terminal) {
      diagnosticLog.record('job.checkpointRejected', {
        'taskId': task.taskId,
        'status': state.name,
        'reason': 'terminalTombstone',
      });
      return false;
    }
    try {
      final accepted = await _jobStore.checkpoint(
        taskId: task.taskId,
        trackingUrl: downloadTrackingUrl(task),
        state: state,
        durableBytes: durableBytes,
        durableByteProvenance: durableByteProvenance,
        expectedBytes: expectedBytes,
        userPaused: userPaused,
        queueWaiting: queueWaiting,
        fingerprint: DownloadResourceFingerprint(
          expectedBytes: expectedBytes ?? -1,
          finalUrl: task.url,
        ),
      );
      if (!accepted) {
        diagnosticLog.record('job.checkpointRejected', {
          'taskId': task.taskId,
          'status': state.name,
        });
        return false;
      }
      if (terminal) _terminalJobIds.add(task.taskId);
      return true;
    } catch (error) {
      diagnosticLog.record('job.checkpointError', {
        'taskId': task.taskId,
        'status': state.name,
        'errorType': error.runtimeType.toString(),
      });
      return false;
    }
  }
'''
    text = replace_once(text, old_helper, new_helper, 'checkpoint helper')

    old_pause_prefix = '''    // Fence callbacks immediately on tap. Native pause/resume-data settlement
    // can take a moment on iOS, but progress events must not visually undo the
    // user's pause while that acknowledgement is in flight.
    _userPausedIds.add(taskId);
    final stoppedRange = await _rangeTransfers.stop(taskId);
    await _serializeQueue(() async {
      _userPausedIds.add(taskId);
      _queueWaitingIds.remove(taskId);
      _waitingPayloads.remove(taskId);
      await _ref
          .read(storageServiceProvider)
          .patchDownloadMetadata(taskId, queueWaiting: false, userPaused: true);

      final recordForId = await FileDownloader().database.recordForId(taskId);
'''
    new_pause_prefix = '''    await _serializeQueue(() async {
      final recordForId = await FileDownloader().database.recordForId(taskId);
'''
    text = replace_once(text, old_pause_prefix, new_pause_prefix, 'pause prefix')

    old_pause_checkpoint = '''        await _checkpointLogicalJob(
          downloadTask,
          state: DownloadJobState.pausing,
          userPaused: true,
          queueWaiting: false,
        );
        // Plugin pause produces URLSession resumeData and drops the
'''
    new_pause_checkpoint = '''        final checkpointed = await _checkpointLogicalJob(
          downloadTask,
          state: DownloadJobState.pausing,
          userPaused: true,
          queueWaiting: false,
        );
        if (!checkpointed) {
          throw StateError('Failed to persist pause intent for $taskId');
        }
        // Fence callbacks only after the durable pause intent exists. Ownership
        // must never be stopped first and then fail to persist the user's intent.
        _userPausedIds.add(taskId);
        _queueWaitingIds.remove(taskId);
        _waitingPayloads.remove(taskId);
        await _ref
            .read(storageServiceProvider)
            .patchDownloadMetadata(
              taskId,
              queueWaiting: false,
              userPaused: true,
            );
        final stoppedRange = await _rangeTransfers.stop(taskId);
        // Plugin pause produces URLSession resumeData and drops the
'''
    text = replace_once(text, old_pause_checkpoint, new_pause_checkpoint, 'pause checkpoint')

    old_resume_prefix = '''  Future<void> _resumeUserPausedUnlocked(String taskId) async {
    await _reconcileTransferOwnership();
    _userPausedIds.remove(taskId);
    _dequeuingPausedIds.remove(taskId);
    DownloadTask? downloadTask = await _liveNativeTaskFor(taskId: taskId);
'''
    new_resume_prefix = '''  Future<void> _resumeUserPausedUnlocked(String taskId) async {
    await _reconcileTransferOwnership();
    DownloadTask? downloadTask = await _liveNativeTaskFor(taskId: taskId);
'''
    text = replace_once(text, old_resume_prefix, new_resume_prefix, 'resume prefix')

    old_resume_checkpoint = '''    _rememberSessionTask(taskId);
    await _ref
        .read(storageServiceProvider)
        .patchDownloadMetadata(taskId, queueWaiting: false, userPaused: false);
    await _checkpointLogicalJob(
      downloadTask,
      state: DownloadJobState.starting,
      userPaused: false,
      queueWaiting: false,
    );

    final max = clampDownloadConcurrency(
'''
    new_resume_checkpoint = '''    _rememberSessionTask(taskId);
    final checkpointed = await _checkpointLogicalJob(
      downloadTask,
      state: DownloadJobState.starting,
      userPaused: false,
      queueWaiting: false,
    );
    if (!checkpointed) {
      throw StateError('Failed to persist resume intent for $taskId');
    }
    _userPausedIds.remove(taskId);
    _dequeuingPausedIds.remove(taskId);
    await _ref
        .read(storageServiceProvider)
        .patchDownloadMetadata(taskId, queueWaiting: false, userPaused: false);

    final max = clampDownloadConcurrency(
'''
    text = replace_once(text, old_resume_checkpoint, new_resume_checkpoint, 'resume checkpoint')

    old_queue = '''    final previous = await FileDownloader().database.recordForId(task.taskId);
    final progress = previous?.progress ?? 0.0;
    final totalSize = previous?.expectedFileSize ?? -1;
    _queueWaitingIds.add(task.taskId);
    _waitingPayloads[task.taskId] = _waitingPayloadFor(task);
    _rememberSessionTask(task.taskId);
    await _ref
        .read(storageServiceProvider)
        .patchDownloadMetadata(task.taskId, queueWaiting: true);
    await _checkpointLogicalJob(
      task,
      state: DownloadJobState.queued,
      expectedBytes: totalSize,
      userPaused: false,
      queueWaiting: true,
    );
    await FileDownloader().database.updateRecord(
'''
    new_queue = '''    final previous = await FileDownloader().database.recordForId(task.taskId);
    final progress = previous?.progress ?? 0.0;
    final totalSize = previous?.expectedFileSize ?? -1;
    final checkpointed = await _checkpointLogicalJob(
      task,
      state: DownloadJobState.queued,
      expectedBytes: totalSize,
      userPaused: false,
      queueWaiting: true,
    );
    if (!checkpointed) {
      throw StateError('Failed to persist queue intent for ${task.taskId}');
    }
    _queueWaitingIds.add(task.taskId);
    _waitingPayloads[task.taskId] = _waitingPayloadFor(task);
    _rememberSessionTask(task.taskId);
    await _ref
        .read(storageServiceProvider)
        .patchDownloadMetadata(task.taskId, queueWaiting: true);
    await FileDownloader().database.updateRecord(
'''
    text = replace_once(text, old_queue, new_queue, 'queue checkpoint')

    SERVICE.write_text(text)

    plan = PLAN.read_text()
    marker = '''  - **Dependencies:** DM-20.\n'''
    note = '''  - **Dependencies:** DM-20.\n  - **Implementation status (2026-09-11, control-boundary slice):** `_checkpointLogicalJob` now reports explicit commit/reject/error success instead of swallowing failure as `void`. Queue admission persists `queued` before mutating waiter/metadata/plugin projections; user resume persists `starting` before clearing durable/user-paused projections; user pause persists `pausing` before stopping Range/native ownership. A failed authoritative checkpoint throws before those ownership side effects. Remaining DM-21 work is to audit/fence fresh-start, refresh replacement, completion and cancel/delete boundaries plus direct JobStore writes and add backend reject/throw fault-injection coverage.\n'''
    # Only replace the DM-21 dependency marker: it is the first exact marker after DM-21.
    dm21 = plan.index('- [ ] **DM-21')
    pos = plan.index(marker, dm21)
    plan = plan[:pos] + plan[pos:].replace(marker, note, 1)
    PLAN.write_text(plan)

if mode == 'tests':
    add_tests()
elif mode == 'apply':
    apply()
else:
    raise SystemExit('usage: tests|apply')
