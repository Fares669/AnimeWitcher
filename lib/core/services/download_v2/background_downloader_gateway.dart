import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;

import 'download_v2_models.dart';

/// Package-neutral description of one V2 parent transfer.
///
/// [parallelChunks] is an aggregate preference only. AnimeWitcher never
/// allocates, persists, or exposes package-managed child chunk identifiers.
final class DownloadTaskSpecV2 {
  const DownloadTaskSpecV2({
    required this.taskId,
    required this.url,
    required this.destinationPath,
    required this.headers,
    required this.allowPause,
    required this.retries,
    required this.parallelChunks,
  }) : assert(taskId != ''),
       assert(url != ''),
       assert(destinationPath != ''),
       assert(retries >= 0),
       assert(parallelChunks > 0);

  final String taskId;
  final String url;
  final String destinationPath;
  final Map<String, String> headers;
  final bool allowPause;
  final int retries;
  final int parallelChunks;
}

abstract interface class BackgroundDownloaderGateway {
  Future<void> initialize();

  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec);

  Future<DownloadTransportHandle?> attach(String taskId);

  Future<List<DownloadTransportHandle>> rehydrate();

  Future<void> removeTracking(String taskId);
}

abstract interface class DownloadTransportHandle {
  String get taskId;

  DownloadTransportSnapshot get current;

  Stream<DownloadTransportSnapshot> get snapshots;

  Future<bool> pause();

  Future<bool> resume();

  Future<bool> cancel();
}

/// Thin adapter over background_downloader 9.6's Transfer API.
///
/// The package remains the only transport/persistence authority. This class
/// only normalizes the package's parent transfer into V2's package-neutral
/// snapshot contract.
final class PackageBackgroundDownloaderGateway
    implements BackgroundDownloaderGateway {
  PackageBackgroundDownloaderGateway({FileDownloader? downloader})
    : _downloader = downloader ?? FileDownloader();

  final FileDownloader _downloader;
  final Map<String, _PackageDownloadTransportHandle> _handles =
      <String, _PackageDownloadTransportHandle>{};

  Future<void>? _initialization;

  @override
  Future<void> initialize() {
    return _initialization ??= _downloader.start(autoCleanDatabase: true);
  }

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    await initialize();
    final task = await packageTaskForV2(spec);
    final transfer = await _downloader.transfers.start(task);
    return _handleFor(transfer);
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async {
    await initialize();

    final tracked = _downloader.transfers.forId(taskId);
    if (tracked != null) return _handleFor(tracked);

    // Rehydrate package persistence first, then select only by the exact
    // current task ID. Never attach by URL/filename heuristics.
    final rehydrated = await _downloader.transfers.rehydrateFromDatabase();
    for (final transfer in rehydrated) {
      if (transfer.taskId == taskId) return _handleFor(transfer);
    }
    return null;
  }

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async {
    await initialize();
    final transfers = await _downloader.transfers.rehydrateFromDatabase();
    return List<DownloadTransportHandle>.unmodifiable(
      transfers.map(_handleFor),
    );
  }

  @override
  Future<void> removeTracking(String taskId) async {
    await initialize();
    _downloader.transfers.remove(taskId);
    _handles.remove(taskId)?.dispose();
    await _downloader.database.deleteRecordWithId(taskId);
  }

  _PackageDownloadTransportHandle _handleFor(Transfer transfer) {
    final existing = _handles[transfer.taskId];
    if (existing != null && identical(existing.transfer, transfer)) {
      return existing;
    }
    existing?.dispose();
    final handle = _PackageDownloadTransportHandle(transfer);
    _handles[transfer.taskId] = handle;
    return handle;
  }
}

/// Maps one AnimeWitcher parent transfer spec to exactly one package task.
///
/// When [DownloadTaskSpecV2.parallelChunks] is greater than one the returned
/// object is a single [ParallelDownloadTask] parent. Package-created child
/// transfers stay opaque and are never exposed or persisted by V2.
Future<DownloadTask> packageTaskForV2(DownloadTaskSpecV2 spec) async {
  final (baseDirectory, directory, filename) = await _destinationFor(
    spec.destinationPath,
  );

  if (spec.parallelChunks > 1) {
    return ParallelDownloadTask(
      taskId: spec.taskId,
      url: spec.url,
      filename: filename,
      headers: spec.headers,
      chunks: spec.parallelChunks,
      directory: directory,
      baseDirectory: baseDirectory,
      updates: Updates.statusAndProgress,
      retries: spec.retries,
      allowPause: spec.allowPause,
    );
  }

  return DownloadTask(
    taskId: spec.taskId,
    url: spec.url,
    filename: filename,
    headers: spec.headers,
    directory: directory,
    baseDirectory: baseDirectory,
    updates: Updates.statusAndProgress,
    retries: spec.retries,
    allowPause: spec.allowPause,
  );
}

Future<(BaseDirectory, String, String)> _destinationFor(String path) async {
  if (p.isAbsolute(path)) {
    return Task.split(filePath: path);
  }

  // Relative V2 destinations are app-document relative, which stays stable
  // across mobile app-container relocations. Absolute stable destinations are
  // delegated to Task.split so the package chooses the best BaseDirectory.
  final directory = p.dirname(path);
  return (
    BaseDirectory.applicationDocuments,
    directory == '.' ? '' : directory,
    p.basename(path),
  );
}

final class _PackageDownloadTransportHandle
    implements DownloadTransportHandle {
  _PackageDownloadTransportHandle(this.transfer) {
    _updatesSubscription = transfer.updates.listen(_onUpdate);
    _holdReasonListener = _emitCurrent;
    transfer.holdReasonNotifier.addListener(_holdReasonListener);
  }

  final Transfer transfer;
  final StreamController<DownloadTransportSnapshot> _snapshots =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);

  late final StreamSubscription<TaskUpdate> _updatesSubscription;
  late final void Function() _holdReasonListener;
  int? _totalBytes;
  bool _disposed = false;

  @override
  String get taskId => transfer.taskId;

  @override
  DownloadTransportSnapshot get current => _snapshot();

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<bool> pause() => transfer.pause();

  @override
  Future<bool> resume() => transfer.resume();

  @override
  Future<bool> cancel() => transfer.cancel();

  void _onUpdate(TaskUpdate update) {
    if (update is TaskProgressUpdate && update.expectedFileSize > 0) {
      _totalBytes = update.expectedFileSize;
    }
    _emitCurrent();
  }

  void _emitCurrent() {
    if (_disposed || _snapshots.isClosed) return;
    _snapshots.add(_snapshot());
  }

  DownloadTransportSnapshot _snapshot() {
    final progress = transfer.progress ??
        (transfer.status == TaskStatus.complete ? 1.0 : 0.0);
    final totalBytes = _totalBytes;
    final transferredBytes = totalBytes == null
        ? null
        : (totalBytes * progress).round();
    final exception = transfer.exception;

    return DownloadTransportSnapshot(
      taskId: taskId,
      status: transportStatusFromPackage(
        transfer.status,
        transfer.holdReason,
      ),
      progress: progress,
      transferredBytes: transferredBytes,
      totalBytes: totalBytes,
      failureCategory: _failureCategory(transfer.status, exception),
      failureMessage: exception?.toString(),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    transfer.holdReasonNotifier.removeListener(_holdReasonListener);
    unawaited(_updatesSubscription.cancel());
    unawaited(_snapshots.close());
  }
}

/// Normalizes package status into the package-neutral V2 state model.
///
/// Kept public so the adapter contract can be regression-tested directly;
/// application code should consume [DownloadTransportSnapshot] instead.
DownloadTransportStatus transportStatusFromPackage(
  TaskStatus status,
  TransferHoldReason holdReason,
) {
  if (holdReason != TransferHoldReason.none && status.isNotFinalState) {
    return DownloadTransportStatus.held;
  }

  return switch (status) {
    TaskStatus.enqueued => DownloadTransportStatus.queued,
    TaskStatus.running => DownloadTransportStatus.running,
    TaskStatus.complete => DownloadTransportStatus.complete,
    TaskStatus.notFound => DownloadTransportStatus.missing,
    TaskStatus.failed => DownloadTransportStatus.failed,
    TaskStatus.canceled => DownloadTransportStatus.canceled,
    TaskStatus.waitingToRetry => DownloadTransportStatus.held,
    TaskStatus.paused => DownloadTransportStatus.paused,
  };
}

DownloadFailureCategory? _failureCategory(
  TaskStatus status,
  TaskException? exception,
) {
  if (status != TaskStatus.failed) {
    return null;
  }

  return switch (exception) {
    TaskHttpException(httpResponseCode: 401 || 403) =>
      DownloadFailureCategory.sourceExpired,
    TaskFileSystemException() => DownloadFailureCategory.filesystem,
    TaskConnectionException() ||
    TaskResumeException() ||
    TaskUrlException() ||
    TaskHttpException() => DownloadFailureCategory.transport,
    TaskException() => DownloadFailureCategory.unknown,
    null => DownloadFailureCategory.transport,
  };
}
