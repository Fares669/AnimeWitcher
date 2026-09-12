from pathlib import Path

path = Path('lib/core/services/download_service.dart')
text = path.read_text()

begin = text.index('  Future<void> pauseDownload(String taskId) async {')
end = text.index('\n  Future<void> resumeDownload(String taskId) async {', begin)
pause = text[begin:end]

if '_jobStore.beginReplicaTransaction(' in pause:
    raise SystemExit(0)

old = '''        final pauseOperation = await _jobStore.beginOperation(
          taskId,
          state: DownloadJobState.pausing,
        );
        if (pauseOperation == null) {
          throw StateError('Failed to fence pause operation for $taskId');
        }
'''
new = '''        final pauseOperation = await _jobStore.beginReplicaTransaction(
          taskId,
          operation: DownloadReplicaOperation.pause,
          state: DownloadJobState.pausing,
        );
        if (pauseOperation == null) {
          throw StateError('Failed to journal pause intent for $taskId');
        }
'''
if old not in pause:
    raise SystemExit('pause operation anchor drift')
pause = pause.replace(old, new, 1)

old = '''        if (!didPause) {
          diagnosticLog.record('pause.settling', {
'''
new = '''        if (!didPause) {
          diagnosticLog.record('pause.settling', {
'''
if old not in pause:
    raise SystemExit('pause settling anchor drift')

success_anchor = '''        await FileDownloader().database.updateRecord(
          TaskRecord(downloadTask, TaskStatus.paused, progress, totalSize),
        );
'''
transaction_prefix = '''        final executorAcknowledged = await _jobStore.advanceReplicaTransaction(
          pauseOperation,
          DownloadReplicaTransactionPhase.executorAcknowledged,
        );
        if (!executorAcknowledged) {
          diagnosticLog.record('pause.replicaAckSuperseded', {'taskId': taskId});
          return;
        }
        final projecting = await _jobStore.advanceReplicaTransaction(
          pauseOperation,
          DownloadReplicaTransactionPhase.projecting,
        );
        if (!projecting) {
          diagnosticLog.record('pause.replicaProjectionSuperseded', {
            'taskId': taskId,
          });
          return;
        }

'''
if success_anchor not in pause:
    raise SystemExit('pause projection anchor drift')
pause = pause.replace(success_anchor, transaction_prefix + success_anchor, 1)

old = '''        if (!pauseCommitted) {
          diagnosticLog.record('pause.superseded', {'taskId': taskId});
          return;
        }
        _publishProgress(
'''
new = '''        if (!pauseCommitted) {
          diagnosticLog.record('pause.superseded', {'taskId': taskId});
          return;
        }
        final replicaCommitted = await _jobStore.commitReplicaTransaction(
          pauseOperation,
        );
        if (!replicaCommitted) {
          diagnosticLog.record('pause.replicaCommitSuperseded', {
            'taskId': taskId,
          });
          return;
        }
        _publishProgress(
'''
if old not in pause:
    raise SystemExit('pause commit anchor drift')
pause = pause.replace(old, new, 1)

text = text[:begin] + pause + text[end:]
path.write_text(text)
