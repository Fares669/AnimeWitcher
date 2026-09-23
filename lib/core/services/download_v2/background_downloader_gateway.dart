import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;

import '../download_concurrency.dart';
import '../download_parallel.dart';
import '../persistent_parallel_download.dart';
import 'download_v2_diagnostics.dart';
import 'download_v2_models.dart';
import 'manga_chapter_transport_v2.dart';

/// Package-neutral description of one V2 parent transfer.
///
/// [parallelChunks] is the requested connection ceiling. On iOS the production
/// gateway may satisfy widths greater than one with durable immutable byte
/// ranges. That transport-private range state never enters the V2 logical store.
final class DownloadTaskSpecV2 {
  const DownloadTaskSpecV2({
    required this.taskId,
    required this.url,
    required this.destinationPath,
    required this.headers,
    required this.allowPause,
    required this.retries,
    required this.parallelChunks,
    this.expectedBytes,
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
  final int? expectedBytes;
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

/// Marker for a handle whose pause/resume settlement is complete at the handle
/// boundary. This covers both durable ranged
/// parents and ordinary single package DownloadTasks. Package-managed
/// ParallelDownloadTask parents deliberately do not implement it because they
/// need the child pause/readiness barrier.
abstract interface class SelfSettlingParallelDownloadTransportHandleV2 {}

/// V2 transport adapter over background_downloader 9.6.
///
/// background_downloader remains the network/native execution authority. For
/// iOS downloads with proven byte-range support this adapter reuses the shared
/// durable immutable-range coordinator for splitting/checkpoint/assembly only;
/// every child range is still a package DownloadTask/URLSession transfer. This
/// also covers a user-selected width of one, because iOS cannot guarantee that
/// cancelByProducingResumeData returns resumable data for one giant DownloadTask.
/// The V2 logical store never persists child task IDs, byte ranges, or offsets.
const String kDownloadV2PackageGroup = 'downloads_v2';
const String kDownloadV2SilentPackageGroup = 'downloads_v2_silent';
const String kDownloadV2DurableParallelGroup = 'downloads_v2_ranges';

/// Selects package child records owned by one durable V2 range parent.
///
/// Child transport state is private to the gateway and must be removed once a
/// parent is terminal so background_downloader does not rehydrate stale
/// part transfers on later launches.
List<String> durableChildTaskIdsForParentV2(
  Iterable<TaskRecord> records,
  String parentTaskId,
) {
  final ids = <String>[
    for (final record in records)
      if (record.task.group == kPersistentDownloadChunkGroup &&
          downloadInternalParentTaskId(record.task) == parentTaskId)
        record.taskId,
  ];
  ids.sort();
  return ids;
}

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

Set<String> activeDurablePartTaskIdsV2({
  required Iterable<Task> packageTasks,
  required Iterable<Task> pausedTasks,
}) {
  final pausedIds = pausedTasks.map((task) => task.taskId).toSet();
  return <String>{
    for (final task in packageTasks)
      if (task.group == kPersistentDownloadChunkGroup &&
          !pausedIds.contains(task.taskId))
        task.taskId,
  };
}

final class PackageBackgroundDownloaderGateway
    implements BackgroundDownloaderGateway, MangaChapterGatewayV2 {
  PackageBackgroundDownloaderGateway({
    FileDownloader? downloader,
    DownloadNotificationPrefs Function()? notificationPreferences,
    Future<void> Function()? initializePackage,
    bool Function()? isIOS,
    Future<DownloadRangeCapabilityV2> Function(DownloadTaskSpecV2 spec)?
    rangeCapabilityProbe,
    DownloadDiagnosticsV2? diagnostics,
  }) : _downloader = downloader ?? FileDownloader(),
       _notificationPreferences =
           notificationPreferences ?? (() => const DownloadNotificationPrefs()),
       _initializePackage = initializePackage,
       _isIOS = isIOS ?? (() => Platform.isIOS),
       _rangeCapabilityProbe = rangeCapabilityProbe,
       _diagnostics = diagnostics ?? const NoopDownloadDiagnosticsV2();

  final FileDownloader _downloader;
  final DownloadNotificationPrefs Function() _notificationPreferences;
  final Future<void> Function()? _initializePackage;
  final bool Function() _isIOS;
  final Future<DownloadRangeCapabilityV2> Function(DownloadTaskSpecV2 spec)?
  _rangeCapabilityProbe;
  final DownloadDiagnosticsV2 _diagnostics;
  String? _lastOwnershipSignature;
  final Map<String, _PackageDownloadTransportHandle> _handles =
      <String, _PackageDownloadTransportHandle>{};
  final Map<String, _DurableParallelDownloadTransportHandle> _durableHandles =
      <String, _DurableParallelDownloadTransportHandle>{};
  PersistentParallelDownload? _durableParallel;
  StreamSubscription<TaskUpdate>? _durableUpdatesSubscription;

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
    await _recordStartupInventory();
    _ensureDurableParallelCoordinator();
  }

  /// Generation-fenced zero-byte Range candidates that iOS may start on the
  /// package's already-running background URLSession after Flutter is suspended.
  ///
  /// Creating this checkpoint is not transport ownership. Callers must release
  /// the transient Dart-side offers after the native snapshot is acknowledged so
  /// the foreground scheduler can continue normally. Native promotion rechecks
  /// the real URLSession before creating a child and Dart adopts it only when its
  /// attemptGeneration still matches.
  List<Map<String, Object>> nativeBackgroundPlansV2() {
    if (!_isIOS()) return const <Map<String, Object>>[];
    final coordinator = _durableParallel;
    if (coordinator == null) return const <Map<String, Object>>[];

    return <Map<String, Object>>[
      for (final plan in coordinator.nativeBackgroundPlans())
        <String, Object>{
          'parentTaskId': plan.parentTaskId,
          'maxConcurrent': plan.maxConcurrent,
          'waiters': <Map<String, Object>>[
            for (final candidate in plan.candidates)
              _nativeBackgroundWaiterPayloadV2(candidate),
          ],
        },
    ];
  }

  /// Native plan export reserves candidates transiently so Dart cannot race the
  /// handoff while the MethodChannel snapshot is in flight. Once persistence is
  /// acknowledged (or fails), foreground Dart may schedule them again. The
  /// native queue independently filters children that already exist in URLSession.
  void releaseNativeBackgroundOffersV2() {
    _durableParallel?.releaseNativeBackgroundOffers();
  }

  @override
  Future<DownloadTransportHandle> startMangaChapter(
    MangaChapterTransportSpecV2 spec,
  ) async {
    await initialize();
    await configurePackageNotificationsV2(
      _downloader,
      _notificationPreferences(),
    );
    final transport = MangaChapterTransportV2(
      startPage: _startMangaPageTaskV2,
    );
    return transport.start(spec);
  }

  Future<DownloadTransportHandle> _startMangaPageTaskV2(
    MangaChapterPageTaskV2 page,
  ) async {
    await initialize();

    // Older Manga builds placed page children in the normal V2 group, which
    // makes them inherit user-facing notifications. Replace such an exact
    // child once so upgraded installs also become notification-silent.
    final tracked = _downloader.transfers.forId(page.taskId);
    final persisted = await _downloader.database.recordForId(page.taskId);
    final existingTask = tracked?.task ?? persisted?.task;
    if (existingTask != null &&
        existingTask.group != kDownloadV2SilentPackageGroup) {
      final legacy = await attach(page.taskId);
      await legacy?.cancel();
      await removeTracking(page.taskId);
    }

    final existing = await attach(page.taskId);
    final reusable = await reusableMangaPageHandleV2(
      existing: existing,
      destinationPath: page.destinationPath,
      removeTracking: () => removeTracking(page.taskId),
    );
    if (reusable != null) return reusable;

    final prefs = _notificationPreferences();
    final task = await packageMangaPageTaskForV2(
      page,
      userInitiated: prefs.running,
      showRunningNotification: prefs.running,
    );
    final transfer = await _downloader.transfers.start(task);
    return _handleFor(transfer);
  }

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    await initialize();
    final prefs = _notificationPreferences();
    await configurePackageNotificationsV2(_downloader, prefs);

    if (_isIOS()) {
      final capability = await (_rangeCapabilityProbe?.call(spec) ??
          _probeRangeCapabilityV2(spec));
      if (capability.supportsRanges && capability.totalBytes > 0) {
        final parent = await packageTaskForV2(
          spec,
          userInitiated: prefs.running,
          group: kDownloadV2DurableParallelGroup,
          isIOS: true,
        );
        if (parent is ParallelDownloadTask) {
          final handle = await _durableHandleFor(
            parent,
            capability.totalBytes,
            initialStatus: DownloadTransportStatus.queued,
            restoreOnly: false,
          );
          return handle;
        }
      }

      // Parallel byte ranges are safe only after proving Range support and a
      // trustworthy total size. Fall back to one normal package task otherwise.
      spec = DownloadTaskSpecV2(
        taskId: spec.taskId,
        url: spec.url,
        destinationPath: spec.destinationPath,
        headers: spec.headers,
        allowPause: spec.allowPause,
        retries: spec.retries,
        parallelChunks: 1,
        expectedBytes: spec.expectedBytes,
      );
    }

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

    final durable = _durableHandles[taskId];
    if (durable != null) return durable;

    final record = await _downloader.database.recordForId(taskId);
    if (record != null &&
        record.task is ParallelDownloadTask &&
        record.task.group == kDownloadV2DurableParallelGroup) {
      final parent = record.task as ParallelDownloadTask;
      return _durableHandleFor(
        parent,
        record.expectedFileSize,
        initialStatus: _snapshotStatusFromRecord(record),
        restoreOnly: true,
      );
    }

    final tracked = _downloader.transfers.forId(taskId);
    if (tracked != null &&
        !_isDurableInternalTask(tracked.task)) {
      return _handleFor(tracked);
    }

    // Rehydrate package persistence first, then select only by the exact
    // current task ID. Never attach by URL/filename heuristics.
    final rehydrated = await _downloader.transfers.rehydrateFromDatabase();
    for (final transfer in rehydrated) {
      if (transfer.taskId == taskId &&
          !_isDurableInternalTask(transfer.task)) {
        return _handleFor(transfer);
      }
    }
    return null;
  }

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async {
    await initialize();
    final result = <DownloadTransportHandle>[];

    for (final record in await _downloader.database.allRecords()) {
      if (record.task is ParallelDownloadTask &&
          record.task.group == kDownloadV2DurableParallelGroup) {
        result.add(
          await _durableHandleFor(
            record.task as ParallelDownloadTask,
            record.expectedFileSize,
            initialStatus: _snapshotStatusFromRecord(record),
            restoreOnly: true,
          ),
        );
      }
    }

    final transfers = await _downloader.transfers.rehydrateFromDatabase();
    for (final transfer in transfers) {
      if (_isDurableInternalTask(transfer.task)) continue;
      result.add(_handleFor(transfer));
    }
    return List<DownloadTransportHandle>.unmodifiable(result);
  }

  Future<void> _recordStartupInventory() async {
    final records = await _downloader.database.allRecords();
    final packageTasks = await _downloader.allTasks(allGroups: true);
    // ignore: invalid_use_of_visible_for_testing_member
    final pausedTasks =
        await _downloader.database.storage.retrieveAllPausedTasks();
    var resumeDataCount = 0;
    for (final task in pausedTasks) {
      // ignore: invalid_use_of_visible_for_testing_member
      if (await _downloader.database.storage.retrieveResumeData(task.taskId) !=
          null) {
        resumeDataCount++;
      }
    }
    final activeDurable = activeDurablePartTaskIdsV2(
      packageTasks: packageTasks,
      pausedTasks: pausedTasks,
    );
    _diagnostics.recordTransport('startup.inventory', <String, Object?>{
      'recordCount': records.length,
      'nativeTaskCount': activeDurable.length,
      'count': packageTasks.length,
      'pausedTaskCount': pausedTasks.length,
      'resumeDataCount': resumeDataCount,
      'manifestPartCount': records
          .where((record) => record.task.group == kPersistentDownloadChunkGroup)
          .length,
      'activeConnections': activeDurable.length,
    });
  }

  @override
  Future<void> removeTracking(String taskId) async {
    await initialize();
    final durable = _durableHandles.remove(taskId);
    if (durable != null) {
      durable.dispose();
    }
    await _cleanupDurableChildTracking(taskId);
    _downloader.transfers.remove(taskId);
    _handles.remove(taskId)?.dispose();
    await _downloader.database.deleteRecordWithId(taskId);
  }

  Future<void> _cleanupDurableChildTracking(String parentTaskId) async {
    final records = await _downloader.database.allRecords(
      group: kPersistentDownloadChunkGroup,
    );
    final childIds = durableChildTaskIdsForParentV2(records, parentTaskId);
    if (childIds.isEmpty) return;

    for (final taskId in childIds) {
      _downloader.transfers.remove(taskId);
    }
    await Future.wait<void>([
      _downloader.database.deleteRecordsWithIds(childIds),
      // background_downloader 9.6.2 does not expose resume/paused cleanup on
      // FileDownloader. Keep the storage escape hatch confined to this adapter.
      // ignore: invalid_use_of_visible_for_testing_member
      ...childIds.map(_downloader.database.storage.removeResumeData),
      // ignore: invalid_use_of_visible_for_testing_member
      ...childIds.map(_downloader.database.storage.removePausedTask),
    ]);
  }

  Future<Set<String>> _activeDurablePartTaskIds() async {
    final packageTasks = await _downloader.allTasks(allGroups: true);
    // background_downloader includes stored paused tasks in allTasks().
    // Keep that package detail inside this adapter: paused children must not
    // reserve a native-writer slot after an app relaunch.
    // ignore: invalid_use_of_visible_for_testing_member
    final pausedTasks =
        await _downloader.database.storage.retrieveAllPausedTasks();
    final active = activeDurablePartTaskIdsV2(
      packageTasks: packageTasks,
      pausedTasks: pausedTasks,
    );
    final pausedIds = pausedTasks.map((task) => task.taskId).toSet();
    final pausedDurableCount = packageTasks
        .where(
          (task) =>
              task.group == kPersistentDownloadChunkGroup &&
              pausedIds.contains(task.taskId),
        )
        .length;
    final signature =
        '${packageTasks.length}:${pausedTasks.length}:${active.length}:$pausedDurableCount';
    if (_lastOwnershipSignature != signature) {
      _lastOwnershipSignature = signature;
      _diagnostics.recordTransport('ownership.snapshot', <String, Object?>{
        'nativeTaskCount': active.length,
        'pausedTaskCount': pausedTasks.length,
        'activeConnections': active.length,
        'packageTaskCount': packageTasks.length,
        'count': pausedDurableCount,
        'reason': pausedDurableCount > 0 ? 'pausedExcluded' : 'nativeOwners',
      });
    }
    return active;
  }

  bool _isDurableInternalTask(Task task) =>
      task.group == kDownloadV2DurableParallelGroup ||
      task.group == kPersistentDownloadChunkGroup;

  DownloadTransportStatus _snapshotStatusFromRecord(TaskRecord record) {
    final status = transportStatusFromPackage(
      record.status,
      TransferHoldReason.none,
    );
    return status == DownloadTransportStatus.missing
        ? DownloadTransportStatus.paused
        : status;
  }

  PersistentParallelDownload _ensureDurableParallelCoordinator() {
    final existing = _durableParallel;
    if (existing != null) return existing;

    final coordinator = PersistentParallelDownload(
      startPart: _startDurablePart,
      pausePart: (task) async {
        if (!await _downloader.pause(task)) {
          throw StateError('Native range did not pause safely');
        }
      },
      cancelParts: (ids) async {
        await _downloader.cancelTasksWithIds(ids);
      },
      saveRecord: _saveDurableRecord,
      recordForId: _downloader.database.recordForId,
      livePartIds: _activeDurablePartTaskIds,
      shouldDrainPartOnPause: (_) => _isIOS(),
      onUpdate: (update) {
        _durableHandles[update.task.taskId]?.accept(update);
        if (update is TaskStatusUpdate &&
            update.status == TaskStatus.complete) {
          unawaited(
            _cleanupDurableChildTracking(update.task.taskId).catchError(
              (Object _, StackTrace __) {},
            ),
          );
        }
      },
      onPartProgress: (_, _, _) {},
      onSourceRefreshNeeded: (parentTaskId) {
        _durableHandles[parentTaskId]?.sourceExpired();
      },
      diagnosticEvent: _diagnostics.recordTransport,
    );
    _durableParallel = coordinator;
    _durableUpdatesSubscription ??= _downloader.updates.listen((update) {
      coordinator.handleUpdate(update);
    });
    return coordinator;
  }

  Future<bool> _startDurablePart(
    DownloadTask task,
    double progress,
    int size,
  ) async {
    final range = _diagnosticRangeBoundsV2(task);
    final liveTaskIds = await _activeDurablePartTaskIds();
    if (liveTaskIds.contains(task.taskId)) {
      _diagnostics.recordTransport('recovery.decision', <String, Object?>{
        'taskId': downloadInternalParentTaskId(task),
        'childTaskId': task.taskId,
        'reason': 'nativeOwnerPresent',
        'nativeLive': true,
        'rangeStart': range?.$1,
        'rangeEnd': range?.$2,
      });
      return true;
    }

    // Read package-owned pause/resume state only for diagnostics. The package
    // remains the sole authority that consumes resumeData.
    // ignore: invalid_use_of_visible_for_testing_member
    final resumeData =
        await _downloader.database.storage.retrieveResumeData(task.taskId);
    // ignore: invalid_use_of_visible_for_testing_member
    final pausedTask =
        await _downloader.database.storage.retrievePausedTask(task.taskId);
    final resumeDataPresent = resumeData != null;
    final packagePaused = pausedTask != null;

    try {
      if (await _downloader.taskCanResume(task) &&
          await _downloader.resume(task)) {
        _diagnostics.recordTransport('recovery.decision', <String, Object?>{
          'taskId': downloadInternalParentTaskId(task),
          'childTaskId': task.taskId,
          'reason': resumeDataPresent ? 'resumeData' : 'nativeResume',
          'resumeDataPresent': resumeDataPresent,
          'packagePaused': packagePaused,
          'rangeStart': range?.$1,
          'rangeEnd': range?.$2,
          'result': true,
        });
        return true;
      }
    } catch (error) {
      _diagnostics.recordTransport('recovery.anomaly', <String, Object?>{
        'taskId': downloadInternalParentTaskId(task),
        'childTaskId': task.taskId,
        'anomaly': 'resumeRejected',
        'resumeDataPresent': resumeDataPresent,
        'packagePaused': packagePaused,
        'errorType': error.runtimeType.toString(),
        'rangeStart': range?.$1,
        'rangeEnd': range?.$2,
      });
      // Resume data is an optimization for one immutable range, never durable
      // authority for the logical episode.
    }

    if (progress > 0) {
      _diagnostics.recordTransport('recovery.anomaly', <String, Object?>{
        'taskId': downloadInternalParentTaskId(task),
        'childTaskId': task.taskId,
        'anomaly': resumeDataPresent ? 'resumeFailed' : 'resumeDataMissing',
        'resumeDataPresent': resumeDataPresent,
        'packagePaused': packagePaused,
        'liveBytes': (size * progress).round(),
        'rangeStart': range?.$1,
        'rangeEnd': range?.$2,
      });
      _ensureDurableParallelCoordinator().resetUndurablePartProgress(
        task.taskId,
        durableBytes: 0,
      );
      await _downloader.database.updateRecord(
        TaskRecord(task, TaskStatus.paused, 0, size),
      );
    }

    final enqueued = await _downloader.enqueue(task);
    _diagnostics.recordTransport('recovery.decision', <String, Object?>{
      'taskId': downloadInternalParentTaskId(task),
      'childTaskId': task.taskId,
      'reason': progress > 0 ? 'rangeRestart' : 'freshEnqueue',
      'resumeDataPresent': resumeDataPresent,
      'packagePaused': packagePaused,
      'rangeStart': range?.$1,
      'rangeEnd': range?.$2,
      'result': enqueued,
    });
    return enqueued;
  }

  Future<void> _saveDurableRecord(TaskRecord record) async {
    if (record.task.group == kDownloadV2DurableParallelGroup) {
      // Keep the custom parent out of background_downloader's killed-task
      // rescheduler. The V2 logical record decides whether this exact manifest
      // resumes after recreation; child URLSession tasks remain package-owned.
      final safeStatus = switch (record.status) {
        TaskStatus.complete => TaskStatus.complete,
        TaskStatus.canceled => TaskStatus.canceled,
        _ => TaskStatus.paused,
      };
      await _downloader.database.updateRecord(
        TaskRecord(
          record.task,
          safeStatus,
          record.progress,
          record.expectedFileSize,
        ),
      );
      return;
    }
    await _downloader.database.updateRecord(record);
  }

  Future<_DurableParallelDownloadTransportHandle> _durableHandleFor(
    ParallelDownloadTask parent,
    int totalBytes, {
    required DownloadTransportStatus initialStatus,
    required bool restoreOnly,
  }) async {
    final existing = _durableHandles[parent.taskId];
    if (existing != null) return existing;

    final coordinator = _ensureDurableParallelCoordinator();
    final restored = await coordinator.restore(parent);
    final handle = _DurableParallelDownloadTransportHandle(
      parent: parent,
      totalBytes: totalBytes,
      coordinator: coordinator,
      initialStatus: restored
          ? initialStatus
          : (restoreOnly
                ? DownloadTransportStatus.missing
                : DownloadTransportStatus.queued),
    );
    _durableHandles[parent.taskId] = handle;

    if (!restoreOnly) {
      final started = await coordinator.start(parent, totalBytes);
      if (!started) {
        handle.fail('Unable to start durable parallel transfer');
      }
    }
    return handle;
  }

  _PackageDownloadTransportHandle _handleFor(Transfer transfer) {
    final existing = _handles[transfer.taskId];
    if (existing != null && identical(existing.transfer, transfer)) {
      return existing;
    }
    existing?.dispose();
    final handle = transfer.task is ParallelDownloadTask
        ? _PackageDownloadTransportHandle(transfer, _downloader)
        : _SelfSettlingPackageDownloadTransportHandle(transfer, _downloader);
    _handles[transfer.taskId] = handle;
    return handle;
  }
}

/// Returns the requested parent width. On iOS the gateway routes widths greater
/// than one through AnimeWitcher's durable immutable-range coordinator instead
/// of background_downloader's ParallelDownloadTask resume implementation.
int effectivePackageParallelChunksV2(
  int requestedChunks, {
  bool? isIOS,
}) {
  assert(requestedChunks > 0);
  return requestedChunks;
}

Future<DownloadTransportHandle?> reusableMangaPageHandleV2({
  required DownloadTransportHandle? existing,
  required String destinationPath,
  required Future<void> Function() removeTracking,
}) async {
  if (existing == null) return null;

  final status = existing.current.status;
  if (status == DownloadTransportStatus.complete) {
    final file = File(destinationPath);
    if (await file.exists() && await file.length() > 0) return existing;
    await removeTracking();
    return null;
  }

  if (status == DownloadTransportStatus.paused) {
    final resumed = await existing.resume();
    if (resumed) return existing;

    // A recovered Manga page must never leave an active chapter parked on a
    // stale paused package task. Cancel/forget it and let the caller recreate
    // only this page from its fresh chapter-page descriptor.
    await existing.cancel();
    await removeTracking();
    return null;
  }

  if (status == DownloadTransportStatus.failed ||
      status == DownloadTransportStatus.canceled ||
      status == DownloadTransportStatus.missing) {
    await removeTracking();
    return null;
  }
  return existing;
}

/// Maps one AnimeWitcher parent transfer spec to exactly one package task.
///
/// A request greater than one maps to one [ParallelDownloadTask] descriptor.
/// The production gateway may execute that descriptor through durable immutable
/// ranges on iOS while preserving the same parent task identity.
Future<DownloadTask> packageMangaPageTaskForV2(
  MangaChapterPageTaskV2 page, {
  required bool userInitiated,
  bool showRunningNotification = true,
}) {
  final parentId = page.taskId.replaceFirst(RegExp(r'_p\d{4,}$'), '');
  return packageTaskForV2(
    DownloadTaskSpecV2(
      taskId: page.taskId,
      url: page.url,
      destinationPath: page.destinationPath,
      headers: page.headers,
      allowPause: true,
      retries: page.retries,
      parallelChunks: 1,
    ),
    userInitiated: userInitiated,
    group: kDownloadV2SilentPackageGroup,
    notificationConfig: TaskNotificationConfig(
      running: showRunningNotification
          ? const TaskNotification(
              'Downloading manga chapter',
              'Pages are downloading',
            )
          : null,
      groupNotificationId: 'manga_$parentId',
    ),
    // Manga page children are implementation details, never user notifications.
    isIOS: false,
  );
}

Future<DownloadTask> packageTaskForV2(
  DownloadTaskSpecV2 spec, {
  bool userInitiated = true,
  String group = kDownloadV2PackageGroup,
  bool? isIOS,
  TaskNotificationConfig? notificationConfig,
}) async {
  final (baseDirectory, directory, filename) = await _destinationFor(
    spec.destinationPath,
  );
  final transferHints = <TransferHint>{
    TransferHint.largeFile,
    if (userInitiated) TransferHint.userInitiated,
  };
  final parallelChunks = effectivePackageParallelChunksV2(
    spec.parallelChunks,
    isIOS: isIOS,
  );

  if (parallelChunks > 1 || isIOS == true) {
    return ParallelDownloadTask(
      taskId: spec.taskId,
      url: spec.url,
      filename: filename,
      headers: spec.headers,
      chunks: parallelChunks,
      directory: directory,
      baseDirectory: baseDirectory,
      group: group,
      displayName: filename,
      transferHints: transferHints,
      updates: Updates.statusAndProgress,
      retries: spec.retries,
      allowPause: spec.allowPause,
      notificationConfig: notificationConfig,
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
    notificationConfig: notificationConfig,
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

typedef DownloadRangeCapabilityV2 = ({
  int totalBytes,
  bool supportsRanges,
});

Future<DownloadRangeCapabilityV2> _probeRangeCapabilityV2(
  DownloadTaskSpecV2 spec,
) async {
  final client = HttpClient()..autoUncompress = false;
  try {
    final request = await client
        .getUrl(Uri.parse(spec.url))
        .timeout(const Duration(seconds: 10));
    for (final entry in spec.headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close().timeout(const Duration(seconds: 10));
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    final total = parseRangeProbeTotalBytesV2(contentRange);
    final subscription = response.listen((_) {});
    await subscription.cancel();
    return (
      totalBytes: total ?? spec.expectedBytes ?? -1,
      supportsRanges:
          response.statusCode == HttpStatus.partialContent &&
          total != null &&
          total > 0,
    );
  } catch (_) {
    return (
      totalBytes: spec.expectedBytes ?? -1,
      supportsRanges: false,
    );
  } finally {
    client.close(force: true);
  }
}

Map<String, Object> _nativeBackgroundWaiterPayloadV2(
  NativeParallelBackgroundCandidate candidate,
) {
  final task = candidate.task;
  final range = _diagnosticRangeBoundsV2(task);
  return <String, Object>{
    'taskId': task.taskId,
    'taskJson': jsonEncode(task.toJson()),
    'displayName': task.displayName,
    'url': task.url,
    'headers': Map<String, String>.from(task.headers),
    'filename': task.filename,
    'directory': task.directory,
    'group': task.group,
    'progress': 0.0,
    if (range != null) 'expectedBytes': range.$2 - range.$1 + 1,
    'generation': candidate.generation,
    'claimId': candidate.claimId,
    'claimLeaseMillis': candidate.claimLease.inMilliseconds,
  };
}

(int, int)? _diagnosticRangeBoundsV2(DownloadTask task) {
  String? value;
  for (final entry in task.headers.entries) {
    if (entry.key.toLowerCase() == 'range') {
      value = entry.value;
      break;
    }
  }
  final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(value ?? '');
  if (match == null) return null;
  final start = int.tryParse(match[1]!);
  final end = int.tryParse(match[2]!);
  if (start == null || end == null || start < 0 || end < start) return null;
  return (start, end);
}

int? parseRangeProbeTotalBytesV2(String? contentRange) {
  final value = contentRange?.trim();
  if (value == null || value.isEmpty) return null;
  final match = RegExp(
    r'^bytes\s+0\s*-\s*0\s*/\s*(\d+)\s*$',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) return null;
  final total = int.tryParse(match[1]!);
  return total != null && total > 0 ? total : null;
}

DownloadTransportStatus durableParallelProgressStatusV2({
  required double progress,
  required bool parentActive,
}) {
  if (progress >= 1 && !parentActive) return DownloadTransportStatus.complete;
  return parentActive
      ? DownloadTransportStatus.running
      : DownloadTransportStatus.paused;
}

DownloadTransportSnapshot durableParallelInitialSnapshotV2({
  required String taskId,
  required DownloadTransportStatus initialStatus,
  required int totalBytes,
  required double? restoredProgress,
  required int? durableBytes,
  int? configuredConnections,
  int? activeConnections,
}) {
  final knownTotal = totalBytes > 0 ? totalBytes : null;
  final complete = initialStatus == DownloadTransportStatus.complete;
  final progress = complete
      ? 1.0
      : (restoredProgress ?? 0).clamp(0.0, 1.0).toDouble();
  return DownloadTransportSnapshot(
    taskId: taskId,
    status: initialStatus,
    progress: progress,
    transferredBytes: complete ? knownTotal : durableBytes,
    totalBytes: knownTotal,
    configuredConnections: configuredConnections,
    activeConnections: activeConnections,
  );
}

DownloadTransportSnapshot durableParallelLiveSnapshotV2({
  required String taskId,
  required double liveProgress,
  required int totalBytes,
  required int? durableBytes,
  required bool parentActive,
  required int configuredConnections,
  required int activeConnections,
  required double networkSpeedMBps,
  required Duration timeRemaining,
}) {
  final progress = liveProgress.clamp(0.0, 1.0).toDouble();
  final knownTotal = totalBytes > 0 ? totalBytes : null;
  final liveBytes = knownTotal == null ? null : (knownTotal * progress).round();
  var transferredBytes = liveBytes;
  if (durableBytes != null &&
      (transferredBytes == null || durableBytes > transferredBytes)) {
    transferredBytes = durableBytes;
  }
  return DownloadTransportSnapshot(
    taskId: taskId,
    status: durableParallelProgressStatusV2(
      progress: progress,
      parentActive: parentActive,
    ),
    progress: progress,
    transferredBytes: transferredBytes,
    totalBytes: knownTotal,
    configuredConnections: configuredConnections,
    activeConnections: activeConnections,
    networkSpeedMBps: networkSpeedMBps,
    timeRemaining: timeRemaining,
  );
}

final class _DurableParallelDownloadTransportHandle
    implements
        DownloadTransportHandle,
        SelfSettlingParallelDownloadTransportHandleV2 {
  _DurableParallelDownloadTransportHandle({
    required this.parent,
    required this.totalBytes,
    required this.coordinator,
    required DownloadTransportStatus initialStatus,
  }) : _current = durableParallelInitialSnapshotV2(
         taskId: parent.taskId,
         initialStatus: initialStatus,
         totalBytes: totalBytes,
         restoredProgress: coordinator.durableProgressFor(parent.taskId),
         durableBytes: coordinator.durableBytesFor(parent.taskId),
         configuredConnections: parent.chunks,
         activeConnections:
             coordinator.activeConnectionCountFor(parent.taskId) ?? 0,
       );

  final ParallelDownloadTask parent;
  final int totalBytes;
  final PersistentParallelDownload coordinator;
  final StreamController<DownloadTransportSnapshot> _snapshots =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);
  DownloadTransportSnapshot _current;
  bool _disposed = false;

  @override
  String get taskId => parent.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<bool> pause() =>
      coordinator.pause(parent, preserveLiveParts: Platform.isIOS);

  @override
  Future<bool> resume() => coordinator.start(parent, totalBytes);

  @override
  Future<bool> cancel() async {
    await coordinator.cancel(parent);
    if (_current.status != DownloadTransportStatus.canceled) {
      _emit(
        DownloadTransportSnapshot(
          taskId: taskId,
          status: DownloadTransportStatus.canceled,
          progress: _current.progress,
          transferredBytes: _current.transferredBytes,
          totalBytes: _current.totalBytes,
          configuredConnections: parent.chunks,
          activeConnections:
              coordinator.activeConnectionCountFor(taskId) ?? 0,
        ),
      );
    }
    return true;
  }

  void accept(TaskUpdate update) {
    if (_disposed || update.task.taskId != taskId) return;
    if (update is TaskProgressUpdate) {
      final total = update.expectedFileSize > 0
          ? update.expectedFileSize
          : totalBytes;
      _emit(
        durableParallelLiveSnapshotV2(
          taskId: taskId,
          liveProgress: update.progress,
          totalBytes: total,
          durableBytes: coordinator.durableBytesFor(taskId),
          parentActive: coordinator.isActive(taskId),
          configuredConnections: parent.chunks,
          activeConnections:
              coordinator.activeConnectionCountFor(taskId) ?? 0,
          networkSpeedMBps: update.networkSpeed,
          timeRemaining: update.timeRemaining,
        ),
      );
      return;
    }
    if (update is TaskStatusUpdate) {
      final status = transportStatusFromPackage(
        update.status,
        TransferHoldReason.none,
      );
      final durableBytes = coordinator.durableBytesFor(taskId);
      final currentBytes = _current.transferredBytes;
      final transferredBytes = durableBytes == null
          ? currentBytes
          : currentBytes == null || durableBytes > currentBytes
          ? durableBytes
          : currentBytes;
      _emit(
        DownloadTransportSnapshot(
          taskId: taskId,
          status: status,
          progress: _current.progress,
          transferredBytes: transferredBytes,
          totalBytes: _current.totalBytes,
          configuredConnections: parent.chunks,
          activeConnections:
              coordinator.activeConnectionCountFor(taskId) ?? 0,
          failureCategory: _failureCategory(update.status, update.exception),
          failureMessage: update.exception?.toString(),
        ),
      );
    }
  }

  void sourceExpired() {
    _emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.failed,
        progress: _current.progress,
        transferredBytes:
            coordinator.durableBytesFor(taskId) ?? _current.transferredBytes,
        totalBytes: _current.totalBytes,
        configuredConnections: parent.chunks,
        activeConnections: coordinator.activeConnectionCountFor(taskId) ?? 0,
        failureCategory: DownloadFailureCategory.sourceExpired,
        failureMessage: 'Download source expired',
      ),
    );
  }

  void fail(String message) {
    _emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.failed,
        progress: _current.progress,
        transferredBytes: _current.transferredBytes,
        totalBytes: _current.totalBytes,
        configuredConnections: parent.chunks,
        activeConnections: coordinator.activeConnectionCountFor(taskId) ?? 0,
        failureCategory: DownloadFailureCategory.transport,
        failureMessage: message,
      ),
    );
  }

  void _emit(DownloadTransportSnapshot snapshot) {
    if (_disposed || _snapshots.isClosed) return;
    _current = snapshot;
    _snapshots.add(snapshot);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_snapshots.close());
  }
}

class _PackageDownloadTransportHandle implements DownloadTransportHandle {
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
    if (Platform.isIOS && task is ParallelDownloadTask) {
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

final class _SelfSettlingPackageDownloadTransportHandle
    extends _PackageDownloadTransportHandle
    implements SelfSettlingParallelDownloadTransportHandleV2 {
  _SelfSettlingPackageDownloadTransportHandle(
    Transfer transfer,
    FileDownloader downloader,
  ) : super(transfer, downloader);
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
  final configuredConnections = parallelParent
      ? (transfer.task as ParallelDownloadTask).chunks
      : 1;
  final activeConnections = parallelParent
      ? null
      : (projectedStatus == DownloadTransportStatus.running ? 1 : 0);

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
    configuredConnections: configuredConnections,
    activeConnections: activeConnections,
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
