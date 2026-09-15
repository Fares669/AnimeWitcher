import 'dart:async';

import 'package:background_downloader/background_downloader.dart';

import 'download_parallel.dart';
import 'download_transport.dart';

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
