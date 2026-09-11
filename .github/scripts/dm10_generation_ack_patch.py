from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f'missing patch target: {label}')
    return text.replace(old, new, 1)


store_path = Path('lib/core/services/download_job_store.dart')
store = store_path.read_text()

store = replace_once(
    store,
    """      if (current.state == DownloadJobState.completed &&
          next.state != DownloadJobState.completed) {
        return false;
      }
""",
    """      // Every terminal logical state is generation-fenced. A newer
      // executor callback may never reopen a canceled/orphaned/completed job;
      // only the explicit tombstone/file cleanup transaction may remove it.
      if (downloadJobIsTerminal(current.state) && next.state != current.state) {
        return false;
      }
""",
    'terminal put fence',
)

old_begin = """  /// Start a new execution generation atomically. The durable bytes and
  /// fingerprint are inherited; beginning an attempt can never reset progress.
  Future<DownloadAttemptToken?> beginAttempt(
    String taskId, {
    DownloadJobState state = DownloadJobState.starting,
    int? updatedAtMillis,
  }) => _serialize(() async {
    final current = await get(taskId);
    if (current == null || current.state == DownloadJobState.completed) {
      return null;
    }
    final next = current.copyWith(
      state: state,
      generation: current.generation + 1,
      updatedAtMillis: updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch,
    );
    if (!await _putUnlocked(next)) return null;
    return next.attemptToken;
  });
"""
new_begin = """  /// Start a new execution generation atomically. The durable bytes and
  /// fingerprint are inherited; beginning an attempt can never reset progress.
  Future<DownloadAttemptToken?> beginAttempt(
    String taskId, {
    DownloadJobState state = DownloadJobState.starting,
    int? updatedAtMillis,
  }) => _serialize(
    () => _beginGenerationUnlocked(
      taskId,
      state: state,
      updatedAtMillis: updatedAtMillis,
    ),
  );

  /// Advance the same durable generation fence for an ownership-changing
  /// control operation (pause/resume/cancel/restack/source replacement).
  ///
  /// Native callbacks do not all carry an operation id, so service-side
  /// state/ownership acknowledgement still gates their projection. Advancing
  /// this generation additionally makes every token-aware Range/multipart
  /// callback from the previous operation stale before the executor effect.
  Future<DownloadAttemptToken?> beginOperation(
    String taskId, {
    required DownloadJobState state,
    int? updatedAtMillis,
  }) => _serialize(
    () => _beginGenerationUnlocked(
      taskId,
      state: state,
      updatedAtMillis: updatedAtMillis,
    ),
  );

  Future<DownloadAttemptToken?> _beginGenerationUnlocked(
    String taskId, {
    required DownloadJobState state,
    int? updatedAtMillis,
  }) async {
    final current = await get(taskId);
    if (current == null || downloadJobIsTerminal(current.state)) return null;
    final next = current.copyWith(
      state: state,
      generation: current.generation + 1,
      updatedAtMillis: updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch,
    );
    if (!await _putUnlocked(next)) return null;
    return next.attemptToken;
  }
"""
store = replace_once(store, old_begin, new_begin, 'beginOperation API')
store_path.write_text(store)

service_path = Path('lib/core/services/download_service.dart')
service = service_path.read_text()

service = replace_once(
    service,
    '  final Set<String> _cancellingUrls = {};\n',
    '',
    'remove cancelling URL timer fence',
)
service = replace_once(
    service,
    '  final Set<String> _restackingWaiterIds = {};\n',
    '',
    'remove restack timer fence',
)

service = replace_once(
    service,
    """    if (_userPausedIds.contains(taskId) ||
        _terminalJobIds.contains(taskId) ||
        _cancellingUrls.contains(trackingUrl)) {
      return;
    }
""",
    """    if (_userPausedIds.contains(taskId) || _terminalJobIds.contains(taskId)) {
      return;
    }
""",
    'native progress terminal fence',
)

restack_listener = """      // Restacking later HQ waiters behind a resumed episode. Swallow only
      // the cancel/fail from the old native task so re-enqueue events pass.
      if (_restackingWaiterIds.contains(update.task.taskId)) {
        if (update is TaskStatusUpdate &&
            (update.status == TaskStatus.canceled ||
                update.status == TaskStatus.failed ||
                update.status == TaskStatus.notFound)) {
          return;
        }
        if (update is TaskProgressUpdate &&
            (update.progress < 0 || update.progress > 1)) {
          return;
        }
      }

"""
service = replace_once(service, restack_listener, '', 'remove restack callback timer set')

cancel_listener = """      // User-initiated cancels are cleaned up in [cancelDownload]; ignore their
      // follow-up events so they cannot race with pause-on-failure handling.
      if (_cancellingUrls.contains(trackingUrl)) {
        if (update is TaskStatusUpdate &&
            update.status == TaskStatus.canceled) {
          _updatesController.add(update);
        }
        return;
      }

"""
service = replace_once(service, cancel_listener, '', 'remove URL cancellation timer set')
service = service.replace(
    'userCancel: _cancellingUrls.contains(trackingUrl),',
    'userCancel: _terminalJobIds.contains(update.task.taskId),',
)

park_block = """      if (update is TaskStatusUpdate &&
          shouldParkSystemCanceledDownload(
            status: update.status,
            userCancel: _terminalJobIds.contains(update.task.taskId),
          )) {
        unawaited(_retainLiveNativeOrPause(update, trackingUrl));
        return;
      }

      _updatesController.add(update);
"""
park_replacement = """      if (update is TaskStatusUpdate &&
          shouldParkSystemCanceledDownload(
            status: update.status,
            userCancel: _terminalJobIds.contains(update.task.taskId),
          )) {
        unawaited(_retainLiveNativeOrPause(update, trackingUrl));
        return;
      }

      // Completion is the one terminal callback that may be safe even when it
      // belongs to an older executor generation, but only after DM-06 proves
      // the final artifact against independent resource evidence. Never publish
      // `complete` to UI/listeners before that verification commits JobStore.
      if (update is TaskStatusUpdate &&
          update.status == TaskStatus.complete) {
        unawaited(_handleVerifiedCompleteUpdate(update, trackingUrl));
        return;
      }

      // A delayed pause acknowledgement from an earlier control generation
      // cannot regress a writer that is already owned by the resumed/current
      // execution. Runtime ownership is the acknowledgement, not elapsed time.
      if (update is TaskStatusUpdate &&
          update.status == TaskStatus.paused &&
          (_rangeTransfers.isActive(update.task.taskId) ||
              _parallel.isActive(update.task.taskId) ||
              _nativeTransport.owns(update.task.taskId))) {
        diagnosticLog.record('callback.stalePauseIgnored', {
          'taskId': update.task.taskId,
        });
        return;
      }

      _updatesController.add(update);
"""
service = replace_once(service, park_block, park_replacement, 'status callback acknowledgement fence')

helper_anchor = """  void _handleStatusUpdate(TaskStatusUpdate update, String trackingUrl) {
"""
helper = """  Future<void> _handleVerifiedCompleteUpdate(
    TaskStatusUpdate update,
    String trackingUrl,
  ) async {
    final current = _ref.read(downloadProgressProvider)[trackingUrl];
    if (!isCompleteDownloadCredible(
      progress: current?.progress,
      expectedBytes: current?.totalSize ?? -1,
    )) {
      diagnosticLog.record('callback.stubCompleteIgnored', {
        'taskId': update.task.taskId,
      });
      await _attachUiToLiveNativeTasks();
      return;
    }

    await _persistCompletedFilePath(update.task);
    final job = await _jobStore.get(update.task.taskId);
    if (job?.state != DownloadJobState.completed) {
      diagnosticLog.record('callback.completeVerificationRejected', {
        'taskId': update.task.taskId,
        'generation': job?.generation,
        'state': job?.state.name,
      });
      return;
    }

    _updatesController.add(update);
    if (update.task is ParallelDownloadTask) {
      BackgroundDownloaderCompat.updateSyntheticNotification(
        update.task,
        update.status,
      );
    }
    _rememberSessionTask(update.task.taskId);
    _queueWaitingIds.remove(update.task.taskId);
    _waitingPayloads.remove(update.task.taskId);
    await _syncSessionOverlay(completedSuccess: true);
    _handleStatusUpdate(update, trackingUrl);
  }

"""
service = replace_once(service, helper_anchor, helper + helper_anchor, 'verified completion callback helper')

retain_anchor = """  Future<void> _retainLiveNativeOrPause(
    TaskStatusUpdate update,
    String trackingUrl,
  ) async {
    if (update.task is DownloadTask) {
"""
retain_replacement = """  Future<void> _retainLiveNativeOrPause(
    TaskStatusUpdate update,
    String trackingUrl,
  ) async {
    final authoritative = await _jobStore.get(update.task.taskId);
    if (authoritative != null &&
        (authoritative.state == DownloadJobState.queued ||
            authoritative.state == DownloadJobState.pausing ||
            authoritative.state == DownloadJobState.pausedByUser ||
            downloadJobIsTerminal(authoritative.state))) {
      diagnosticLog.record('callback.staleTerminalIgnored', {
        'taskId': update.task.taskId,
        'callback': update.status.name,
        'state': authoritative.state.name,
        'generation': authoritative.generation,
      });
      return;
    }
    if (update.task is DownloadTask) {
"""
service = replace_once(service, retain_anchor, retain_replacement, 'terminal callback logical state fence')

# Cancel: advance generation before any executor effect while preserving the
# existing write-ahead canceled checkpoint required by DM-21.
cancel_checkpoint_anchor = """    if (existingJob != null &&
        existingJob.state != DownloadJobState.completed) {
      if (cancelTask != null) {
"""
cancel_checkpoint_replacement = """    if (existingJob != null &&
        existingJob.state != DownloadJobState.completed) {
      final cancelOperation = await _jobStore.beginOperation(
        taskId,
        state: existingJob.state,
      );
      if (cancelOperation == null) {
        throw StateError('Failed to fence cancel operation for $taskId');
      }
      if (cancelTask != null) {
"""
service = replace_once(service, cancel_checkpoint_anchor, cancel_checkpoint_replacement, 'cancel generation')
service = replace_once(
    service,
    '    _cancellingUrls.add(trackingUrl);\n',
    '',
    'cancel URL projection removal',
)

service = replace_once(
    service,
    """    await _rangeTransfers.stop(taskId);
    try {
      await _serializeQueue(() async {
""",
    """    await _rangeTransfers.stop(taskId);
    await _serializeQueue(() async {
""",
    'cancel remove timed try wrapper',
)
service = replace_once(
    service,
    """      });
    } finally {
      // Small delay to let final updates clear
      Future.delayed(const Duration(milliseconds: 500), () {
        _cancellingUrls.remove(trackingUrl);
      });
    }
  }

  Future<DownloadCommandOutcome> cancelDownloadOutcome(
""",
    """    });
  }

  Future<DownloadCommandOutcome> cancelDownloadOutcome(
""",
    'cancel remove 500ms suppression',
)

# Pause: persist intent, then advance generation before stopping ownership. The
# settle acknowledgement commits through the token so a superseded pause cannot
# overwrite a later resume.
pause_checkpoint = """        if (!checkpointed) {
          throw StateError('Failed to persist pause intent for $taskId');
        }
        // Fence callbacks only after the durable pause intent exists. Ownership
"""
pause_checkpoint_replacement = """        if (!checkpointed) {
          throw StateError('Failed to persist pause intent for $taskId');
        }
        final pauseOperation = await _jobStore.beginOperation(
          taskId,
          state: DownloadJobState.pausing,
        );
        if (pauseOperation == null) {
          throw StateError('Failed to fence pause operation for $taskId');
        }
        // Fence callbacks only after the durable pause intent exists. Ownership
"""
service = replace_once(service, pause_checkpoint, pause_checkpoint_replacement, 'pause generation')

pause_final = """        await _checkpointLogicalJob(
          downloadTask,
          state: DownloadJobState.pausedByUser,
          expectedBytes: totalSize,
          userPaused: true,
          queueWaiting: false,
        );
        _publishProgress(
"""
pause_final_replacement = """        final pauseCommitted = await _jobStore.updateForAttempt(
          pauseOperation,
          state: DownloadJobState.pausedByUser,
          expectedBytes: totalSize,
          userPaused: true,
          queueWaiting: false,
        );
        if (!pauseCommitted) {
          diagnosticLog.record('pause.superseded', {'taskId': taskId});
          return;
        }
        _publishProgress(
"""
service = replace_once(service, pause_final, pause_final_replacement, 'pause ack commit')

# Resume command generation. _resumeDownloadTask advances again when it actually
# establishes a new executor attempt.
resume_checkpoint = """    if (!checkpointed) {
      throw StateError('Failed to persist resume intent for $taskId');
    }
    _userPausedIds.remove(taskId);
"""
resume_checkpoint_replacement = """    if (!checkpointed) {
      throw StateError('Failed to persist resume intent for $taskId');
    }
    final resumeOperation = await _jobStore.beginOperation(
      taskId,
      state: DownloadJobState.starting,
    );
    if (resumeOperation == null) {
      throw StateError('Failed to fence resume operation for $taskId');
    }
    _userPausedIds.remove(taskId);
"""
service = replace_once(service, resume_checkpoint, resume_checkpoint_replacement, 'resume generation')

service = replace_once(
    service,
    """    await _cancelNativeWaitersForRestackUnlocked(plan.waitersToRestack);
""",
    """    final waitersReadyForRestack =
        await _cancelNativeWaitersForRestackUnlocked(plan.waitersToRestack);
""",
    'restack settled list',
)
service = replace_once(
    service,
    """      for (final waiterId in plan.waitersToRestack) {
""",
    """      for (final waiterId in waitersReadyForRestack) {
""",
    'restack only acknowledged waiters',
)
service = replace_once(
    service,
    """
    Future<void>.delayed(const Duration(milliseconds: 800), () {
      _restackingWaiterIds.removeAll(plan.waitersToRestack);
    });

""",
    "\n",
    'remove 800ms restack suppression',
)

old_restack = """  Future<void> _cancelNativeWaitersForRestackUnlocked(List<String> ids) async {
    if (ids.isEmpty) return;
    final liveIds = <String>{};
    for (final task in await FileDownloader().allTasks(allGroups: true)) {
      if (!ids.contains(task.taskId)) continue;
      final record = await FileDownloader().database.recordForId(task.taskId);
      if (record != null &&
          reservesDownloadSlot(
            status: record.status,
            queueWaiting: _queueWaitingIds.contains(task.taskId),
          )) {
        continue;
      }
      liveIds.add(task.taskId);
    }
    if (liveIds.isEmpty) return;
    _restackingWaiterIds.addAll(liveIds);
    try {
      await FileDownloader().cancelTasksWithIds(liveIds.toList());
    } catch (_) {}
  }
"""
new_restack = """  Future<List<String>> _cancelNativeWaitersForRestackUnlocked(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const <String>[];

    // Advance the durable generation before canceling the old waiter identity.
    // This makes token-aware callbacks stale immediately. A waiter is eligible
    // for re-enqueue only after the runtime oracle independently acknowledges
    // that the old owner is gone.
    final ready = <String>[];
    for (final id in ids) {
      final job = await _jobStore.get(id);
      if (job == null) {
        // Migration-only fallback: no durable generation exists yet.
        ready.add(id);
        continue;
      }
      final token = await _jobStore.beginOperation(
        id,
        state: DownloadJobState.queued,
      );
      if (token != null) ready.add(id);
    }

    final liveIds = <String>{};
    for (final task in await FileDownloader().allTasks(allGroups: true)) {
      if (!ready.contains(task.taskId)) continue;
      final record = await FileDownloader().database.recordForId(task.taskId);
      if (record != null &&
          reservesDownloadSlot(
            status: record.status,
            queueWaiting: _queueWaitingIds.contains(task.taskId),
          )) {
        continue;
      }
      liveIds.add(task.taskId);
    }
    if (liveIds.isEmpty) return List<String>.unmodifiable(ready);

    try {
      await FileDownloader().cancelTasksWithIds(liveIds.toList());
    } catch (_) {
      for (final id in liveIds) {
        ready.remove(id);
      }
      return List<String>.unmodifiable(ready);
    }

    for (final id in liveIds) {
      final ownership = await _waitForCancelOwnershipRelease(id);
      if (ownership == DownloadRuntimeOwnership.notOwned) continue;
      ready.remove(id);
      diagnosticLog.record('restack.ownershipUnsettled', {
        'taskId': id,
        'ownership': ownership.name,
      });
    }
    return List<String>.unmodifiable(ready);
  }
"""
service = replace_once(service, old_restack, new_restack, 'restack ownership acknowledgement')

# Every actual resume/retry establishes a fresh durable execution generation
# after live-owner adoption has already been ruled out.
resume_task_anchor = """    if (live != null) {
      final record = await FileDownloader().database.recordForId(live.taskId);
      if (record != null && isLiveNativeDownloadStatus(record.status)) {
        await _attachToLiveNativeTask(task, live: live);
        return true;
      }
    }

    final saved = await _savedProgressFor(task);
"""
resume_task_replacement = """    if (live != null) {
      final record = await FileDownloader().database.recordForId(live.taskId);
      if (record != null && isLiveNativeDownloadStatus(record.status)) {
        await _attachToLiveNativeTask(task, live: live);
        return true;
      }
    }

    final currentJob = await _jobStore.get(task.taskId);
    if (currentJob != null) {
      final execution = await _jobStore.beginOperation(
        task.taskId,
        state: DownloadJobState.starting,
      );
      if (execution == null) return false;
    }

    final saved = await _savedProgressFor(task);
"""
service = replace_once(service, resume_task_anchor, resume_task_replacement, 'resume execution generation')

# Fresh starts also get an execution generation immediately before ownership is
# handed to the executor.
fresh_start_anchor = """        _updatesController.add(
          TaskStatusUpdate(transferTask, TaskStatus.enqueued),
        );
        final success = await _enqueueTransfer(transferTask, expectedBytes);
"""
fresh_start_replacement = """        _updatesController.add(
          TaskStatusUpdate(transferTask, TaskStatus.enqueued),
        );
        final startOperation = await _jobStore.beginOperation(
          transferTask.taskId,
          state: DownloadJobState.starting,
        );
        if (startOperation == null) {
          throw StateError(
            'Failed to fence start operation for ${transferTask.taskId}',
          );
        }
        final success = await _enqueueTransfer(transferTask, expectedBytes);
"""
service = replace_once(service, fresh_start_anchor, fresh_start_replacement, 'fresh execution generation')

# Source replacement advances generation after the durable identity boundary and
# before changing executor/manifest identity.
refresh_anchor = """    if (!refreshCheckpointed) {
      throw StateError(
        'Failed to persist source refresh boundary for ${task.taskId}',
      );
    }

    if (task is ParallelDownloadTask) {
"""
refresh_replacement = """    if (!refreshCheckpointed) {
      throw StateError(
        'Failed to persist source refresh boundary for ${task.taskId}',
      );
    }
    final refreshOperation = await _jobStore.beginOperation(
      task.taskId,
      state: DownloadJobState.interrupted,
    );
    if (refreshOperation == null) {
      throw StateError(
        'Failed to fence source refresh operation for ${task.taskId}',
      );
    }

    if (task is ParallelDownloadTask) {
"""
service = replace_once(service, refresh_anchor, refresh_replacement, 'source refresh generation')

service = service.replace(
    "if (_cancellingUrls.contains(trackingUrl)) return;",
    "if (_terminalJobIds.contains(parentTaskId)) return;",
)
service = service.replace(
    "_cancellingUrls.contains(downloadTrackingUrl(task))",
    "_terminalJobIds.contains(task.taskId)",
)

if '_cancellingUrls' in service:
    raise SystemExit('remaining _cancellingUrls correctness fence')
if '_restackingWaiterIds' in service:
    raise SystemExit('remaining _restackingWaiterIds correctness fence')
if 'Duration(milliseconds: 500)' in service:
    raise SystemExit('remaining 500ms cancel correctness fence')
if 'Duration(milliseconds: 800)' in service:
    raise SystemExit('remaining 800ms restack correctness fence')

service_path.write_text(service)
