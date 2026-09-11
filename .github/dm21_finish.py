from pathlib import Path
import sys

SERVICE = Path('lib/core/services/download_service.dart')
PLAN = Path('DOWNLOAD_MANAGER_PLAN.md')
SOURCE_TEST = Path('test/core/services/download_source_refresh_checkpoint_guard_test.dart')
RESULT_TEST = Path('test/core/services/download_checkpoint_commit_result_test.dart')

mode = sys.argv[1]

SOURCE_TEST_CONTENT = r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source replacement is gated by an authoritative checkpoint', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();
    final begin = source.indexOf(
      'Future<({DownloadTask task, bool refreshed})> _refreshTaskBeforeResume(',
    );
    final end = source.indexOf('Future<List<Task>> _liveTransferTasks()', begin);
    final refresh = source.substring(begin, end);

    expect(
      refresh,
      contains('final refreshCheckpointed = await _checkpointLogicalJob('),
    );
    expect(refresh, contains('state: DownloadJobState.interrupted'));
    expect(
      refresh,
      contains(
        r"throw StateError('Failed to persist source refresh boundary for ${task.taskId}')",
      ),
    );

    final checkpoint = refresh.indexOf(
      'final refreshCheckpointed = await _checkpointLogicalJob(',
    );
    expect(checkpoint, greaterThanOrEqualTo(0));
    expect(checkpoint, lessThan(refresh.indexOf('await _parallel.replaceSource(')));
    expect(
      checkpoint,
      lessThan(refresh.indexOf('await FileDownloader().database.updateRecord(')),
    );
  });
}
'''

RESULT_TEST_CONTENT = r'''import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/services/download_service.dart';

void main() {
  test('authoritative checkpoint reports committed writes', () async {
    final result = await commitAuthoritativeDownloadCheckpoint(() async => true);
    expect(result, DownloadLifecycleCheckpointCommit.committed);
  });

  test('authoritative checkpoint reports rejected writes', () async {
    final result = await commitAuthoritativeDownloadCheckpoint(() async => false);
    expect(result, DownloadLifecycleCheckpointCommit.rejected);
  });

  test('authoritative checkpoint converts backend exceptions to failed', () async {
    final result = await commitAuthoritativeDownloadCheckpoint(() async {
      throw StateError('backend write failed');
    });
    expect(result, DownloadLifecycleCheckpointCommit.failed);
  });
}
'''


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected 1 match, got {count}')
    return text.replace(old, new, 1)


if mode == 'tests':
    SOURCE_TEST.write_text(SOURCE_TEST_CONTENT)
    RESULT_TEST.write_text(RESULT_TEST_CONTENT)
elif mode == 'apply':
    text = SERVICE.read_text()

    helper = '''enum DownloadLifecycleCheckpointCommit { committed, rejected, failed }\n\n@visibleForTesting\nFuture<DownloadLifecycleCheckpointCommit> commitAuthoritativeDownloadCheckpoint(\n  Future<bool> Function() checkpoint,\n) async {\n  try {\n    return await checkpoint()\n        ? DownloadLifecycleCheckpointCommit.committed\n        : DownloadLifecycleCheckpointCommit.rejected;\n  } catch (_) {\n    return DownloadLifecycleCheckpointCommit.failed;\n  }\n}\n\n'''
    text = replace_once(
        text,
        'class DownloadService {\n',
        helper + 'class DownloadService {\n',
        'checkpoint result helper',
    )

    old = '''    try {\n      final accepted = await _jobStore.checkpoint(\n        taskId: task.taskId,\n        trackingUrl: downloadTrackingUrl(task),\n        state: state,\n        durableBytes: durableBytes,\n        durableByteProvenance: durableByteProvenance,\n        expectedBytes: expectedBytes,\n        userPaused: userPaused,\n        queueWaiting: queueWaiting,\n        fingerprint: DownloadResourceFingerprint(\n          expectedBytes: expectedBytes ?? -1,\n          finalUrl: task.url,\n        ),\n      );\n      if (!accepted) {\n        diagnosticLog.record('job.checkpointRejected', {\n          'taskId': task.taskId,\n          'status': state.name,\n        });\n        return false;\n      }\n      if (terminal) _terminalJobIds.add(task.taskId);\n      return true;\n    } catch (error) {\n      diagnosticLog.record('job.checkpointError', {\n        'taskId': task.taskId,\n        'status': state.name,\n        'errorType': error.runtimeType.toString(),\n      });\n      return false;\n    }\n'''
    new = '''    final commit = await commitAuthoritativeDownloadCheckpoint(\n      () => _jobStore.checkpoint(\n        taskId: task.taskId,\n        trackingUrl: downloadTrackingUrl(task),\n        state: state,\n        durableBytes: durableBytes,\n        durableByteProvenance: durableByteProvenance,\n        expectedBytes: expectedBytes,\n        userPaused: userPaused,\n        queueWaiting: queueWaiting,\n        fingerprint: DownloadResourceFingerprint(\n          expectedBytes: expectedBytes ?? -1,\n          finalUrl: task.url,\n        ),\n      ),\n    );\n    if (commit != DownloadLifecycleCheckpointCommit.committed) {\n      diagnosticLog.record(\n        commit == DownloadLifecycleCheckpointCommit.rejected\n            ? 'job.checkpointRejected'\n            : 'job.checkpointError',\n        {\n          'taskId': task.taskId,\n          'status': state.name,\n          'result': commit.name,\n        },\n      );\n      return false;\n    }\n    if (terminal) _terminalJobIds.add(task.taskId);\n    return true;\n'''
    text = replace_once(text, old, new, 'checkpoint implementation')

    anchor = '''    if (task is ParallelDownloadTask) {\n      final replaced = await _parallel.replaceSource(\n'''
    replacement = '''    // Source replacement changes executor/manifest identity. Persist an\n    // interrupted write-ahead boundary first so a storage failure cannot let\n    // the old durable state race a newly installed URL. DM-11/DM-31 later\n    // make the source capability itself transactional and generation-aware.\n    final refreshCheckpointed = await _checkpointLogicalJob(\n      task,\n      state: DownloadJobState.interrupted,\n      expectedBytes: expectedBytes,\n      userPaused: false,\n      queueWaiting: false,\n    );\n    if (!refreshCheckpointed) {\n      throw StateError(\n        'Failed to persist source refresh boundary for ${task.taskId}',\n      );\n    }\n\n    if (task is ParallelDownloadTask) {\n      final replaced = await _parallel.replaceSource(\n'''
    text = replace_once(text, anchor, replacement, 'source refresh boundary')
    SERVICE.write_text(text)

    plan = PLAN.read_text()
    plan = replace_once(
        plan,
        '- [ ] **DM-21 — Make authoritative lifecycle checkpoints fail closed at control boundaries**',
        '- [x] **DM-21 — Make authoritative lifecycle checkpoints fail closed at control boundaries**',
        'DM-21 checkbox',
    )
    anchor_note = '  - **Implementation status (2026-09-11, cancel-boundary slice):** Active user cancel now persists authoritative `canceled` intent before Range/native/multipart/plugin ownership is stopped or durable state is removed; rejected persistence aborts the irreversible cleanup path. Completed-file deletion remains exempt from rewriting a terminal `completed` record. DM-07 still owns the stronger cleanup-acknowledged durable tombstone lifetime. Remaining DM-21 work is source-refresh boundary ordering, final direct-write audit, and backend reject/throw behavioral coverage.'
    extra = '''\n  - **Implementation status (2026-09-11, source-refresh/final slice):** Source refresh now writes an authoritative `interrupted` checkpoint before either multipart source replacement or single-file plugin-record replacement. A rejected or throwing checkpoint aborts the replacement, so an expired-source recovery cannot install new executor state when durable lifecycle storage is unavailable.\n  - **Final direct-write audit:** Critical control-boundary writes are now checked before fresh-start projection, queue admission, user resume, user pause, Range attempt/restart, completion projection, cancel cleanup, and source replacement. Generation-fenced hot progress callbacks remain best-effort because they do not authorize irreversible ownership changes; startup reconciliation writes are recovery convergence rather than user control boundaries. Durable cancel-row removal remains intentionally deferred to DM-07/DM-30 for positive ownership settlement.\n  - **Verification passed:** RED source-replacement ordering guard; behavioral `commitAuthoritativeDownloadCheckpoint` coverage for accepted, rejected, and throwing backend writes; lifecycle/persistence/cancel boundary guards; JobStore attempt/provenance/reconciliation tests; recovery/zero-restart/runtime-ownership/multipart regressions; and `flutter analyze --no-fatal-warnings --no-fatal-infos`.'''
    plan = replace_once(plan, anchor_note, anchor_note + extra, 'DM-21 final notes')
    PLAN.write_text(plan)
else:
    raise SystemExit('usage: tests|apply')
