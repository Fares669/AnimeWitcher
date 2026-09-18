import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;

import '../download_concurrency.dart';
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
const String kDownloadV2PackageGroup = 'downloads_v2';
const String kDownloadV2SilentPackageGroup = 'downloads_v2_silent';

Future<void> configurePackageNotificationsV2(
  FileDownloader downloader,
  DownloadNotificationPrefs prefs,
) async {
  if (prefs.noneEnabled) return;
  const title = '{displayName}';
  downloader.configureNotificationForGroup(
    kDownloadV2PackageGroup,
    running: downloadNotificationIfEnabled(
      enabled: prefs.running,
      title: title,
      body: Platform.isIOS
          ? kDownloadRunningNotificationBodyIos
          : kDownloadRunningNotificationBodyAndroid,
    ),
    complete: downloadNotificationIfEnabled(
      enabled: prefs.complete,
      title: title,
      body: kDownloadCompleteNotificationBody,
    ),
    error: downloadNotificationIfEnabled(
      enabled: prefs.error,
      title: title,
      body: kDownloadParkedNotificationBody,
    ),
    paused: downloadNotificationIfEnabled(
      enabled: prefs.paused,
      title: title,
      body: kDownloadParkedNotificationBody,
    ),
    canceled: downloadNotificationIfEnabled(
      enabled: prefs.canceled,
      title: title,
      body: kDownloadCanceledNotificationBody,
    ),
    progressBar: !Platform.isIOS && prefs.running,
  );
}

final class PackageBackgroundDownloaderGateway
    implements BackgroundDownloaderGateway {
  PackageBackgroundDownloaderGateway({
    FileDownloader? downloader,
    DownloadNotificationPrefs Function()? notificationPreferences,
    Future<void> Function()? initializePackage,
  }) : _downloader = downloader ?? FileDownloader(),
       _notificationPreferences =
           notificationPreferences ?? (() => const DownloadNotificationPrefs()),
       _initializePackage = initializePackage;

  final FileDownloader _downloader;
  final DownloadNotificationPrefs Function() _notificationPreferences;
  final Future<void> Function()? _initializePackage;
  final Map<String, _PackageDownloadTransportHandle> _handles =
      <String, _PackageDownloadTransportHandle>{};

  Future<void>? _initialization;

  @override
  Future<void> initialize() {
    final existing = _initialization;
    if (existing != null) return existing;

    final attempt = _initializePackage?.call() ?? _initializeOnce();
    _initialization = attempt;
    unawaited(
      attempt.catchError((Object _, StackTrace __) {
        if (identical(_initialization, attempt)) {
          _initialization = null;
        }
      }),
    );
    return attempt;
  }

  Future<void> _initializeOnce() async {
    await _downloader.configure(
      globalConfig: const <(String, dynamic)>[
        (Config.holdingQueue, false),
      ],
      iOSConfig: const <(String, dynamic)>[
        (Config.excludeFromCloudBackup, Config.always),
      ],
    );
    await configurePackageNotificationsV2(
      _downloader,
      _notificationPreferences(),
    );
    await _downloader.start(autoCleanDatabase: true);
  }

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    await initialize();
    final prefs = _notificationPreferences();
    await configurePackageNotificationsV2(_downloader, prefs);
    final task = await packageTaskForV2(
      spec,
      userInitiated: prefs.running,
      group: prefs.noneEnabled
          ? kDownloadV2SilentPackageGroup
          : kDownloadV2PackageGroup,
    );
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
    final handle = _PackageDownloadTransportHandle(transfer, _downloader);
    _handles[transfer.taskId] = handle;
    return handle;
  }
}

/// Maps one AnimeWitcher parent transfer spec to exactly one package task.
///
/// When [DownloadTaskSpecV2.parallelChunks] is greater than one the returned
/// object is a single [ParallelDownloadTask] parent. Package-created child
/// transfers stay opaque and are never exposed or persisted by V2.
Future<DownloadTask> packageTaskForV2(
  DownloadTaskSpecV2 spec, {
  bool userInitiated = true,
  String group = kDownloadV2PackageGroup,
}) async {
  final (baseDirectory, directory, filename) = await _destinationFor(
    spec.destinationPath,
  );
  final transferHints = <TransferHint>{
    TransferHint.largeFile,
    if (userInitiated) TransferHint.userInitiated,
  };

  if (spec.parallelChunks > 1) {
    return ParallelDownloadTask(
      taskId: spec.taskId,
      url: spec.url,
      filename: filename,
      headers: spec.headers,
      chunks: spec.parallelChunks,
      directory: directory,
      baseDirectory: baseDirectory,
      group: group,
      displayName: filename,
      transferHints: transferHints,
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
    group: group,
    displayName: filename,
    transferHints: transferHints,
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

/// Waits until background_downloader has durably stored the parent and every
/// child resume payload for one paused ParallelDownloadTask.
///
/// background_downloader 9.6.2 publishes paused callbacks before its async
/// PersistentStorage writes are necessarily visible. Calling its parallel
/// resume path during that window can make one child return false, which causes
/// the package to cancel the parent. This probe only reads package-owned state;
/// AnimeWitcher never copies or mutates resume/range data.
Future<bool> waitForPackageParallelResumeDataV2({
  required DownloadTask task,
  required Future<ResumeData?> Function(String taskId) retrieveResumeData,
  int maxAttempts = 100,
  Duration pollInterval = const Duration(milliseconds: 50),
  Future<void> Function(Duration duration)? delay,
}) async {
  if (task is! ParallelDownloadTask) return true;
  if (maxAttempts <= 0) return false;

  final wait =
      delay ?? ((duration) => Future<void>.delayed(duration));
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    final parentResumeData = await retrieveResumeData(task.taskId);
    if (parentResumeData != null) {
      final childTaskIds = _parallelChildTaskIds(
        parentResumeData.data,
      );
      if (childTaskIds.isNotEmpty) {
        final childResumeData = await Future.wait(
          childTaskIds.map(retrieveResumeData),
        );
        if (childResumeData.every((resumeData) => resumeData != null)) {
          return true;
        }
      }
    }

    if (attempt + 1 < maxAttempts) {
      await wait(pollInterval);
    }
  }
  return false;
}

List<String> _parallelChildTaskIds(String resumeData) {
  try {
    final decoded = jsonDecode(resumeData);
    if (decoded is! List) return const <String>[];

    final ids = <String>{};
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final task = entry['task'];
      if (task is! Map) continue;
      final taskId = task['taskId'];
      if (taskId is String && taskId.isNotEmpty) {
        ids.add(taskId);
      }
    }
    return ids.toList(growable: false);
  } catch (_) {
    return const <String>[];
  }
}

final class _PackageDownloadTransportHandle
    implements DownloadTransportHandle {
  _PackageDownloadTransportHandle(this.transfer, this._downloader) {
    _updatesSubscription = transfer.updates.listen(_onUpdate);
    _holdReasonListener = _emitCurrent;
    transfer.holdReasonNotifier.addListener(_holdReasonListener);
  }

  final Transfer transfer;
  final FileDownloader _downloader;
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
  Future<bool> resume() async {
    final task = transfer.task;
    if (task is! DownloadTask) return false;

    // Transfer.resume() intentionally falls back to enqueueing from byte zero
    // when resume data is unavailable. Explicit V2 Resume must never do that:
    // use the package's lower-level resume-only path for the exact task.
    if (task is ParallelDownloadTask) {
      final ready = await waitForPackageParallelResumeDataV2(
        task: task,
        // background_downloader 9.6.2 has no public awaitable signal for
        // "all parallel child resume-data writes are durable". Keep this
        // read-only probe confined to the adapter and remove it when upstream
        // exposes/awaits that lifecycle point.
        // ignore: invalid_use_of_visible_for_testing_member
        retrieveResumeData:
            _downloader.database.storage.retrieveResumeData,
      );
      if (!ready) return false;
    }
    return _downloader.resume(task);
  }

  @override
  Future<bool> cancel() => transfer.cancel();

  void _onUpdate(TaskUpdate update) {
    if (update is TaskProgressUpdate) {
      if (update.expectedFileSize > 0) {
        _totalBytes = update.expectedFileSize;
      }
    }
    _emitCurrent();
  }

  void _emitCurrent() {
    if (_disposed || _snapshots.isClosed) return;
    _snapshots.add(_snapshot());
  }

  DownloadTransportSnapshot _snapshot() =>
      packageTransportSnapshotForV2(transfer, totalBytes: _totalBytes);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    transfer.holdReasonNotifier.removeListener(_holdReasonListener);
    unawaited(_updatesSubscription.cancel());
    unawaited(_snapshots.close());
  }
}

/// Projects one package Transfer into V2 without maintaining a second metric
/// cache. The Transfer notifiers are updated before its progress stream emits,
/// so reading them here preserves the package's current speed/ETA on iOS and
/// package-managed parallel parents.
DownloadTransportSnapshot packageTransportSnapshotForV2(
  Transfer transfer, {
  int? totalBytes,
}) {
  final progress =
      transfer.progress ?? (transfer.status == TaskStatus.complete ? 1.0 : 0.0);
  final transferredBytes =
      totalBytes == null ? null : (totalBytes * progress).round();
  final exception = transfer.exception;
  final packageStatus = transfer.status;
  var projectedStatus = transportStatusFromPackage(
    packageStatus,
    transfer.holdReason,
  );

  // On iOS, background_downloader 9.6.2 can keep a ParallelDownloadTask
  // parent enqueued while multiple child chunks are already transferring.
  // A real parent progress update is authoritative evidence that transport is
  // active. Promote presentation only; user-paused state is still fenced by
  // DownloadManagerV2 and raw package pause/resume semantics stay untouched.
  if (packageStatus == TaskStatus.enqueued &&
      progress > 0 &&
      progress < 1 &&
      transfer.holdReason == TransferHoldReason.none) {
    projectedStatus = DownloadTransportStatus.running;
  }

  final parallelParent = transfer.task is ParallelDownloadTask;

  return DownloadTransportSnapshot(
    taskId: transfer.taskId,
    status: projectedStatus,
    progress: progress,
    transferredBytes: transferredBytes,
    totalBytes: totalBytes,
    // background_downloader derives ParallelDownloadTask parent speed from
    // aggregate child-progress jumps. Those callbacks can arrive in bursts and
    // report impossible transient rates (for example 200+ MB/s) followed by 0.
    // V2 uses read-only native child throughput for parallel presentation.
    networkSpeedMBps: parallelParent ? -1 : transfer.networkSpeed,
    timeRemaining: parallelParent
        ? Duration.zero
        : transfer.timeRemainingNotifier.value,
    failureCategory: _failureCategory(transfer.status, exception),
    failureMessage: exception?.toString(),
  );
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