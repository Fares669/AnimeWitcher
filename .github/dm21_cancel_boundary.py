from pathlib import Path
import sys

SERVICE = Path('lib/core/services/download_service.dart')
PLAN = Path('DOWNLOAD_MANAGER_PLAN.md')
TEST = Path('test/core/services/download_cancel_checkpoint_guard_test.dart')

mode = sys.argv[1]

TEST_CONTENT = r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active cancel intent persists before ownership cleanup', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();
    final begin = source.indexOf('Future<void> cancelDownload(');
    final end = source.indexOf('Future<void> pauseDownload(', begin);
    final cancel = source.substring(begin, end);

    expect(cancel, contains('final existingJob = await _jobStore.get(taskId);'));
    expect(cancel, contains('final cancelPersisted = await _checkpointLogicalJob('));
    expect(cancel, contains('state: DownloadJobState.canceled'));
    expect(cancel, contains(r"throw StateError('Failed to persist cancel intent for $taskId')"));

    final checkpoint = cancel.indexOf('final cancelPersisted = await _checkpointLogicalJob(');
    expect(checkpoint, greaterThanOrEqualTo(0));
    expect(checkpoint, lessThan(cancel.indexOf('_terminalJobIds.add(taskId);')));
    expect(checkpoint, lessThan(cancel.indexOf('await _rangeTransfers.stop(taskId);')));
    expect(checkpoint, lessThan(cancel.indexOf('await _parallel.cancel(')));
    expect(checkpoint, lessThan(cancel.indexOf('await _nativeTransport.cancel(')));
    expect(checkpoint, lessThan(cancel.indexOf('await FileDownloader().cancelTasksWithIds(')));
    expect(checkpoint, lessThan(cancel.indexOf('await _jobStore.remove(taskId);')));
  });
}
'''

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected 1 match, got {count}')
    return text.replace(old, new, 1)

if mode == 'tests':
    TEST.write_text(TEST_CONTENT)
elif mode == 'apply':
    text = SERVICE.read_text()
    old = '''    diagnosticLog.record('command.cancel', {'taskId': taskId});
    // Tombstone the logical download before waiting on native IO. This makes a
    // user delete immediate in every UI and prevents late URLSession callbacks
    // from resurrecting the row while the OS finishes canceling its worker.
    _cancellingUrls.add(trackingUrl);
    _terminalJobIds.add(taskId);
'''
    new = '''    diagnosticLog.record('command.cancel', {'taskId': taskId});
    // Persist terminal intent before stopping any writer. The durable row is
    // removed only after native/plugin cleanup below has returned; DM-07 will
    // further extend this into a cleanup-acknowledged tombstone protocol.
    final existingJob = await _jobStore.get(taskId);
    final parentRecord = await FileDownloader().database.recordForId(taskId);
    DownloadTask? cancelTask = parentRecord?.task is DownloadTask
        ? parentRecord!.task as DownloadTask
        : await _liveNativeTaskFor(taskId: taskId, trackingUrl: trackingUrl);
    if (existingJob != null &&
        existingJob.state != DownloadJobState.completed) {
      if (cancelTask != null) {
        final cancelPersisted = await _checkpointLogicalJob(
          cancelTask,
          state: DownloadJobState.canceled,
          userPaused: false,
          queueWaiting: false,
        );
        if (!cancelPersisted) {
          throw StateError('Failed to persist cancel intent for $taskId');
        }
      } else {
        final cancelPersisted = await _jobStore.checkpoint(
          taskId: existingJob.taskId,
          trackingUrl: existingJob.trackingUrl,
          state: DownloadJobState.canceled,
          durableBytes: existingJob.durableBytes,
          durableByteProvenance: existingJob.durableByteProvenance,
          expectedBytes: existingJob.expectedBytes,
          userPaused: false,
          queueWaiting: false,
          fingerprint: existingJob.fingerprint,
        );
        if (!cancelPersisted) {
          throw StateError('Failed to persist cancel intent for $taskId');
        }
        _terminalJobIds.add(taskId);
      }
    }

    // Project the tombstone only after durable cancel intent is secured.
    _cancellingUrls.add(trackingUrl);
    _terminalJobIds.add(taskId);
'''
    text = replace_once(text, old, new, 'cancel prefix')

    old_record = '''        final parentRecord = await FileDownloader().database.recordForId(
          taskId,
        );
        if (parentRecord?.task is ParallelDownloadTask) {
'''
    new_record = '''        if (parentRecord?.task is ParallelDownloadTask) {
'''
    text = replace_once(text, old_record, new_record, 'cancel parent record')
    SERVICE.write_text(text)

    plan = PLAN.read_text()
    anchor = '  - **Implementation status (2026-09-11, persistence-boundary slice):**'
    pos = plan.index(anchor, plan.index('- [ ] **DM-21'))
    line_end = plan.index('\n', pos)
    note = "\n  - **Implementation status (2026-09-11, cancel-boundary slice):** Active user cancel now persists authoritative `canceled` intent before Range/native/multipart/plugin ownership is stopped or durable state is removed; rejected persistence aborts the irreversible cleanup path. Completed-file deletion remains exempt from rewriting a terminal `completed` record. DM-07 still owns the stronger cleanup-acknowledged durable tombstone lifetime. Remaining DM-21 work is source-refresh boundary ordering, final direct-write audit, and backend reject/throw behavioral coverage."
    plan = plan[:line_end] + note + plan[line_end:]
    PLAN.write_text(plan)
else:
    raise SystemExit('usage: tests|apply')
