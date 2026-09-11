from pathlib import Path

service = Path('lib/core/services/download_service.dart')
text = service.read_text()
marker = '  Future<void> pauseDownload(String taskId) async {'
assert text.count(marker) == 1
wrappers = '''  Future<DownloadCommandOutcome> cancelDownloadOutcome(
    String taskId,
    String trackingUrl, {
    bool notifyContinuedProcessing = true,
  }) async {
    try {
      await cancelDownload(
        taskId,
        trackingUrl,
        notifyContinuedProcessing: notifyContinuedProcessing,
      );
    } on DownloadServiceUnavailableException {
      return DownloadCommandOutcome.serviceUnavailable;
    } catch (_) {
      return DownloadCommandOutcome.recoverableFailure;
    }

    final ownership = await _runtimeOwnershipFor(taskId);
    if (ownership != DownloadRuntimeOwnership.notOwned) {
      return DownloadCommandOutcome.settlingOwnership;
    }
    final job = await _jobStore.get(taskId);
    if (job == null || job.state == DownloadJobState.canceled) {
      return DownloadCommandOutcome.terminal;
    }
    return downloadCommandOutcomeForJobState(job.state);
  }

  Future<DownloadCommandOutcome> pauseDownloadOutcome(String taskId) async {
    try {
      await pauseDownload(taskId);
    } on DownloadServiceUnavailableException {
      return DownloadCommandOutcome.serviceUnavailable;
    } catch (_) {
      return DownloadCommandOutcome.recoverableFailure;
    }
    final job = await _jobStore.get(taskId);
    final outcome = downloadCommandOutcomeForJobState(job?.state);
    if (outcome != DownloadCommandOutcome.missingState) return outcome;
    final ownership = await _runtimeOwnershipFor(taskId);
    return ownership == DownloadRuntimeOwnership.notOwned
        ? DownloadCommandOutcome.missingState
        : DownloadCommandOutcome.settlingOwnership;
  }

  Future<DownloadCommandOutcome> resumeDownloadOutcome(String taskId) async {
    try {
      await resumeDownload(taskId);
    } on DownloadServiceUnavailableException {
      return DownloadCommandOutcome.serviceUnavailable;
    } catch (_) {
      return DownloadCommandOutcome.recoverableFailure;
    }
    final job = await _jobStore.get(taskId);
    final outcome = downloadCommandOutcomeForJobState(job?.state);
    if (outcome != DownloadCommandOutcome.missingState) return outcome;
    final ownership = await _runtimeOwnershipFor(taskId);
    return switch (ownership) {
      DownloadRuntimeOwnership.owned => DownloadCommandOutcome.attached,
      DownloadRuntimeOwnership.settling || DownloadRuntimeOwnership.unknown =>
        DownloadCommandOutcome.settlingOwnership,
      DownloadRuntimeOwnership.notOwned => DownloadCommandOutcome.missingState,
    };
  }

'''
service.write_text(text.replace(marker, wrappers + marker))

provider = Path('lib/features/library/presentation/downloads_provider.dart')
text = provider.read_text()
old = '''  Future<void> pauseDownload(String taskId) async {
    _setOptimisticStatus(taskId, TaskStatus.paused);
    try {
      await ref.read(downloadServiceProvider).pauseDownload(taskId);
    } catch (_) {
      state = AsyncData(await _refreshList());
    }
  }

  Future<void> resumeDownload(String taskId) async {
    // Queue state is the only universally correct immediate state: if a slot is
    // free DownloadService will replace it with running almost immediately;
    // otherwise the user sees في الانتظار instead of a dead play button.
    _setOptimisticStatus(taskId, TaskStatus.enqueued);
    try {
      await ref.read(downloadServiceProvider).resumeDownload(taskId);
    } catch (_) {
      state = AsyncData(await _refreshList());
    }
  }
'''
assert text.count(old) == 1
new = '''  Future<void> pauseDownload(String taskId) async {
    final outcome = await ref
        .read(downloadServiceProvider)
        .pauseDownloadOutcome(taskId);
    if (outcome == DownloadCommandOutcome.paused) {
      _setOptimisticStatus(taskId, TaskStatus.paused);
      return;
    }
    state = AsyncData(await _refreshList());
  }

  Future<void> resumeDownload(String taskId) async {
    final outcome = await ref
        .read(downloadServiceProvider)
        .resumeDownloadOutcome(taskId);
    switch (outcome) {
      case DownloadCommandOutcome.running:
      case DownloadCommandOutcome.attached:
        _setOptimisticStatus(taskId, TaskStatus.running);
      case DownloadCommandOutcome.queued:
        _setOptimisticStatus(taskId, TaskStatus.enqueued);
      default:
        state = AsyncData(await _refreshList());
    }
  }
'''
provider.write_text(text.replace(old, new))

dialog = Path('lib/features/details/presentation/widgets/download_progress_dialog.dart')
text = dialog.read_text()
old_cancel = '      await service.cancelDownload(data.taskId, widget.trackingUrl);'
assert text.count(old_cancel) == 1
new_cancel = '''      final outcome = await service.cancelDownloadOutcome(
        data.taskId,
        widget.trackingUrl,
      );
      if (outcome != DownloadCommandOutcome.terminal &&
          outcome != DownloadCommandOutcome.alreadyComplete) {
        if (mounted) setState(() => _dismissRequested = false);
        return;
      }'''
text = text.replace(old_cancel, new_cancel)
assert text.count('await service.resumeDownload(data.taskId);') == 1
assert text.count('await service.pauseDownload(data.taskId);') == 1
text = text.replace('await service.resumeDownload(data.taskId);', 'await service.resumeDownloadOutcome(data.taskId);')
text = text.replace('await service.pauseDownload(data.taskId);', 'await service.pauseDownloadOutcome(data.taskId);')
dialog.write_text(text)

guard = Path('test/core/services/download_control_outcome_guard_test.dart')
guard.write_text('''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DM-03 exposes typed pause resume and cancel outcomes', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();
    expect(source, contains('Future<DownloadCommandOutcome> pauseDownloadOutcome('));
    expect(source, contains('Future<DownloadCommandOutcome> resumeDownloadOutcome('));
    expect(source, contains('Future<DownloadCommandOutcome> cancelDownloadOutcome('));
  });

  test('DM-03 callers use typed control settlement', () {
    final provider = File('lib/features/library/presentation/downloads_provider.dart').readAsStringSync();
    final dialog = File('lib/features/details/presentation/widgets/download_progress_dialog.dart').readAsStringSync();
    expect(provider, contains('.pauseDownloadOutcome(taskId)'));
    expect(provider, contains('.resumeDownloadOutcome(taskId)'));
    expect(dialog, contains('cancelDownloadOutcome('));
    expect(dialog, contains('resumeDownloadOutcome(data.taskId)'));
    expect(dialog, contains('pauseDownloadOutcome(data.taskId)'));
  });
}
''')

plan = Path('DOWNLOAD_MANAGER_PLAN.md')
text = plan.read_text()
anchor = '- **Still required before `[x]`:** migrate pause/resume/cancel to typed service outcomes, migrate launcher/provider/UI callers off bool/void APIs, remove compatibility ambiguity where practical, and add the full scenario matrix (including missing DB/JobStore-only/native failure/Range failure/manifest/source-refresh/unknown-owner/init failure).'
assert text.count(anchor) == 1
replacement = anchor + '''
  - **Progress (2026-09-11, control outcomes):** Added typed `pauseDownloadOutcome`, `resumeDownloadOutcome`, and `cancelDownloadOutcome` adapters. They distinguish service unavailability/recoverable failures and consult durable JobStore state plus runtime ownership, so unknown/settling ownership cannot be reported as terminal or safely paused.
  - **Caller migration (partial):** Downloads-provider pause/resume and progress-dialog pause/resume/cancel now consume typed outcomes. Provider no longer projects paused/enqueued before settlement; ambiguous outcomes force a durable refresh.
  - **Still required before `[x]`:** migrate the remove-download cleanup path and launcher/start compatibility caller, then execute the full command × state × ownership × restart matrix. Legacy void methods remain compatibility implementation details until that migration is complete.'''
plan.write_text(text.replace(anchor, replacement))
