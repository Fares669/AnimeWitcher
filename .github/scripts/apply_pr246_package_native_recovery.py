from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def replace_once_or_keep(
    text: str,
    old: str,
    new: str,
    *,
    applied_marker: str,
    label: str,
) -> str:
    if applied_marker in text:
        return text
    return replace_once(text, old, new, label)


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
transport = replace_once_or_keep(
    transport,
    old_ownership,
    new_ownership,
    applied_marker="final transfer = handleFor(taskId);",
    label="transport ownershipFor",
)

pause_anchor = '''  @override
  Future<bool> pause(DownloadTask task) async {
'''
restart_method = '''  /// Replaces a stale zero-byte package-owned generation with [task].
  ///
  /// background_downloader owns cleanup, duplicate lookup, and child
  /// recreation: cancel settles the old Transfer and its package-managed
  /// pause/resume state, then getOrStart creates or reattaches the refreshed
  /// generation without permitting a duplicate writer.
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
      final replacement = await _downloader.transfers.getOrStart(
        task,
        matchBy: (existingTask) => existingTask.taskId == task.taskId,
        reEnqueueIfFailed: true,
      );
      _attach(replacement);
      return runtimeTaskStatusCanOwnWriter(replacement.status) ||
          replacement.status == TaskStatus.complete;
    } catch (_) {
      return false;
    }
  }

'''
if "Future<bool> restartFromZero(" not in transport:
    transport = replace_once(
        transport,
        pause_anchor,
        restart_method + pause_anchor,
        "transport pause anchor",
    )
transport_path.write_text(transport)

service_path = Path("lib/core/services/download_service.dart")
service = service_path.read_text()

refreshing_field = '''  final Set<String> _refreshingParallelParentIds = <String>{};
'''
source_replacing_field = '''  final Set<String> _refreshingParallelParentIds = <String>{};
  final Set<String> _sourceReplacingTaskIds = <String>{};
'''
service = replace_once_or_keep(
    service,
    refreshing_field,
    source_replacing_field,
    applied_marker="final Set<String> _sourceReplacingTaskIds = <String>{};",
    label="source replacement fence field",
)

pause_intent_guard = '''      if (_userPausedIds.contains(update.task.taskId) ||
          _dequeuingPausedIds.contains(update.task.taskId)) {
        return;
      }

'''
source_replacement_guard = pause_intent_guard + '''      // restartFromZero deliberately cancels the stale package generation.
      // That terminal callback belongs to the old signed URL, not to the
      // logical episode. Keep it behind the source-replacement fence while
      // background_downloader settles and starts the refreshed Transfer.
      if (update is TaskStatusUpdate &&
          _sourceReplacingTaskIds.contains(update.task.taskId) &&
          (update.status == TaskStatus.failed ||
              update.status == TaskStatus.canceled ||
              update.status == TaskStatus.notFound)) {
        diagnosticLog.record('source.staleGenerationTerminalIgnored', {
          'taskId': update.task.taskId,
          'status': update.status.name,
        });
        return;
      }

'''
service = replace_once_or_keep(
    service,
    pause_intent_guard,
    source_replacement_guard,
    applied_marker="source.staleGenerationTerminalIgnored",
    label="source replacement callback fence",
)

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
replacement_guard = '''    // A refreshed zero-byte package generation has no durable bytes to lose.
    // Keep source identity in AnimeWitcher, but delegate stale resume cleanup,
    // child recreation and duplicate suppression to background_downloader.
    final restartPluginFromZero =
        !legacySessionExists && hasOpaqueNativeResume && partialBytes <= 0;
    final updated = task.copyWith(
      url: refreshed.url,
      headers: Map<String, String>.from(refreshed.headers),
    );

'''
service = replace_once_or_keep(
    service,
    old_guard,
    replacement_guard,
    applied_marker="final restartPluginFromZero =",
    label="zero-byte refresh guard",
)

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
service = replace_once_or_keep(
    service,
    old_checkpoint,
    new_checkpoint,
    applied_marker="durableByteProvenance: DownloadDurableByteProvenance.exactDisk,\n      expectedBytes: expectedBytes,",
    label="source refresh checkpoint",
)

source_refresh_start = service.index(
    "  Future<({DownloadTask task, bool refreshed, bool restartRequired})>"
)
legacy_index = service.index("    if (legacySessionExists) {", source_refresh_start)
old_updated = '''    final updated = task.copyWith(
      url: refreshed.url,
      headers: Map<String, String>.from(refreshed.headers),
    );
'''
# After applying replacement_guard, only the later duplicate remains. Remove it
# exactly once before installing restartFromZero. On subsequent runs the restart
# marker makes this section a no-op.
if "source.refreshPluginRestart" not in service:
    old_updated_index = service.index(old_updated, legacy_index)
    service = (
        service[:old_updated_index]
        + service[old_updated_index + len(old_updated) :]
    )

record_anchor = '''    final record = await FileDownloader().database.recordForId(task.taskId);
'''
restart_block = '''    if (restartPluginFromZero) {
      _sourceReplacingTaskIds.add(task.taskId);
      try {
        final restarted = await _nativeTransport.restartFromZero(updated);
        diagnosticLog.record('source.refreshPluginRestart', {
          'taskId': task.taskId,
          'accepted': restarted,
          'opaqueNativeResume': hasOpaqueNativeResume,
        });
        if (!restarted) {
          return (task: updated, refreshed: true, restartRequired: true);
        }
        return (task: updated, refreshed: true, restartRequired: false);
      } finally {
        // Let any already-queued terminal callback from the canceled stale
        // generation drain while the fence is still active.
        await Future<void>.delayed(Duration.zero);
        _sourceReplacingTaskIds.remove(task.taskId);
      }
    }

'''
if "source.refreshPluginRestart" not in service:
    record_index = service.index(record_anchor, legacy_index)
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
service = replace_once_or_keep(
    service,
    old_reconcile,
    new_reconcile,
    applied_marker="final ownership = await _runtimeOwnershipFor(record.taskId);",
    label="transfer ownership reconciliation",
)
service_path.write_text(service)
