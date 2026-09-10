import 'dart:async';

import 'package:background_downloader/background_downloader.dart';

bool isNativeSingleDownloadTask(Task task) =>
    task is DownloadTask && task is! ParallelDownloadTask;

const int kDownloadLargeFileHintThresholdBytes = 50 * 1024 * 1024;

/// Runtime ownership is intentionally separate from persisted task status.
/// Only [notOwned] permits a new writer for the same execution identity.
enum DownloadRuntimeOwnership { owned, notOwned, settling, unknown }

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
  // A successful executor query that does not contain the task is the
  // independent negative acknowledgement needed before another writer starts.
  return DownloadRuntimeOwnership.notOwned;
}

/// Anime episodes are explicit user downloads. User-initiated is always useful;
/// largeFile is added when size is unknown or the episode is large enough to
/// benefit from background_downloader's long-running transfer policy.
Set<TransferHint> animeDownloadTransferHints({required int expectedBytes}) {
  final hints = <TransferHint>{TransferHint.userInitiated};
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
  Future<bool> cancel(DownloadTask task);
  Stream<TaskUpdate> updatesFor(String taskId);
  Future<void> dispose();
}

/// background_downloader 9.6 Transfer-backed executor for normal one-file
/// downloads. Multipart parents deliberately stay under
/// PersistentParallelDownload.
class NativeSingleDownloadTransport implements DownloadTransport {
  NativeSingleDownloadTransport({FileDownloader? downloader})
    : _downloader = downloader ?? FileDownloader();

  final FileDownloader _downloader;
  final Map<String, Transfer> _handles = <String, Transfer>{};
  final Map<String, StreamController<TaskUpdate>> _controllers =
      <String, StreamController<TaskUpdate>>{};
  final Map<String, StreamSubscription<TaskUpdate>> _subscriptions =
      <String, StreamSubscription<TaskUpdate>>{};

  Future<List<DownloadTask>> rehydrate({String? group}) async {
    final transfers = await _downloader.transfers.rehydrateFromDatabase(
      group: group,
    );
    final tasks = <DownloadTask>[];
    for (final transfer in transfers) {
      final task = transfer.task;
      if (!isNativeSingleDownloadTask(task)) continue;
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

  @override
  Future<bool> start(DownloadTask task) async {
    if (!isNativeSingleDownloadTask(task)) return false;
    final existing = handleFor(task.taskId);
    if (existing != null &&
        existing.status != TaskStatus.failed &&
        existing.status != TaskStatus.canceled &&
        existing.status != TaskStatus.notFound) {
      _attach(existing);
      return true;
    }

    try {
      // This method is called only after DownloadService proved that there are
      // no durable bytes to preserve. Rehydration and strict resume use their
      // own methods; fresh start therefore has exactly one meaning here.
      final transfer = await _downloader.transfers.start(task);
      _attach(transfer);
      return transfer.status != TaskStatus.failed &&
          transfer.status != TaskStatus.canceled &&
          transfer.status != TaskStatus.notFound;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> pause(DownloadTask task) async {
    if (!isNativeSingleDownloadTask(task)) return false;
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
    if (!isNativeSingleDownloadTask(task)) return false;
    try {
      // Transfer.resume may fall back to re-enqueueing when resume data is
      // missing. The low-level resume API preserves AnimeWitcher's strict
      // contract: false means fall back to verified on-disk Range bytes.
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
  Future<bool> cancel(DownloadTask task) async {
    if (!isNativeSingleDownloadTask(task)) return false;
    final transfer = handleFor(task.taskId);
    try {
      final canceled = transfer != null
          ? await transfer.cancel()
          : await _downloader.cancelTaskWithId(task.taskId);
      _detach(task.taskId);
      return canceled;
    } catch (_) {
      return false;
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
