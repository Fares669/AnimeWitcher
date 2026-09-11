from pathlib import Path

SERVICE = Path('lib/core/services/download_service.dart')
PLAN = Path('DOWNLOAD_MANAGER_PLAN.md')
TEST = Path('test/core/services/download_command_outcome_test.dart')
GUARD = Path('test/core/services/download_start_outcome_guard_test.dart')

source = SERVICE.read_text()

enum_anchor = "class DownloadProgressData {\n"
enum_block = '''enum DownloadCommandOutcome {\n  running,\n  attached,\n  queued,\n  paused,\n  settlingOwnership,\n  alreadyComplete,\n  restartRequired,\n  recoverableFailure,\n  serviceUnavailable,\n  missingState,\n  terminal,\n}\n\nDownloadCommandOutcome downloadCommandOutcomeForJobState(\n  DownloadJobState? state,\n) {\n  return switch (state) {\n    DownloadJobState.running ||\n    DownloadJobState.starting ||\n    DownloadJobState.assembling ||\n    DownloadJobState.verifying => DownloadCommandOutcome.running,\n    DownloadJobState.queued => DownloadCommandOutcome.queued,\n    DownloadJobState.retryWaiting || DownloadJobState.interrupted =>\n      DownloadCommandOutcome.recoverableFailure,\n    DownloadJobState.pausing => DownloadCommandOutcome.settlingOwnership,\n    DownloadJobState.pausedByUser => DownloadCommandOutcome.paused,\n    DownloadJobState.completed => DownloadCommandOutcome.alreadyComplete,\n    DownloadJobState.canceled => DownloadCommandOutcome.terminal,\n    DownloadJobState.orphaned || null => DownloadCommandOutcome.missingState,\n  };\n}\n\n'''
if enum_anchor not in source:
    raise SystemExit('DownloadProgressData anchor missing')
source = source.replace(enum_anchor, enum_block + enum_anchor, 1)

start_sig = '''  Future<bool> startDownload({\n    required String url,\n    required String filename,\n    required String directory, // Relative for mobile/mac, absolute for others\n    required MultimediaItem item,\n    Episode? episode,\n    String? trackingUrl,\n    Map<String, String>? headers,\n    int totalBytes = -1,\n  }) async {\n    await _awaitCommandReadiness('startDownload');\n'''
wrapper_and_sig = '''  Future<bool> startDownload({\n    required String url,\n    required String filename,\n    required String directory, // Relative for mobile/mac, absolute for others\n    required MultimediaItem item,\n    Episode? episode,\n    String? trackingUrl,\n    Map<String, String>? headers,\n    int totalBytes = -1,\n  }) async {\n    final outcome = await startDownloadOutcome(\n      url: url,\n      filename: filename,\n      directory: directory,\n      item: item,\n      episode: episode,\n      trackingUrl: trackingUrl,\n      headers: headers,\n      totalBytes: totalBytes,\n    );\n    return switch (outcome) {\n      DownloadCommandOutcome.running ||\n      DownloadCommandOutcome.attached ||\n      DownloadCommandOutcome.queued ||\n      DownloadCommandOutcome.alreadyComplete => true,\n      _ => false,\n    };\n  }\n\n  Future<DownloadCommandOutcome> startDownloadOutcome({\n    required String url,\n    required String filename,\n    required String directory, // Relative for mobile/mac, absolute for others\n    required MultimediaItem item,\n    Episode? episode,\n    String? trackingUrl,\n    Map<String, String>? headers,\n    int totalBytes = -1,\n  }) async {\n    try {\n      await _awaitCommandReadiness('startDownload');\n    } catch (_) {\n      return DownloadCommandOutcome.serviceUnavailable;\n    }\n'''
if start_sig not in source:
    raise SystemExit('startDownload signature anchor missing')
source = source.replace(start_sig, wrapper_and_sig, 1)

start_begin = source.index('  Future<DownloadCommandOutcome> startDownloadOutcome({')
start_end = source.index('  Future<List<TaskRecord>> _completeRecordsForEpisode(', start_begin)
segment = source[start_begin:start_end]

replacements = [
    ('''          _ref.read(activeDownloadsProvider.notifier).add(trackingUrl ?? url);\n          return true;\n''', '''          _ref.read(activeDownloadsProvider.notifier).add(trackingUrl ?? url);\n          return DownloadCommandOutcome.attached;\n''', 'existing active attach', 2),
    ('''        if (existingRecord.task is! DownloadTask) {\n          return false;\n        }\n''', '''        if (existingRecord.task is! DownloadTask) {\n          return DownloadCommandOutcome.recoverableFailure;\n        }\n''', 'invalid existing task', 1),
    ('''          await _attachToLiveNativeTask(existingTask, live: live);\n          _ref.read(activeDownloadsProvider.notifier).add(trackingUrl ?? url);\n          return true;\n''', '''          await _attachToLiveNativeTask(existingTask, live: live);\n          _ref.read(activeDownloadsProvider.notifier).add(trackingUrl ?? url);\n          return DownloadCommandOutcome.attached;\n''', 'native live attach', 1),
    ('''        await _resumeUserPausedUnlocked(existingTask.taskId);\n        return true;\n''', '''        await _resumeUserPausedUnlocked(existingTask.taskId);\n        return downloadCommandOutcomeForJobState(\n          (await _jobStore.get(existingTask.taskId))?.state,\n        );\n''', 'existing resume outcome', 1),
    ('''          return true;\n        case CompleteDownloadAction.dropAndEnqueue:\n''', '''          return DownloadCommandOutcome.alreadyComplete;\n        case CompleteDownloadAction.dropAndEnqueue:\n''', 'already complete', 1),
    ('''          await _persistNativeWaitingSnapshot();\n          unawaited(_syncSessionOverlay());\n          return true;\n        }\n\n        _startingTaskIds.add(transferTask.taskId);\n''', '''          await _persistNativeWaitingSnapshot();\n          unawaited(_syncSessionOverlay());\n          return DownloadCommandOutcome.queued;\n        }\n\n        _startingTaskIds.add(transferTask.taskId);\n''', 'fresh queued', 1),
    ('''          _updatesController.add(\n            TaskStatusUpdate(transferTask, TaskStatus.paused),\n          );\n          return false;\n        }\n\n        await _persistNativeWaitingSnapshot();\n        unawaited(_syncSessionOverlay());\n        return true;\n''', '''          _updatesController.add(\n            TaskStatusUpdate(transferTask, TaskStatus.paused),\n          );\n          return DownloadCommandOutcome.recoverableFailure;\n        }\n\n        await _persistNativeWaitingSnapshot();\n        unawaited(_syncSessionOverlay());\n        return DownloadCommandOutcome.running;\n''', 'fresh enqueue result', 1),
    ('''        return false;\n      } finally {\n''', '''        return DownloadCommandOutcome.recoverableFailure;\n      } finally {\n''', 'start catch failure', 1),
]
for old, new, label, expected in replacements:
    count = segment.count(old)
    if count != expected:
        raise SystemExit(f'{label}: expected {expected} match(es), got {count}')
    segment = segment.replace(old, new, 1)
source = source[:start_begin] + segment + source[start_end:]
SERVICE.write_text(source)

TEST.write_text(r'''import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('downloadCommandOutcomeForJobState', () {
    test('maps active pipeline stages and queue distinctly', () {
      for (final state in [
        DownloadJobState.starting,
        DownloadJobState.running,
        DownloadJobState.assembling,
        DownloadJobState.verifying,
      ]) {
        expect(
          downloadCommandOutcomeForJobState(state),
          DownloadCommandOutcome.running,
        );
      }
      expect(
        downloadCommandOutcomeForJobState(DownloadJobState.queued),
        DownloadCommandOutcome.queued,
      );
    });

    test('keeps transient failure, ownership settlement and pause distinct', () {
      for (final state in [
        DownloadJobState.retryWaiting,
        DownloadJobState.interrupted,
      ]) {
        expect(
          downloadCommandOutcomeForJobState(state),
          DownloadCommandOutcome.recoverableFailure,
        );
      }
      expect(
        downloadCommandOutcomeForJobState(DownloadJobState.pausing),
        DownloadCommandOutcome.settlingOwnership,
      );
      expect(
        downloadCommandOutcomeForJobState(DownloadJobState.pausedByUser),
        DownloadCommandOutcome.paused,
      );
    });

    test('maps terminal, complete, orphaned and absent state explicitly', () {
      expect(
        downloadCommandOutcomeForJobState(DownloadJobState.completed),
        DownloadCommandOutcome.alreadyComplete,
      );
      expect(
        downloadCommandOutcomeForJobState(DownloadJobState.canceled),
        DownloadCommandOutcome.terminal,
      );
      expect(
        downloadCommandOutcomeForJobState(DownloadJobState.orphaned),
        DownloadCommandOutcome.missingState,
      );
      expect(
        downloadCommandOutcomeForJobState(null),
        DownloadCommandOutcome.missingState,
      );
    });
  });
}
''')

GUARD.write_text(r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('start exposes logical outcome while legacy bool delegates to it', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();
    expect(source, contains('Future<DownloadCommandOutcome> startDownloadOutcome('));
    expect(source, contains('final outcome = await startDownloadOutcome('));
    expect(source, contains('DownloadCommandOutcome.attached'));
    expect(source, contains('DownloadCommandOutcome.queued'));
    expect(source, contains('DownloadCommandOutcome.alreadyComplete'));
    expect(source, contains('DownloadCommandOutcome.serviceUnavailable'));
    expect(source, contains('DownloadCommandOutcome.recoverableFailure'));
  });
}
''')

plan = PLAN.read_text()
needle = '  - **Verification (partial):** pure outcome matrix test + native transport wrapper compilation + generated-source-aware analyzer. **Still required before `[x]`:** introduce the logical `DownloadCommandOutcome` at DownloadService, map start/attach/queue/already-complete/readiness/missing-state/ownership-settling/failure/terminal branches, migrate launcher/provider/UI callers, then add the full scenario matrix listed above.\n'
replacement = needle + '  - **Progress (2026-09-11, service start):** Added the logical `DownloadCommandOutcome` contract and a typed `startDownloadOutcome()` path. Fresh start now distinguishes `running`, `queued`, `alreadyComplete`, live `attached`, readiness `serviceUnavailable`, and recoverable enqueue/setup failures. Existing paused jobs are projected from durable `DownloadJobState` instead of returning unconditional success. The old `startDownload()->bool` remains only as a compatibility wrapper until caller migration.\n  - **Still required before `[x]`:** migrate pause/resume/cancel to typed service outcomes, migrate launcher/provider/UI callers off bool/void APIs, remove compatibility ambiguity where practical, and add the full scenario matrix (including missing DB/JobStore-only/native failure/Range failure/manifest/source-refresh/unknown-owner/init failure).\n'
if needle not in plan:
    raise SystemExit('DM-03 partial note anchor missing')
plan = plan.replace(needle, replacement, 1)
PLAN.write_text(plan)
