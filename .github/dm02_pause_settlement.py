from pathlib import Path
import re
import sys

SERVICE = Path('lib/core/services/download_service.dart')
PLAN = Path('DOWNLOAD_MANAGER_PLAN.md')
TEST = Path('test/core/services/download_pause_settlement_guard_test.dart')

TEST_CONTENT = r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String methodBody(String source, String signature, String nextSignature) {
  final start = source.indexOf(signature);
  final end = source.indexOf(nextSignature, start + signature.length);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $signature');
  expect(end, greaterThan(start), reason: 'missing boundary $nextSignature');
  return source.substring(start, end);
}

void main() {
  final source = File('lib/core/services/download_service.dart').readAsStringSync();

  test('ordinary single-file pause requires runtime ownership settlement', () {
    final body = methodBody(
      source,
      'Future<bool> _pauseTransfer(',
      'Future<bool> _resumeDownloadTask(',
    );

    expect(body, contains('var ownership = await _runtimeOwnershipFor(task.taskId);'));
    expect(body, contains('ownership != DownloadRuntimeOwnership.notOwned'));
    expect(
      body,
      isNot(contains('if (isInternalDownloaderChunk(task)) {\n        // Verify the child really left the live native set')),
      reason: 'ownership proof must not be restricted to multipart children',
    );
  });

  test('unsettled user pause stays durable pausing instead of rolling back to running', () {
    final body = methodBody(
      source,
      'Future<void> pauseDownload(String taskId) async {',
      'Future<void> resumeDownload(String taskId) async {',
    );
    final failedPause = body.substring(body.indexOf('if (!didPause) {'), body.indexOf('await FileDownloader().database.updateRecord(', body.indexOf('if (!didPause) {')));

    expect(failedPause, contains("diagnosticLog.record('pause.settling'"));
    expect(failedPause, isNot(contains('_userPausedIds.remove(taskId)')));
    expect(failedPause, isNot(contains('DownloadJobState.running')));
    expect(failedPause, isNot(contains('TaskStatus.running')));
  });

  test('startup pause projection is conditional on proven settlement', () {
    final recovery = methodBody(
      source,
      'Future<void> _recoverPersistedDownloads() async {',
      'int _occupiedSlotCount(',
    );

    expect(recovery, contains('var userPauseSettled = !userPaused;'));
    expect(recovery, contains('userPauseSettled = await _pauseTransfer(task);'));
    expect(recovery, contains('if (userPauseSettled) {\n          await FileDownloader().database.updateRecord('));
    expect(recovery, contains('(userPaused && userPauseSettled)'));
  });
}
'''


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected 1 match, got {count}')
    return text.replace(old, new, 1)


if len(sys.argv) != 2:
    raise SystemExit('usage: tests|apply')
mode = sys.argv[1]

if mode == 'tests':
    TEST.write_text(TEST_CONTENT)
    raise SystemExit(0)

service = SERVICE.read_text()

# 1. DM-02 core invariant: every native pause must prove ownership release,
# not only internal multipart children. Keep the existing one retry for an
# owned worker, but apply it to ordinary single-file downloads too.
pattern = re.compile(
    r'''      if \(isInternalDownloaderChunk\(task\)\) \{\n        // Verify the child really left the live native set\. If the first pause\n        // raced URLSession hand-off, retry the same identity once; never cancel\.\n        var ownership = await _runtimeOwnershipFor\(task\.taskId\);\n        if \(ownership == DownloadRuntimeOwnership\.owned\) \{\n          if \(!await FileDownloader\(\)\.pause\(task\)\) return false;\n          await Future<void>\.delayed\(const Duration\(milliseconds: 200\)\);\n          ownership = await _runtimeOwnershipFor\(task\.taskId\);\n        \}\n        if \(ownership != DownloadRuntimeOwnership\.notOwned\) return false;\n      \}\n      return true;'''
)
replacement = '''      // Command acceptance and even a paused callback are not sufficient proof\n      // that URLSession released the writer. DM-19 runtime ownership is the\n      // final authority for both ordinary single-file and multipart children.\n      var ownership = await _runtimeOwnershipFor(task.taskId);\n      if (ownership == DownloadRuntimeOwnership.owned) {\n        // A hand-off race can leave the same task alive briefly. Retry pause on\n        // the same identity once; never cancel because that can destroy resume data.\n        final retried = isInternalDownloaderChunk(task)\n            ? await FileDownloader().pause(task)\n            : await _nativeTransport.pause(task);\n        if (!retried) return false;\n        await Future<void>.delayed(const Duration(milliseconds: 200));\n        ownership = await _runtimeOwnershipFor(task.taskId);\n      }\n      if (ownership != DownloadRuntimeOwnership.notOwned) return false;\n      return true;'''
service, count = pattern.subn(replacement, service, count=1)
if count != 1:
    raise SystemExit(f'pause ownership proof: expected 1 match, got {count}')

# 2. An unresolved pause keeps durable user intent in `pausing`. Do not lie to
# UI/DB by rolling back to running, and do not clear user pause intent while the
# old writer is still owned/settling/unknown.
old_failed = '''        if (!didPause) {\n          _userPausedIds.remove(taskId);\n          await _ref\n              .read(storageServiceProvider)\n              .patchDownloadMetadata(\n                taskId,\n                queueWaiting: false,\n                userPaused: false,\n                lastProgress: progress,\n                lastExpectedBytes: totalSize,\n              );\n          await _checkpointLogicalJob(\n            downloadTask,\n            state: DownloadJobState.running,\n            expectedBytes: totalSize,\n            userPaused: false,\n            queueWaiting: false,\n          );\n          _publishProgress(\n            trackingUrl: trackingUrl,\n            taskId: taskId,\n            progress: progress,\n            totalSize: totalSize,\n            status: TaskStatus.running,\n            networkSpeed: current?.networkSpeed ?? 0,\n            timeRemaining: current?.timeRemaining ?? Duration.zero,\n          );\n          _updatesController.add(\n            TaskStatusUpdate(downloadTask, TaskStatus.running),\n          );\n          await _syncSessionOverlay(completedSuccess: false);\n          await _persistNativeWaitingSnapshot();\n          return;\n        }\n'''
new_failed = '''        if (!didPause) {\n          diagnosticLog.record('pause.settling', {\n            'taskId': taskId,\n            'ownership': (await _runtimeOwnershipFor(taskId)).name,\n          });\n          // Keep the already-persisted `pausing` + userPaused intent. The task\n          // must not become logically/UI paused until ownership release is\n          // proven, and must not be rolled back to running while the user has\n          // an outstanding pause request. A later reconcile/retry can settle it.\n          await _syncSessionOverlay(completedSuccess: false);\n          await _persistNativeWaitingSnapshot();\n          return;\n        }\n'''
service = replace_once(service, old_failed, new_failed, 'unsettled pause branch')

# 3. Startup enforcement must use the exact same settlement invariant. Persisted
# user intent is retained even if enforcement cannot yet prove writer release,
# but the plugin row/UI must not falsely claim settled `paused`.
old_startup = '''      if (userPaused) {\n        _userPausedIds.add(task.taskId);\n        _queueWaitingIds.remove(task.taskId);\n        _waitingPayloads.remove(task.taskId);\n        _rememberSessionTask(task.taskId);\n        if (shouldNativePauseAfterUserPause(\n          userPaused: true,\n          stillInNativeQueue:\n              stillNative || _parallel.hasLiveConnections(task.taskId),\n        )) {\n          try {\n            await _pauseTransfer(task);\n          } catch (_) {}\n        }\n        await FileDownloader().database.updateRecord(\n          TaskRecord(\n            task,\n            TaskStatus.paused,\n            progress,\n            record.expectedFileSize,\n          ),\n        );\n        await storage.patchDownloadMetadata(\n          task.taskId,\n          queueWaiting: false,\n          userPaused: true,\n        );\n      }\n'''
new_startup = '''      var userPauseSettled = !userPaused;\n      if (userPaused) {\n        _userPausedIds.add(task.taskId);\n        _queueWaitingIds.remove(task.taskId);\n        _waitingPayloads.remove(task.taskId);\n        _rememberSessionTask(task.taskId);\n        final needsNativePause = shouldNativePauseAfterUserPause(\n          userPaused: true,\n          stillInNativeQueue:\n              stillNative || _parallel.hasLiveConnections(task.taskId),\n        );\n        userPauseSettled = !needsNativePause;\n        if (needsNativePause) {\n          try {\n            userPauseSettled = await _pauseTransfer(task);\n          } catch (_) {\n            userPauseSettled = false;\n          }\n        }\n        if (userPauseSettled) {\n          await FileDownloader().database.updateRecord(\n            TaskRecord(\n              task,\n              TaskStatus.paused,\n              progress,\n              record.expectedFileSize,\n            ),\n          );\n        } else {\n          await _checkpointLogicalJob(\n            task,\n            state: DownloadJobState.pausing,\n            expectedBytes: expectedBytes,\n            userPaused: true,\n            queueWaiting: false,\n          );\n          diagnosticLog.record('recovery.pauseSettling', {\n            'taskId': task.taskId,\n          });\n        }\n        await storage.patchDownloadMetadata(\n          task.taskId,\n          queueWaiting: false,\n          userPaused: true,\n        );\n      }\n'''
service = replace_once(service, old_startup, new_startup, 'startup pause enforcement')

old_display = '''            : (userPaused\n                  ? TaskStatus.paused\n                  : (showAsRunning'''
new_display = '''            : ((userPaused && userPauseSettled)\n                  ? TaskStatus.paused\n                  : (showAsRunning'''
service = replace_once(service, old_display, new_display, 'startup pause UI projection')
# Additional opening parenthesis requires one extra close at the end of the nested ternary.
old_tail = '''                        : (stillNative && wasRunning\n                              ? record.status\n                              : TaskStatus.paused))),\n      );'''
new_tail = '''                        : (stillNative && wasRunning\n                              ? record.status\n                              : TaskStatus.paused)))),\n      );'''
service = replace_once(service, old_tail, new_tail, 'startup pause UI close')

SERVICE.write_text(service)
TEST.write_text(TEST_CONTENT)

plan = PLAN.read_text()
anchor = '''- [ ] **DM-02 — Make single-file pause prove that transport ownership actually stopped**'''
if anchor not in plan:
    raise SystemExit('DM-02 anchor missing')
# Do not mark complete here; CI tests do that only after all implementation checks pass.
PLAN.write_text(plan)
