from pathlib import Path
import sys

SERVICE = Path('lib/core/services/download_service.dart')
PLAN = Path('DOWNLOAD_MANAGER_PLAN.md')
TEST = Path('test/core/services/download_persistence_boundary_guard_test.dart')

mode = sys.argv[1]

TEST_CONTENT = r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('start range and completion fail closed on authoritative persistence', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();

    final startBegin = source.indexOf('Future<bool> startDownload({');
    final startEnd = source.indexOf('Future<List<TaskRecord>> _completeRecordsForEpisode(', startBegin);
    final start = source.substring(startBegin, startEnd);
    expect(start, contains('final jobPersisted = await _jobStore.put('));
    expect(start, contains(r"throw StateError('Failed to persist fresh download intent')"));
    expect(start.indexOf('final jobPersisted = await _jobStore.put('), lessThan(start.indexOf('_waitingPayloads[transferTask.taskId]')));

    final rangeBegin = source.indexOf('Future<DownloadAttemptToken?> _beginLogicalRangeAttempt(');
    final rangeEnd = source.indexOf('Future<({DownloadTask task, bool refreshed})> _refreshTaskBeforeResume(', rangeBegin);
    final range = source.substring(rangeBegin, rangeEnd);
    expect(range, contains('if (!await _jobStore.put('));
    expect(range, contains('return null;'));

    final completeBegin = source.indexOf('Future<void> _persistCompletedFilePath(Task task)');
    final completeEnd = source.indexOf('Future<String> getDownloadPath(', completeBegin);
    final complete = source.substring(completeBegin, completeEnd);
    expect(complete, contains('final completedPersisted = await _checkpointLogicalJob('));
    expect(complete, contains("if (!completedPersisted)"));
    expect(complete.indexOf('final completedPersisted = await _checkpointLogicalJob('), lessThan(complete.indexOf('.patchDownloadMetadata(')));
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

    old_start = '''        await _jobStore.put(
          DownloadJobRecord(
            taskId: transferTask.taskId,
            trackingUrl: trackingUrl ?? url,
            state: startNow
                ? DownloadJobState.starting
                : DownloadJobState.queued,
            generation: 0,
            durableBytes: 0,
            expectedBytes: expectedBytes,
            userPaused: false,
            queueWaiting: !startNow,
            updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
            fingerprint: DownloadResourceFingerprint(
              expectedBytes: expectedBytes,
              finalUrl: url,
            ),
          ),
        );

        _waitingPayloads[transferTask.taskId] = _waitingPayloadFor(
'''
    new_start = '''        final jobPersisted = await _jobStore.put(
          DownloadJobRecord(
            taskId: transferTask.taskId,
            trackingUrl: trackingUrl ?? url,
            state: startNow
                ? DownloadJobState.starting
                : DownloadJobState.queued,
            generation: 0,
            durableBytes: 0,
            expectedBytes: expectedBytes,
            userPaused: false,
            queueWaiting: !startNow,
            updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
            fingerprint: DownloadResourceFingerprint(
              expectedBytes: expectedBytes,
              finalUrl: url,
            ),
          ),
        );
        if (!jobPersisted) {
          throw StateError('Failed to persist fresh download intent');
        }

        _waitingPayloads[transferTask.taskId] = _waitingPayloadFor(
'''
    text = replace_once(text, old_start, new_start, 'fresh start persistence')

    old_range = '''    } else if (existingBytes > job.durableBytes) {
      await _jobStore.put(
        job.copyWith(
          durableBytes: existingBytes,
          durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
          expectedBytes: expectedBytes > 0 ? expectedBytes : job.expectedBytes,
          updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    return _jobStore.beginAttempt(task.taskId, state: DownloadJobState.running);
'''
    new_range = '''    } else if (existingBytes > job.durableBytes) {
      if (!await _jobStore.put(
        job.copyWith(
          durableBytes: existingBytes,
          durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
          expectedBytes: expectedBytes > 0 ? expectedBytes : job.expectedBytes,
          updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      )) {
        return null;
      }
    }
    return _jobStore.beginAttempt(task.taskId, state: DownloadJobState.running);
'''
    text = replace_once(text, old_range, new_range, 'range seed persistence')

    old_complete = '''      await _ref
          .read(storageServiceProvider)
          .patchDownloadMetadata(
            task.taskId,
            trackingUrl: downloadTrackingUrl(task),
            filePath: path,
            lastProgress: 1,
            lastExpectedBytes: expectedBytes,
          );
      if (task is DownloadTask) {
        await _checkpointLogicalJob(
          task,
          state: DownloadJobState.completed,
          durableBytes: fileBytes > 0 ? fileBytes : null,
          durableByteProvenance: fileBytes > 0
              ? DownloadDurableByteProvenance.verifiedFinalFile
              : null,
          expectedBytes: expectedBytes,
          userPaused: false,
          queueWaiting: false,
        );
      }
'''
    new_complete = '''      if (task is DownloadTask) {
        final completedPersisted = await _checkpointLogicalJob(
          task,
          state: DownloadJobState.completed,
          durableBytes: fileBytes > 0 ? fileBytes : null,
          durableByteProvenance: fileBytes > 0
              ? DownloadDurableByteProvenance.verifiedFinalFile
              : null,
          expectedBytes: expectedBytes,
          userPaused: false,
          queueWaiting: false,
        );
        if (!completedPersisted) {
          diagnosticLog.record('completion.persistenceBlocked', {
            'taskId': task.taskId,
          });
          return;
        }
      }
      await _ref
          .read(storageServiceProvider)
          .patchDownloadMetadata(
            task.taskId,
            trackingUrl: downloadTrackingUrl(task),
            filePath: path,
            lastProgress: 1,
            lastExpectedBytes: expectedBytes,
          );
'''
    text = replace_once(text, old_complete, new_complete, 'completion persistence')
    SERVICE.write_text(text)

    plan = PLAN.read_text()
    anchor = '  - **Implementation status (2026-09-11, control-boundary slice):**'
    pos = plan.index(anchor, plan.index('- [ ] **DM-21'))
    line_end = plan.index('\n', pos)
    note = "\n  - **Implementation status (2026-09-11, persistence-boundary slice):** Fresh starts now require the initial JobStore record to commit before queue/UI/native projections; Range resume refuses to begin a new attempt if stronger exact-disk byte evidence cannot be persisted; completion commits `completed` plus verified-final-file bytes before metadata is allowed to project 100%. Remaining DM-21 work is cancel/delete and source-refresh boundaries, direct-write audit, and backend reject/throw behavioral coverage."
    plan = plan[:line_end] + note + plan[line_end:]
    PLAN.write_text(plan)
else:
    raise SystemExit('usage: tests|apply')
