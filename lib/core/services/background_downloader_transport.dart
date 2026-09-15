import 'dart:async';

import 'package:background_downloader/background_downloader.dart';

import 'download_parallel.dart';

const int kDownloadLargeFileHintThresholdBytes = 50 * 1024 * 1024;

/// Runtime ownership is intentionally separate from persisted task status.
/// Only [notOwned] permits a new writer for the same execution identity.
enum DownloadRuntimeOwnership { owned, notOwned, settling, unknown }

/// Maps a settled Transfer status to writer ownership without consulting a
/// persisted task row. Only executor-active states may own a writer.
DownloadRuntimeOwnership ownershipFromStatus(TaskStatus status) =>
    switch (status) {
      TaskStatus.enqueued ||
      TaskStatus.running ||
      TaskStatus.waitingToRetry => DownloadRuntimeOwnership.owned,
      TaskStatus.paused ||
      TaskStatus.complete ||
      TaskStatus.canceled ||
      TaskStatus.failed ||
      TaskStatus.notFound => DownloadRuntimeOwnership.notOwned,
    };

/// Only non-final executor states can plausibly own a native writer. Persisted
/// database state alone is never sufficient evidence of current ownership.
bool runtimeTaskStatusCanOwnWriter(TaskStatus status) =>
    ownershipFromStatus(status) == DownloadRuntimeOwnership.owned;

/// Result of issuing a cancellation command. A successful command is not by
/// itself proof that the executor has released file ownership.
enum DownloadCancelSettlement { canceled, alreadyGone, stillOwned, unknown }

/// Low-level result of issuing a non-terminal transport command. This remains
/// distinct from DownloadService's logical/user-visible command outcome.
enum DownloadTransportCommandOutcome { accepted, rejected, unavailable }

DownloadTransportCommandOutcome resolveDownloadTransportCommandOutcome({
  required bool commandAccepted,
  bool transportAvailable = true,
}) {
  if (!transportAvailable) return DownloadTransportCommandOutcome.unavailable;
  return commandAccepted
      ? DownloadTransportCommandOutcome.accepted
      : DownloadTransportCommandOutcome.rejected;
}

DownloadCancelSettlement resolveDownloadCancelCommand({
  required bool hadTrackedOwner,
  required bool commandSucceeded,
  required bool commandThrew,
}) {
  if (commandThrew) return DownloadCancelSettlement.unknown;
  if (commandSucceeded) return DownloadCancelSettlement.canceled;
  return hadTrackedOwner
      ? DownloadCancelSettlement.stillOwned
      : DownloadCancelSettlement.unknown;
}

extension DownloadRuntimeOwnershipSafety on DownloadRuntimeOwnership {
  bool get blocksNewWriter => this != DownloadRuntimeOwnership.notOwned;
}

/// Resolve ownership from executor/runtime evidence only. A persisted database
/// status is deliberately not an input: it may describe an older projection.
DownloadRuntimeOwnership resolveDownloadRuntimeOwnership({
  required bool runtimeQuerySucceeded,
  required bool runtimeTaskPresent,
  bool localRangeWriterActive = false,
  bool operationSettling = false,
  bool transferHandlePresent = false,
}) {
  if (localRangeWriterActive || runtimeTaskPresent) {
    return DownloadRuntimeOwnership.owned;
  }
  if (operationSettling) return DownloadRuntimeOwnership.settling;
  if (!runtimeQuerySucceeded) {
    // A Transfer handle can be rehydrated from persistence, so presence alone
    // cannot prove ownership; query failure therefore remains unknown.
    return DownloadRuntimeOwnership.unknown;
  }
  return DownloadRuntimeOwnership.notOwned;
}

/// Android 14+ UIDT requires a user-visible notification. When notifications
/// are disabled in-app or permission is denied, fall back to the normal
/// resumable WorkManager path instead of requesting userInitiated priority.
bool shouldUseUserInitiatedDownloadHint({
  required bool isAndroid,
  required bool notificationsConfigured,
  required bool notificationPermissionGranted,
}) {
  if (!isAndroid) return true;
  return notificationsConfigured && notificationPermissionGranted;
}

/// Anime episodes remain pause/resume capable for long-running WorkManager
/// fallback even when Android UIDT cannot be used.
Set<TransferHint> animeDownloadTransferHints({
  required int expectedBytes,
  bool useUserInitiated = true,
}) {
  final hints = <TransferHint>{};
  if (useUserInitiated) {
    hints.add(TransferHint.userInitiated);
  }
  if (expectedBytes <= 0 ||
      expectedBytes >= kDownloadLargeFileHintThresholdBytes) {
    hints.add(TransferHint.largeFile);
  }
  return hints;
}

abstract interface class DownloadTransport {
  bool owns(String taskId);

  Future<bool> start(DownloadTask task);
  Future<bool> pause(DownloadTask task);
  Future<bool> resume(DownloadTask task);
  Future<DownloadTransportCommandOutcome> startOutcome(DownloadTask task);
  Future<DownloadTransportCommandOutcome> pauseOutcome(DownloadTask task);
  Future<DownloadTransportCommandOutcome> resumeOutcome(DownloadTask task);
  Future<DownloadCancelSettlement> cancel(DownloadTask task);
  Stream<TaskUpdate> updatesFor(String taskId);
  Future<void> dispose();
}

/// True for logical episode tasks that may be owned directly by
/// background_downloader. Plugin-generated chunk tasks and AnimeWitcher's
/// legacy multipart children are deliberately excluded: they are implementation
/// details of another executor and must never be promoted to logical transfers.
bool isBackgroundDownloaderTransportTask(Task task) =>
    task is DownloadTask && !isInternalDownloaderChunk(task);

/// Transfer-backed background_downloader executor for logical episode tasks.
///
/// Both ordinary [DownloadTask] and [ParallelDownloadTask] are accepted. Which
/// task shape is selected remains the responsibility of download transport
/// policy; this adapter only guarantees one plugin-owned execution boundary.
class BackgroundDownloaderTransport implements DownloadTransport {
  BackgroundDownloaderTransport({FileDownloader? downloader})
    : _downloader = downloader ?? FileDownloader();

  final FileDownloader _downloader;
  final Map<String, Transfer> _handles = <String, Transfer>{};
  final Map<String, StreamController<TaskUpdate>> _controllers =
      <String, StreamController<TaskUpdate>>{};
  final Map<String, StreamSubscription<TaskUpdate>> _subscriptions =
      <String, StreamSubscription<TaskUpdate>>{};

  /// Rehydrates plugin Transfer handles without enqueueing anything.
  ///
  /// Rehydration reconnects observation only. A persisted/final Transfer is
  /// not treated as proof that an executor still owns a writer.
  Future<List<DownloadTask>> rehydrate({String? group}) async {
    final transfers = await _downloader.transfers.rehydrateFromDatabase(
      group: group,
    );
    final tasks = <DownloadTask>[];
    for (final transfer in transfers) {
      final task = transfer.task;
      if (!isBackgroundDownloaderTransportTask(task)) continue;
      _attach(transfer);
      tasks.add(task as DownloadTask);
    }
    return tasks;
  }

  @override
  bool owns(String taskId) =>
      _handles.containsKey(taskId) ||
      _downloader.transfers.forId(taskId) != null;

  Transfer? handleFor(String taskId) =>
      _handles[taskId] ?? _downloader.transfers.forId(taskId);

  TaskStatus? statusFor(String taskId) => handleFor(taskId)?.status;

  /// Returns true only when current runtime Transfer status can still own a
  /// writer. Mere presence of a rehydrated/persisted handle is insufficient.
  bool runtimeStatusCanOwnWriter(String taskId) {
    final status = statusFor(taskId);
    return status != null && runtimeTaskStatusCanOwnWriter(status);
  }

  /// Resolves writer ownership from the plugin's targeted runtime queue query.
  ///
  /// A rehydrated Transfer status is a useful projection but is not sufficient
  /// proof of live native I/O. Conversely, failure of the runtime query cannot
  /// be converted into [DownloadRuntimeOwnership.notOwned], because starting a
  /// second writer in that state would violate the single-writer invariant.
  Future<DownloadRuntimeOwnership> ownershipFor(String taskId) async {
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

  @override
  Future<bool> start(DownloadTask task) async {
    if (!isBackgroundDownloaderTransportTask(task)) return false;

    final existing = handleFor(task.taskId);
    if (existing != null && runtimeTaskStatusCanOwnWriter(existing.status)) {
      _attach(existing);
      return true;
    }

    try {
      // Callers may reach fresh start only after logical reconciliation proved
      // that another writer cannot own this identity and durable bytes do not
      // require a stricter resume path.
      final transfer = await _downloader.transfers.start(task);
      _attach(transfer);
      return runtimeTaskStatusCanOwnWriter(transfer.status) ||
          transfer.status == TaskStatus.complete;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> pause(DownloadTask task) async {
    if (!isBackgroundDownloaderTransportTask(task)) return false;
    final transfer = handleFor(task.taskId);
    if (transfer == null) return _downloader.pause(task);
    _attach(transfer);
    try {
      return await transfer.pause();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> resume(DownloadTask task) async {
    if (!isBackgroundDownloaderTransportTask(task)) return false;
    try {
      // Use the low-level resume API so missing resume data returns false and
      // AnimeWitcher can fall back to its verified on-disk Range recovery.
      final resumed = await _downloader.resume(task);
      if (!resumed) return false;
      final transfer = await _downloader.transfers.getOrStart(
        task,
        matchBy: (existingTask) => existingTask.taskId == task.taskId,
        reEnqueueIfFailed: false,
      );
      _attach(transfer);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<DownloadTransportCommandOutcome> startOutcome(
    DownloadTask task,
  ) async {
    if (!isBackgroundDownloaderTransportTask(task)) {
      return DownloadTransportCommandOutcome.unavailable;
    }
    return resolveDownloadTransportCommandOutcome(
      commandAccepted: await start(task),
    );
  }

  @override
  Future<DownloadTransportCommandOutcome> pauseOutcome(
    DownloadTask task,
  ) async {
    if (!isBackgroundDownloaderTransportTask(task)) {
      return DownloadTransportCommandOutcome.unavailable;
    }
    return resolveDownloadTransportCommandOutcome(
      commandAccepted: await pause(task),
    );
  }

  @override
  Future<DownloadTransportCommandOutcome> resumeOutcome(
    DownloadTask task,
  ) async {
    if (!isBackgroundDownloaderTransportTask(task)) {
      return DownloadTransportCommandOutcome.unavailable;
    }
    return resolveDownloadTransportCommandOutcome(
      commandAccepted: await resume(task),
    );
  }

  @override
  Future<DownloadCancelSettlement> cancel(DownloadTask task) async {
    if (!isBackgroundDownloaderTransportTask(task)) {
      return DownloadCancelSettlement.unknown;
    }
    final transfer = handleFor(task.taskId);
    try {
      final canceled = transfer != null
          ? await transfer.cancel()
          : await _downloader.cancelTaskWithId(task.taskId);
      // Command acknowledgement is not independent proof that native I/O has
      // released ownership. Keep the handle until reconciliation proves it.
      return resolveDownloadCancelCommand(
        hadTrackedOwner: transfer != null,
        commandSucceeded: canceled,
        commandThrew: false,
      );
    } catch (_) {
      return resolveDownloadCancelCommand(
        hadTrackedOwner: transfer != null,
        commandSucceeded: false,
        commandThrew: true,
      );
    }
  }

  void forget(String taskId) => _detach(taskId);

  @override
  Stream<TaskUpdate> updatesFor(String taskId) {
    final controller = _controllers.putIfAbsent(
      taskId,
      () => StreamController<TaskUpdate>.broadcast(),
    );
    final transfer = handleFor(taskId);
    if (transfer != null) _attach(transfer);
    return controller.stream;
  }

  void _attach(Transfer transfer) {
    final id = transfer.taskId;
    if (_handles[id] == transfer && _subscriptions.containsKey(id)) return;
    unawaited(_subscriptions.remove(id)?.cancel());
    _handles[id] = transfer;
    final controller = _controllers.putIfAbsent(
      id,
      () => StreamController<TaskUpdate>.broadcast(),
    );
    _subscriptions[id] = transfer.updates.listen(
      (update) {
        if (!controller.isClosed) controller.add(update);
      },
      onError: (Object error, StackTrace stack) {
        if (!controller.isClosed) controller.addError(error, stack);
      },
    );
  }

  void _detach(String taskId) {
    unawaited(_subscriptions.remove(taskId)?.cancel());
    _handles.remove(taskId);
    _downloader.transfers.remove(taskId, dispose: true);
  }

  @override
  Future<void> dispose() async {
    final subscriptions = _subscriptions.values.toList(growable: false);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    final controllers = _controllers.values.toList(growable: false);
    _controllers.clear();
    for (final controller in controllers) {
      await controller.close();
    }
    for (final id in _handles.keys.toList(growable: false)) {
      _downloader.transfers.remove(id, dispose: true);
    }
    _handles.clear();
  }
}
