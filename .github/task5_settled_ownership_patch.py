from pathlib import Path

transport_path = Path('lib/core/services/background_downloader_transport.dart')
guard_path = Path('test/core/services/download_recovery_reconciliation_guard_test.dart')

transport = transport_path.read_text()
old = """  Future<DownloadRuntimeOwnership> ownershipFor(String taskId) async {
    try {
      final runtimeTask = await _downloader.taskForId(taskId);
      if (runtimeTask != null) return DownloadRuntimeOwnership.owned;
      return DownloadRuntimeOwnership.notOwned;
    } catch (_) {
      return DownloadRuntimeOwnership.unknown;
    }
  }
"""
new = """  Future<DownloadRuntimeOwnership> ownershipFor(String taskId) async {
    // Rehydrated Transfer handles may come from persistence, but a settled
    // status is still definitive negative ownership: paused/final transfers
    // cannot own a writer and must not reserve a slot merely because the
    // plugin can still look up their task descriptor.
    final projectedStatus = statusFor(taskId);
    if (projectedStatus != null &&
        ownershipFromStatus(projectedStatus) ==
            DownloadRuntimeOwnership.notOwned) {
      return DownloadRuntimeOwnership.notOwned;
    }

    try {
      // Active-looking projections still require targeted executor evidence.
      // Failure is ambiguous and therefore fail-closed as unknown.
      final runtimeTask = await _downloader.taskForId(taskId);
      if (runtimeTask != null) return DownloadRuntimeOwnership.owned;
      return DownloadRuntimeOwnership.notOwned;
    } catch (_) {
      return DownloadRuntimeOwnership.unknown;
    }
  }
"""
count = transport.count(old)
if count != 1:
    raise SystemExit(f'ownershipFor patch expected one match, found {count}')
transport_path.write_text(transport.replace(old, new, 1))

guard = guard_path.read_text()
needle = """    expect(ownershipSource, contains('_downloader.taskForId(taskId)'));
    expect(ownershipSource, isNot(contains('allTasks(')));
"""
replacement = """    expect(ownershipSource, contains('final projectedStatus = statusFor(taskId);'));
    expect(
      ownershipSource.indexOf('ownershipFromStatus(projectedStatus)'),
      lessThan(ownershipSource.indexOf('_downloader.taskForId(taskId)')),
    );
    expect(ownershipSource, contains('_downloader.taskForId(taskId)'));
    expect(ownershipSource, isNot(contains('allTasks(')));
"""
count = guard.count(needle)
if count != 1:
    raise SystemExit(f'guard patch expected one match, found {count}')
guard_path.write_text(guard.replace(needle, replacement, 1))
