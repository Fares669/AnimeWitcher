from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


transport_path = Path("lib/core/services/background_downloader_transport.dart")
transport = transport_path.read_text()

old_ownership = '''  Future<DownloadRuntimeOwnership> ownershipFor(String taskId) async {
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
'''
new_ownership = '''  Future<DownloadRuntimeOwnership> ownershipFor(String taskId) async {
    // Transfer is background_downloader's public lifecycle projection. For a
    // ParallelDownloadTask on iOS the logical parent is synthetic and is not a
    // URLSession task, so taskForId(parentId) cannot prove parent ownership.
    // An active parent Transfer therefore owns the writer generation; settled
    // statuses remain definitive negative ownership.
    final transfer = handleFor(taskId);
    final projectedStatus = transfer?.status;
    if (projectedStatus != null &&
        ownershipFromStatus(projectedStatus) ==
            DownloadRuntimeOwnership.notOwned) {
      return DownloadRuntimeOwnership.notOwned;
    }
    if (transfer?.task is ParallelDownloadTask &&
        projectedStatus != null &&
        runtimeTaskStatusCanOwnWriter(projectedStatus)) {
      return DownloadRuntimeOwnership.owned;
    }

    try {
      // Ordinary tasks have a native task with the same identity, so use the
      // package's targeted runtime query. Failure remains ambiguous/fail-closed.
      final runtimeTask = await _downloader.taskForId(taskId);
      if (runtimeTask != null) return DownloadRuntimeOwnership.owned;
      return DownloadRuntimeOwnership.notOwned;
    } catch (_) {
      return DownloadRuntimeOwnership.unknown;
    }
  }
'''
transport = replace_once(
    transport, old_ownership, new_ownership, "transport ownershipFor"
)

pause_anchor = '''  @override
  Future<bool> pause(DownloadTask task) async {
'''
restart_method = '''  /// Replaces a stale zero-byte package-owned generation with [task].
  ///
  /// background_downloader owns cleanup and child recreation: cancel settles
  /// the old Transfer and its package-managed pause/resume state, then
  /// Transfers.start creates a fresh generation from the refreshed task.
  Future<bool> restartFromZero(DownloadTask task) async {
    if (!isBackgroundDownloaderTransportTask(task)) return false;
    try {
      var existing = handleFor(task.taskId);
      if (existing == null) {
        await _downloader.transfers.rehydrateFromDatabase(group: task.group);
        existing = handleFor(task.taskId);
      }

      if (existing != null && !existing.status.isFinalState) {
        if (!await existing.cancel()) return false;
        final settled = await existing.result.timeout(
          const Duration(seconds: 5),
        );
        if (!settled.status.isFinalState) return false;
      }

      final ownership = await ownershipFor(task.taskId);
      if (ownership.blocksNewWriter) return false;

      _detach(task.taskId);
      _downloader.transfers.remove(task.taskId);
      final replacement = await _downloader.transfers.start(task);
      _attach(replacement);
      return runtimeTaskStatusCanOwnWriter(replacement.status) ||
          replacement.status == TaskStatus.complete;
    } catch (_) {
      return false;
    }
  }

'''
transport = replace_once(
    transport, pause_anchor, restart_method + pause_anchor, "transport pause anchor"
)
transport_path.write_text(transport)

service_path = Path("lib/core/services/download_service.dart")
service = service_path.read_text()

old_guard = '''    if (!legacySessionExists && hasOpaqueNativeResume && partialBytes <= 0) {
      // background_downloader 9.6.1 owns plugin resume/re-enqueue. Its
      // ParallelDownloadTask resume payload, however, contains the original
      // child task descriptors and there is no public API to rewrite those
      // child URLs. Never migrate that plugin state into AnimeWitcher's legacy
      // executor and never discard opaque bytes silently. A user-visible
      // restart decision is safer until the plugin exposes source replacement
      // for paused parallel chunks.
      return (task: task, refreshed: false, restartRequired: true);
    }

'''
replacement_guard = '''    // A refreshed zero-byte plugin generation has no durable bytes to lose.
    // Replace that generation through background_downloader itself so stale
    // child URLs and pause/resume state never leak into the refreshed source.
    final restartPluginFromZero =
        !legacySessionExists && partialBytes <= 0;
    final updated = legacySessionExists
        ? task
        : task.copyWith(
            url: refreshed.url,
            headers: Map<String, String>.from(refreshed.headers),
          );

'''
service = replace_once(service, old_guard, replacement_guard, "zero-byte refresh guard")

old_checkpoint = '''    final refreshCheckpointed = await _checkpointLogicalJob(
      task,
      state: DownloadJobState.interrupted,
      expectedBytes: expectedBytes,
'''
new_checkpoint = '''    final refreshCheckpointed = await _checkpointLogicalJob(
      updated,
      state: DownloadJobState.interrupted,
      durableBytes: partialBytes,
      durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
      expectedBytes: expectedBytes,
'''
service = replace_once(
    service, old_checkpoint, new_checkpoint, "source refresh checkpoint"
)

old_updated = '''    final updated = task.copyWith(
      url: refreshed.url,
      headers: Map<String, String>.from(refreshed.headers),
    );
'''
service = replace_once(service, old_updated, "", "duplicate refreshed task")

record_anchor = '''    final record = await FileDownloader().database.recordForId(task.taskId);
'''
restart_block = '''    if (restartPluginFromZero) {
      final restarted = await _nativeTransport.restartFromZero(updated);
      diagnosticLog.record('source.refreshPluginRestart', {
        'taskId': task.taskId,
        'accepted': restarted,
        'opaqueNativeResume': hasOpaqueNativeResume,
      });
      return (
        task: updated,
        refreshed: true,
        restartRequired: !restarted,
      );
    }

'''
# Insert only in the source-refresh tail, after legacy replacement handling.
source_refresh_start = service.index("  Future<({DownloadTask task, bool refreshed, bool restartRequired})>")
record_index = service.index(record_anchor, source_refresh_start)
service = service[:record_index] + restart_block + service[record_index:]

old_reconcile = '''  Future<void> _reconcileTransferOwnership() async {
    await _parallel.reconcile(_livePartIds);
    final liveIds = await _livePartIds();
    for (final record in await FileDownloader().database.allRecords()) {
      if (!isLogicalEpisodeDownloadTask(record.task) ||
          _queueWaitingIds.contains(record.taskId) ||
          _startingTaskIds.contains(record.taskId) ||
          liveIds.contains(record.taskId) ||
          _parallel.isActive(record.taskId) ||
          !isLiveNativeDownloadStatus(record.status))
        continue;
      final task = record.task as DownloadTask;
      final saved = await _savedProgressFor(task);
      await FileDownloader().database.updateRecord(
        TaskRecord(task, TaskStatus.paused, saved.progress, saved.totalSize),
      );
      _publishProgress(
        trackingUrl: downloadTrackingUrl(task),
        taskId: task.taskId,
        progress: saved.progress,
        totalSize: saved.totalSize,
        status: TaskStatus.paused,
      );
      _updatesController.add(TaskStatusUpdate(task, TaskStatus.paused));
    }
  }
'''
new_reconcile = '''  Future<void> _reconcileTransferOwnership() async {
    await _parallel.reconcile(_livePartIds);
    for (final record in await FileDownloader().database.allRecords()) {
      if (!isLogicalEpisodeDownloadTask(record.task) ||
          _queueWaitingIds.contains(record.taskId) ||
          _startingTaskIds.contains(record.taskId) ||
          _parallel.isActive(record.taskId) ||
          !isLiveNativeDownloadStatus(record.status)) {
        continue;
      }
      final ownership = await _runtimeOwnershipFor(record.taskId);
      if (ownership != DownloadRuntimeOwnership.notOwned) continue;
      final task = record.task as DownloadTask;
      final saved = await _savedProgressFor(task);
      await FileDownloader().database.updateRecord(
        TaskRecord(task, TaskStatus.paused, saved.progress, saved.totalSize),
      );
      _publishProgress(
        trackingUrl: downloadTrackingUrl(task),
        taskId: task.taskId,
        progress: saved.progress,
        totalSize: saved.totalSize,
        status: TaskStatus.paused,
      );
      _updatesController.add(TaskStatusUpdate(task, TaskStatus.paused));
    }
  }
'''
service = replace_once(
    service, old_reconcile, new_reconcile, "transfer ownership reconciliation"
)
service_path.write_text(service)
