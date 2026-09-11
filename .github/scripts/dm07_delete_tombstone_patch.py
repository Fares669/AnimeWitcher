from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise SystemExit(f'{label}: expected exactly one match, got {text.count(old)}')
    return text.replace(old, new, 1)


def replace_between(text: str, start: str, end: str, replacement: str, label: str) -> str:
    i = text.find(start)
    if i < 0:
        raise SystemExit(f'{label}: missing start')
    j = text.find(end, i + len(start))
    if j < 0:
        raise SystemExit(f'{label}: missing end')
    return text[:i] + replacement + text[j:]


job_path = Path('lib/core/services/download_job_store.dart')
job = job_path.read_text()
job = replace_once(
    job,
    'const int kDownloadJobSchemaVersion = 6;\n',
    '''const int kDownloadJobSchemaVersion = 6;\n\n'''
    '''/// User-delete tombstones stay durable long enough to fence late native\n'''
    '''/// callbacks across relaunches. Cleanup may happen immediately after\n'''
    '''/// ownership settlement; only the tombstone itself is age-gated for GC.\n'''
    '''const Duration kDownloadCanceledTombstoneRetention = Duration(days: 30);\n\n'''
    '''bool downloadCanceledTombstoneEligibleForGc(\n'''
    '''  DownloadJobRecord job, {\n'''
    '''  required int nowMillis,\n'''
    '''  required bool ownershipReleased,\n'''
    '''  required bool pluginRecordAbsent,\n'''
    '''  required bool metadataAbsent,\n'''
    '''}) {\n'''
    '''  if (job.state != DownloadJobState.canceled || job.generation <= 0) {\n'''
    '''    return false;\n'''
    '''  }\n'''
    '''  if (!ownershipReleased || !pluginRecordAbsent || !metadataAbsent) {\n'''
    '''    return false;\n'''
    '''  }\n'''
    '''  final ageMillis = nowMillis - job.updatedAtMillis;\n'''
    '''  return ageMillis >= kDownloadCanceledTombstoneRetention.inMilliseconds;\n'''
    '''}\n''',
    'insert tombstone retention policy',
)
job = replace_once(
    job,
    '  /// Start a new execution generation atomically. The durable bytes and\n',
    '''  /// Persist the explicit user-delete terminal fact before touching any\n'''
    '''  runtime owner. This is the only transition allowed to convert another\n'''
    '''  terminal state (for example completed) into canceled. Ordinary writes\n'''
    '''  remain protected by [_putUnlocked]'s terminal fence.\n'''
    '''  Future<DownloadAttemptToken?> tombstoneForDeletion(\n'''
    '''    DownloadJobRecord seed, {\n'''
    '''    int? updatedAtMillis,\n'''
    '''  }) => _serialize(() async {\n'''
    '''    final taskId = seed.taskId.trim();\n'''
    '''    final trackingUrl = seed.trackingUrl.trim();\n'''
    '''    if (taskId.isEmpty || trackingUrl.isEmpty) return null;\n'''
    '''    if (seed.generation < 0 || seed.durableBytes < 0) return null;\n\n'''
    '''    final current = await get(taskId);\n'''
    '''    final seedLogicalId = _nonEmptyString(seed.logicalId);\n'''
    '''    final currentLogicalId = _nonEmptyString(current?.logicalId);\n'''
    '''    if (current != null) {\n'''
    '''      if (current.trackingUrl != trackingUrl) return null;\n'''
    '''      if (currentLogicalId != null &&\n'''
    '''          seedLogicalId != null &&\n'''
    '''          currentLogicalId != seedLogicalId) {\n'''
    '''        return null;\n'''
    '''      }\n'''
    '''      if (current.state == DownloadJobState.canceled) {\n'''
    '''        return current.attemptToken;\n'''
    '''      }\n'''
    '''    }\n\n'''
    '''    final base = current ?? seed;\n'''
    '''    final next = base.copyWith(\n'''
    '''      logicalId: currentLogicalId ?? seedLogicalId,\n'''
    '''      state: DownloadJobState.canceled,\n'''
    '''      generation: base.generation + 1,\n'''
    '''      userPaused: false,\n'''
    '''      queueWaiting: false,\n'''
    '''      updatedAtMillis:\n'''
    '''          updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch,\n'''
    '''    );\n'''
    '''    // Intentionally bypass the generic terminal-transition rejection.\n'''
    '''    // Every other identity/byte field is inherited from the current row.\n'''
    '''    await backend.write(taskId, next.toJson());\n'''
    '''    return next.attemptToken;\n'''
    '''  });\n\n'''
    '''  /// Start a new execution generation atomically. The durable bytes and\n''',
    'insert explicit delete tombstone API',
)
job_path.write_text(job)

service_path = Path('lib/core/services/download_service.dart')
service = service_path.read_text()

cancel_replacement = r'''  Future<void> cancelDownload(
    String taskId,
    String trackingUrl, {
    bool notifyContinuedProcessing = true,
  }) async {
    await _awaitCommandReadiness('cancelDownload');
    diagnosticLog.record('command.cancel', {'taskId': taskId});

    final storage = _ref.read(storageServiceProvider);
    final existingJob = await _jobStore.get(taskId);
    final parentRecord = await FileDownloader().database.recordForId(taskId);
    DownloadTask? cancelTask = parentRecord?.task is DownloadTask
        ? parentRecord!.task as DownloadTask
        : await _liveNativeTaskFor(taskId: taskId, trackingUrl: trackingUrl);

    // The durable delete fact is written before any executor stop/cancel. The
    // tombstone itself advances the DM-10 generation fence and is idempotent on
    // repeated delete commands.
    DownloadJobRecord? deletionSeed = existingJob;
    if (deletionSeed == null) {
      var durableBytes = 0;
      var expectedBytes = -1;
      Map<String, dynamic>? taskSnapshot;
      String? logicalId;
      if (cancelTask != null) {
        final saved = await _savedProgressFor(cancelTask);
        durableBytes = saved.partialBytes > 0 ? saved.partialBytes : 0;
        expectedBytes = saved.totalSize;
        taskSnapshot = cancelTask.toJson();
        logicalId = logicalDownloadIdFromMetadata(
          await storage.getDownloadMetadata(taskId),
        );
      }
      final stableTrackingUrl = trackingUrl.trim().isNotEmpty
          ? trackingUrl.trim()
          : (cancelTask == null ? '' : downloadTrackingUrl(cancelTask));
      if (stableTrackingUrl.isNotEmpty) {
        deletionSeed = DownloadJobRecord(
          taskId: taskId,
          logicalId: logicalId,
          trackingUrl: stableTrackingUrl,
          state: DownloadJobState.canceled,
          generation: 0,
          durableBytes: durableBytes,
          durableByteProvenance: durableBytes > 0
              ? DownloadDurableByteProvenance.exactDisk
              : DownloadDurableByteProvenance.none,
          expectedBytes: expectedBytes,
          userPaused: false,
          queueWaiting: false,
          updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
          taskSnapshot: taskSnapshot,
        );
      }
    }
    if (deletionSeed != null) {
      final tombstone = await _jobStore.tombstoneForDeletion(deletionSeed);
      if (tombstone == null) {
        throw StateError('Failed to persist delete tombstone for $taskId');
      }
    }

    // UI/session projections may disappear after the terminal fact is durable,
    // but destructive storage cleanup stays behind ownership settlement.
    _terminalJobIds.add(taskId);
    _queueWaitingIds.remove(taskId);
    _waitingPayloads.remove(taskId);
    _forgetSessionTask(taskId);
    _userPausedIds.remove(taskId);
    _dequeuingPausedIds.remove(taskId);
    _ref.read(activeDownloadsProvider.notifier).remove(trackingUrl);
    _ref.read(downloadProgressProvider.notifier).remove(trackingUrl);
    _ref.read(downloadChunkProgressProvider.notifier).remove(taskId);
    _telemetry.remove(taskId);
    _expectedSizePersistedIds.remove(taskId);

    await _rangeTransfers.stop(taskId);
    await _serializeQueue(() async {
      _queueWaitingIds.remove(taskId);
      _waitingPayloads.remove(taskId);
      _forgetSessionTask(taskId);
      final ids = <String>{taskId};
      for (final task in await FileDownloader().allTasks(allGroups: true)) {
        if (task.taskId == taskId || downloadTrackingUrl(task) == trackingUrl) {
          ids.add(task.taskId);
        }
      }
      if (parentRecord?.task is ParallelDownloadTask) {
        await _parallel.cancel(parentRecord!.task as ParallelDownloadTask);
      } else if (parentRecord?.task is DownloadTask &&
          isNativeSingleDownloadTask(parentRecord!.task)) {
        final settlement = await _nativeTransport.cancel(
          parentRecord.task as DownloadTask,
        );
        diagnosticLog.record('cancel.commandSettlement', {
          'taskId': taskId,
          'settlement': settlement.name,
        });
        ids.remove(taskId);
      }
      if (ids.isNotEmpty) {
        await FileDownloader().cancelTasksWithIds(ids.toList());
      }

      final cancelOwnership = await _waitForCancelOwnershipRelease(taskId);
      if (cancelOwnership != DownloadRuntimeOwnership.notOwned) {
        diagnosticLog.record('cancel.ownershipUnsettled', {
          'taskId': taskId,
          'ownership': cancelOwnership.name,
        });
        await _persistNativeWaitingSnapshot();
        if (notifyContinuedProcessing) {
          await _syncSessionOverlay(completedSuccess: false);
        }
        return;
      }

      _nativeTransport.forget(taskId);
      _userPausedIds.remove(taskId);
      _dequeuingPausedIds.remove(taskId);
      _ref.read(activeDownloadsProvider.notifier).remove(trackingUrl);
      _ref.read(downloadProgressProvider.notifier).remove(trackingUrl);
      await FileDownloader().database.deleteRecordWithId(taskId);
      await storage.removeDownloadMetadata(taskId);
      await _ref.read(downloadUrlRefreshStoreProvider).remove(trackingUrl);
      // Keep the canceled JobStore row. It is the durable fence against late
      // complete/running callbacks and is GC'd only by the age+ownership policy.
      await _syncQueueToCapUnlocked();
      if (notifyContinuedProcessing) {
        await _syncSessionOverlay(completedSuccess: false);
      }
    });
  }

'''
service = replace_between(
    service,
    '  Future<void> cancelDownload(\n',
    '  Future<DownloadCommandOutcome> cancelDownloadOutcome(\n',
    cancel_replacement,
    'replace cancel with tombstone-first transaction',
)

insert_delete = r'''  Future<DownloadCommandOutcome> deleteDownloadOutcome(
    Task task,
    MultimediaItem item, {
    Episode? episode,
    bool notifyContinuedProcessing = true,
  }) async {
    final filesToDelete = <String, File>{};
    try {
      final directPath = await task.filePath();
      if (directPath.isNotEmpty) filesToDelete[directPath] = File(directPath);
    } catch (_) {}
    try {
      final resolved = await resolveDownloadedFile(task, item, episode: episode);
      if (resolved != null) filesToDelete[resolved.path] = resolved;
    } catch (_) {}

    final outcome = await cancelDownloadOutcome(
      task.taskId,
      downloadTrackingUrl(task),
      notifyContinuedProcessing: notifyContinuedProcessing,
    );
    final safeToDestroy = switch (outcome) {
      DownloadCommandOutcome.terminal ||
      DownloadCommandOutcome.alreadyComplete ||
      DownloadCommandOutcome.missingState => true,
      _ => false,
    };
    if (!safeToDestroy) return outcome;

    final ownership = await _runtimeOwnershipFor(task.taskId);
    if (ownership != DownloadRuntimeOwnership.notOwned) {
      return DownloadCommandOutcome.settlingOwnership;
    }

    var cleanupFailed = false;
    for (final file in filesToDelete.values) {
      try {
        if (await file.exists() && !await deleteDownloadedFile(file)) {
          cleanupFailed = true;
        }
      } catch (_) {
        cleanupFailed = true;
      }
    }
    return cleanupFailed
        ? DownloadCommandOutcome.recoverableFailure
        : DownloadCommandOutcome.terminal;
  }

'''
service = replace_once(
    service,
    '  Future<DownloadCommandOutcome> pauseDownloadOutcome(String taskId) async {\n',
    insert_delete + '  Future<DownloadCommandOutcome> pauseDownloadOutcome(String taskId) async {\n',
    'insert service-owned delete outcome',
)

gc_method = r'''  Future<void> _garbageCollectCanceledTombstones() async {
    final storage = _ref.read(storageServiceProvider);
    final refreshStore = _ref.read(downloadUrlRefreshStoreProvider);
    final nowMillis = DateTime.now().millisecondsSinceEpoch;
    for (final job in await _jobStore.all()) {
      if (job.state != DownloadJobState.canceled) continue;
      final ownership = await _runtimeOwnershipFor(job.taskId);
      if (ownership != DownloadRuntimeOwnership.notOwned) continue;

      // Cleanup is idempotent and may be retried on every recovery. It never
      // runs while a writer might still own the destination.
      try {
        await FileDownloader().database.deleteRecordWithId(job.taskId);
      } catch (_) {}
      try {
        await storage.removeDownloadMetadata(job.taskId);
      } catch (_) {}
      try {
        await refreshStore.remove(job.trackingUrl);
      } catch (_) {}
      final restored = job.restoreTaskSnapshot();
      if (restored != null) {
        try {
          final path = await restored.filePath();
          if (path.isNotEmpty) {
            final file = File(path);
            if (await file.exists()) await deleteDownloadedFile(file);
          }
        } catch (_) {}
      }

      final pluginRecordAbsent =
          await FileDownloader().database.recordForId(job.taskId) == null;
      final metadataAbsent =
          await storage.getDownloadMetadata(job.taskId) == null;
      if (downloadCanceledTombstoneEligibleForGc(
        job,
        nowMillis: nowMillis,
        ownershipReleased: true,
        pluginRecordAbsent: pluginRecordAbsent,
        metadataAbsent: metadataAbsent,
      )) {
        await _jobStore.remove(job.taskId);
      }
    }
  }

'''
service = replace_once(
    service,
    '    await _syncQueueToCapUnlocked();\n    await _syncSessionOverlay();\n  }\n\n  Future<int> _occupiedSlotCount(',
    '    await _syncQueueToCapUnlocked();\n    await _syncSessionOverlay();\n    await _garbageCollectCanceledTombstones();\n  }\n\n' + gc_method + '  Future<int> _occupiedSlotCount(',
    'insert startup tombstone cleanup/gc',
)
service_path.write_text(service)

provider_path = Path('lib/features/library/presentation/downloads_provider.dart')
provider = provider_path.read_text()
provider = replace_once(
    provider,
    "import 'dart:io';\n",
    '',
    'remove UI filesystem import',
)
provider_replacement = r'''  Future<void> removeDownloads(List<DownloadItem> items) async {
    if (items.isEmpty) return;
    final downloadService = ref.read(downloadServiceProvider);
    final current = List<DownloadItem>.from(state.value ?? items);

    final toRemove = <String, DownloadItem>{};
    for (final requested in items) {
      toRemove[requested.id] = requested;
      for (final candidate in current) {
        if (downloadsPointAtSameTarget(requested, candidate)) {
          toRemove[candidate.id] = candidate;
        }
      }
    }

    // Presentation submits a delete command only. Tombstone persistence,
    // ownership settlement and DB/metadata/video destruction are service-owned.
    for (final item in toRemove.values) {
      final outcome = await downloadService
          .deleteDownloadOutcome(
            item.task,
            item.item,
            episode: item.episode,
            notifyContinuedProcessing: false,
          )
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => DownloadCommandOutcome.settlingOwnership,
          );
      final safeToHide = switch (outcome) {
        DownloadCommandOutcome.terminal ||
        DownloadCommandOutcome.alreadyComplete ||
        DownloadCommandOutcome.missingState => true,
        _ => false,
      };
      if (!safeToHide) {
        state = AsyncData(await _refreshList());
        return;
      }
    }

    final droppedIds = toRemove.keys.toSet();
    _deletingIds.addAll(droppedIds);
    for (final id in droppedIds) {
      _lastProgressUiUpdate.remove(id);
    }
    if (state.value != null) {
      state = AsyncData(
        state.value!.where((item) => !droppedIds.contains(item.id)).toList(),
      );
    }

    for (final item in toRemove.values) {
      final trackingUrl = downloadTrackingUrl(item.task);
      ref.read(activeDownloadsProvider.notifier).remove(trackingUrl);
      ref.read(downloadProgressProvider.notifier).remove(trackingUrl);
      ref.read(downloadChunkProgressProvider.notifier).remove(item.id);
      // Artwork is presentation cache, not lifecycle authority. DM-12 will
      // remove the remaining presentation-owned cache mutation separately.
      try {
        await deleteDownloadedEpisodeArtwork(item.id);
      } catch (_) {}
    }
  }

'''
provider = replace_between(
    provider,
    '  Future<void> removeDownloads(List<DownloadItem> items) async {\n',
    '  void _setOptimisticStatus(',
    provider_replacement,
    'move delete orchestration out of provider',
)
provider_path.write_text(provider)

# Assertions make patch drift fail loudly instead of producing a partial fix.
job_check = job_path.read_text()
service_check = service_path.read_text()
provider_check = provider_path.read_text()
for needle in (
    'tombstoneForDeletion(',
    'kDownloadCanceledTombstoneRetention',
    'downloadCanceledTombstoneEligibleForGc(',
):
    if needle not in job_check:
        raise SystemExit(f'missing JobStore DM-07 marker: {needle}')
if '_jobStore.remove(taskId)' in service_check[service_check.index('  Future<void> cancelDownload('):service_check.index('  Future<DownloadCommandOutcome> cancelDownloadOutcome(')]:
    raise SystemExit('cancelDownload still removes tombstone')
for forbidden in (
    'FileDownloader().database.deleteRecordWithId',
    'removeDownloadMetadata(',
    '.deleteDownloadedFile(',
    'file.delete(recursive: true)',
):
    body = provider_check[provider_check.index('  Future<void> removeDownloads('):provider_check.index('  void _setOptimisticStatus(')]
    if forbidden in body:
        raise SystemExit(f'provider still owns destructive lifecycle cleanup: {forbidden}')
