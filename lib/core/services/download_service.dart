import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:collection/collection.dart';
import 'package:permission_handler/permission_handler.dart'
    hide PermissionStatus;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:disk_usage/disk_usage.dart';

import '../domain/entity/multimedia_item.dart';
import '../router/app_router.dart';
import '../storage/storage_service.dart';
import '../storage/settings_repository.dart';
import '../../features/skip/data/aniskip_service.dart';
import '../../features/skip/data/mal_id_resolver.dart';
import '../../features/skip/data/skip_segment_cache.dart';

import '../network/dio_client_provider.dart';
import '../utils/download_resume.dart';
import '../utils/download_cleanup.dart';
import '../utils/episode_label.dart';
import 'download_concurrency.dart';
import 'download_parallel.dart';
import 'persistent_parallel_download.dart';
import 'download_range_transfer.dart';
import 'download_diagnostic_log.dart';
import 'download_retry_policy.dart';
import 'download_host_profile.dart';
import 'download_job_state.dart';
import 'download_job_store.dart';
import 'download_resource_identity.dart';
import 'download_logical_identity.dart';
import 'download_service_readiness.dart';
import 'download_url_refresh.dart';
import 'download_plugin_compat.dart';
import 'download_transport.dart';
import 'download_continued_processing_service.dart';
import 'download_telemetry.dart';

part 'download_service.g.dart';

@Riverpod(keepAlive: true)
DownloadService downloadService(Ref ref) {
  final service = DownloadService(ref);
  // Cancel the FileDownloader stream subscription when the ProviderScope is
  // disposed (e.g. on app restart). Without this the subscription outlives the
  // scope and the next DownloadService.init() throws "Stream already listened".
  ref.onDispose(service.dispose);
  return service;
}

enum DownloadCommandOutcome {
  running,
  attached,
  queued,
  paused,
  settlingOwnership,
  alreadyComplete,
  restartRequired,
  recoverableFailure,
  serviceUnavailable,
  missingState,
  terminal,
}

class _DownloadRestartRequiredException implements Exception {
  final String taskId;

  const _DownloadRestartRequiredException(this.taskId);
}

DownloadCommandOutcome downloadCommandOutcomeForJobState(
  DownloadJobState? state,
) {
  return switch (state) {
    DownloadJobState.running ||
    DownloadJobState.starting ||
    DownloadJobState.assembling ||
    DownloadJobState.verifying => DownloadCommandOutcome.running,
    DownloadJobState.queued => DownloadCommandOutcome.queued,
    DownloadJobState.retryWaiting ||
    DownloadJobState.waitingForNetwork ||
    DownloadJobState.interrupted => DownloadCommandOutcome.recoverableFailure,
    DownloadJobState.pausing => DownloadCommandOutcome.settlingOwnership,
    DownloadJobState.pausedByUser => DownloadCommandOutcome.paused,
    DownloadJobState.completed => DownloadCommandOutcome.alreadyComplete,
    DownloadJobState.canceled => DownloadCommandOutcome.terminal,
    DownloadJobState.orphaned || null => DownloadCommandOutcome.missingState,
  };
}

DownloadCommandOutcome resolvePauseCommandOutcome({
  required DownloadJobState? state,
  required DownloadRuntimeOwnership ownership,
}) {
  final durable = downloadCommandOutcomeForJobState(state);
  if (durable == DownloadCommandOutcome.alreadyComplete ||
      durable == DownloadCommandOutcome.terminal) {
    return durable;
  }
  if (ownership != DownloadRuntimeOwnership.notOwned) {
    return DownloadCommandOutcome.settlingOwnership;
  }
  return durable;
}

DownloadCommandOutcome resolveResumeCommandOutcome({
  required DownloadJobState? state,
  required DownloadRuntimeOwnership ownership,
}) {
  final durable = downloadCommandOutcomeForJobState(state);
  if (durable == DownloadCommandOutcome.alreadyComplete ||
      durable == DownloadCommandOutcome.terminal) {
    return durable;
  }
  return switch (ownership) {
    DownloadRuntimeOwnership.owned => DownloadCommandOutcome.attached,
    DownloadRuntimeOwnership.settling || DownloadRuntimeOwnership.unknown =>
      DownloadCommandOutcome.settlingOwnership,
    DownloadRuntimeOwnership.notOwned => durable,
  };
}

DownloadCommandOutcome resolveCancelCommandOutcome({
  required DownloadJobState? state,
  required DownloadRuntimeOwnership ownership,
}) {
  if (ownership != DownloadRuntimeOwnership.notOwned) {
    return DownloadCommandOutcome.settlingOwnership;
  }
  if (state == null || state == DownloadJobState.canceled) {
    return DownloadCommandOutcome.terminal;
  }
  return downloadCommandOutcomeForJobState(state);
}

class DownloadProgressData {
  final String taskId;
  final double progress;
  final double networkSpeed; // MB/s
  final Duration timeRemaining;
  final int totalSize; // Bytes
  final TaskStatus status;

  DownloadProgressData({
    required this.taskId,
    required double progress,
    required this.networkSpeed,
    required this.timeRemaining,
    required this.status,
    this.totalSize = -1,
  }) : progress = progress.clamp(0.0, 1.0);

  String get speedString {
    if (status == TaskStatus.paused) return 'متوقف';
    if (progress >= 1.0) return 'اكتمل';
    if (networkSpeed < 0) return 'جارٍ الحساب…';
    if (networkSpeed == 0) return '0 MB/s';

    if (networkSpeed < 1.0) {
      return '${(networkSpeed * 1000).toStringAsFixed(2)} KB/s';
    }
    return '${networkSpeed.toStringAsFixed(2)} MB/s';
  }
}

@Riverpod(keepAlive: true)
class DownloadProgressNotifier extends _$DownloadProgressNotifier {
  static const Duration _uiSampleInterval = Duration(seconds: 1);
  static const Duration _staleMetricInterval = kDownloadTelemetryStaleAfter;
  final Map<String, Timer> _timers = <String, Timer>{};
  final Map<String, Timer> _staleTimers = <String, Timer>{};
  final Map<String, DownloadProgressData> _pending =
      <String, DownloadProgressData>{};
  final Map<String, DateTime> _lastPublished = <String, DateTime>{};

  @override
  Map<String, DownloadProgressData> build() {
    ref.onDispose(() {
      for (final timer in _timers.values) {
        timer.cancel();
      }
      for (final timer in _staleTimers.values) {
        timer.cancel();
      }
      _timers.clear();
      _staleTimers.clear();
      _pending.clear();
      _lastPublished.clear();
    });
    return {};
  }

  void update(String url, DownloadProgressData data) {
    final previous = state[url];
    final statusChanged = previous == null || previous.status != data.status;

    if (data.status == TaskStatus.running && data.progress < 1.0) {
      _armStaleMetricTimer(url, data.taskId);
    } else {
      _staleTimers.remove(url)?.cancel();
    }

    // Commands and lifecycle changes must feel instantaneous. Only repeated
    // running metrics are sampled: downloaded MB, percentage, speed and ETA
    // then move together once per second instead of repainting dozens of times.
    if (statusChanged ||
        data.status != TaskStatus.running ||
        data.progress >= 1.0) {
      _publishNow(url, data);
      return;
    }

    _pending[url] = data;
    final last = _lastPublished[url];
    if (last == null) {
      _publishNow(url, data);
      return;
    }

    final elapsed = DateTime.now().difference(last);
    if (elapsed >= _uiSampleInterval) {
      _publishPending(url);
      return;
    }

    _timers[url] ??= Timer(_uiSampleInterval - elapsed, () {
      _timers.remove(url);
      _publishPending(url);
    });
  }

  void _armStaleMetricTimer(String url, String taskId) {
    _staleTimers.remove(url)?.cancel();
    _staleTimers[url] = Timer(_staleMetricInterval, () {
      _staleTimers.remove(url);
      final current = state[url];
      if (current == null ||
          current.taskId != taskId ||
          current.status != TaskStatus.running ||
          current.progress >= 1.0) {
        return;
      }
      _timers.remove(url)?.cancel();
      _pending.remove(url);
      _lastPublished[url] = DateTime.now();
      state = {
        ...state,
        url: DownloadProgressData(
          taskId: current.taskId,
          progress: current.progress,
          networkSpeed: 0,
          timeRemaining: Duration.zero,
          totalSize: current.totalSize,
          status: current.status,
        ),
      };
    });
  }

  void _publishNow(String url, DownloadProgressData data) {
    _timers.remove(url)?.cancel();
    _pending.remove(url);
    _lastPublished[url] = DateTime.now();
    state = {...state, url: data};
  }

  void _publishPending(String url) {
    _timers.remove(url)?.cancel();
    final data = _pending.remove(url);
    if (data == null) return;
    _lastPublished[url] = DateTime.now();
    state = {...state, url: data};
  }

  void remove(String url) {
    _timers.remove(url)?.cancel();
    _staleTimers.remove(url)?.cancel();
    _pending.remove(url);
    _lastPublished.remove(url);
    state = {...state}..remove(url);
  }
}

@Riverpod(keepAlive: true)
class DownloadChunkProgress extends _$DownloadChunkProgress {
  @override
  Map<String, Map<String, double>> build() => {};

  void update({
    required String parentTaskId,
    required String chunkTaskId,
    double? progress,
    int? statusOrdinal,
  }) {
    final chunks = Map<String, double>.from(
      state[parentTaskId] ?? const <String, double>{},
    );
    if (progress != null && progress >= 0 && progress <= 1) {
      chunks[chunkTaskId] = progress.clamp(0.0, 1.0).toDouble();
    }
    if (statusOrdinal == TaskStatus.complete.index) {
      chunks[chunkTaskId] = 1.0;
    }
    state = {...state, parentTaskId: chunks};
  }

  void remove(String parentTaskId) {
    if (!state.containsKey(parentTaskId)) return;
    state = {...state}..remove(parentTaskId);
  }
}

@Riverpod(keepAlive: true)
class ActiveDownloadsNotifier extends _$ActiveDownloadsNotifier {
  @override
  Set<String> build() => {};

  void add(String url) => state = {...state, url};
  void remove(String url) => state = {...state}..remove(url);
}

enum DownloadLifecycleCheckpointCommit { committed, rejected, failed }

@visibleForTesting
Future<DownloadLifecycleCheckpointCommit> commitAuthoritativeDownloadCheckpoint(
  Future<bool> Function() checkpoint,
) async {
  try {
    return await checkpoint()
        ? DownloadLifecycleCheckpointCommit.committed
        : DownloadLifecycleCheckpointCommit.rejected;
  } catch (_) {
    return DownloadLifecycleCheckpointCommit.failed;
  }
}

@visibleForTesting
class DownloadServiceTeardownBarrier {
  Future<void> _tail = Future<void>.value();

  Future<void> wait() => _tail;

  Future<void> run(Future<void> Function() teardown) {
    final next = _tail.then<void>(
      (_) => teardown(),
      onError: (Object _, StackTrace __) => teardown(),
    );
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }
}

class DownloadService {
  final diagnosticLog = DownloadDiagnosticLog(
    () async => Directory(
      p.join((await getApplicationDocumentsDirectory()).path, 'log'),
    ),
  );

  Future<void> setDiagnosticLogging(bool enabled) async {
    await _awaitCommandReadiness('setDiagnosticLogging');
    final previous = diagnosticLog.enabled;
    try {
      await diagnosticLog.configure(enabled);
      await _ref.read(storageServiceProvider).setDownloadDiagnosticLog(enabled);
      await _continuedProcessing.configureDiagnosticLog(enabled);
    } catch (_) {
      await diagnosticLog.configure(previous);
      rethrow;
    }
  }

  // FileDownloader().updates is a single-subscription stream that rejects
  // re-subscription even after cancel. Subscribe once as a static bridge so
  // each DownloadService instance can listen via the broadcast proxy instead.
  static StreamSubscription<TaskUpdate>? _fdSubscription;
  static final _sharedEvents = StreamController<TaskUpdate>.broadcast();
  static final DownloadServiceTeardownBarrier _teardownBarrier =
      DownloadServiceTeardownBarrier();

  final Ref _ref;
  final Dio _dio;
  final Set<String> _userPausedIds = {};
  final Set<String> _dequeuingPausedIds = {};
  late final DownloadContinuedProcessingService _continuedProcessing;
  final _updatesController = StreamController<TaskUpdate>.broadcast();
  final _parallelFailures =
      StreamController<ParallelAssemblyFailure>.broadcast();

  Stream<ParallelAssemblyFailure> get parallelFailures =>
      _parallelFailures.stream;
  StreamSubscription<TaskUpdate>? _updatesSubscription;
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _networkAvailable = true;
  bool _isInitialized = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  final DownloadServiceReadinessBarrier _readiness =
      DownloadServiceReadinessBarrier();
  late final PersistentParallelDownload _parallel;
  late final DownloadRangeTransfer _rangeTransfers;
  late final NativeSingleDownloadTransport _nativeTransport;
  late final DownloadHostProfileStore _hostProfiles;
  late final DownloadJobStore _jobStore;
  final DownloadTelemetryEstimator _telemetry = DownloadTelemetryEstimator();
  final Set<String> _expectedSizePersistedIds = <String>{};
  Future<void> _queueChain = Future<void>.value();
  final Set<String> _queueWaitingIds = {};
  final Set<String> _startingTaskIds = {};
  final Set<String> _refreshingParallelParentIds = <String>{};
  final Set<String> _terminalJobIds = <String>{};
  final List<String> _sessionOrder = [];
  bool _sessionOverlayActive = false;
  int _sessionCompletedCount = 0;
  int _sessionBatchTotal = 0;
  String _overlayCurrentTaskId = '';
  final Map<String, Map<String, Object>> _waitingPayloads = {};

  DownloadService(this._ref) : _dio = _ref.read(dioClientProvider) {
    _nativeTransport = NativeSingleDownloadTransport();
    _rangeTransfers = DownloadRangeTransfer(_dio, diagnosticLog: diagnosticLog);
    _hostProfiles = DownloadHostProfileStore(
      const HiveDownloadHostProfileBackend(),
    );
    _jobStore = DownloadJobStore(const HiveDownloadJobBackend());
    _parallel = PersistentParallelDownload(
      diagnosticLog: diagnosticLog,
      startPart: _startPart,
      pausePart: (task) async {
        if (!await _pauseTransfer(task)) {
          throw StateError('Native multipart child did not pause');
        }
      },
      cancelParts: (ids) async {
        for (final id in ids) {
          await _rangeTransfers.stop(id);
        }
        await FileDownloader().cancelTasksWithIds(ids);
        final unsettled = <String>[];
        for (final id in ids) {
          final ownership = await _waitForCancelOwnershipRelease(id);
          if (ownership != DownloadRuntimeOwnership.notOwned) {
            unsettled.add(id);
            continue;
          }
          await FileDownloader().database.deleteRecordWithId(id);
        }
        if (unsettled.isNotEmpty) {
          throw StateError(
            'Multipart cancel ownership did not settle: ${unsettled.join(',')}',
          );
        }
      },
      saveRecord: (record) => FileDownloader().database.updateRecord(record),
      recordForId: (id) => FileDownloader().database.recordForId(id),
      livePartIds: _livePartIds,
      shouldRecoverFailedStart: (childTaskId) =>
          _rangeTransfers.failureFor(childTaskId) == null,
      onSourceRefreshNeeded: _scheduleParallelParentRefresh,
      verifyPartSource: (task, file, bytes) =>
          _rangeTransfers.verifyExistingPrefix(
            id: task.taskId,
            url: task.url,
            headers: task.headers,
            file: file,
            written: bytes,
          ),
      shouldDrainPartOnPause: (task) =>
          Platform.isIOS &&
          isInternalDownloaderChunk(task) &&
          !_rangeTransfers.isActive(task.taskId),
      onPausedDrainSettled: (parentTaskId) {
        if (_disposed) return;
        diagnosticLog.record('parallel.pauseDrainQueueRelease', {
          'taskId': parentTaskId,
        });
        unawaited(_serializeQueue(_syncQueueToCapUnlocked));
        unawaited(_syncSessionOverlay(completedSuccess: false));
      },
      onUpdate: (update) {
        if (!_disposed) _sharedEvents.add(update);
      },
      availableStorageBytes: (path) => DiskUsage.freeSpace(path),
      onAssemblyFailure: (failure) {
        diagnosticLog.record('parallel.failure', {
          'taskId': failure.parentTaskId,
          'reason': failure.reason.name,
        });
        if (!_disposed) _parallelFailures.add(failure);
      },
      onPartProgress: (parent, child, progress) {
        if (!_disposed) {
          _publishChunkProgress(
            parentTaskId: parent,
            chunkTaskId: child,
            progress: progress,
          );
        }
      },
      onHostPressure: (url, ceiling) {
        if (_disposed) return;
        diagnosticLog.record('parallel.hostPressure', {'count': ceiling});
        unawaited(
          _hostProfiles.recordPressure(url: url, fallbackCeiling: ceiling),
        );
      },
      onHostSample: (url, connections, bytesPerSecond) {
        if (_disposed) return;
        unawaited(
          _hostProfiles.recordSuccess(
            url: url,
            activeConnections: connections,
            bytesPerSecond: bytesPerSecond,
          ),
        );
      },
    );
    _continuedProcessing = DownloadContinuedProcessingService(
      onSystemCancel: _cancelFromSystemUI,
      onTaskUpdate: _handleNativeTaskUpdate,
      onChunkUpdate: _handleNativeChunkUpdate,
    );
  }

  Stream<TaskUpdate> get updates => _updatesController.stream;

  /// Read-only logical lifecycle projection for UI surfaces. Executor/plugin
  /// status remains evidence and must not overwrite a durable JobStore state.
  Future<DownloadJobState?> logicalJobStateForTask(String taskId) async {
    final id = taskId.trim();
    if (id.isEmpty) return null;
    return (await _jobStore.get(id))?.state;
  }

  void _handleNativeTaskUpdate({
    required String taskId,
    required String trackingUrl,
    required int writtenBytes,
    required int expectedBytes,
    double? speedBytesPerSecond,
  }) {
    diagnosticLog.record('native.progress', {
      'taskId': taskId,
      'bytes': writtenBytes,
      'total': expectedBytes,
      'speed': speedBytesPerSecond,
    });
    if (_disposed ||
        taskId.isEmpty ||
        trackingUrl.isEmpty ||
        writtenBytes < 0) {
      return;
    }
    if (_userPausedIds.contains(taskId) || _terminalJobIds.contains(taskId)) {
      return;
    }

    final current = _ref.read(downloadProgressProvider)[trackingUrl];
    final total = knownDownloadSize(<int?>[
      expectedBytes,
      _telemetry.expectedBytesFor(taskId),
      current?.totalSize,
    ]);
    final reading = _telemetry.observe(
      taskId: taskId,
      transferredBytes: writtenBytes,
      expectedBytes: total,
      fallbackSpeedBytesPerSecond: speedBytesPerSecond ?? 0,
    );
    final knownTotal = reading.expectedBytes > 0
        ? reading.expectedBytes
        : total;
    final measuredProgress = knownTotal > 0
        ? (reading.transferredBytes / knownTotal).clamp(0.0, 1.0).toDouble()
        : (current?.progress ?? 0.0);
    final progress = keepLastKnownDownloadProgress(
      incoming: measuredProgress,
      lastKnown: current?.progress,
    );
    final recentBytes = _telemetry.hasRecentBytes(taskId);
    final speedMb = reading.speedBytesPerSecond > 0
        ? reading.speedBytesPerSecond / 1000000
        : (recentBytes ? -1.0 : 0.0);

    _queueWaitingIds.remove(taskId);
    _waitingPayloads.remove(taskId);
    _ref.read(activeDownloadsProvider.notifier).add(trackingUrl);
    _ref
        .read(downloadProgressProvider.notifier)
        .update(
          trackingUrl,
          DownloadProgressData(
            taskId: taskId,
            progress: progress,
            networkSpeed: speedMb,
            timeRemaining: reading.timeRemaining,
            totalSize: knownTotal,
            status: TaskStatus.running,
          ),
        );
    unawaited(
      _ref
          .read(storageServiceProvider)
          .patchDownloadMetadata(taskId, queueWaiting: false),
    );
    if (knownTotal > 0) {
      unawaited(
        _rememberExpectedBytes(
          taskId: taskId,
          expectedBytes: knownTotal,
          progress: progress,
        ),
      );
    }
  }

  Future<void> _rememberExpectedBytes({
    required String taskId,
    required int expectedBytes,
    double? progress,
  }) async {
    if (expectedBytes <= 0 || !_expectedSizePersistedIds.add(taskId)) return;
    try {
      final record = await FileDownloader().database.recordForId(taskId);
      if (record != null && record.expectedFileSize <= 0) {
        final keptProgress = progress != null && progress >= 0 && progress <= 1
            ? progress
            : record.progress;
        await FileDownloader().database.updateRecord(
          TaskRecord(record.task, record.status, keptProgress, expectedBytes),
        );
      }
    } catch (_) {}
    try {
      await _ref
          .read(storageServiceProvider)
          .patchDownloadMetadata(
            taskId,
            lastExpectedBytes: expectedBytes,
            lastProgress: progress != null && progress > 0 && progress <= 1
                ? progress
                : null,
          );
    } catch (_) {}
    try {
      final job = await _jobStore.get(taskId);
      if (job != null && job.expectedBytes <= 0) {
        await _jobStore.checkpoint(
          taskId: job.taskId,
          trackingUrl: job.trackingUrl,
          state: job.state,
          durableBytes: job.durableBytes,
          expectedBytes: expectedBytes,
          userPaused: job.userPaused,
          queueWaiting: job.queueWaiting,
          fingerprint: job.fingerprint,
        );
      }
    } catch (_) {}
  }

  void _publishChunkProgress({
    required String parentTaskId,
    required String chunkTaskId,
    double? progress,
    int? statusOrdinal,
  }) {
    _ref
        .read(downloadChunkProgressProvider.notifier)
        .update(
          parentTaskId: parentTaskId,
          chunkTaskId: chunkTaskId,
          progress: progress,
          statusOrdinal: statusOrdinal,
        );
  }

  void _handleNativeChunkUpdate({
    required String parentTaskId,
    required String chunkTaskId,
    double? progress,
    int? statusOrdinal,
    int? writtenBytes,
    int? expectedBytes,
    int? attemptGeneration,
    double? speedBytesPerSecond,
    bool completed = false,
  }) {
    if (_disposed || _terminalJobIds.contains(parentTaskId)) return;
    final parentUserPaused = _userPausedIds.contains(parentTaskId);
    diagnosticLog.record('chunk.update', {
      'taskId': chunkTaskId,
      'parentTaskId': parentTaskId,
      'bytes': writtenBytes,
      'total': expectedBytes,
      'progress': progress,
      'status': statusOrdinal,
      'result': completed,
    });
    final derivedProgress = completed
        ? 1.0
        : (progress ??
              ((writtenBytes != null &&
                      expectedBytes != null &&
                      expectedBytes > 0)
                  ? writtenBytes / expectedBytes
                  : null));
    if (!parentUserPaused || completed) {
      _publishChunkProgress(
        parentTaskId: parentTaskId,
        chunkTaskId: chunkTaskId,
        progress: derivedProgress,
        statusOrdinal: completed ? TaskStatus.complete.index : statusOrdinal,
      );
    }

    unawaited(
      _parallel.handleNativeChunkUpdate(
        parentTaskId: parentTaskId,
        chunkTaskId: chunkTaskId,
        progress: derivedProgress,
        writtenBytes: writtenBytes,
        expectedBytes: expectedBytes,
        attemptGeneration: attemptGeneration,
        speedBytesPerSecond: speedBytesPerSecond,
        completed: completed,
      ),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _disposeFuture ??= _teardownBarrier.run(_disposeResources);
  }

  Future<void> _disposeResources() async {
    await _updatesSubscription?.cancel();
    _updatesSubscription = null;
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    await _rangeTransfers.dispose();
    await _parallel.dispose();
    await _nativeTransport.dispose();
    await _continuedProcessing.dispose();
    await _parallelFailures.close();
    await _updatesController.close();
    _telemetry.clear();
    _expectedSizePersistedIds.clear();
    _terminalJobIds.clear();
    // Do NOT cancel _fdSubscription — it matches FileDownloader()'s singleton
    // lifetime and cannot be re-subscribed after cancellation.
  }

  bool _hasConnectivity(List<ConnectivityResult> results) =>
      results.any((result) => result != ConnectivityResult.none);

  Future<void> _initializeConnectivity() async {
    try {
      _networkAvailable = _hasConnectivity(
        await _connectivity.checkConnectivity(),
      );
    } catch (_) {
      // A platform connectivity probe failure is unknown, not proof of offline.
      _networkAvailable = true;
    }
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      _handleConnectivityChanged,
    );
    diagnosticLog.record('network.state', {'available': _networkAvailable});
  }

  void _handleConnectivityChanged(List<ConnectivityResult> results) {
    final available = _hasConnectivity(results);
    final restored = !_networkAvailable && available;
    _networkAvailable = available;
    diagnosticLog.record('network.state', {
      'available': available,
      'restored': restored,
    });
    if (restored && _isInitialized && !_disposed) {
      unawaited(_resumeNetworkHeldDownloads());
    }
  }

  Future<void> _holdDownloadForNetwork(DownloadTask task) async {
    if (_disposed ||
        _terminalJobIds.contains(task.taskId) ||
        _userPausedIds.contains(task.taskId)) {
      return;
    }
    final saved = await _savedProgressFor(task);
    final checkpointed = await _checkpointLogicalJob(
      task,
      state: DownloadJobState.waitingForNetwork,
      durableBytes: saved.partialBytes,
      durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
      expectedBytes: saved.totalSize,
      userPaused: false,
      queueWaiting: false,
    );
    if (!checkpointed) return;
    final hold = await _jobStore.beginOperation(
      task.taskId,
      state: DownloadJobState.waitingForNetwork,
    );
    if (hold == null) return;
    _queueWaitingIds.remove(task.taskId);
    _waitingPayloads.remove(task.taskId);
    await FileDownloader().database.updateRecord(
      TaskRecord(
        task,
        TaskStatus.waitingToRetry,
        saved.progress,
        saved.totalSize,
      ),
    );
    _publishProgress(
      trackingUrl: downloadTrackingUrl(task),
      taskId: task.taskId,
      progress: saved.progress,
      totalSize: saved.totalSize,
      status: TaskStatus.waitingToRetry,
    );
    _updatesController.add(TaskStatusUpdate(task, TaskStatus.waitingToRetry));
    diagnosticLog.record('network.hold', {
      'taskId': task.taskId,
      'generation': hold.generation,
    });
  }

  Future<void> _resumeNetworkHeldDownloads() async {
    if (!_networkAvailable || _disposed) return;
    await _serializeQueue(() async {
      if (!_networkAvailable || _disposed) return;
      final held = (await _jobStore.all())
          .where((job) => job.state == DownloadJobState.waitingForNetwork)
          .toList(growable: false);
      for (final job in held) {
        if (_terminalJobIds.contains(job.taskId) ||
            _userPausedIds.contains(job.taskId)) {
          continue;
        }
        final ownership = await _runtimeOwnershipFor(job.taskId);
        if (ownership == DownloadRuntimeOwnership.owned) {
          diagnosticLog.record('network.restoreOwned', {'taskId': job.taskId});
          continue;
        }
        if (ownership != DownloadRuntimeOwnership.notOwned) {
          diagnosticLog.record('network.restoreDeferred', {
            'taskId': job.taskId,
            'ownership': ownership.name,
          });
          continue;
        }
        final record = await FileDownloader().database.recordForId(job.taskId);
        final task = record?.task is DownloadTask
            ? record!.task as DownloadTask
            : job.restoreTaskSnapshot();
        if (task == null) continue;
        final claim = await _jobStore.beginOperation(
          job.taskId,
          state: DownloadJobState.interrupted,
        );
        if (claim == null) continue;
        await _enqueueExistingTaskAsWaiterUnlocked(task);
        diagnosticLog.record('network.restoreQueued', {
          'taskId': job.taskId,
          'generation': claim.generation,
        });
      }
      await _syncQueueToCapUnlocked();
      await _syncSessionOverlay();
    });
  }

  Future<void> _acknowledgeNativeNetworkResume(DownloadTask task) async {
    final job = await _jobStore.get(task.taskId);
    if (job?.state != DownloadJobState.waitingForNetwork) return;
    final ownership = await _runtimeOwnershipFor(task.taskId);
    if (ownership != DownloadRuntimeOwnership.owned) return;
    final token = await _jobStore.beginOperation(
      task.taskId,
      state: DownloadJobState.running,
    );
    if (token != null) {
      diagnosticLog.record('network.nativeResumeAck', {
        'taskId': task.taskId,
        'generation': token.generation,
      });
    }
  }

  Future<void> init() {
    if (_disposed) {
      return Future<void>.error(DownloadServiceUnavailableException.disposed());
    }
    return _readiness.ensureReady(() async {
      await _teardownBarrier.wait();
      if (_disposed) {
        throw DownloadServiceUnavailableException.disposed();
      }
      await _initialize();
    });
  }

  Future<void> _awaitCommandReadiness(String command) async {
    try {
      await init();
    } on DownloadServiceUnavailableException catch (error) {
      diagnosticLog.record('command.serviceUnavailable', {
        'command': command,
        'reason': error.reason.name,
        'retryable': error.retryable,
        if (error.cause != null)
          'causeType': error.cause.runtimeType.toString(),
      });
      rethrow;
    }
  }

  Future<bool> _awaitLifecycleReadiness(String event) async {
    try {
      await init();
      return true;
    } on DownloadServiceUnavailableException catch (error) {
      diagnosticLog.record('lifecycle.serviceUnavailable', {
        'event': event,
        'reason': error.reason.name,
        'retryable': error.retryable,
      });
      return false;
    }
  }

  Future<void> _initialize() async {
    if (_isInitialized) {
      if (kDebugMode) debugPrint('[DownloadService] Already initialized.');
      return;
    }
    final logging = _ref
        .read(storageServiceProvider)
        .getDownloadDiagnosticLog();
    try {
      await diagnosticLog.configure(logging);
      await _continuedProcessing.configureDiagnosticLog(logging);
    } catch (_) {
      diagnosticLog.lastError = 'Unable to initialize log directory';
    }
    diagnosticLog.record('service.initialize');
    await _initializeConnectivity();
    // Restore durable user intent before native/plugin callbacks can race the
    // startup reconciliation pass.
    await _restoreAuthoritativeJobIntent();
    // 1. Configure the downloader (chainable API)
    final concurrency = _ref
        .read(storageServiceProvider)
        .getDownloadConcurrency();
    await FileDownloader()
        .configure(
          globalConfig: [
            (
              Config.requestTimeout,
              Platform.isIOS
                  ? const Duration(minutes: 10)
                  : const Duration(seconds: 100),
            ),
            ...downloadHoldingQueueGlobalConfig(concurrency),
          ],
          androidConfig: [(Config.runInForeground, Config.always)],
          iOSConfig: [(Config.excludeFromCloudBackup, Config.always)],
        )
        .then((result) => debugPrint('Configuration result = $result'));

    // 2. Register callbacks and configure notifications
    FileDownloader().registerCallbacks(
      taskNotificationTapCallback: _myNotificationTapCallback,
    );
    _configureDownloadNotifications(
      _ref.read(storageServiceProvider).getDownloadNotificationPrefs(),
    );

    // 3. Re-check Permission status (native API)
    final status = await FileDownloader().permissions.status(
      PermissionType.notifications,
    );
    if (status != PermissionStatus.granted) {
      await FileDownloader().permissions.request(PermissionType.notifications);
    }

    // 4. Bridge FileDownloader updates into a shared broadcast stream (once),
    //    then let this instance listen to that broadcast proxy.
    _fdSubscription ??= FileDownloader().updates.listen(_sharedEvents.add);
    // A previous initialization attempt may have failed after installing
    // this instance listener. Cancel it before retrying so deliberate retry
    // cannot duplicate callback consumers.
    await _updatesSubscription?.cancel();
    _updatesSubscription = _sharedEvents.stream.listen((update) {
      diagnosticLog.record('task.update', {
        'taskId': update.task.taskId,
        if (update is TaskStatusUpdate) ...{
          'status': update.status.name,
          'errorType': update.exception?.runtimeType.toString(),
          if (update.exception is TaskHttpException)
            'httpStatus':
                (update.exception as TaskHttpException).httpResponseCode,
        },
        if (update is TaskProgressUpdate) ...{
          'progress': update.progress,
          'total': update.expectedFileSize,
          'speed': update.networkSpeed < 0
              ? update.networkSpeed
              : update.networkSpeed * 1000000,
        },
      });
      if (_parallel.handleUpdate(update)) return;
      if (isInternalDownloaderChunk(update.task)) return;
      if (_terminalJobIds.contains(update.task.taskId)) return;
      final trackingUrl = update.task.metaData.isNotEmpty
          ? update.task.metaData
          : update.task.url;

      // User pause uses plugin pause (resumeData). Swallow cancel/fail so the
      // row stays **متوقف مؤقتاً** with its saved percent.
      if (_userPausedIds.contains(update.task.taskId) ||
          _dequeuingPausedIds.contains(update.task.taskId)) {
        return;
      }

      if (update is TaskStatusUpdate &&
          update.task is DownloadTask &&
          !_networkAvailable &&
          (update.status == TaskStatus.waitingToRetry ||
              update.status == TaskStatus.failed ||
              update.status == TaskStatus.canceled ||
              update.status == TaskStatus.notFound)) {
        unawaited(_holdDownloadForNetwork(update.task as DownloadTask));
        return;
      }

      if (update is TaskStatusUpdate &&
          update.task is DownloadTask &&
          update.status == TaskStatus.running) {
        unawaited(_acknowledgeNativeNetworkResume(update.task as DownloadTask));
      }

      // Ghost cancel/fail from HQ dequeue while URLSession still owns this
      // episode: attach, do not park as paused. A real fail/system-cancel
      // parks that one file and the queue continues — never finish the
      // whole session as an error.
      if (update is TaskStatusUpdate &&
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
      if (update is TaskStatusUpdate && update.status == TaskStatus.complete) {
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

      if (update is TaskStatusUpdate && update.task is ParallelDownloadTask) {
        // Custom multipart parents are not enqueued through FileDownloader,
        // so the plugin never receives their synthetic status automatically.
        // Updating the parent explicitly gives one notification per episode
        // while the child parts stay silent.
        BackgroundDownloaderCompat.updateSyntheticNotification(
          update.task,
          update.status,
        );
      }

      switch (update) {
        case TaskProgressUpdate():
          final current = _ref.read(downloadProgressProvider)[trackingUrl];

          // Ignore completion and negative sentinel progress (-1 failed, -2
          // canceled, -5 paused, etc.) so we never clobber a paused download
          // back to "running" after a failure.
          if (current != null && current.status == TaskStatus.complete) {
            return;
          }
          if (update.progress < 0 || update.progress > 1) {
            return;
          }

          final previous = current;
          // Multipart parent progress is already the byte-credible aggregate
          // from PersistentParallelDownload. Let it correct an older inflated
          // UI value after manifest migration/recovery; ordinary downloads keep
          // the monotonic late-callback protection.
          final progress = update.task is ParallelDownloadTask
              ? update.progress.clamp(0.0, 1.0).toDouble()
              : keepLastKnownDownloadProgress(
                  incoming: update.progress,
                  lastKnown: previous?.progress,
                );

          // Bytes on the wire mean native is transferring. Never keep the row
          // frozen at في الانتظار while Speed: 1.9MB/s (Rivera case 1).
          if (progressMeansNativeTransfer(progress)) {
            _queueWaitingIds.remove(update.task.taskId);
          } else if (_queueWaitingIds.contains(update.task.taskId) ||
              current?.status == TaskStatus.enqueued) {
            return;
          }

          final knownTotal = knownDownloadSize(<int?>[
            update.expectedFileSize,
            _telemetry.expectedBytesFor(update.task.taskId),
            previous?.totalSize,
          ]);
          final isAggregateMultipart = update.task is ParallelDownloadTask;
          final fallbackSpeedBytes =
              update.networkSpeed.isFinite && update.networkSpeed > 0
              ? update.networkSpeed * 1000000
              : 0.0;
          final telemetry = _telemetry.observeProgress(
            taskId: update.task.taskId,
            progress: progress,
            expectedBytes: knownTotal,
            fallbackSpeedBytesPerSecond: fallbackSpeedBytes,
          );
          // PersistentParallelDownload already owns the aggregate byte clock
          // and smoothing window. Re-estimating its synthetic parent here made
          // the card and iOS continued-processing task use different speeds.
          final measuredSpeed = isAggregateMultipart
              ? fallbackSpeedBytes
              : telemetry.speedBytesPerSecond;
          final speed = isAggregateMultipart
              ? (update.networkSpeed.isFinite && update.networkSpeed > 0
                    ? update.networkSpeed
                    : 0.0)
              : (measuredSpeed > 0
                    ? measuredSpeed / 1000000
                    : (_telemetry.hasRecentBytes(update.task.taskId)
                          ? -1.0
                          : 0.0));
          final remaining = isAggregateMultipart
              ? update.timeRemaining
              : (telemetry.timeRemaining > Duration.zero
                    ? telemetry.timeRemaining
                    : (update.timeRemaining > Duration.zero
                          ? update.timeRemaining
                          : (previous?.timeRemaining ?? Duration.zero)));
          final progressData = DownloadProgressData(
            taskId: update.task.taskId,
            progress: progress,
            networkSpeed: speed,
            timeRemaining: remaining,
            totalSize: telemetry.expectedBytes > 0
                ? telemetry.expectedBytes
                : knownTotal,
            status: TaskStatus.running,
          );
          if (progressData.totalSize > 0) {
            unawaited(
              _rememberExpectedBytes(
                taskId: update.task.taskId,
                expectedBytes: progressData.totalSize,
                progress: progress,
              ),
            );
          }

          if (update.progress < 1.0) {
            _ref.read(activeDownloadsProvider.notifier).add(trackingUrl);
          } else {
            _ref.read(activeDownloadsProvider.notifier).remove(trackingUrl);
          }

          _ref
              .read(downloadProgressProvider.notifier)
              .update(trackingUrl, progressData);

          if (_sessionOverlayActive) {
            _rememberSessionTask(update.task.taskId);
            unawaited(
              _syncSessionOverlay(
                preferTaskId: update.task.taskId,
                progress: progressData.progress,
                totalBytes: progressData.totalSize,
                speedBytesPerSecond: progressData.networkSpeed * 1000 * 1000,
              ),
            );
          } else if (progressMeansNativeTransfer(progressData.progress)) {
            unawaited(
              _syncSessionOverlay(
                preferTaskId: update.task.taskId,
                progress: progressData.progress,
                totalBytes: progressData.totalSize,
                speedBytesPerSecond: progressData.networkSpeed * 1000 * 1000,
              ),
            );
          }

        case TaskStatusUpdate():
          if (kDebugMode) {
            debugPrint(
              '[DownloadService] Status: ${update.status} for $trackingUrl',
            );
          }
          final current = _ref.read(downloadProgressProvider)[trackingUrl];
          if (update.status == TaskStatus.complete &&
              !isCompleteDownloadCredible(
                progress: current?.progress,
                expectedBytes: current?.totalSize ?? -1,
              )) {
            if (kDebugMode) {
              debugPrint(
                '[DownloadService] Ignoring stub complete for $trackingUrl '
                '(progress=${current?.progress})',
              );
            }
            unawaited(_attachUiToLiveNativeTasks());
            return;
          }
          final uiStatus = displayDownloadStatus(
            persisted: update.status,
            queueWaiting: _queueWaitingIds.contains(update.task.taskId),
          );
          if (uiStatus != TaskStatus.running) {
            _telemetry.resetSpeed(update.task.taskId);
          }
          if (current != null) {
            final kept = keepLastKnownDownloadProgress(
              incoming: current.progress,
              lastKnown: current.progress,
            );
            _ref
                .read(downloadProgressProvider.notifier)
                .update(
                  trackingUrl,
                  DownloadProgressData(
                    taskId: current.taskId,
                    progress: kept,
                    networkSpeed: uiStatus == TaskStatus.running
                        ? current.networkSpeed
                        : 0,
                    timeRemaining: uiStatus == TaskStatus.running
                        ? current.timeRemaining
                        : Duration.zero,
                    totalSize: current.totalSize,
                    status: uiStatus,
                  ),
                );
          }

          switch (update.status) {
            case TaskStatus.complete:
              _rememberSessionTask(update.task.taskId);
              _queueWaitingIds.remove(update.task.taskId);
              _waitingPayloads.remove(update.task.taskId);
              // Do not finish the session overlay here. Finishing when ep1
              // completes suspends the process before ep2 can start.
              unawaited(_syncSessionOverlay(completedSuccess: true));
              unawaited(_persistCompletedFilePath(update.task));
            case TaskStatus.paused:
              unawaited(_syncSessionOverlay());
            case TaskStatus.running:
              _queueWaitingIds.remove(update.task.taskId);
              _waitingPayloads.remove(update.task.taskId);
              _rememberSessionTask(update.task.taskId);
              unawaited(
                _syncSessionOverlay(
                  preferTaskId: update.task.taskId,
                  progress: current?.progress ?? 0,
                  totalBytes: current?.totalSize ?? -1,
                ),
              );
            case TaskStatus.enqueued:
              // Waiting rows stay في الانتظار. Keep the session overlay if
              // another episode is still running or waiting.
              if (update.task is DownloadTask) {
                _waitingPayloads[update.task.taskId] = _waitingPayloadFor(
                  update.task as DownloadTask,
                );
              }
              _rememberSessionTask(update.task.taskId);
              unawaited(_syncSessionOverlay());
            case TaskStatus.failed:
            case TaskStatus.canceled:
            case TaskStatus.notFound:
              // Intercepted above into pause-and-continue. If a raw event
              // still lands here, do not finish the overlay as failed.
              unawaited(_syncSessionOverlay());
            default:
              break;
          }

          if (uiStatus != update.status) {
            _handleStatusUpdate(
              TaskStatusUpdate(update.task, uiStatus),
              trackingUrl,
            );
          } else {
            _handleStatusUpdate(update, trackingUrl);
          }
      }
    });

    // 5. Catch up on native tasks. Do not reschedule killed tasks with a
    //    fresh enqueue — that restarts the file from byte 0. Interrupted
    //    transfers are resumed from leftover bytes below.
    // Restore persisted host knowledge before any multipart session picks
    // its slow-start target. Expired profiles are removed by the store.
    _parallel.seedHostCeilings(await _hostProfiles.validHostCeilings());

    // Restore part identities before replaying native callbacks.
    for (final record in await FileDownloader().database.allRecords()) {
      if (record.task is ParallelDownloadTask &&
          record.status != TaskStatus.complete) {
        try {
          await _parallel.restore(record.task as ParallelDownloadTask);
        } catch (_) {}
      }
    }
    await FileDownloader().start(
      doRescheduleKilledTasks: false,
      markDownloadedComplete: false,
    );
    // Rebuild Transfer handles from the plugin database without enqueueing
    // anything. Recovery below remains the only code allowed to decide whether
    // an interrupted task should resume, wait, or stay user-paused.
    await _nativeTransport.rehydrate(group: kLogicalDownloadGroup);

    // 6. Restore UI rows and continue any download that was running when
    //    the process died, keeping already-written bytes.
    await _serializeQueue(_recoverPersistedDownloads);

    _isInitialized = true;
  }

  /// Test hook that replaces [FileDownloader.configure] for the holding queue.
  /// Production code leaves this null.
  @visibleForTesting
  static Future<void> Function(List<(String, dynamic)> globalConfig)?
  configureHoldingQueueForTesting;

  /// Persist [maxConcurrent] (clamped 1–5) and reconfigure the native
  /// holding queue. Every episode is OS-enqueued; extras wait as
  /// **في الانتظار**. Dart still promotes leftover waiters when a slot frees.
  Future<void> applyQueueSettings({required int maxConcurrent}) async {
    if (configureHoldingQueueForTesting == null) {
      await _awaitCommandReadiness('applyQueueSettings');
    }
    await applyDownloadQueueSettings(
      maxConcurrent: maxConcurrent,
      persist: _ref.read(storageServiceProvider).setDownloadConcurrency,
      configure: (globalConfig) async {
        final override = configureHoldingQueueForTesting;
        if (override != null) {
          await override(globalConfig);
          return;
        }
        await FileDownloader().configure(globalConfig: globalConfig);
      },
    );
    // Tests replace FileDownloader.configure; skip native record sync there.
    if (configureHoldingQueueForTesting != null) return;
    await _serializeQueue(_syncQueueToCapUnlocked);
  }

  Future<void> applyNotificationSettings(
    DownloadNotificationPrefs prefs,
  ) async {
    // Notification preferences are configuration, not download lifecycle
    // ownership. Persist them even while startup recovery is still settling;
    // _initialize() reads the same persisted value before recovery begins.
    await _ref.read(storageServiceProvider).setDownloadNotificationPrefs(prefs);
    _configureDownloadNotifications(prefs);
  }

  void _configureDownloadNotifications(DownloadNotificationPrefs prefs) {
    // A default notification config applies to every DownloadTask, including
    // the internal multipart children. Clear legacy/default configs first and
    // install only the logical-episode group so four parts still emit one
    // user-visible notification for their parent episode.
    // background_downloader 9.6 cannot clear notification configs through
    // its public configureNotification API because an empty config asserts.
    // Keep that unsupported operation inside the compatibility seam.
    BackgroundDownloaderCompat.clearNotificationConfigs();
    if (shouldClearDownloadNotificationConfigs(prefs)) return;
    const title = '{displayName}';
    final running = downloadNotificationIfEnabled(
      enabled: prefs.running,
      title: title,
      body: Platform.isIOS
          ? kDownloadRunningNotificationBodyIos
          : kDownloadRunningNotificationBodyAndroid,
    );
    final complete = downloadNotificationIfEnabled(
      enabled: prefs.complete,
      title: title,
      body: kDownloadCompleteNotificationBody,
    );
    final error = downloadNotificationIfEnabled(
      enabled: prefs.error,
      title: title,
      body: kDownloadParkedNotificationBody,
    );
    final paused = downloadNotificationIfEnabled(
      enabled: prefs.paused,
      title: title,
      body: kDownloadParkedNotificationBody,
    );
    final canceled = downloadNotificationIfEnabled(
      enabled: prefs.canceled,
      title: title,
      body: kDownloadCanceledNotificationBody,
    );
    final progressBar = !Platform.isIOS && prefs.running;
    FileDownloader().configureNotificationForGroup(
      kLogicalDownloadGroup,
      running: running,
      complete: complete,
      error: error,
      paused: paused,
      canceled: canceled,
      progressBar: progressBar,
    );
  }

  Future<T> _serializeQueue<T>(Future<T> Function() action) {
    final done = Completer<void>();
    final previous = _queueChain;
    _queueChain = previous.catchError((_) {}).whenComplete(() => done.future);
    return previous.catchError((_) {}).then((_) async {
      try {
        return await action();
      } catch (error) {
        diagnosticLog.record('queue.error', {
          'errorType': error.runtimeType.toString(),
        });
        rethrow;
      } finally {
        if (!done.isCompleted) done.complete();
      }
    });
  }

  DownloadTask? _downloadTaskFromMetadataSnapshot(
    Map<String, dynamic>? metadata,
  ) {
    final raw = metadata?['taskSnapshot'];
    if (raw is! Map) return null;
    try {
      final restored = Task.createFromJson(Map<String, dynamic>.from(raw));
      return restored is DownloadTask && isLogicalEpisodeDownloadTask(restored)
          ? restored
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _restoreAuthoritativeJobIntent() async {
    for (final job in await _jobStore.all()) {
      if (downloadJobHasUserPauseIntent(job.state)) {
        _userPausedIds.add(job.taskId);
      }
      if (downloadJobQueueWaiting(job.state)) {
        _queueWaitingIds.add(job.taskId);
      }
      if (downloadJobIsTerminal(job.state)) {
        _terminalJobIds.add(job.taskId);
      }
    }
  }

  /// Persist lifecycle boundaries for the logical episode without turning
  /// hot progress callbacks into Hive writes. DownloadJobStore owns monotonic
  /// byte/identity merging; this service only supplies orchestration evidence.
  Future<bool> _checkpointLogicalJob(
    DownloadTask task, {
    required DownloadJobState state,
    int? durableBytes,
    DownloadDurableByteProvenance? durableByteProvenance,
    int? expectedBytes,
    bool? userPaused,
    bool? queueWaiting,
    DownloadResourceFingerprint? fingerprint,
  }) async {
    final terminal =
        state == DownloadJobState.completed ||
        state == DownloadJobState.canceled ||
        state == DownloadJobState.orphaned;
    if (_terminalJobIds.contains(task.taskId) && !terminal) {
      diagnosticLog.record('job.checkpointRejected', {
        'taskId': task.taskId,
        'status': state.name,
        'reason': 'terminalTombstone',
      });
      return false;
    }
    final commit = await commitAuthoritativeDownloadCheckpoint(
      () => _jobStore.checkpoint(
        taskId: task.taskId,
        trackingUrl: downloadTrackingUrl(task),
        state: state,
        durableBytes: durableBytes,
        durableByteProvenance: durableByteProvenance,
        expectedBytes: expectedBytes,
        userPaused: userPaused,
        queueWaiting: queueWaiting,
        taskSnapshot: task.toJson(),
        fingerprint:
            fingerprint ??
            fingerprintWithExpectedBytes(
              remote: null,
              expectedBytes: expectedBytes ?? -1,
              fallbackFinalUrl: task.url,
            ),
      ),
    );
    if (commit != DownloadLifecycleCheckpointCommit.committed) {
      diagnosticLog.record(
        commit == DownloadLifecycleCheckpointCommit.rejected
            ? 'job.checkpointRejected'
            : 'job.checkpointError',
        {'taskId': task.taskId, 'status': state.name, 'result': commit.name},
      );
      return false;
    }
    if (terminal) _terminalJobIds.add(task.taskId);
    return true;
  }

  Future<void> _recoverPersistedDownloads() async {
    final storage = _ref.read(storageServiceProvider);
    final persistedRecords = await FileDownloader().database.allRecords();
    final runtimeTasks = await _liveTransferTasks();
    final jobs = await _jobStore.all();
    final metadataById = await storage.getAllDownloadMetadata();

    // DM-04: manifests are durable executor evidence even when plugin DB,
    // JobStore or metadata projections were lost. Scan only the app-owned
    // Downloads subtree; never infer task identity from arbitrary files.
    final discoveredManifests = await discoverParallelManifestRecoveryEvidence([
      Directory(
        p.join(await _getPublicDownloadsPath(), 'AnimeWitcher', 'Downloads'),
      ),
    ]);
    final manifestEvidenceById = <String, ParallelManifestRecoveryEvidence>{};
    final unresolvedManifestEvidence = <ParallelManifestRecoveryEvidence>[];
    final manifestsByParent =
        <String, List<ParallelManifestRecoveryEvidence>>{};
    for (final manifestEvidence in discoveredManifests) {
      manifestsByParent
          .putIfAbsent(
            manifestEvidence.parentTaskId,
            () => <ParallelManifestRecoveryEvidence>[],
          )
          .add(manifestEvidence);
    }
    for (final entry in manifestsByParent.entries) {
      final candidates = entry.value;
      if (candidates.length != 1) {
        unresolvedManifestEvidence.addAll(candidates);
        diagnosticLog.record('recovery.unresolvedManifest', {
          'taskId': entry.key,
          'reason': 'duplicateParentEvidence',
          'count': candidates.length,
        });
        continue;
      }
      final manifestEvidence = candidates.single;
      if (manifestEvidence.parentTask == null) {
        unresolvedManifestEvidence.add(manifestEvidence);
        diagnosticLog.record('recovery.unresolvedManifest', {
          'taskId': manifestEvidence.parentTaskId,
          'reason': 'missingParentDescriptor',
          'schemaVersion': manifestEvidence.schemaVersion,
        });
        continue;
      }
      manifestEvidenceById[manifestEvidence.parentTaskId] = manifestEvidence;
      try {
        // Rehydrate multipart child ownership before any orphan/user-pause
        // decision so a surviving writer cannot become invisible at parent level.
        await _parallel.restore(manifestEvidence.parentTask!);
      } catch (_) {
        diagnosticLog.record('recovery.unresolvedManifestOwnership', {
          'taskId': manifestEvidence.parentTaskId,
          'reason': 'restoreFailed',
        });
      }
    }

    // Legacy manifests are intentionally not enough to fabricate a parent.
    // If a known child writer survived, settle that exact child identity before
    // ignoring the unresolved parent evidence.
    Set<String>? liveManifestPartIds;
    try {
      liveManifestPartIds = await _livePartIds();
    } catch (_) {
      liveManifestPartIds = null;
    }
    final settledLegacyChildIds = <String>{};
    for (final manifestEvidence in unresolvedManifestEvidence) {
      if (liveManifestPartIds == null) {
        diagnosticLog.record('recovery.unresolvedManifestOwnership', {
          'taskId': manifestEvidence.parentTaskId,
          'reason': 'ownershipQueryFailed',
        });
        continue;
      }
      for (final childTask in manifestEvidence.childTasks) {
        if (!liveManifestPartIds.contains(childTask.taskId) ||
            !settledLegacyChildIds.add(childTask.taskId)) {
          continue;
        }
        var settled = false;
        try {
          settled = await _pauseTransfer(childTask);
        } catch (_) {
          settled = false;
        }
        if (!settled) {
          diagnosticLog.record('recovery.unresolvedManifestOwnership', {
            'taskId': manifestEvidence.parentTaskId,
            'childTaskId': childTask.taskId,
            'reason': 'childOwnershipNotReleased',
          });
        }
      }
    }

    final durableRecords = <TaskRecord>[];
    final orderByTaskId = <String, int>{};
    final knownExecutorIds = <String>{
      for (final record in persistedRecords) record.task.taskId,
      for (final task in runtimeTasks) task.taskId,
    };

    for (final entry in metadataById.entries) {
      final timestamp = entry.value['timestamp'];
      if (timestamp is num) orderByTaskId[entry.key] = timestamp.toInt();
    }
    final jobById = <String, DownloadJobRecord>{
      for (final job in jobs) job.taskId: job,
    };
    for (final job in jobs) {
      orderByTaskId.putIfAbsent(job.taskId, () => job.updatedAtMillis);
      if (knownExecutorIds.contains(job.taskId) ||
          job.state == DownloadJobState.completed ||
          job.state == DownloadJobState.canceled ||
          job.state == DownloadJobState.orphaned) {
        continue;
      }
      final metadata = metadataById[job.taskId];
      final task =
          job.restoreTaskSnapshot() ??
          _downloadTaskFromMetadataSnapshot(metadata) ??
          manifestEvidenceById[job.taskId]?.parentTask;
      final disposition = planDurableOnlyRecoveryDisposition(
        hasPresentationMetadata: metadata?['item'] is Map,
        hasRecoverableTaskDescriptor: task != null,
      );
      if (disposition == DownloadDurableOnlyRecoveryDisposition.orphan) {
        await _jobStore.checkpoint(
          taskId: job.taskId,
          trackingUrl: job.trackingUrl,
          state: DownloadJobState.orphaned,
          durableBytes: job.durableBytes,
          durableByteProvenance: job.durableByteProvenance,
          expectedBytes: job.expectedBytes,
          userPaused: job.userPaused,
          queueWaiting: false,
          fingerprint: job.fingerprint,
        );
        diagnosticLog.record(
          metadata?['item'] is! Map
              ? 'recovery.orphanedMissingPresentation'
              : 'recovery.orphanedMissingDescriptor',
          {'taskId': job.taskId, 'source': 'jobStore'},
        );
        continue;
      }
      final recoverableTask = task!;
      final progress = job.expectedBytes > 0
          ? (job.durableBytes / job.expectedBytes).clamp(0.0, 1.0).toDouble()
          : downloadMetadataProgress(metadata);
      durableRecords.add(
        TaskRecord(
          recoverableTask,
          TaskStatus.paused,
          progress,
          job.expectedBytes,
        ),
      );
    }

    // Metadata can survive even if both executor DB and JobStore were lost.
    // New-format rows carry a complete task snapshot and are recoverable; old
    // rows become explicit orphans instead of guessing URL/headers/path.
    for (final entry in metadataById.entries) {
      final taskId = entry.key;
      if (knownExecutorIds.contains(taskId) ||
          jobById.containsKey(taskId) ||
          durableRecords.any((record) => record.task.taskId == taskId)) {
        continue;
      }
      final metadata = entry.value;
      final manifestEvidence = manifestEvidenceById[taskId];
      final metadataTask = _downloadTaskFromMetadataSnapshot(metadata);
      final task =
          _downloadTaskFromMetadataSnapshot(metadata) ??
          manifestEvidenceById[taskId]?.parentTask;
      final trackingUrl = (metadata['trackingUrl'] as String?)?.trim() ?? '';
      if (task == null) {
        if (trackingUrl.isNotEmpty) {
          await _jobStore.checkpoint(
            taskId: taskId,
            trackingUrl: trackingUrl,
            state: DownloadJobState.orphaned,
            expectedBytes: downloadMetadataExpectedBytes(metadata),
            userPaused: isUserPausedMetadata(metadata),
            queueWaiting: false,
          );
          diagnosticLog.record('recovery.orphanedMissingDescriptor', {
            'taskId': taskId,
            'source': 'metadata',
          });
        }
        continue;
      }
      final expected = knownDownloadSize(<int?>[
        downloadMetadataExpectedBytes(metadata),
        manifestEvidence?.expectedBytes,
      ]);
      final progress =
          metadataTask == null &&
              manifestEvidence != null &&
              manifestEvidence.expectedBytes > 0
          ? (manifestEvidence.durableBytes / manifestEvidence.expectedBytes)
                .clamp(0.0, 1.0)
                .toDouble()
          : downloadMetadataProgress(metadata);
      durableRecords.add(
        TaskRecord(task, TaskStatus.paused, progress, expected),
      );
    }

    // A v6 manifest can be the only surviving logical descriptor. Add it once
    // as durable paused evidence; the normal missing-presentation policy below
    // either reconstructs the projection from metadata or explicitly orphans it.
    for (final manifestEvidence in manifestEvidenceById.values) {
      if (knownExecutorIds.contains(manifestEvidence.parentTaskId) ||
          jobById.containsKey(manifestEvidence.parentTaskId) ||
          metadataById.containsKey(manifestEvidence.parentTaskId) ||
          durableRecords.any(
            (record) => record.task.taskId == manifestEvidence.parentTaskId,
          )) {
        continue;
      }
      final parentTask = manifestEvidence.parentTask!;
      final progress = manifestEvidence.expectedBytes > 0
          ? (manifestEvidence.durableBytes / manifestEvidence.expectedBytes)
                .clamp(0.0, 1.0)
                .toDouble()
          : 0.0;
      durableRecords.add(
        TaskRecord(
          parentTask,
          TaskStatus.paused,
          progress,
          manifestEvidence.expectedBytes,
        ),
      );
    }

    final inventory = buildDownloadRecoveryInventory(
      persistedRecords: persistedRecords,
      runtimeTasks: runtimeTasks,
      durableRecords: durableRecords,
      orderByTaskId: orderByTaskId,
    );
    final records = inventory.records;
    diagnosticLog.record('recovery.begin', {
      'count': records.length,
      'nativeOnly': inventory.nativeOnlyTaskIds.length,
      'durableOnly': inventory.durableOnlyTaskIds.length,
    });
    for (final record in records) {
      diagnosticLog.record('recovery.record', {
        'taskId': record.task.taskId,
        'status': record.status.name,
        'progress': record.progress,
        'nativeOnly': inventory.nativeOnlyTaskIds.contains(record.task.taskId),
      });
    }
    final nativeIds = <String>{
      for (final task in runtimeTasks)
        if (isLogicalEpisodeDownloadTask(task)) task.taskId,
    };

    for (final record in records) {
      final task = record.task as DownloadTask;
      final trackingUrl = downloadTrackingUrl(task);
      final metadata = await storage.getDownloadMetadata(task.taskId);
      // JobStore is read before any legacy/plugin early-exit. A stale canceled
      // executor row must not hide a durable logical job after process death.
      final oldJob = await _jobStore.get(task.taskId);
      final userPausedMeta = isUserPausedMetadata(metadata);
      if (record.status == TaskStatus.complete) {
        continue;
      }
      if (record.status == TaskStatus.canceled &&
          metadata == null &&
          oldJob == null &&
          !userPausedMeta) {
        continue;
      }
      final legacyQueueWaiting = isQueueWaitingMetadata(metadata);
      final queueWaiting = oldJob == null
          ? legacyQueueWaiting
          : downloadJobQueueWaiting(oldJob.state);
      if (queueWaiting) {
        _queueWaitingIds.add(task.taskId);
        _waitingPayloads[task.taskId] = _waitingPayloadFor(task);
        _rememberSessionTask(task.taskId);
      } else if (record.status == TaskStatus.running ||
          record.status == TaskStatus.enqueued ||
          record.status == TaskStatus.waitingToRetry) {
        _rememberSessionTask(task.taskId);
      }

      final isFailed =
          record.status == TaskStatus.failed ||
          record.status == TaskStatus.canceled ||
          record.status == TaskStatus.notFound;
      var progress = record.progress;
      if (progress < 0 || progress > 1) progress = 0.0;
      final parallelProgress = task is ParallelDownloadTask
          ? _parallel.progressFor(task.taskId)
          : null;
      if (parallelProgress != null) {
        progress = parallelProgress;
        // Heal lastProgress written by older builds so the first pause/resume
        // after upgrading cannot resurrect a phantom 18.5 MB Range.
        await storage.patchDownloadMetadata(
          task.taskId,
          lastProgress: progress,
        );
      }

      final wasRunning =
          record.status == TaskStatus.running ||
          record.status == TaskStatus.enqueued ||
          record.status == TaskStatus.waitingToRetry;
      final stillNative =
          nativeIds.contains(task.taskId) || _parallel.isActive(task.taskId);
      final hasLiveOwnership =
          stillNative || _parallel.hasLiveConnections(task.taskId);
      final presentationDisposition = planMissingPresentationRecovery(
        hasPresentationMetadata: metadata?['item'] is Map,
        hasLiveOwnership: hasLiveOwnership,
        authoritativeState: oldJob?.state,
      );
      if (presentationDisposition ==
          DownloadMissingPresentationRecoveryDisposition.preserveTerminal) {
        if (hasLiveOwnership) {
          try {
            await _pauseTransfer(task);
          } catch (_) {
            // The terminal durable state stays authoritative. A later
            // reconciliation pass retries settlement without revival.
          }
        }
        _queueWaitingIds.remove(task.taskId);
        _waitingPayloads.remove(task.taskId);
        _forgetSessionTask(task.taskId);
        continue;
      }
      if (presentationDisposition !=
          DownloadMissingPresentationRecoveryDisposition.recover) {
        final orphanManifest = manifestEvidenceById[task.taskId];
        final expectedForOrphan = knownDownloadSize(<int?>[
          record.expectedFileSize,
          downloadMetadataExpectedBytes(metadata),
          oldJob?.expectedBytes,
          orphanManifest?.expectedBytes,
        ]);
        final orphanBytes = selectDownloadRecoveryBytes(
          exactDiskBytes: -1,
          currentGenerationJobBytes: authoritativeDownloadJobBytes(oldJob),
          multipartManifestBytes: orphanManifest?.durableBytes ?? -1,
        );
        final orphanProvenance = switch (orphanBytes.source) {
          DownloadRecoveryByteSource.jobStore =>
            oldJob?.durableByteProvenance ?? DownloadDurableByteProvenance.none,
          DownloadRecoveryByteSource.multipartManifest =>
            DownloadDurableByteProvenance.multipartManifest,
          _ => DownloadDurableByteProvenance.none,
        };
        if (presentationDisposition ==
            DownloadMissingPresentationRecoveryDisposition.settleOwner) {
          final pausingCommitted = await _checkpointLogicalJob(
            task,
            state: DownloadJobState.pausing,
            expectedBytes: expectedForOrphan,
            userPaused: false,
            queueWaiting: false,
          );
          if (!pausingCommitted) {
            diagnosticLog.record('recovery.missingPresentationSettling', {
              'taskId': task.taskId,
              'reason': 'checkpointFailed',
            });
            continue;
          }
          var settled = false;
          try {
            settled = await _pauseTransfer(task);
          } catch (_) {
            settled = false;
          }
          if (!settled) {
            diagnosticLog.record('recovery.missingPresentationSettling', {
              'taskId': task.taskId,
              'reason': 'ownershipNotReleased',
            });
            continue;
          }
        }

        final orphanCommitted = await _checkpointLogicalJob(
          task,
          state: DownloadJobState.orphaned,
          durableBytes: orphanBytes.bytes,
          durableByteProvenance: orphanProvenance,
          expectedBytes: expectedForOrphan,
          userPaused: false,
          queueWaiting: false,
        );
        if (!orphanCommitted) {
          diagnosticLog.record('recovery.missingPresentationSettling', {
            'taskId': task.taskId,
            'reason': 'orphanCheckpointFailed',
          });
          continue;
        }
        _queueWaitingIds.remove(task.taskId);
        _waitingPayloads.remove(task.taskId);
        _forgetSessionTask(task.taskId);
        await FileDownloader().database.updateRecord(
          TaskRecord(task, TaskStatus.paused, progress, expectedForOrphan),
        );
        diagnosticLog.record('recovery.orphanedMissingPresentation', {
          'taskId': task.taskId,
          'source': stillNative ? 'runtime' : 'executor',
        });
        continue;
      }
      final userPaused = oldJob != null
          ? downloadJobHasUserPauseIntent(oldJob.state)
          : isUserPausedMetadata(metadata) ||
                _userPausedIds.contains(task.taskId);
      final recoveryPlan = planDownloadRecoveryWithJobAuthority(
        persisted: record.status,
        queueWaiting: queueWaiting,
        userPaused: userPaused,
        stillInNativeQueue: stillNative,
        hasMetadata: metadata != null,
        authoritativeState: oldJob?.state,
        authoritativeUserPaused: oldJob?.userPaused ?? false,
        authoritativeQueueWaiting: oldJob?.queueWaiting ?? false,
        networkAvailable: _networkAvailable,
      );

      // Migrate pre-DownloadJobStore installs on first reconciliation. Only
      // byte-credible disk/manifests are counted; native resume blobs with no
      // visible prefix remain unknown instead of being guessed from percent.
      final saved = await _savedProgressFor(task);
      final expectedBytes = knownDownloadSize(<int?>[
        saved.totalSize,
        record.expectedFileSize,
        downloadMetadataExpectedBytes(metadata),
        oldJob?.expectedBytes,
      ]);
      final manifestBytes = task is ParallelDownloadTask
          ? (_parallel.durableBytesFor(task.taskId) ?? -1)
          : -1;
      final recoveryBytes = selectDownloadRecoveryBytes(
        exactDiskBytes: saved.partialBytes > 0 ? saved.partialBytes : -1,
        currentGenerationJobBytes: authoritativeDownloadJobBytes(oldJob),
        multipartManifestBytes: manifestBytes,
      );
      final durableBytes = recoveryBytes.bytes;
      final durableByteProvenance = switch (recoveryBytes.source) {
        DownloadRecoveryByteSource.verifiedFinalFile =>
          DownloadDurableByteProvenance.verifiedFinalFile,
        DownloadRecoveryByteSource.exactDisk =>
          DownloadDurableByteProvenance.exactDisk,
        DownloadRecoveryByteSource.jobStore =>
          oldJob?.durableByteProvenance ?? DownloadDurableByteProvenance.none,
        DownloadRecoveryByteSource.multipartManifest =>
          DownloadDurableByteProvenance.multipartManifest,
        DownloadRecoveryByteSource.none => DownloadDurableByteProvenance.none,
      };
      _telemetry.seed(
        task.taskId,
        transferredBytes: durableBytes,
        expectedBytes: expectedBytes,
      );
      final migratedJob = DownloadJobRecord(
        taskId: task.taskId,
        trackingUrl: trackingUrl,
        state: recoveryPlan.state,
        generation: oldJob?.generation ?? 0,
        durableBytes: durableBytes,
        durableByteProvenance: durableByteProvenance,
        expectedBytes: expectedBytes,
        userPaused: downloadJobHasUserPauseIntent(recoveryPlan.state),
        queueWaiting: downloadJobQueueWaiting(recoveryPlan.state),
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
        taskSnapshot: oldJob?.taskSnapshot ?? task.toJson(),
        fingerprint:
            oldJob?.fingerprint ??
            DownloadResourceFingerprint(
              expectedBytes: expectedBytes,
              finalUrl: task.url,
            ),
      );
      if (oldJob != null && durableBytes < oldJob.durableBytes) {
        final reason = switch (recoveryBytes.source) {
          DownloadRecoveryByteSource.multipartManifest =>
            DownloadByteReconciliationReason.multipartManifestRollback,
          DownloadRecoveryByteSource.exactDisk when durableBytes == 0 =>
            DownloadByteReconciliationReason.noSurvivingBytes,
          DownloadRecoveryByteSource.exactDisk =>
            DownloadByteReconciliationReason.exactDiskLoss,
          _ => DownloadByteReconciliationReason.nativeRecoverabilityLoss,
        };
        final reconciled = await _jobStore.reconcileDurableBytes(
          oldJob.attemptToken,
          durableBytes: durableBytes,
          evidenceProvenance:
              durableByteProvenance == DownloadDurableByteProvenance.none
              ? DownloadDurableByteProvenance.exactDisk
              : durableByteProvenance,
          reason: reason,
          fingerprint: migratedJob.fingerprint,
        );
        if (reconciled != null) {
          final corrected = migratedJob.copyWith(
            generation: reconciled.generation,
          );
          await _jobStore.put(corrected);
        }
      } else {
        await _jobStore.put(migratedJob);
      }

      if (inventory.durableOnlyTaskIds.contains(task.taskId) &&
          recoveryPlan.action != DownloadRecoveryAction.ignore) {
        await FileDownloader().database.updateRecord(
          TaskRecord(task, TaskStatus.paused, progress, expectedBytes),
        );
        diagnosticLog.record('recovery.repairedDurableProjection', {
          'taskId': task.taskId,
          'progress': progress,
          'expectedBytes': expectedBytes,
        });
      }

      if (inventory.nativeOnlyTaskIds.contains(task.taskId) &&
          recoveryPlan.action != DownloadRecoveryAction.ignore) {
        // The runtime already owns this task but the executor DB projection was
        // lost. Repair the projection only after durable logical state exists;
        // this is not a start/enqueue operation and therefore cannot create a
        // second writer. A user-pause path below may immediately settle it to
        // paused once ownership release is acknowledged.
        await FileDownloader().database.updateRecord(
          TaskRecord(task, TaskStatus.running, progress, expectedBytes),
        );
        diagnosticLog.record('recovery.repairedPluginProjection', {
          'taskId': task.taskId,
          'progress': progress,
          'expectedBytes': expectedBytes,
        });
      }

      if (oldJob != null &&
          recoveryPlan.action == DownloadRecoveryAction.ignore) {
        _queueWaitingIds.remove(task.taskId);
        _waitingPayloads.remove(task.taskId);
        _forgetSessionTask(task.taskId);
        continue;
      }

      if (recoveryPlan.action == DownloadRecoveryAction.keepNetworkHeld) {
        _queueWaitingIds.remove(task.taskId);
        _waitingPayloads.remove(task.taskId);
        _rememberSessionTask(task.taskId);
        await FileDownloader().database.updateRecord(
          TaskRecord(task, TaskStatus.waitingToRetry, progress, expectedBytes),
        );
        _publishProgress(
          trackingUrl: trackingUrl,
          taskId: task.taskId,
          progress: progress,
          totalSize: expectedBytes,
          status: TaskStatus.waitingToRetry,
        );
        diagnosticLog.record('recovery.networkHeld', {'taskId': task.taskId});
        continue;
      }

      var userPauseSettled = !userPaused;
      if (userPaused) {
        _userPausedIds.add(task.taskId);
        _queueWaitingIds.remove(task.taskId);
        _waitingPayloads.remove(task.taskId);
        _rememberSessionTask(task.taskId);
        final needsNativePause = shouldNativePauseAfterUserPause(
          userPaused: true,
          stillInNativeQueue:
              stillNative || _parallel.hasLiveConnections(task.taskId),
        );
        userPauseSettled = !needsNativePause;
        if (needsNativePause) {
          try {
            userPauseSettled = await _pauseTransfer(task);
          } catch (_) {
            userPauseSettled = false;
          }
        }
        if (userPauseSettled) {
          await FileDownloader().database.updateRecord(
            TaskRecord(
              task,
              TaskStatus.paused,
              progress,
              record.expectedFileSize,
            ),
          );
        } else {
          await _checkpointLogicalJob(
            task,
            state: DownloadJobState.pausing,
            expectedBytes: expectedBytes,
            userPaused: true,
            queueWaiting: false,
          );
          diagnosticLog.record('recovery.pauseSettling', {
            'taskId': task.taskId,
          });
        }
        await storage.patchDownloadMetadata(
          task.taskId,
          queueWaiting: false,
          userPaused: true,
        );
      }

      if (isFailed) {
        await FileDownloader().database.updateRecord(
          TaskRecord(
            task,
            TaskStatus.paused,
            progress,
            record.expectedFileSize,
          ),
        );
      }

      final shouldReenqueue = recoveryPlan.shouldRequeue;
      if (shouldReenqueue) {
        _queueWaitingIds.add(task.taskId);
        _waitingPayloads[task.taskId] = _waitingPayloadFor(task);
        _rememberSessionTask(task.taskId);
        await storage.patchDownloadMetadata(task.taskId, queueWaiting: true);
      }

      final shouldContinue = shouldAutoResumeInterruptedDownload(
        wasRunningOrFailed: wasRunning,
        userPaused: userPaused || isFailed,
        stillInNativeQueue: stillNative,
        queueWaiting: queueWaiting || shouldReenqueue,
      );
      if (shouldContinue) {
        // Recovery uses the same capped queue as a user start, so a batch of
        // interrupted episodes cannot all resume at once after relaunch.
        await _enqueueExistingTaskAsWaiterUnlocked(task);
      }

      final projectedJob = await _jobStore.get(task.taskId);
      final projectedState = projectedJob?.state ?? recoveryPlan.state;
      _publishProgress(
        trackingUrl: trackingUrl,
        taskId: task.taskId,
        progress: progress,
        totalSize: expectedBytes,
        status: downloadJobDisplayStatus(projectedState),
      );
    }

    await _syncQueueToCapUnlocked();
    await _syncSessionOverlay();
    await _garbageCollectCanceledTombstones();
  }

  Future<void> _garbageCollectCanceledTombstones() async {
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
        await refreshStore.removeForOwnerGeneration(
          job.trackingUrl,
          job.taskId,
          job.generation,
        );
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

  Future<int> _occupiedSlotCount(List<TaskRecord> records) async {
    final occupying = <String>{};
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final taskId = record.task.taskId;
      final job = await _jobStore.get(taskId);
      if (job != null) {
        if (downloadJobOccupiesSlot(job.state)) {
          occupying.add(taskId);
        } else if (job.state == DownloadJobState.waitingForNetwork) {
          final ownership = await _runtimeOwnershipFor(taskId);
          if (ownership.blocksNewWriter) occupying.add(taskId);
        }
        continue;
      }

      // Pre-JobStore migration fallback only. Once a durable job exists the
      // replicas below are never allowed to decide lifecycle.
      if (_userPausedIds.contains(taskId)) {
        if (_parallel.hasLiveConnections(taskId)) occupying.add(taskId);
        continue;
      }
      if (reservesDownloadSlot(
        status: record.status,
        queueWaiting: _queueWaitingIds.contains(taskId),
      )) {
        occupying.add(taskId);
      }
    }
    occupying.addAll(_startingTaskIds);
    return occupying.length;
  }

  Future<List<DownloadQueueEntry>> _queueEntries(
    List<TaskRecord> records,
  ) async {
    final storage = _ref.read(storageServiceProvider);
    final entries = <DownloadQueueEntry>[];
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final taskId = record.task.taskId;
      final job = await _jobStore.get(taskId);
      if (job != null &&
          (job.state == DownloadJobState.completed ||
              job.state == DownloadJobState.canceled ||
              job.state == DownloadJobState.orphaned)) {
        continue;
      }
      if (job == null &&
          (record.status == TaskStatus.complete ||
              record.status == TaskStatus.canceled)) {
        continue;
      }
      final metadata = await storage.getDownloadMetadata(taskId);
      final queueWaiting = job != null
          ? downloadJobQueueWaiting(job.state)
          : _queueWaitingIds.contains(taskId) ||
                isQueueWaitingMetadata(metadata);
      final userPaused = job != null
          ? downloadJobUserPaused(job.state)
          : _userPausedIds.contains(taskId) || isUserPausedMetadata(metadata);
      entries.add(
        DownloadQueueEntry(
          taskId: taskId,
          status: job != null
              ? downloadJobTaskStatus(job.state)
              : record.status,
          timestamp:
              (metadata?['timestamp'] as int?) ?? job?.updatedAtMillis ?? 0,
          queueWaiting: queueWaiting,
          userPaused: userPaused,
        ),
      );
    }
    return entries;
  }

  Future<void> _syncQueueToCapUnlocked() async {
    if (!_networkAvailable) return;
    final max = clampDownloadConcurrency(
      _ref.read(storageServiceProvider).getDownloadConcurrency(),
    );
    final records = await FileDownloader().database.allRecords();
    final byId = <String, TaskRecord>{
      for (final record in records) record.task.taskId: record,
    };
    final plan = planDownloadQueue(
      maxConcurrent: max,
      entries: await _queueEntries(records),
      queueOrder: _queueOrder(),
    );

    // Promote leftover parked waiters. Native HoldingQueue already owns
    // OS-enqueued waiters — do not enqueue a second copy.
    for (final taskId in plan.idsToPromote) {
      if ((await _occupiedSlotCount(
            await FileDownloader().database.allRecords(),
          )) >=
          max) {
        break;
      }
      final record = byId[taskId];
      if (record == null || record.task is! DownloadTask) continue;
      await _promoteWaitingTask(record.task as DownloadTask);
    }
    await _persistNativeWaitingSnapshot();
  }

  /// Attach UI to live native tasks. Never detach a live URLSession task.
  /// Promote leftover parked waiters only if native does not already own
  /// that episode. Never pause/re-enqueue/restart URLSession here.
  Future<void> onAppForegrounded() async {
    if (!await _awaitLifecycleReadiness('foreground')) return;
    await _serializeQueue(() async {
      await _reconcileTransferOwnership();
      await _attachUiToLiveNativeTasks();
      await _syncQueueToCapUnlocked();
    });
    await _syncSessionOverlay();
  }

  List<String> _queueOrder() => List<String>.from(_sessionOrder);

  void _rememberSessionTask(String taskId) {
    if (taskId.isEmpty) return;
    if (!_sessionOrder.contains(taskId)) _sessionOrder.add(taskId);
  }

  void _forgetSessionTask(String taskId) {
    _sessionOrder.remove(taskId);
  }

  // Pre-logical-identity migration fallback: mutable executor keys are
  // consulted only when no canonical logical identity survives.
  String _overlayEpisodeKeyFromParts({
    required String taskId,
    required String trackingUrl,
    required String url,
    required String directory,
    required String filename,
  }) {
    final track = trackingUrl.trim();
    final source = url.trim();
    // startDownload stores the server URL in metaData when no separate
    // tracking URL exists. In that case prefer the stable destination file.
    if (track.isNotEmpty && track != source) return 'track:$track';
    final file = filename.trim();
    if (file.isNotEmpty) {
      final dir = directory.replaceAll('\\', '/').trim();
      return 'file:$dir|$file';
    }
    if (source.isNotEmpty) return 'url:$source';
    return 'id:$taskId';
  }

  String _overlayEpisodeKeyForTask(Task task) {
    return _overlayEpisodeKeyFromParts(
      taskId: task.taskId,
      trackingUrl: task.metaData,
      url: task.url,
      directory: task.directory,
      filename: task.filename,
    );
  }

  Future<DownloadOverlaySession> _planSessionOverlay({
    String? preferTaskId,
    double? progress,
    int? totalBytes,
    double? speedBytesPerSecond,
  }) async {
    final records = await FileDownloader().database.allRecords();
    final storage = _ref.read(storageServiceProvider);
    final liveProgress = _ref.read(downloadProgressProvider);
    final entries = <DownloadOverlayEntry>[];
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final job = await _jobStore.get(record.task.taskId);
      final metadata = await storage.getDownloadMetadata(record.task.taskId);
      final logicalId =
          job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);
      final trackingUrl = downloadTrackingUrl(record.task);
      final live = liveProgress[trackingUrl];
      final liveRunning = live?.status == TaskStatus.running;
      final leftoverWaiting = job != null
          ? downloadJobQueueWaiting(job.state)
          : _queueWaitingIds.contains(record.task.taskId);
      final inSession = job != null
          ? _sessionOrder.contains(record.task.taskId) ||
                downloadJobOccupiesSlot(job.state) ||
                leftoverWaiting ||
                liveRunning
          : _sessionOrder.contains(record.task.taskId) ||
                occupiesDownloadSlot(
                  status: record.status,
                  queueWaiting: leftoverWaiting,
                ) ||
                leftoverWaiting ||
                liveRunning ||
                record.status == TaskStatus.enqueued;
      // Pre-JobStore migration fallback above is deliberately isolated to
      // rows that do not yet have durable lifecycle authority.
      if (!inSession) continue;
      _rememberSessionTask(record.task.taskId);
      final isPreferred = preferTaskId == record.task.taskId;
      var storedProgress = isPreferred
          ? (progress ?? live?.progress ?? record.progress)
          : (live?.progress ?? record.progress);
      final parallelProgress = record.task is ParallelDownloadTask
          ? _parallel.progressFor(record.task.taskId)
          : null;
      if (parallelProgress != null) {
        storedProgress = parallelProgress;
      } else {
        storedProgress = keepLastKnownDownloadProgress(
          incoming: storedProgress,
          lastKnown: live?.progress ?? record.progress,
        );
      }
      final storedTotal = isPreferred
          ? (totalBytes ?? live?.totalSize ?? record.expectedFileSize)
          : (live?.totalSize ?? record.expectedFileSize);
      final displayStatus = job != null
          ? downloadJobDisplayStatus(job.state)
          : displayDownloadStatus(
              persisted: liveRunning ? TaskStatus.running : record.status,
              queueWaiting: leftoverWaiting && !liveRunning,
            );
      final incomingSpeed = isPreferred
          ? (speedBytesPerSecond ?? (live?.networkSpeed ?? 0) * 1000 * 1000)
          : (live?.networkSpeed ?? 0) * 1000 * 1000;
      final speed = keepLastKnownDownloadSpeed(
        status: displayStatus,
        incomingSpeed: incomingSpeed,
        lastKnownSpeed: (live?.networkSpeed ?? 0) * 1000 * 1000,
      );
      entries.add(
        DownloadOverlayEntry(
          taskId: record.task.taskId,
          status: displayStatus,
          displayName: record.task.displayName,
          queueWaiting: leftoverWaiting,
          progress: storedProgress,
          totalBytes: storedTotal,
          speedBytesPerSecond: speed,
          episodeKey: logicalId ?? _overlayEpisodeKeyForTask(record.task),
        ),
      );
    }
    final seen = {for (final entry in entries) entry.taskId};
    for (final payload in _waitingPayloads.entries) {
      if (seen.contains(payload.key)) continue;
      final job = await _jobStore.get(payload.key);
      if (job != null && !downloadJobQueueWaiting(job.state)) continue;
      _rememberSessionTask(payload.key);
      final payloadLogicalId = (payload.value['logicalId'] as String?)?.trim();
      entries.add(
        DownloadOverlayEntry(
          taskId: payload.key,
          status: job != null
              ? downloadJobDisplayStatus(job.state)
              : TaskStatus.enqueued,
          displayName: payload.value['displayName'] as String? ?? '',
          queueWaiting: job != null ? downloadJobQueueWaiting(job.state) : true,
          episodeKey: payloadLogicalId != null && payloadLogicalId.isNotEmpty
              ? payloadLogicalId
              : _overlayEpisodeKeyFromParts(
                  taskId: payload.key,
                  trackingUrl: payload.value['metaData'] as String? ?? '',
                  url: payload.value['url'] as String? ?? '',
                  directory: payload.value['directory'] as String? ?? '',
                  filename: payload.value['filename'] as String? ?? '',
                ),
        ),
      );
    }
    return planDownloadOverlaySession(
      entries: entries,
      queueOrder: _sessionOrder,
    );
  }

  Future<void> _syncSessionOverlay({
    bool completedSuccess = true,
    String? preferTaskId,
    double? progress,
    int? totalBytes,
    double? speedBytesPerSecond,
  }) async {
    final session = await _planSessionOverlay(
      preferTaskId: preferTaskId,
      progress: progress,
      totalBytes: totalBytes,
      speedBytesPerSecond: speedBytesPerSecond,
    );
    _sessionCompletedCount = session.completedCount;
    _sessionBatchTotal = session.batchTotal;

    var activeEngineCount = _sessionOrder.where((taskId) {
      return _parallel.isActive(taskId) ||
          _rangeTransfers.isActive(taskId) ||
          _startingTaskIds.contains(taskId);
    }).length;
    // Only pay the native lookup cost in the rare bookkeeping gap where the
    // planner sees no running/waiting row. URLSession ownership is stronger
    // evidence than a transient DB status and prevents finish->recreate churn.
    if (session.runningCount == 0 &&
        session.waitingCount == 0 &&
        _waitingPayloads.isEmpty &&
        activeEngineCount == 0) {
      try {
        final liveIds = (await _liveTransferTasks())
            .map((task) => task.taskId)
            .toSet();
        activeEngineCount = _sessionOrder.where(liveIds.contains).length;
      } catch (_) {}
    }
    final hasRemaining = downloadSessionHasRemainingWork(
      runningCount: session.runningCount,
      waitingCount: session.waitingCount,
      pendingWaiterPayloads: _waitingPayloads.length,
      activeEngineCount: activeEngineCount,
    );
    if (!hasRemaining) {
      if (_sessionOverlayActive) {
        await _continuedProcessing.finish(
          taskId: kDownloadSessionOverlayTaskId,
          success: completedSuccess,
          status: downloadSessionFinishStatus(
            success: completedSuccess,
            parkedFailure: !completedSuccess,
          ),
          endSession: true,
        );
      }
      _sessionOverlayActive = false;
      _overlayCurrentTaskId = '';
      _sessionOrder.clear();
      await _persistNativeWaitingSnapshot(overlay: session);
      return;
    }

    final keepAlive =
        _sessionOverlayActive &&
        (session.waitingCount > 0 || activeEngineCount > 0);
    if (session.runningCount == 0 && !keepAlive) {
      await _persistNativeWaitingSnapshot(overlay: session);
      return;
    }

    final speed = overlayNativeSpeedUpdate(
      currentTaskId: session.currentTaskId,
      previousTaskId: _overlayCurrentTaskId,
      runningCount: session.runningCount,
      plannedSpeed: session.speedBytesPerSecond,
    );
    _overlayCurrentTaskId = session.currentTaskId;
    if (_sessionOverlayActive) {
      await _continuedProcessing.update(
        taskId: session.currentTaskId,
        progress: session.progress,
        totalBytes: session.totalBytes,
        transferredBytes: session.transferredBytes,
        completedCount: session.completedCount,
        batchTotal: session.batchTotal < 1 ? 1 : session.batchTotal,
        speedBytesPerSecond: speed,
        displayName: session.displayName,
        currentIndex: session.currentIndex,
      );
    } else {
      await _continuedProcessing.start(
        taskId: session.currentTaskId,
        displayName: session.displayName,
        progress: session.progress,
        totalBytes: session.totalBytes,
        transferredBytes: session.transferredBytes,
        completedCount: session.completedCount,
        batchTotal: session.batchTotal < 1 ? 1 : session.batchTotal,
        speedBytesPerSecond: speed < 0 ? 0 : speed,
        currentIndex: session.currentIndex,
      );
    }
    _sessionOverlayActive = true;
    await _persistNativeWaitingSnapshot(overlay: session);
  }

  Future<void> _persistNativeWaitingSnapshot({
    DownloadOverlaySession? overlay,
  }) async {
    final max = clampDownloadConcurrency(
      _ref.read(storageServiceProvider).getDownloadConcurrency(),
    );
    final records = await FileDownloader().database.allRecords();
    final waiters = <Map<String, Object>>[];
    final transferring = <String>[];
    final paused = <String>[];
    final waiterIds = <String>{};
    final queueWaitingIds = <String>{};
    final completedIds = <String>{};
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final task = record.task as DownloadTask;
      final job = await _jobStore.get(task.taskId);
      if (job != null &&
          (job.state == DownloadJobState.completed ||
              job.state == DownloadJobState.canceled ||
              job.state == DownloadJobState.orphaned)) {
        completedIds.add(task.taskId);
        _waitingPayloads.remove(task.taskId);
        continue;
      }
      if (job == null) {
        // Pre-JobStore migration fallback: plugin status and in-memory intent
        // may classify old executor rows only until durable authority exists.
        if (record.status == TaskStatus.complete) {
          completedIds.add(task.taskId);
          _waitingPayloads.remove(task.taskId);
          continue;
        }
        if (record.status == TaskStatus.canceled &&
            !_userPausedIds.contains(task.taskId)) {
          completedIds.add(task.taskId);
          _waitingPayloads.remove(task.taskId);
          continue;
        }
      }
      final leftoverWaiting = job != null
          ? downloadJobQueueWaiting(job.state)
          : _queueWaitingIds.contains(task.taskId);
      final userPaused = job != null
          ? downloadJobUserPaused(job.state)
          : _userPausedIds.contains(task.taskId) ||
                (record.status == TaskStatus.paused && !leftoverWaiting);
      final projectedStatus = job != null
          ? downloadJobTaskStatus(job.state)
          : record.status;
      if (leftoverWaiting) queueWaitingIds.add(task.taskId);
      if (userPaused) {
        paused.add(task.taskId);
        continue;
      }
      // Swift's fallback waiter starts one raw URLSession task.
      // Never pass it a ParallelDownloadTask: doing so silently turns a
      // requested four-part episode into one part. Dart/PersistentParallelDownload
      // owns multipart promotion and all child checkpoint/assembly semantics.
      if (isNativeWaitingSnapshotWaiter(
            status: projectedStatus,
            queueWaiting: leftoverWaiting,
            userPaused: false,
          ) &&
          task is! ParallelDownloadTask) {
        waiters.add(await _waitingPayloadPreservingBytes(task));
        waiterIds.add(task.taskId);
        continue;
      }
      final occupiesSlot = job != null
          ? downloadJobOccupiesSlot(job.state)
          : occupiesDownloadSlot(status: record.status, queueWaiting: false);
      if (occupiesSlot) {
        transferring.add(task.taskId);
        _waitingPayloads.remove(task.taskId);
      }
    }
    for (final id in _userPausedIds) {
      final job = await _jobStore.get(id);
      if (job != null && !downloadJobUserPaused(job.state)) continue;
      if (!paused.contains(id) && !completedIds.contains(id)) {
        paused.add(id);
        transferring.remove(id);
        queueWaitingIds.remove(id);
      }
    }
    for (final entry in _waitingPayloads.entries) {
      if (waiterIds.contains(entry.key) ||
          paused.contains(entry.key) ||
          transferring.contains(entry.key) ||
          completedIds.contains(entry.key)) {
        continue;
      }
      final job = await _jobStore.get(entry.key);
      if (job != null) {
        if (downloadJobUserPaused(job.state)) {
          paused.add(entry.key);
          continue;
        }
        if (!downloadJobQueueWaiting(job.state)) continue;
        queueWaitingIds.add(entry.key);
      }
      final record = records.firstWhereOrNull(
        (record) => record.task.taskId == entry.key,
      );
      if (record?.task is ParallelDownloadTask ||
          _rangeTransfers.isActive(entry.key)) {
        continue;
      }
      waiters.add(
        await _waitingPayloadPreservingBytes(
          record?.task as DownloadTask? ??
              Task.createFromJsonString(entry.value['taskJson'] as String)
                  as DownloadTask,
        ),
      );
    }
    waiters.sort((a, b) {
      final idA = a['taskId'] as String? ?? '';
      final idB = b['taskId'] as String? ?? '';
      return compareByDownloadQueueOrder(idA, idB, _sessionOrder);
    });
    for (var i = 0; i < waiters.length; i++) {
      final id = waiters[i]['taskId'] as String?;
      if (id == null || id.isEmpty) continue;
      if (waiters[i]['resumeDataBase64'] is String) continue;
      try {
        final resume = await BackgroundDownloaderCompat.resumeDataForTaskId(id);
        if (resume != null && resume.data.isNotEmpty) {
          waiters[i] = {...waiters[i], 'resumeDataBase64': resume.data};
        }
      } catch (_) {}
    }
    final multipartPlans = <Map<String, Object>>[];
    if (Platform.isIOS) {
      for (final plan in _parallel.nativeBackgroundPlans()) {
        multipartPlans.add(<String, Object>{
          'parentTaskId': plan.parentTaskId,
          'maxConcurrent': plan.maxConcurrent,
          'waiters': <Map<String, Object>>[
            for (final child in plan.tasks) nativeWaitingPayload(child),
          ],
        });
      }
    }
    await _continuedProcessing.persistNativeQueue(
      maxConcurrent: max,
      waiters: waiters,
      transferringTaskIds: transferring,
      pausedTaskIds: paused,
      queueWaitingTaskIds: queueWaitingIds.toList(),
      sessionTaskIds: List<String>.from(_sessionOrder),
      sessionCompletedCount: overlay?.completedCount ?? _sessionCompletedCount,
      sessionBatchTotal: overlay?.batchTotal ?? _sessionBatchTotal,
      sessionCurrentTaskId: overlay?.currentTaskId ?? '',
      sessionDisplayName: overlay?.displayName ?? '',
      sessionProgress: overlay?.progress ?? 0,
      sessionTotalBytes: overlay?.totalBytes ?? -1,
      sessionTransferredBytes: overlay?.transferredBytes ?? 0,
      sessionSpeedBytesPerSecond: overlay?.speedBytesPerSecond ?? 0,
      sessionCurrentIndex: overlay?.currentIndex ?? 0,
      multipartPlans: multipartPlans,
    );
  }

  String? _notificationConfigJson(DownloadTask task) {
    try {
      final prefs = _ref
          .read(storageServiceProvider)
          .getDownloadNotificationPrefs();
      if (shouldClearDownloadNotificationConfigs(prefs)) return null;
      const title = '{displayName}';
      final config = TaskNotificationConfig(
        taskOrGroup: task,
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
      return jsonEncode(config.toJson());
    } catch (_) {
      return null;
    }
  }

  Map<String, Object> _waitingPayloadFor(DownloadTask task) {
    return nativeWaitingPayload(
      task,
      notificationConfigJson: _notificationConfigJson(task),
    );
  }

  Future<Map<String, Object>> _waitingPayloadPreservingBytes(
    DownloadTask task,
  ) async {
    final payload = Map<String, Object>.from(_waitingPayloadFor(task));
    final job = await _jobStore.get(task.taskId);
    final metadata = await _ref
        .read(storageServiceProvider)
        .getDownloadMetadata(task.taskId);
    final logicalId = job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);
    if (logicalId != null && logicalId.isNotEmpty) {
      payload['logicalId'] = logicalId;
    }
    if (task is! ParallelDownloadTask) {
      try {
        final resume = await BackgroundDownloaderCompat.resumeDataForTaskId(
          task.taskId,
        );
        if (resume != null && resume.data.isNotEmpty) {
          payload['resumeDataBase64'] = resume.data;
        }
      } catch (_) {}
    }
    final saved = await _savedProgressFor(task);
    if (saved.progress > 0) payload['progress'] = saved.progress;
    if (saved.totalSize > 0) payload['expectedBytes'] = saved.totalSize;
    return payload;
  }

  Future<({double progress, int totalSize, int partialBytes})>
  _savedProgressFor(DownloadTask task) async {
    if (task is ParallelDownloadTask) {
      try {
        await _parallel.restore(task);
      } catch (_) {}
    }
    final trackingUrl = downloadTrackingUrl(task);
    final current = _ref.read(downloadProgressProvider)[trackingUrl];
    final record = await FileDownloader().database.recordForId(task.taskId);
    final metadata = await _ref
        .read(storageServiceProvider)
        .getDownloadMetadata(task.taskId);
    final job = await _jobStore.get(task.taskId);
    final parallelProgress = task is ParallelDownloadTask
        ? _parallel.progressFor(task.taskId)
        : null;
    var progress =
        parallelProgress ??
        keepLastKnownDownloadProgress(
          incoming: current?.progress ?? 0,
          lastKnown: record?.progress,
        );
    if (parallelProgress == null) {
      progress = keepLastKnownDownloadProgress(
        incoming: progress,
        lastKnown: downloadMetadataProgress(metadata),
      );
    }
    final totalSize = knownDownloadSize([
      current?.totalSize,
      _telemetry.expectedBytesFor(task.taskId),
      record?.expectedFileSize,
      downloadMetadataExpectedBytes(metadata),
      job?.expectedBytes,
    ]);
    if (job != null && job.expectedBytes > 0 && job.durableBytes > 0) {
      progress = keepLastKnownDownloadProgress(
        incoming: progress,
        lastKnown: job.durableBytes / job.expectedBytes,
      );
    }
    var partialBytes = 0;
    var exactDiskBytes = -1;
    try {
      final path = await task.filePath();
      if (path.isNotEmpty) {
        final partial = await findPartialDownloadFile(destinationPath: path);
        if (partial != null) {
          partialBytes = await partial.length();
          exactDiskBytes = partialBytes;
          if (parallelProgress == null && totalSize > 0 && partialBytes > 0) {
            progress = keepLastKnownDownloadProgress(
              incoming: progress,
              lastKnown: partialBytes / totalSize,
            );
          }
        }
      }
    } catch (_) {}
    final manifestBytes = task is ParallelDownloadTask
        ? (_parallel.durableBytesFor(task.taskId) ?? -1)
        : -1;
    final recoveryBytes = selectDownloadRecoveryBytes(
      exactDiskBytes: exactDiskBytes,
      currentGenerationJobBytes: authoritativeDownloadJobBytes(job),
      multipartManifestBytes: manifestBytes,
    );
    _telemetry.seed(
      task.taskId,
      transferredBytes: recoveryBytes.bytes,
      expectedBytes: totalSize,
    );
    return (
      progress: progress,
      totalSize: totalSize,
      partialBytes: partialBytes,
    );
  }

  Future<DownloadTask?> _liveNativeTaskFor({
    required String taskId,
    String? trackingUrl,
  }) async {
    if (_terminalJobIds.contains(taskId)) return null;
    final transfer = _nativeTransport.handleFor(taskId);
    final transferTask = transfer?.task;
    if (transfer != null &&
        transferTask is DownloadTask &&
        isLogicalEpisodeDownloadTask(transferTask) &&
        isLiveNativeDownloadStatus(transfer.status)) {
      return transferTask;
    }
    final track = trackingUrl ?? '';
    for (final task in await _liveTransferTasks()) {
      if (!isLogicalEpisodeDownloadTask(task)) continue;
      final downloadTask = task as DownloadTask;
      if (downloadTask.taskId == taskId) return downloadTask;
      if (track.isNotEmpty && downloadTrackingUrl(downloadTask) == track) {
        return downloadTask;
      }
    }
    return null;
  }

  Future<void> _attachToLiveNativeTask(
    DownloadTask task, {
    DownloadTask? live,
  }) async {
    final attached = live ?? task;
    _queueWaitingIds.remove(task.taskId);
    _waitingPayloads.remove(task.taskId);
    await _ref
        .read(storageServiceProvider)
        .patchDownloadMetadata(task.taskId, queueWaiting: false);
    final record = await FileDownloader().database.recordForId(attached.taskId);
    final trackingUrl = downloadTrackingUrl(attached);
    final saved = await _savedProgressFor(attached);
    var progress = record?.progress ?? saved.progress;
    if (progress < 0 || progress > 1) progress = saved.progress;
    progress = keepLastKnownDownloadProgress(
      incoming: progress,
      lastKnown: saved.progress,
    );
    final totalSize = saved.totalSize;
    final transferring =
        record?.status == TaskStatus.running ||
        record?.status == TaskStatus.waitingToRetry ||
        progressMeansNativeTransfer(progress);
    final status = transferring
        ? TaskStatus.running
        : (record?.status ?? TaskStatus.enqueued);
    if (!_userPausedIds.contains(attached.taskId)) {
      await _checkpointLogicalJob(
        attached,
        state: transferring
            ? DownloadJobState.running
            : DownloadJobState.starting,
        expectedBytes: totalSize,
        userPaused: false,
        queueWaiting: false,
      );
    }
    _publishProgress(
      trackingUrl: trackingUrl,
      taskId: attached.taskId,
      progress: progress,
      totalSize: totalSize,
      status: displayDownloadStatus(persisted: status, queueWaiting: false),
    );
    if (transferring) {
      await _syncSessionOverlay(
        preferTaskId: attached.taskId,
        progress: progress,
        totalBytes: totalSize,
      );
    }
  }

  Future<void> _attachUiToLiveNativeTasks() async {
    final records = await FileDownloader().database.allRecords();
    final byId = <String, TaskRecord>{
      for (final record in records) record.task.taskId: record,
    };
    for (final task in await _liveTransferTasks()) {
      if (!isLogicalEpisodeDownloadTask(task)) continue;
      _queueWaitingIds.remove(task.taskId);
      await _ref
          .read(storageServiceProvider)
          .patchDownloadMetadata(task.taskId, queueWaiting: false);
      final record = byId[task.taskId];
      final saved = await _savedProgressFor(task as DownloadTask);
      var progress = record?.progress ?? saved.progress;
      if (progress < 0 || progress > 1) progress = saved.progress;
      progress = keepLastKnownDownloadProgress(
        incoming: progress,
        lastKnown: saved.progress,
      );
      final totalSize = saved.totalSize;
      final transferring =
          record?.status == TaskStatus.running ||
          record?.status == TaskStatus.waitingToRetry ||
          progressMeansNativeTransfer(progress);
      _publishProgress(
        trackingUrl: downloadTrackingUrl(task),
        taskId: task.taskId,
        progress: progress,
        totalSize: totalSize,
        status: transferring
            ? TaskStatus.running
            : (record?.status ?? TaskStatus.enqueued),
      );
    }
    await _syncSessionOverlay();
  }

  Future<void> _retainLiveNativeOrPause(
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
      final live = await _liveNativeTaskFor(
        taskId: update.task.taskId,
        trackingUrl: trackingUrl,
      );
      if (live != null && update.task is! ParallelDownloadTask) {
        await _attachToLiveNativeTask(update.task as DownloadTask, live: live);
        return;
      }
    }
    if (_queueWaitingIds.contains(update.task.taskId)) {
      return;
    }
    await _preserveDownloadAsPaused(update, trackingUrl);
  }

  Future<bool> _promoteWaitingTask(DownloadTask task) async {
    final live = await _liveNativeTaskFor(
      taskId: task.taskId,
      trackingUrl: downloadTrackingUrl(task),
    );
    if (live != null) {
      await _attachToLiveNativeTask(task, live: live);
      return true;
    }

    final wasWaiting =
        _queueWaitingIds.contains(task.taskId) ||
        isQueueWaitingMetadata(
          await _ref
              .read(storageServiceProvider)
              .getDownloadMetadata(task.taskId),
        );
    _queueWaitingIds.remove(task.taskId);
    _waitingPayloads.remove(task.taskId);
    await _ref
        .read(storageServiceProvider)
        .patchDownloadMetadata(task.taskId, queueWaiting: false);
    _startingTaskIds.add(task.taskId);
    try {
      final started = await _resumeDownloadTask(task);
      if (!started && wasWaiting) {
        _queueWaitingIds.add(task.taskId);
        _waitingPayloads[task.taskId] = _waitingPayloadFor(task);
        final record = await FileDownloader().database.recordForId(task.taskId);
        await FileDownloader().database.updateRecord(
          TaskRecord(
            task,
            TaskStatus.paused,
            record?.progress ?? 0,
            record?.expectedFileSize ?? -1,
          ),
        );
        await _ref
            .read(storageServiceProvider)
            .patchDownloadMetadata(task.taskId, queueWaiting: true);
      }
      return started;
    } finally {
      _startingTaskIds.remove(task.taskId);
    }
  }

  void _publishProgress({
    required String trackingUrl,
    required String taskId,
    required double progress,
    required int totalSize,
    required TaskStatus status,
    double networkSpeed = 0,
    Duration timeRemaining = Duration.zero,
  }) {
    final previous = _ref.read(downloadProgressProvider)[trackingUrl];
    final parallelProgress = _parallel.progressFor(taskId);
    final knownTotal = knownDownloadSize(<int?>[
      totalSize,
      _telemetry.expectedBytesFor(taskId),
      previous?.totalSize,
    ]);
    if (knownTotal > 0) {
      _telemetry.seed(taskId, expectedBytes: knownTotal);
    }
    final keptProgress = parallelProgress != null
        ? parallelProgress.clamp(0.0, 1.0).toDouble()
        : keepLastKnownDownloadProgress(
            incoming: progress,
            lastKnown: previous?.progress,
          );
    final speed = keepLastKnownDownloadSpeed(
      status: status,
      incomingSpeed: networkSpeed,
      lastKnownSpeed: previous?.networkSpeed,
    );
    final remaining = status == TaskStatus.running
        ? (timeRemaining > Duration.zero
              ? timeRemaining
              : (previous?.timeRemaining ?? Duration.zero))
        : timeRemaining;
    _ref.read(activeDownloadsProvider.notifier).add(trackingUrl);
    _ref
        .read(downloadProgressProvider.notifier)
        .update(
          trackingUrl,
          DownloadProgressData(
            taskId: taskId,
            progress: keptProgress,
            networkSpeed: speed,
            timeRemaining: remaining,
            status: status,
            totalSize: knownTotal,
          ),
        );
  }

  /// Process tapping on a notification
  void _myNotificationTapCallback(
    Task task,
    NotificationType notificationType,
  ) {
    if (kDebugMode) {
      debugPrint(
        '[DownloadService] Tapped $notificationType for ${task.taskId}',
      );
    }
    // Navigate to the Downloads tab (LibraryScreen)
    _ref.read(appRouterProvider).go('/library');
  }

  Future<void> _handleVerifiedCompleteUpdate(
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

  void _handleStatusUpdate(TaskStatusUpdate update, String trackingUrl) {
    if (update.status == TaskStatus.complete) {
      _ref.read(activeDownloadsProvider.notifier).remove(trackingUrl);
      _ref.read(downloadProgressProvider.notifier).remove(trackingUrl);
      unawaited(
        _serializeQueue(() async {
          await _attachUiToLiveNativeTasks();
          await _syncQueueToCapUnlocked();
        }),
      );
      return;
    }
    if (update.status == TaskStatus.failed ||
        update.status == TaskStatus.canceled ||
        update.status == TaskStatus.notFound) {
      unawaited(_serializeQueue(_syncQueueToCapUnlocked));
      return;
    }
    if (update.status == TaskStatus.paused &&
        !_queueWaitingIds.contains(update.task.taskId)) {
      unawaited(_serializeQueue(_syncQueueToCapUnlocked));
    }
  }

  /// Keep a failed/system-canceled download as [TaskStatus.paused] with its
  /// last known progress so it stays on the Downloads page and can resume.
  /// The rest of the queue keeps going — do not finish the session overlay
  /// or cancel remaining waiters.
  Future<void> _preserveDownloadAsPaused(
    TaskStatusUpdate update,
    String trackingUrl,
  ) async {
    if (update.task is! DownloadTask) return;
    final task = update.task as DownloadTask;

    final current = _ref.read(downloadProgressProvider)[trackingUrl];
    final record = await FileDownloader().database.recordForId(task.taskId);
    final parallelProgress = task is ParallelDownloadTask
        ? _parallel.progressFor(task.taskId)
        : null;

    var progress = parallelProgress ?? (current?.progress ?? 0.0);
    if (progress < 0 || progress > 1) progress = 0.0;
    if (parallelProgress == null && (progress == 0.0) && record != null) {
      final recorded = record.progress;
      if (recorded > 0 && recorded <= 1) progress = recorded;
    }
    final metadata = await _ref
        .read(storageServiceProvider)
        .getDownloadMetadata(task.taskId);
    if (parallelProgress == null) {
      progress = keepLastKnownDownloadProgress(
        incoming: progress,
        lastKnown: downloadMetadataProgress(metadata),
      );
    }

    final totalSize = knownDownloadSize([
      current?.totalSize,
      record?.expectedFileSize,
      downloadMetadataExpectedBytes(metadata),
    ]);

    // Never delete the DB record, metadata, or partial file here — only mark
    // paused so retry/unpause can continue from the saved offset.
    await FileDownloader().database.updateRecord(
      TaskRecord(task, TaskStatus.paused, progress, totalSize),
    );
    await _ref
        .read(storageServiceProvider)
        .patchDownloadMetadata(
          task.taskId,
          lastProgress: progress,
          lastExpectedBytes: totalSize,
        );
    await _checkpointLogicalJob(
      task,
      state: DownloadJobState.interrupted,
      expectedBytes: totalSize,
      userPaused: false,
      queueWaiting: false,
    );

    _ref.read(activeDownloadsProvider.notifier).add(trackingUrl);
    _ref
        .read(downloadProgressProvider.notifier)
        .update(
          trackingUrl,
          DownloadProgressData(
            taskId: task.taskId,
            progress: progress,
            networkSpeed: 0,
            timeRemaining: Duration.zero,
            totalSize: totalSize,
            status: TaskStatus.paused,
          ),
        );

    // UI listeners only ever see paused, never failed/canceled for this path.
    _updatesController.add(TaskStatusUpdate(task, TaskStatus.paused));

    if (kDebugMode) {
      debugPrint(
        '[DownloadService] Preserved ${update.status.name} download as paused '
        '(${(progress * 100).toStringAsFixed(1)}%): $trackingUrl',
      );
    }
    await _serializeQueue(() async {
      await _syncQueueToCapUnlocked();
      await _startNextAfterParkedFailureUnlocked();
    });
    unawaited(_syncSessionOverlay());
  }

  /// After parking a failed file, attach UI to the next waiter (HQ already
  /// owns it) or re-enqueue leftover Dart-parked waiters. Never enqueue a
  /// second copy of a live native task.
  Future<void> _startNextAfterParkedFailureUnlocked() async {
    final max = clampDownloadConcurrency(
      _ref.read(storageServiceProvider).getDownloadConcurrency(),
    );
    final records = await FileDownloader().database.allRecords();
    final byId = <String, TaskRecord>{
      for (final record in records) record.task.taskId: record,
    };
    final ids = idsToStartAfterParkedFailure(
      maxConcurrent: max,
      entries: await _queueEntries(records),
      queueOrder: _queueOrder(),
    );
    for (final taskId in ids) {
      if ((await _occupiedSlotCount(
            await FileDownloader().database.allRecords(),
          )) >=
          max) {
        break;
      }
      final record = byId[taskId];
      if (record == null || record.task is! DownloadTask) continue;
      final task = record.task as DownloadTask;
      final live = await _liveNativeTaskFor(
        taskId: task.taskId,
        trackingUrl: downloadTrackingUrl(task),
      );
      if (live != null) {
        await _attachToLiveNativeTask(task, live: live);
        continue;
      }
      await _promoteWaitingTask(task);
    }
    await _persistNativeWaitingSnapshot();
  }

  /// iOS continued-processing expiration / system cancel — treat as pause,
  /// not as a user delete. Network drops often surface through this path.
  Future<void> _cancelFromSystemUI(String taskId) async {
    DownloadTask? downloadTask = await _liveNativeTaskFor(taskId: taskId);
    if (downloadTask == null) {
      final record = await FileDownloader().database.recordForId(taskId);
      if (record?.task is DownloadTask) {
        downloadTask = record!.task as DownloadTask;
      }
    }
    if (downloadTask == null) return;

    final trackingUrl = downloadTask.metaData.isNotEmpty
        ? downloadTask.metaData
        : downloadTask.url;

    if (kDebugMode) {
      debugPrint(
        '[DownloadService] System cancel → pause for $taskId ($trackingUrl)',
      );
    }

    final didPause = downloadTask is ParallelDownloadTask
        ? await _parallel.pause(downloadTask, preserveLiveParts: Platform.isIOS)
        : await _nativeTransport.pause(downloadTask);
    if (didPause) {
      await _syncSessionOverlay();
      return;
    }

    await _preserveDownloadAsPaused(
      TaskStatusUpdate(downloadTask, TaskStatus.failed),
      trackingUrl,
    );
  }

  Future<void> cancelDownload(
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
      final cancelJob = await _jobStore.get(taskId);
      await _ref
          .read(downloadUrlRefreshStoreProvider)
          .removeForOwnerGeneration(
            trackingUrl,
            taskId,
            cancelJob?.generation ?? 0,
          );
      // Keep the canceled JobStore row. It is the durable fence against late
      // complete/running callbacks and is GC'd only by the age+ownership policy.
      await _syncQueueToCapUnlocked();
      if (notifyContinuedProcessing) {
        await _syncSessionOverlay(completedSuccess: false);
      }
    });
  }

  Future<DownloadCommandOutcome> cancelDownloadOutcome(
    String taskId,
    String trackingUrl, {
    bool notifyContinuedProcessing = true,
  }) async {
    try {
      await cancelDownload(
        taskId,
        trackingUrl,
        notifyContinuedProcessing: notifyContinuedProcessing,
      );
    } on DownloadServiceUnavailableException {
      return DownloadCommandOutcome.serviceUnavailable;
    } catch (_) {
      return DownloadCommandOutcome.recoverableFailure;
    }

    final ownership = await _runtimeOwnershipFor(taskId);
    final job = await _jobStore.get(taskId);
    return resolveCancelCommandOutcome(state: job?.state, ownership: ownership);
  }

  Future<DownloadCommandOutcome> deleteDownloadOutcome(
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
      final resolved = await resolveDownloadedFile(
        task,
        item,
        episode: episode,
      );
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

  Future<DownloadCommandOutcome> pauseDownloadOutcome(String taskId) async {
    try {
      await pauseDownload(taskId);
    } on DownloadServiceUnavailableException {
      return DownloadCommandOutcome.serviceUnavailable;
    } catch (_) {
      return DownloadCommandOutcome.recoverableFailure;
    }
    final job = await _jobStore.get(taskId);
    final ownership = await _runtimeOwnershipFor(taskId);
    return resolvePauseCommandOutcome(state: job?.state, ownership: ownership);
  }

  Future<DownloadCommandOutcome> resumeDownloadOutcome(String taskId) async {
    try {
      await resumeDownload(taskId);
    } on _DownloadRestartRequiredException {
      return DownloadCommandOutcome.restartRequired;
    } on DownloadServiceUnavailableException {
      return DownloadCommandOutcome.serviceUnavailable;
    } catch (_) {
      return DownloadCommandOutcome.recoverableFailure;
    }
    final job = await _jobStore.get(taskId);
    final ownership = await _runtimeOwnershipFor(taskId);
    return resolveResumeCommandOutcome(state: job?.state, ownership: ownership);
  }

  Future<void> pauseDownload(String taskId) async {
    await _awaitCommandReadiness('pauseDownload');
    diagnosticLog.record('command.pauseDownload', {'taskId': taskId});
    await _serializeQueue(() async {
      final recordForId = await FileDownloader().database.recordForId(taskId);
      final tracking = recordForId != null
          ? downloadTrackingUrl(recordForId.task)
          : null;
      DownloadTask? downloadTask = await _liveNativeTaskFor(
        taskId: taskId,
        trackingUrl: tracking,
      );
      if (downloadTask == null && recordForId?.task is DownloadTask) {
        downloadTask = recordForId!.task as DownloadTask;
      }

      if (downloadTask != null) {
        final checkpointed = await _checkpointLogicalJob(
          downloadTask,
          state: DownloadJobState.pausing,
          userPaused: true,
          queueWaiting: false,
        );
        if (!checkpointed) {
          throw StateError('Failed to persist pause intent for $taskId');
        }
        final pauseOperation = await _jobStore.beginReplicaTransaction(
          taskId,
          operation: DownloadReplicaOperation.pause,
          state: DownloadJobState.pausing,
        );
        if (pauseOperation == null) {
          throw StateError('Failed to journal pause intent for $taskId');
        }
        // Fence callbacks only after the durable pause intent exists. Ownership
        // must never be stopped first and then fail to persist the user's intent.
        _userPausedIds.add(taskId);
        _queueWaitingIds.remove(taskId);
        _waitingPayloads.remove(taskId);
        await _ref
            .read(storageServiceProvider)
            .patchDownloadMetadata(
              taskId,
              queueWaiting: false,
              userPaused: true,
            );
        final stoppedRange = await _rangeTransfers.stop(taskId);
        // Plugin pause produces URLSession resumeData and drops the
        // transferring task so it no longer occupies a slot. Never cancel —
        // cancel deletes the temp file and forces a restart from byte 0.
        var didPause = false;
        try {
          didPause = await _pauseTransfer(
            downloadTask,
            rangeAlreadyStopped: stoppedRange,
          );
        } catch (_) {}
        final trackingUrl = downloadTrackingUrl(downloadTask);
        final current = _ref.read(downloadProgressProvider)[trackingUrl];
        final record = await FileDownloader().database.recordForId(taskId);
        final metadata = await _ref
            .read(storageServiceProvider)
            .getDownloadMetadata(taskId);
        final parallelProgress = downloadTask is ParallelDownloadTask
            ? _parallel.progressFor(taskId)
            : null;
        var progress =
            parallelProgress ??
            keepLastKnownDownloadProgress(
              incoming: current?.progress ?? 0,
              lastKnown: record?.progress,
            );
        if (parallelProgress == null) {
          progress = keepLastKnownDownloadProgress(
            incoming: progress,
            lastKnown: downloadMetadataProgress(metadata),
          );
        }
        final totalSize = knownDownloadSize([
          current?.totalSize,
          _telemetry.expectedBytesFor(taskId),
          record?.expectedFileSize,
          downloadMetadataExpectedBytes(metadata),
        ]);
        if (!didPause) {
          diagnosticLog.record('pause.settling', {
            'taskId': taskId,
            'ownership': (await _runtimeOwnershipFor(taskId)).name,
          });
          // Keep the already-persisted `pausing` + userPaused intent. The task
          // must not become logically/UI paused until ownership release is
          // proven, and must not be rolled back to running while the user has
          // an outstanding pause request. A later reconcile/retry can settle it.
          await _syncSessionOverlay(completedSuccess: false);
          await _persistNativeWaitingSnapshot();
          return;
        }

        final executorAcknowledged = await _jobStore.advanceReplicaTransaction(
          pauseOperation,
          DownloadReplicaTransactionPhase.executorAcknowledged,
        );
        if (!executorAcknowledged) {
          diagnosticLog.record('pause.replicaAckSuperseded', {
            'taskId': taskId,
          });
          return;
        }
        final projecting = await _jobStore.advanceReplicaTransaction(
          pauseOperation,
          DownloadReplicaTransactionPhase.projecting,
        );
        if (!projecting) {
          diagnosticLog.record('pause.replicaProjectionSuperseded', {
            'taskId': taskId,
          });
          return;
        }

        await FileDownloader().database.updateRecord(
          TaskRecord(downloadTask, TaskStatus.paused, progress, totalSize),
        );
        await _ref
            .read(storageServiceProvider)
            .patchDownloadMetadata(
              taskId,
              queueWaiting: false,
              userPaused: true,
              lastProgress: progress,
              lastExpectedBytes: totalSize,
            );
        final pauseCommitted = await _jobStore.updateForAttempt(
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
        final replicaCommitted = await _jobStore.commitReplicaTransaction(
          pauseOperation,
        );
        if (!replicaCommitted) {
          diagnosticLog.record('pause.replicaCommitSuperseded', {
            'taskId': taskId,
          });
          return;
        }
        _publishProgress(
          trackingUrl: trackingUrl,
          taskId: taskId,
          progress: progress,
          totalSize: totalSize,
          status: TaskStatus.paused,
        );
        _updatesController.add(
          TaskStatusUpdate(downloadTask, TaskStatus.paused),
        );
      }
      await _syncSessionOverlay(completedSuccess: false);
      await _persistNativeWaitingSnapshot();
      await _syncQueueToCapUnlocked();
    });
  }

  Future<void> resumeDownload(String taskId) async {
    await _awaitCommandReadiness('resumeDownload');
    diagnosticLog.record('command.resumeDownload', {'taskId': taskId});
    await _serializeQueue(() async {
      await _resumeUserPausedUnlocked(taskId);
    });
  }

  Future<void> _resumeUserPausedUnlocked(String taskId) async {
    await _reconcileTransferOwnership();
    DownloadTask? downloadTask = await _liveNativeTaskFor(taskId: taskId);
    if (downloadTask == null) {
      final record = await FileDownloader().database.recordForId(taskId);
      if (record?.task is DownloadTask) {
        downloadTask = record!.task as DownloadTask;
      }
    }
    if (downloadTask == null) return;
    _rememberSessionTask(taskId);
    final checkpointed = await _checkpointLogicalJob(
      downloadTask,
      state: DownloadJobState.starting,
      userPaused: false,
      queueWaiting: false,
    );
    if (!checkpointed) {
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
    _dequeuingPausedIds.remove(taskId);
    await _ref
        .read(storageServiceProvider)
        .patchDownloadMetadata(taskId, queueWaiting: false, userPaused: false);

    final max = clampDownloadConcurrency(
      _ref.read(storageServiceProvider).getDownloadConcurrency(),
    );
    final records = await FileDownloader().database.allRecords();
    final byId = <String, TaskRecord>{
      for (final record in records) record.task.taskId: record,
    };
    final plan = planUserResumeQueue(
      resumedId: taskId,
      maxConcurrent: max,
      entries: await _queueEntries(records),
      queueOrder: _queueOrder(),
    );

    final waitersReadyForRestack = await _cancelNativeWaitersForRestackUnlocked(
      plan.waitersToRestack,
    );

    final reservedEarlier = <String>{};
    try {
      for (final earlierId in plan.earlierWaiterIds) {
        if (await _occupiedSlotCount(
              await FileDownloader().database.allRecords(),
            ) >=
            max) {
          break;
        }
        final record = byId[earlierId];
        if (record == null || record.task is! DownloadTask) continue;
        final started = await _promoteWaitingTask(record.task as DownloadTask);
        if (started) {
          reservedEarlier.add(earlierId);
          _startingTaskIds.add(earlierId);
        }
      }

      final latestRecords = await FileDownloader().database.allRecords();
      final occupiedAfterEarlier = await _occupiedSlotCount(latestRecords);
      final remainingWaiters = plan.waitingFifoIds
          .where(
            (id) =>
                id == taskId ||
                !_isOccupyingTaskId(
                  id,
                  records: latestRecords,
                  starting: _startingTaskIds,
                ),
          )
          .toList();
      final startNow = shouldStartImmediatelyAfterUserResume(
        resumedId: taskId,
        occupyingCount: occupiedAfterEarlier,
        waitingFifoIdsIncludingResumed: remainingWaiters,
        maxConcurrent: max,
      );

      if (startNow) {
        _queueWaitingIds.remove(taskId);
        _waitingPayloads.remove(taskId);
        await _ref
            .read(storageServiceProvider)
            .patchDownloadMetadata(taskId, queueWaiting: false);
        final started = await _resumeDownloadTask(downloadTask);
        if (!started) {
          final saved = await _savedProgressFor(downloadTask);
          await _checkpointLogicalJob(
            downloadTask,
            state: DownloadJobState.interrupted,
            durableBytes: saved.partialBytes,
            durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
            expectedBytes: saved.totalSize,
            userPaused: false,
            queueWaiting: false,
          );
          await FileDownloader().database.updateRecord(
            TaskRecord(
              downloadTask,
              TaskStatus.paused,
              saved.progress,
              saved.totalSize,
            ),
          );
          _publishProgress(
            trackingUrl: downloadTrackingUrl(downloadTask),
            taskId: taskId,
            progress: saved.progress,
            totalSize: saved.totalSize,
            status: TaskStatus.paused,
          );
          _updatesController.add(
            TaskStatusUpdate(downloadTask, TaskStatus.paused),
          );
        }
      } else {
        await _enqueueExistingTaskAsWaiterUnlocked(downloadTask);
      }

      for (final waiterId in waitersReadyForRestack) {
        final record = byId[waiterId];
        if (record == null || record.task is! DownloadTask) continue;
        await _enqueueExistingTaskAsWaiterUnlocked(record.task as DownloadTask);
      }
    } finally {
      _startingTaskIds.removeAll(reservedEarlier);
    }

    await _persistNativeWaitingSnapshot();
    await _syncSessionOverlay();
    await _syncQueueToCapUnlocked();
  }

  bool _isOccupyingTaskId(
    String taskId, {
    required List<TaskRecord> records,
    required Set<String> starting,
  }) {
    if (starting.contains(taskId)) return true;
    if (_userPausedIds.contains(taskId)) return false;
    for (final record in records) {
      if (record.task.taskId != taskId) continue;
      return reservesDownloadSlot(
        status: record.status,
        queueWaiting: _queueWaitingIds.contains(taskId),
      );
    }
    return false;
  }

  Future<List<String>> _cancelNativeWaitersForRestackUnlocked(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const <String>[];

    final ready = <String>[];
    for (final id in ids) {
      final job = await _jobStore.get(id);
      if (job == null) {
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

  Future<void> _enqueueExistingTaskAsWaiterUnlocked(DownloadTask task) async {
    final trackingUrl = downloadTrackingUrl(task);
    final live = await _liveNativeTaskFor(
      taskId: task.taskId,
      trackingUrl: trackingUrl,
    );
    if (live != null) {
      final record = await FileDownloader().database.recordForId(live.taskId);
      if (record != null &&
          reservesDownloadSlot(
            status: record.status,
            queueWaiting: _queueWaitingIds.contains(live.taskId),
          )) {
        await _attachToLiveNativeTask(task, live: live);
        return;
      }
    }

    final previous = await FileDownloader().database.recordForId(task.taskId);
    final progress = previous?.progress ?? 0.0;
    final totalSize = previous?.expectedFileSize ?? -1;
    final checkpointed = await _checkpointLogicalJob(
      task,
      state: DownloadJobState.queued,
      expectedBytes: totalSize,
      userPaused: false,
      queueWaiting: true,
    );
    if (!checkpointed) {
      throw StateError('Failed to persist queue intent for ${task.taskId}');
    }
    _queueWaitingIds.add(task.taskId);
    _waitingPayloads[task.taskId] = _waitingPayloadFor(task);
    _rememberSessionTask(task.taskId);
    await _ref
        .read(storageServiceProvider)
        .patchDownloadMetadata(task.taskId, queueWaiting: true);
    await FileDownloader().database.updateRecord(
      TaskRecord(task, TaskStatus.paused, progress, totalSize),
    );
    _publishProgress(
      trackingUrl: trackingUrl,
      taskId: task.taskId,
      progress: progress,
      totalSize: totalSize,
      status: TaskStatus.enqueued,
    );
    _updatesController.add(TaskStatusUpdate(task, TaskStatus.enqueued));
  }

  Future<DownloadTask> _adaptiveTaskForFreshStart(
    DownloadTask template, {
    int knownTotalBytes = -1,
  }) async {
    if (template is ParallelDownloadTask) return template;
    final preference = _ref
        .read(storageServiceProvider)
        .getDownloadParallelParts();
    if (preference == 1) return template;

    final metadata = await getMetadata(template.url, headers: template.headers);
    final total = knownTotalBytes > 0
        ? knownTotalBytes
        : (metadata?.size ?? -1);
    final parts = selectAdaptiveDownloadParts(
      preference: preference,
      totalBytes: total,
      supportsRanges: metadata?.supportsRanges ?? false,
    );
    return buildAdaptiveDownloadTask(template: template, parts: parts);
  }

  Future<bool> _enqueueFreshAdaptiveTask(
    DownloadTask template, {
    int knownTotalBytes = -1,
  }) async {
    final task = await _adaptiveTaskForFreshStart(
      template,
      knownTotalBytes: knownTotalBytes,
    );
    final previous = await FileDownloader().database.recordForId(task.taskId);
    if (previous != null) {
      await FileDownloader().database.updateRecord(
        TaskRecord(
          task,
          TaskStatus.enqueued,
          previous.progress,
          previous.expectedFileSize,
        ),
      );
    }
    return _enqueueTransfer(task, knownTotalBytes);
  }

  Future<bool> _canNativeResume(DownloadTask task) async {
    try {
      return await FileDownloader()
          .taskCanResume(task)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return false;
    }
  }

  Future<bool> _resumeDownloadTask(DownloadTask task) async {
    if (!_networkAvailable) {
      await _holdDownloadForNetwork(task);
      return true;
    }
    if (_parallel.isActive(task.taskId) ||
        _rangeTransfers.isActive(task.taskId))
      return true;
    final live = await _liveNativeTaskFor(
      taskId: task.taskId,
      trackingUrl: downloadTrackingUrl(task),
    );
    if (live != null) {
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
    if (saved.totalSize > 0 &&
        saved.partialBytes == saved.totalSize &&
        await _resumeUsingPartialFile(task)) {
      return true;
    }
    final canNativeResume =
        task is! ParallelDownloadTask && await _canNativeResume(task);
    final refreshResult = await _refreshTaskBeforeResume(
      task,
      expectedBytes: saved.totalSize,
      partialBytes: saved.partialBytes,
      hasOpaqueNativeResume: canNativeResume && saved.partialBytes <= 0,
    );
    if (refreshResult.restartRequired) {
      diagnosticLog.record('source.refreshRestartRequired', {
        'taskId': task.taskId,
        'opaqueNativeResume': canNativeResume,
      });
      throw _DownloadRestartRequiredException(task.taskId);
    }
    task = refreshResult.task;
    final trackingUrl = downloadTrackingUrl(task);
    if (saved.progress > 0) {
      _publishProgress(
        trackingUrl: trackingUrl,
        taskId: task.taskId,
        progress: saved.progress,
        totalSize: saved.totalSize,
        status: TaskStatus.paused,
      );
    }

    if (task is ParallelDownloadTask) {
      if (await _parallel.restore(task))
        return _parallel.start(task, saved.totalSize);
      // Import completed/paused legacy chunks without using resumeChunkTasks,
      // which cancels all siblings when one completed child cannot be resumed.
      final data = await BackgroundDownloaderCompat.resumeDataForTaskId(
        task.taskId,
      );
      if (data != null && data.data.isNotEmpty) {
        await _parallel.importLegacy(task, data.data);
        return _parallel.start(task, saved.totalSize);
      }
      // A historical percentage can survive after all multipart manifests and
      // bytes are gone. Only actual surviving bytes may block a zero restart.
      if (saved.partialBytes > 0) return false;
      return _enqueueTransfer(task, saved.totalSize);
    }

    // A refreshed signed URL cannot use native resume data that embeds the
    // expired URL. When a verified partial file exists, go directly to the
    // prefix-validated Range append path.
    if (refreshResult.refreshed && saved.partialBytes > 0) {
      return _resumeUsingPartialFile(task);
    }

    if (canNativeResume && !refreshResult.refreshed) {
      var resumed = false;
      try {
        resumed = await _nativeTransport.resume(task);
      } catch (_) {
        resumed = false;
      }
      if (resumed) return true;
      if (saved.partialBytes <= 0) {
        // taskCanResume proves opaque native ownership existed, but the executor
        // could not adopt it. Never convert that hidden byte ownership into an
        // implicit zero-byte restart.
        throw _DownloadRestartRequiredException(task.taskId);
      }
    }

    return resumeOrRestartDownload(
      canResume: () async => false,
      resume: () async => false,
      resumeFromPartial: () => _resumeUsingPartialFile(task),
      restart: () =>
          _enqueueFreshAdaptiveTask(task, knownTotalBytes: saved.totalSize),
      savedProgress: saved.progress,
      existingPartialBytes: saved.partialBytes,
      expectedBytes: saved.totalSize,
    );
  }

  Future<bool> _resumeUsingPartialFile(DownloadTask task) async {
    final isParallel = task is ParallelDownloadTask;
    if (isParallel) {
      Set<String> livePartIds;
      try {
        livePartIds = await _livePartIds();
      } catch (_) {
        diagnosticLog.record('completion.localArtifactOwnershipUnknown', {
          'taskId': task.taskId,
        });
        return false;
      }
      if (livePartIds.any((id) => id.startsWith('${task.taskId}.part.'))) {
        diagnosticLog.record('completion.localArtifactOwnedParts', {
          'taskId': task.taskId,
        });
        return false;
      }
    }

    String destinationPath;
    try {
      destinationPath = await task.filePath();
    } catch (_) {
      return false;
    }
    if (destinationPath.isEmpty) return false;

    final expectedBytes = (await _savedProgressFor(task)).totalSize;
    if (isParallel) {
      final candidate = await findPartialDownloadFile(
        destinationPath: destinationPath,
      );
      if (candidate == null || expectedBytes <= 0) return false;
      int candidateBytes;
      try {
        candidateBytes = await candidate.length();
      } catch (_) {
        return false;
      }
      if (candidateBytes != expectedBytes) return false;
    }

    final partial = await canonicalizePartialDownloadFile(
      destinationPath: destinationPath,
    );
    if (partial == null) return false;
    final existingBytes = partial.bytes;
    if (expectedBytes > 0 && existingBytes == expectedBytes) {
      final persistedFingerprint = (await _jobStore.get(task.taskId))
          ?.fingerprint;
      final currentFingerprint = await _probeResourceFingerprint(
        task.url,
        headers: task.headers,
      );
      final prefixProof = await _rangeTransfers.verifyExistingPrefix(
        id: '${task.taskId}.completion-proof',
        url: task.url,
        headers: task.headers,
        file: partial.file,
        written: existingBytes,
      );
      if (!downloadCompletionEvidenceMatches(
        observedFileBytes: existingBytes,
        expectedResourceBytes: expectedBytes,
        prefixMatches: prefixProof.matches,
        persistedFingerprint: persistedFingerprint,
        currentFingerprint: currentFingerprint,
      )) {
        diagnosticLog.record('completion.identityRejected', {
          'taskId': task.taskId,
          'bytes': existingBytes,
          'expected': expectedBytes,
        });
        return false;
      }
      final checkpointed = await _checkpointLogicalJob(
        task,
        state: DownloadJobState.completed,
        durableBytes: expectedBytes,
        durableByteProvenance: DownloadDurableByteProvenance.verifiedFinalFile,
        expectedBytes: expectedBytes,
        userPaused: false,
        queueWaiting: false,
        fingerprint: fingerprintWithExpectedBytes(
          remote: currentFingerprint,
          expectedBytes: expectedBytes,
          fallbackFinalUrl: task.url,
        ),
      );
      if (!checkpointed) return false;

      await FileDownloader().database.updateRecord(
        TaskRecord(task, TaskStatus.complete, 1, expectedBytes),
      );
      diagnosticLog.record('completion.adoptedExactLocalArtifact', {
        'taskId': task.taskId,
        'bytes': expectedBytes,
        'parallel': isParallel,
      });
      _sharedEvents.add(TaskProgressUpdate(task, 1, expectedBytes));
      _sharedEvents.add(TaskStatusUpdate(task, TaskStatus.complete));
      return true;
    }
    if (task is ParallelDownloadTask) return false;
    if (!shouldResumeFromPartialBytes(
      existingPartialBytes: existingBytes,
      expectedBytes: expectedBytes,
    )) {
      return false;
    }

    return _appendRemainingWithDio(
      task,
      dest: partial.file,
      existingBytes: existingBytes,
      expectedBytes: expectedBytes,
    );
  }

  Future<ParallelDownloadTask?> _parallelParentForInternalPart(
    DownloadTask task,
  ) async {
    final parentTaskId = downloadInternalParentTaskId(task);
    if (parentTaskId == null) return null;
    final record = await FileDownloader().database.recordForId(parentTaskId);
    final parent = record?.task;
    return parent is ParallelDownloadTask ? parent : null;
  }

  void _scheduleParallelParentRefresh(String parentTaskId) {
    if (parentTaskId.isEmpty ||
        !_refreshingParallelParentIds.add(parentTaskId)) {
      return;
    }
    Future<void>.delayed(Duration.zero, () async {
      try {
        if (_disposed || _userPausedIds.contains(parentTaskId)) return;
        await _serializeQueue(() async {
          if (_disposed || _userPausedIds.contains(parentTaskId)) return;
          var record = await FileDownloader().database.recordForId(
            parentTaskId,
          );
          if (record?.task is! ParallelDownloadTask) return;
          var parent = record!.task as ParallelDownloadTask;
          final trackingUrl = downloadTrackingUrl(parent);
          if (_terminalJobIds.contains(parentTaskId)) return;

          final descriptor = await _ref
              .read(downloadUrlRefreshStoreProvider)
              .get(trackingUrl);
          if (descriptor == null) {
            diagnosticLog.record('source.refreshUnavailable', {
              'taskId': parentTaskId,
            });
            return;
          }

          // A child failure callback can arrive while healthy siblings are still
          // owned by URLSession. Settle them first so replaceSource can update one
          // coherent generation without racing stale native callbacks.
          if (_parallel.isActive(parentTaskId)) {
            if (!await _parallel.pause(parent)) return;
          }

          record = await FileDownloader().database.recordForId(parentTaskId);
          if (record?.task is! ParallelDownloadTask) return;
          parent = record!.task as ParallelDownloadTask;
          final saved = await _savedProgressFor(parent);
          final refreshed = await _refreshTaskBeforeResume(
            parent,
            expectedBytes: saved.totalSize,
            partialBytes: saved.partialBytes,
          );
          if (!refreshed.refreshed || refreshed.task is! ParallelDownloadTask) {
            diagnosticLog.record('source.refreshParked', {
              'taskId': parentTaskId,
            });
            return;
          }

          await _resumeDownloadTask(refreshed.task);
        });
      } finally {
        _refreshingParallelParentIds.remove(parentTaskId);
      }
    });
  }

  Future<bool> _appendRemainingWithDio(
    DownloadTask task, {
    required File dest,
    required int existingBytes,
    required int expectedBytes,
  }) async {
    final logical = isLogicalEpisodeDownloadTask(task);
    final parallelParent = logical
        ? null
        : await _parallelParentForInternalPart(task);
    DownloadAttemptToken? token;
    var canRefreshUrl = false;
    if (logical) {
      token = await _beginLogicalRangeAttempt(
        task,
        existingBytes: existingBytes,
        expectedBytes: expectedBytes,
      );
      canRefreshUrl =
          await _ref
              .read(downloadUrlRefreshStoreProvider)
              .get(downloadTrackingUrl(task)) !=
          null;
    } else if (parallelParent != null) {
      canRefreshUrl =
          await _ref
              .read(downloadUrlRefreshStoreProvider)
              .get(downloadTrackingUrl(parallelParent)) !=
          null;
    }

    return _rangeTransfers.start(
      id: task.taskId,
      url: task.url,
      headers: task.headers,
      file: dest,
      existingBytes: existingBytes,
      expectedBytes: expectedBytes,
      canRefreshUrl: canRefreshUrl,
      onState: (written, total, complete) async {
        if (_disposed) return;
        if (token != null &&
            !await _jobStore.updateForAttempt(
              token,
              state: complete
                  ? DownloadJobState.completed
                  : DownloadJobState.running,
              durableBytes: written,
              durableByteProvenance: DownloadDurableByteProvenance.rangeFlushed,
              expectedBytes: total,
              queueWaiting: false,
            )) {
          return;
        }
        final status = complete ? TaskStatus.complete : TaskStatus.running;
        await FileDownloader().database.updateRecord(
          TaskRecord(task, status, written / total, total),
        );
        _sharedEvents.add(TaskProgressUpdate(task, written / total, total));
        if (complete) {
          _sharedEvents.add(TaskStatusUpdate(task, TaskStatus.complete));
        }
      },
      onPaused: (written, total) async {
        if (_disposed) return;
        if (token != null &&
            !await _jobStore.updateForAttempt(
              token,
              state: _userPausedIds.contains(task.taskId)
                  ? DownloadJobState.pausedByUser
                  : DownloadJobState.interrupted,
              durableBytes: written,
              durableByteProvenance: DownloadDurableByteProvenance.rangeFlushed,
              expectedBytes: total,
            )) {
          return;
        }
        await FileDownloader().database.updateRecord(
          TaskRecord(task, TaskStatus.paused, written / total, total),
        );
        _sharedEvents.add(TaskStatusUpdate(task, TaskStatus.paused));
      },
      onFailure: (failure) async {
        if (!logical || token == null) {
          if (parallelParent != null &&
              failure.action == DownloadFailureAction.waitForNetwork) {
            await _holdDownloadForNetwork(parallelParent);
          } else if (parallelParent != null &&
              failure.action == DownloadFailureAction.refreshUrl) {
            _scheduleParallelParentRefresh(parallelParent.taskId);
          }
          return;
        }
        final activeToken = token;
        if (!await _jobStore.accepts(activeToken)) return;
        if (failure.action == DownloadFailureAction.waitForNetwork) {
          await _holdDownloadForNetwork(task);
          return;
        }
        if (failure.action == DownloadFailureAction.refreshUrl) {
          // DownloadRangeTransfer removes its ownership immediately after this
          // callback returns. Queue the retry on the next event turn so the
          // same taskId can start a new fenced generation safely.
          Future<void>.delayed(Duration.zero, () async {
            if (_disposed ||
                _userPausedIds.contains(task.taskId) ||
                _terminalJobIds.contains(task.taskId)) {
              return;
            }
            await _serializeQueue(() async {
              final record = await FileDownloader().database.recordForId(
                task.taskId,
              );
              if (record?.task is DownloadTask) {
                await _resumeDownloadTask(record!.task as DownloadTask);
              }
            });
          });
        } else if (failure.action == DownloadFailureAction.reconcileRange &&
            failure.resourceSize > 0 &&
            await dest.exists() &&
            await dest.length() == failure.resourceSize &&
            (expectedBytes <= 0 || expectedBytes == failure.resourceSize)) {
          final currentFingerprint = await _probeResourceFingerprint(
            task.url,
            headers: task.headers,
          );
          final persistedFingerprint = (await _jobStore.get(task.taskId))
              ?.fingerprint;
          final completionExpected = knownDownloadSize(<int?>[
            expectedBytes,
            persistedFingerprint?.expectedBytes,
            currentFingerprint?.expectedBytes,
            failure.resourceSize,
          ]);
          if (!downloadCompletionEvidenceMatches(
            observedFileBytes: failure.resourceSize,
            expectedResourceBytes: completionExpected,
            // DownloadRangeTransfer only reaches reconcileRange after its
            // existing-prefix guard has succeeded.
            prefixMatches: true,
            persistedFingerprint: persistedFingerprint,
            currentFingerprint: currentFingerprint,
          )) {
            return;
          }
          await _jobStore.updateForAttempt(
            activeToken,
            state: DownloadJobState.completed,
            durableBytes: failure.resourceSize,
            durableByteProvenance: DownloadDurableByteProvenance.rangeFlushed,
            expectedBytes: completionExpected,
            fingerprint: fingerprintWithExpectedBytes(
              remote: currentFingerprint,
              expectedBytes: completionExpected,
              fallbackFinalUrl: task.url,
            ),
          );
          await FileDownloader().database.updateRecord(
            TaskRecord(task, TaskStatus.complete, 1, completionExpected),
          );
          _sharedEvents.add(TaskProgressUpdate(task, 1, completionExpected));
          _sharedEvents.add(TaskStatusUpdate(task, TaskStatus.complete));
        }
      },
    );
  }

  Future<DownloadAttemptToken?> _beginLogicalRangeAttempt(
    DownloadTask task, {
    required int existingBytes,
    required int expectedBytes,
  }) async {
    final trackingUrl = downloadTrackingUrl(task);
    var job = await _jobStore.get(task.taskId);
    if (job == null) {
      final remoteFingerprint = await _probeResourceFingerprint(
        task.url,
        headers: task.headers,
      );
      final seeded = DownloadJobRecord(
        taskId: task.taskId,
        trackingUrl: trackingUrl,
        state: DownloadJobState.interrupted,
        generation: 0,
        durableBytes: existingBytes,
        durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
        expectedBytes: expectedBytes,
        userPaused: false,
        queueWaiting: false,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
        taskSnapshot: task.toJson(),
        fingerprint: fingerprintWithExpectedBytes(
          remote: remoteFingerprint,
          expectedBytes: expectedBytes,
          fallbackFinalUrl: task.url,
        ),
      );
      if (!await _jobStore.put(seeded)) return null;
      job = seeded;
    } else if (existingBytes > job.durableBytes) {
      if (!await _jobStore.put(
        job.copyWith(
          durableBytes: existingBytes,
          durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
          expectedBytes: expectedBytes > 0 ? expectedBytes : job.expectedBytes,
          updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      )) {
        return null;
      }
    }
    return _jobStore.beginAttempt(task.taskId, state: DownloadJobState.running);
  }

  Future<({DownloadTask task, bool refreshed, bool restartRequired})>
  _refreshTaskBeforeResume(
    DownloadTask task, {
    required int expectedBytes,
    required int partialBytes,
    bool hasOpaqueNativeResume = false,
  }) async {
    diagnosticLog.record('source.check', {
      'taskId': task.taskId,
      'bytes': partialBytes,
      'total': expectedBytes,
    });
    final trackingUrl = downloadTrackingUrl(task);
    final authoritativeFingerprint = (await _jobStore.get(task.taskId))
        ?.fingerprint;
    final store = _ref.read(downloadUrlRefreshStoreProvider);
    final descriptor = await store.get(trackingUrl);
    if (descriptor == null)
      return (task: task, refreshed: false, restartRequired: false);

    // Keep a still-valid URL. This avoids provider extraction work on every
    // short pause/resume while still detecting expired signed links.
    final current = await getMetadata(task.url, headers: task.headers);
    final currentFingerprint = await _probeResourceFingerprint(
      task.url,
      headers: task.headers,
    );
    final currentIdentityMatches =
        authoritativeFingerprint == null ||
        currentFingerprint == null ||
        authoritativeFingerprint.compatibleWith(currentFingerprint);
    final currentSizeMatches =
        expectedBytes <= 0 ||
        current?.size == null ||
        current?.size == expectedBytes;
    final currentRangeOk =
        task is! ParallelDownloadTask && partialBytes <= 0 ||
        current?.supportsRanges == true;
    if (current != null &&
        current.size != null &&
        currentSizeMatches &&
        currentRangeOk &&
        currentIdentityMatches) {
      return (task: task, refreshed: false, restartRequired: false);
    }

    final refreshed = await _ref
        .read(downloadUrlRefresherProvider)
        .refresh(descriptor, currentUrl: task.url);
    diagnosticLog.record('source.refresh', {
      'taskId': task.taskId,
      'result': refreshed != null,
    });
    if (refreshed == null)
      return (task: task, refreshed: false, restartRequired: false);
    final metadata = await getMetadata(
      refreshed.url,
      headers: refreshed.headers,
    );
    final refreshedFingerprint = await _probeResourceFingerprint(
      refreshed.url,
      headers: refreshed.headers,
    );
    final refreshedIdentityMatches =
        authoritativeFingerprint == null ||
        refreshedFingerprint == null ||
        authoritativeFingerprint.compatibleWith(refreshedFingerprint);
    if (metadata?.size == null ||
        (expectedBytes > 0 && metadata!.size != expectedBytes) ||
        ((task is ParallelDownloadTask || partialBytes > 0) &&
            metadata?.supportsRanges != true) ||
        !refreshedIdentityMatches) {
      return (task: task, refreshed: false, restartRequired: false);
    }

    if (task is! ParallelDownloadTask &&
        hasOpaqueNativeResume &&
        partialBytes <= 0) {
      // We proved the old source needs replacement and also proved that the
      // only resumable bytes are opaque native resume data tied to that old
      // source. The replacement itself is valid, but those bytes cannot be
      // migrated safely, so leave durable/source state untouched and require an
      // explicit user-visible restart decision.
      return (task: task, refreshed: false, restartRequired: true);
    }

    // Source replacement changes executor/manifest identity. Persist an
    // interrupted write-ahead boundary first so a storage failure cannot let
    // the old durable state race a newly installed URL. DM-11/DM-31 later
    // make the source capability itself transactional and generation-aware.
    final refreshCheckpointed = await _checkpointLogicalJob(
      task,
      state: DownloadJobState.interrupted,
      expectedBytes: expectedBytes,
      userPaused: false,
      queueWaiting: false,
      fingerprint: fingerprintWithExpectedBytes(
        remote: refreshedFingerprint,
        expectedBytes: expectedBytes,
        fallbackFinalUrl: refreshed.url,
      ),
    );
    if (!refreshCheckpointed) {
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
      final replaced = await _parallel.replaceSource(
        task,
        url: refreshed.url,
        headers: refreshed.headers,
      );
      return replaced == null
          ? (task: task, refreshed: false, restartRequired: false)
          : (task: replaced, refreshed: true, restartRequired: false);
    }

    final updated = task.copyWith(
      url: refreshed.url,
      headers: Map<String, String>.from(refreshed.headers),
    );
    final record = await FileDownloader().database.recordForId(task.taskId);
    if (record != null) {
      await FileDownloader().database.updateRecord(
        TaskRecord(
          updated,
          record.status,
          record.progress,
          record.expectedFileSize,
        ),
      );
    }
    _nativeTransport.forget(task.taskId);
    return (task: updated, refreshed: true, restartRequired: false);
  }

  Future<List<Task>> _liveTransferTasks() =>
      FileDownloader().allTasks(allGroups: true);

  Future<DownloadRuntimeOwnership> _runtimeOwnershipFor(String taskId) async {
    if (_rangeTransfers.isActive(taskId) ||
        _parallel.isActive(taskId) ||
        _parallel.hasLiveConnections(taskId)) {
      return DownloadRuntimeOwnership.owned;
    }
    try {
      final activeTasks = await _liveTransferTasks();
      return resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: true,
        runtimeTaskPresent: activeTasks.any((task) => task.taskId == taskId),
        transferHandlePresent: _nativeTransport.handleFor(taskId) != null,
      );
    } catch (_) {
      return resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: false,
        runtimeTaskPresent: false,
        transferHandlePresent: _nativeTransport.handleFor(taskId) != null,
      );
    }
  }

  Future<DownloadRuntimeOwnership> _waitForCancelOwnershipRelease(
    String taskId, {
    int attempts = 10,
    Duration delay = const Duration(milliseconds: 100),
  }) async {
    var ownership = await _runtimeOwnershipFor(taskId);
    for (
      var attempt = 1;
      attempt < attempts && ownership != DownloadRuntimeOwnership.notOwned;
      attempt++
    ) {
      await Future<void>.delayed(delay);
      ownership = await _runtimeOwnershipFor(taskId);
    }
    return ownership;
  }

  Future<void> _reconcileTransferOwnership() async {
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

  Future<Set<String>> _livePartIds() async => {
    for (final task in await _liveTransferTasks()) task.taskId,
    ..._rangeTransfers.activeTaskIds,
  };

  Future<bool> _pauseTransfer(
    DownloadTask task, {
    bool rangeAlreadyStopped = false,
  }) async {
    if (_rangeTransfers.isActive(task.taskId)) {
      await _rangeTransfers.stop(task.taskId);
      return true;
    }
    if (task is ParallelDownloadTask && await _parallel.restore(task)) {
      return _parallel.pause(
        task,
        preserveLiveParts:
            Platform.isIOS && _userPausedIds.contains(task.taskId),
      );
    }

    final settled = Completer<void>();
    final listener = _sharedEvents.stream.listen((update) {
      if (update.task.taskId == task.taskId &&
          update is TaskStatusUpdate &&
          (update.status == TaskStatus.paused || update.status.isFinalState)) {
        if (!settled.isCompleted) settled.complete();
      }
    });

    try {
      final accepted = isInternalDownloaderChunk(task)
          ? await FileDownloader().pause(task)
          : await _nativeTransport.pause(task);
      diagnosticLog.record('native.pauseAck', {
        'taskId': task.taskId,
        'result': accepted,
      });
      if (!accepted) {
        // pauseDownload already joined the Range writer before entering the
        // control queue. A missing native task is expected in that case.
        return rangeAlreadyStopped &&
            await _runtimeOwnershipFor(task.taskId) ==
                DownloadRuntimeOwnership.notOwned;
      }

      // pause() acknowledges the command before URLSession has necessarily
      // produced resume data. Wait for its state callback before resume can run.
      await settled.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );

      // Command acceptance and even a paused callback are not sufficient proof
      // that URLSession released the writer. DM-19 runtime ownership is the
      // final authority for both ordinary single-file and multipart children.
      var ownership = await _runtimeOwnershipFor(task.taskId);
      if (ownership == DownloadRuntimeOwnership.owned) {
        // A hand-off race can leave the same task alive briefly. Retry pause on
        // the same identity once; never cancel because that can destroy resume data.
        final retried = isInternalDownloaderChunk(task)
            ? await FileDownloader().pause(task)
            : await _nativeTransport.pause(task);
        if (!retried) return false;
        await Future<void>.delayed(const Duration(milliseconds: 200));
        ownership = await _runtimeOwnershipFor(task.taskId);
      }
      if (ownership != DownloadRuntimeOwnership.notOwned) return false;
      return true;
    } finally {
      await listener.cancel();
    }
  }

  Future<bool> _startPart(DownloadTask task, double progress, int size) async {
    diagnosticLog.record('part.start', {
      'taskId': task.taskId,
      'progress': progress,
      'total': size,
    });
    final ownership = await _runtimeOwnershipFor(task.taskId);
    if (ownership == DownloadRuntimeOwnership.owned) return true;
    if (ownership.blocksNewWriter) {
      diagnosticLog.record('part.startOwnershipBlocked', {
        'taskId': task.taskId,
        'ownership': ownership.name,
      });
      return false;
    }

    final forceSourceValidation = downloadInternalSourceValidationRequired(
      task,
    );
    var nativeCanResume = false;
    if (!forceSourceValidation) {
      try {
        nativeCanResume = await FileDownloader()
            .taskCanResume(task)
            .timeout(const Duration(seconds: 3));
        if (nativeCanResume && await FileDownloader().resume(task)) return true;
      } catch (_) {
        // A stale native checkpoint must not prevent the disk-prefix fallback.
      }
    }

    final partial = await canonicalizePartialDownloadFile(
      destinationPath: await task.filePath(),
    );
    final bytes = partial?.bytes ?? 0;
    if (bytes == size && size > 0) {
      await FileDownloader().database.updateRecord(
        TaskRecord(task, TaskStatus.complete, 1, size),
      );
      if (forceSourceValidation) {
        await _parallel.markPartSourceValidated(task.taskId);
      }
      _sharedEvents.add(TaskStatusUpdate(task, TaskStatus.complete));
      return true;
    }
    if (bytes > 0 && bytes < size) {
      final started = await _appendRemainingWithDio(
        task,
        dest: partial!.file,
        existingBytes: bytes,
        expectedBytes: size,
      );
      if (started && forceSourceValidation) {
        await _parallel.markPartSourceValidated(task.taskId);
      }
      return started;
    }

    if (progress > 0 &&
        bytes == 0 &&
        (!nativeCanResume || forceSourceValidation)) {
      // Resume bytes that exist only inside old native resumeData cannot be
      // proven after a signed URL refresh. Drop only this immutable Range's
      // phantom prefix and fetch it from byte zero on the refreshed source.
      final repaired = _parallel.resetUndurablePartProgress(
        task.taskId,
        durableBytes: 0,
      );
      if (!repaired) return false;
      diagnosticLog.record('part.checkpointLost', {
        'taskId': task.taskId,
        'progress': progress,
        'total': size,
        'sourceRefresh': forceSourceValidation,
      });
      await FileDownloader().database.updateRecord(
        TaskRecord(task, TaskStatus.paused, 0, size),
      );
      final enqueued = await FileDownloader().enqueue(task);
      if (enqueued && forceSourceValidation) {
        await _parallel.markPartSourceValidated(task.taskId);
      }
      return enqueued;
    }

    if (bytes > 0) return false;
    final enqueued = await FileDownloader().enqueue(task);
    if (enqueued && forceSourceValidation) {
      await _parallel.markPartSourceValidated(task.taskId);
    }
    return enqueued;
  }

  Future<bool> _enqueueTransfer(DownloadTask task, int totalBytes) async {
    if (!_networkAvailable) {
      await _holdDownloadForNetwork(task);
      return true;
    }
    if (task is! ParallelDownloadTask) return _nativeTransport.start(task);
    if (totalBytes <= 0) {
      totalBytes =
          (await getMetadata(task.url, headers: task.headers))?.size ?? -1;
    }
    return _parallel.start(task, totalBytes);
  }

  Future<DownloadResourceFingerprint?> _probeResourceFingerprint(
    String url, {
    Map<String, String>? headers,
  }) async {
    String? strongEtag;
    String? lastModified;
    var expectedBytes = -1;
    String? finalUrl;

    void absorb(Response<dynamic> response) {
      strongEtag ??= strongDownloadEtag(response.headers.value('etag'));
      final modified = response.headers.value('last-modified')?.trim();
      if (lastModified == null && modified != null && modified.isNotEmpty) {
        lastModified = modified;
      }
      final range = RegExp(r'^bytes\s+\d+-\d+/(\d+)$')
          .firstMatch(response.headers.value('content-range') ?? '');
      final rangeBytes = range == null ? null : int.tryParse(range[1]!);
      final contentBytes = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (rangeBytes != null && rangeBytes > 0) {
        expectedBytes = rangeBytes;
      } else if (response.statusCode != 206 &&
          contentBytes != null &&
          contentBytes > 0) {
        expectedBytes = contentBytes;
      }
      final resolved = response.realUri.toString().trim();
      if (resolved.isNotEmpty) finalUrl = resolved;
    }

    try {
      final response = await _dio
          .head<dynamic>(
            url,
            options: Options(
              headers: {...?headers, 'Accept-Encoding': 'identity'},
              followRedirects: true,
            ),
          )
          .timeout(const Duration(seconds: 10));
      absorb(response);
    } catch (_) {}

    if (expectedBytes <= 0 || (strongEtag == null && lastModified == null)) {
      try {
        final response = await _dio
            .get<dynamic>(
              url,
              options: Options(
                headers: {
                  ...?headers,
                  'Range': 'bytes=0-0',
                  'Accept-Encoding': 'identity',
                },
                followRedirects: true,
                responseType: ResponseType.stream,
                validateStatus: (status) =>
                    status != null && (status == 200 || status == 206),
              ),
            )
            .timeout(const Duration(seconds: 10));
        absorb(response);
        final body = response.data;
        if (body is ResponseBody) {
          final subscription = body.stream.listen(null);
          await subscription.cancel();
        }
      } catch (_) {}
    }

    if (strongEtag == null && lastModified == null && expectedBytes <= 0) {
      return null;
    }
    return DownloadResourceFingerprint(
      strongEtag: strongEtag,
      lastModified: lastModified,
      expectedBytes: expectedBytes,
      finalUrl: finalUrl ?? url,
    );
  }

  Future<DownloadMetadata?> getMetadata(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      int? size;
      String? mimeType;
      var supportsRanges = false;

      try {
        final response = await _dio
            .head<dynamic>(
              url,
              options: Options(
                headers: {...?headers, 'Accept-Encoding': 'identity'},
                followRedirects: true,
              ),
            )
            .timeout(const Duration(seconds: 10));
        size = int.tryParse(response.headers.value('content-length') ?? '');
        mimeType = response.headers.value('content-type');
        final acceptRanges = response.headers.value('accept-ranges');
        supportsRanges = acceptRanges?.toLowerCase().contains('bytes') == true;
      } catch (_) {}

      // A 206 response is stronger evidence than Accept-Ranges and also covers
      // hosts that reject HEAD. Stream and cancel immediately so a bad server
      // that ignores Range cannot buffer a whole episode into memory.
      {
        try {
          final response = await _dio
              .get<dynamic>(
                url,
                options: Options(
                  headers: {
                    ...?headers,
                    'Range': 'bytes=0-0',
                    'Accept-Encoding': 'identity',
                  },
                  followRedirects: true,
                  responseType: ResponseType.stream,
                  validateStatus: (status) =>
                      status != null && (status == 200 || status == 206),
                ),
              )
              .timeout(const Duration(seconds: 10));
          final contentRange = response.headers.value('content-range');
          if (response.statusCode == 206 && contentRange != null) {
            final match = RegExp(r'^bytes 0-0/(\d+)$').firstMatch(contentRange);
            supportsRanges = match != null;
            if (match != null) size = int.tryParse(match[1]!);
          } else {
            // A successful 200 to an explicit Range request means the
            // origin ignored the range. A thrown probe keeps HEAD's prior
            // Accept-Ranges evidence instead of falsely disabling parts.
            supportsRanges = false;
            final contentLength = int.tryParse(
              response.headers.value('content-length') ?? '',
            );
            if (contentLength != null && contentLength > 1) {
              size ??= contentLength;
            }
          }
          mimeType ??= response.headers.value('content-type');
          final body = response.data;
          if (body is ResponseBody) {
            final subscription = body.stream.listen(null);
            await subscription.cancel();
          }
        } catch (_) {}
      }

      return DownloadMetadata(
        size: size,
        mimeType: mimeType,
        supportsRanges: supportsRanges,
      );
    } catch (_) {
      return null;
    }
  }

  /// Stores an episode's intro/credits timestamps alongside the download so
  /// the skip button still works with no connection. Best-effort: a failure
  /// here must never affect the download itself.
  Future<void> _cacheSkipSegmentsForDownload(
    MultimediaItem item,
    Episode? episode,
  ) async {
    if (episode == null) return;
    final episodeUrl = episode.url.trim();
    if (episodeUrl.isEmpty) return;

    try {
      final settings = _ref.read(settingsRepositoryProvider);
      final enabled =
          settings.getPlayerSetting<bool>(
            'player_skip_segments',
            defaultValue: true,
          ) ??
          true;
      if (!enabled) return;

      final cache = _ref.read(skipSegmentCacheProvider);
      final keys = <String>[SkipSegmentCache.keyForEpisodeUrl(episodeUrl)];
      if (cache.readAny(keys).isNotEmpty) return; // already stored

      var malId = int.tryParse(
        (item.syncData?['malId'] ?? item.syncData?['mal_id'] ?? '').trim(),
      );
      malId ??= item.title.trim().isEmpty
          ? null
          : await _ref.read(malIdResolverProvider).resolve(item.title);
      if (malId == null) return;

      final episodeNumber = episode.episode > 0 ? episode.episode : 1;
      // The file isn't on disk yet, so its exact length is unknown; the
      // catalog runtime (in minutes) is close enough for AniSkip to pick the
      // submission that matches this release.
      final runtimeMinutes = int.tryParse(
        item.syncData?['awDuration']?.trim() ?? '',
      );
      final segments = await _ref
          .read(aniSkipServiceProvider)
          .getSkipSegments(
            malId: malId,
            season: 1,
            episode: episodeNumber,
            duration: (runtimeMinutes != null && runtimeMinutes > 0)
                ? runtimeMinutes * 60
                : null,
          );
      if (segments.isEmpty) return;

      keys.add(SkipSegmentCache.keyForMal(malId, episodeNumber));
      await cache.write(keys, segments);
      if (kDebugMode) {
        debugPrint(
          '[DownloadService] Cached ${segments.length} skip segments for '
          'episode $episodeNumber (mal $malId)',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DownloadService] Skip segment caching skipped: $e');
      }
    }
  }

  Future<bool> _commitRefreshDescriptorForGeneration(
    DownloadUrlRefreshDescriptor descriptor, {
    required String trackingUrl,
    required String ownerTaskId,
    required String logicalId,
    required int generation,
    bool claimOwnership = false,
  }) {
    final owned = DownloadUrlRefreshDescriptor(
      trackingUrl: trackingUrl,
      providerId: descriptor.providerId,
      source: descriptor.source,
      quality: descriptor.quality,
      refreshUrl: descriptor.refreshUrl,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      generation: generation,
      ownerTaskId: ownerTaskId,
      logicalId: logicalId,
    );
    final store = _ref.read(downloadUrlRefreshStoreProvider);
    return claimOwnership ? store.claimOwnership(owned) : store.save(owned);
  }

  Future<bool> startDownload({
    required String url,
    required String filename,
    required String directory, // Relative for mobile/mac, absolute for others
    required MultimediaItem item,
    Episode? episode,
    String? trackingUrl,
    Map<String, String>? headers,
    int totalBytes = -1,
    DownloadUrlRefreshDescriptor? refreshDescriptor,
  }) async {
    final outcome = await startDownloadOutcome(
      url: url,
      filename: filename,
      directory: directory,
      item: item,
      episode: episode,
      trackingUrl: trackingUrl,
      headers: headers,
      totalBytes: totalBytes,
      refreshDescriptor: refreshDescriptor,
    );
    return switch (outcome) {
      DownloadCommandOutcome.running ||
      DownloadCommandOutcome.attached ||
      DownloadCommandOutcome.queued ||
      DownloadCommandOutcome.alreadyComplete => true,
      _ => false,
    };
  }

  Future<DownloadCommandOutcome> startDownloadOutcome({
    required String url,
    required String filename,
    required String directory, // Relative for mobile/mac, absolute for others
    required MultimediaItem item,
    Episode? episode,
    String? trackingUrl,
    Map<String, String>? headers,
    int totalBytes = -1,
    DownloadUrlRefreshDescriptor? refreshDescriptor,
  }) async {
    try {
      await _awaitCommandReadiness('startDownload');
    } catch (_) {
      return DownloadCommandOutcome.serviceUnavailable;
    }
    final logicalId = DownloadLogicalIdentity.fromMedia(
      item: item,
      episode: episode,
    ).key;
    diagnosticLog.record('command.start', {
      'total': totalBytes,
      'logicalId': logicalId,
    });
    if (kDebugMode) {
      debugPrint('[DownloadService] startDownload called');
      debugPrint('[DownloadService] - URL: $url');
      debugPrint('[DownloadService] - Tracking URL: $trackingUrl');
      debugPrint('[DownloadService] - Filename: $filename');
      debugPrint('[DownloadService] - Directory: $directory');
    }

    // Resolve the intro/credits timestamps now, while there is definitely a
    // connection, and keep them on disk. Watching the file later is the one
    // case where the skip sources are unreachable.
    unawaited(_cacheSkipSegmentsForDownload(item, episode));

    // Industry Standard: Ask for battery optimization when a real download starts
    await requestIgnoreBatteryOptimizations();

    // Request permission on Android (Version Aware)
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 30) {
        // For Android 11+, request MANAGE_EXTERNAL_STORAGE to allow native C++ players (media_kit)
        // to bypass FUSE directory depth limits for deeply nested series folders
        final status = await Permission.manageExternalStorage.status;
        if (!status.isGranted) {
          await Permission.manageExternalStorage.request();
        }
      } else {
        // For Android 10 and below, request standard storage permission
        await Permission.storage.request();
      }
    }

    final isAndroid = Platform.isAndroid;
    final isIOS = Platform.isIOS;

    return _serializeQueue(() async {
      // Canonical logical identity is the primary duplicate/adoption key. A
      // signed URL, filename or execution taskId may rotate between attempts.
      final records = await FileDownloader().database.allRecords();
      final recordsById = <String, TaskRecord>{
        for (final record in records) record.task.taskId: record,
      };
      final logicalJobs = await _jobStore.allForLogicalId(logicalId);
      DownloadJobRecord? existingLogicalJob;
      TaskRecord? existingRecord;
      for (final job in logicalJobs.reversed) {
        if (job.state == DownloadJobState.completed ||
            job.state == DownloadJobState.canceled ||
            job.state == DownloadJobState.orphaned) {
          continue;
        }
        final projected = recordsById[job.taskId];
        if (projected != null && isLogicalEpisodeDownloadTask(projected.task)) {
          existingLogicalJob = job;
          existingRecord = projected;
          break;
        }
        final restored = job.restoreTaskSnapshot();
        if (restored == null || !isLogicalEpisodeDownloadTask(restored))
          continue;
        final progress = job.expectedBytes > 0
            ? (job.durableBytes / job.expectedBytes).clamp(0.0, 1.0)
            : 0.0;
        existingLogicalJob = job;
        existingRecord = TaskRecord(
          restored,
          downloadJobTaskStatus(job.state),
          progress,
          job.expectedBytes,
        );
        // Repair a lost executor projection; this does not start a writer.
        await FileDownloader().database.updateRecord(existingRecord);
        break;
      }

      if (existingRecord == null) {
        // Reconstruct canonical identity for pre-DM24 JobStore rows before any
        // mutable URL/path fallback. This is adoption/repair only; it never
        // creates a second execution writer.
        final allJobs = await _jobStore.all();
        final storage = _ref.read(storageServiceProvider);
        for (final candidateJob in allJobs.reversed) {
          if (candidateJob.state == DownloadJobState.completed ||
              candidateJob.state == DownloadJobState.canceled ||
              candidateJob.state == DownloadJobState.orphaned) {
            continue;
          }
          final metadata = await storage.getDownloadMetadata(
            candidateJob.taskId,
          );
          final candidateLogicalId =
              candidateJob.logicalId ?? logicalDownloadIdFromMetadata(metadata);
          if (candidateLogicalId != logicalId) continue;

          var migratedJob = candidateJob;
          if (candidateJob.logicalId == null) {
            migratedJob = candidateJob.copyWith(
              logicalId: logicalId,
              updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
            );
            if (!await _jobStore.put(migratedJob)) continue;
          }

          final projected = recordsById[candidateJob.taskId];
          if (projected != null &&
              isLogicalEpisodeDownloadTask(projected.task)) {
            existingLogicalJob = migratedJob;
            existingRecord = projected;
            break;
          }

          final restored = migratedJob.restoreTaskSnapshot();
          if (restored == null || !isLogicalEpisodeDownloadTask(restored)) {
            continue;
          }
          final progress = migratedJob.expectedBytes > 0
              ? (migratedJob.durableBytes / migratedJob.expectedBytes).clamp(
                  0.0,
                  1.0,
                )
              : 0.0;
          existingLogicalJob = migratedJob;
          existingRecord = TaskRecord(
            restored,
            downloadJobTaskStatus(migratedJob.state),
            progress,
            migratedJob.expectedBytes,
          );
          await FileDownloader().database.updateRecord(existingRecord);
          break;
        }
      }

      // Pre-logical-identity migration fallback: only evidence that genuinely
      // lacks canonical identity may use a historical tracking URL. Once a row
      // has a logical ID, a different episode can never collapse through URL.
      if (existingRecord == null) {
        final storage = _ref.read(storageServiceProvider);
        for (final candidate in records) {
          if (!isLogicalEpisodeDownloadTask(candidate.task) ||
              !(candidate.status == TaskStatus.failed ||
                  candidate.status == TaskStatus.notFound ||
                  candidate.status == TaskStatus.enqueued ||
                  candidate.status == TaskStatus.running ||
                  candidate.status == TaskStatus.paused ||
                  candidate.status == TaskStatus.waitingToRetry)) {
            continue;
          }
          final candidateJob = await _jobStore.get(candidate.task.taskId);
          final candidateMetadata = await storage.getDownloadMetadata(
            candidate.task.taskId,
          );
          final candidateLogicalId =
              candidateJob?.logicalId ??
              logicalDownloadIdFromMetadata(candidateMetadata);
          if (candidateLogicalId != null) {
            if (candidateLogicalId != logicalId) continue;
            existingLogicalJob = candidateJob;
            existingRecord = candidate;
            break;
          }

          final candidateTracking = candidate.task.metaData.isNotEmpty
              ? candidate.task.metaData
              : candidate.task.url;
          if (candidateTracking == (trackingUrl ?? url)) {
            existingRecord = candidate;
            break;
          }
        }
      }

      if (existingRecord != null) {
        if (kDebugMode) {
          debugPrint(
            '[DownloadService] Task already exists in database with status: ${existingRecord.status}',
          );
        }

        final authoritativeJob =
            existingLogicalJob ??
            await _jobStore.get(existingRecord.task.taskId);
        final occupying = authoritativeJob != null
            ? downloadJobOccupiesSlot(authoritativeJob.state)
            : occupiesDownloadSlot(
                status: existingRecord.status,
                queueWaiting: _queueWaitingIds.contains(
                  existingRecord.task.taskId,
                ),
              );
        if (occupying &&
            (_parallel.isActive(existingRecord.task.taskId) ||
                _rangeTransfers.isActive(existingRecord.task.taskId) ||
                await _liveNativeTaskFor(taskId: existingRecord.task.taskId) !=
                    null)) {
          _ref.read(activeDownloadsProvider.notifier).add(trackingUrl ?? url);
          return DownloadCommandOutcome.attached;
        }

        if (existingRecord.task is! DownloadTask) {
          return DownloadCommandOutcome.recoverableFailure;
        }
        final existingTask = existingRecord.task as DownloadTask;
        final live = await _liveNativeTaskFor(
          taskId: existingTask.taskId,
          trackingUrl: trackingUrl ?? url,
        );
        if (live != null &&
            (occupying || isLiveNativeDownloadStatus(existingRecord.status))) {
          await _attachToLiveNativeTask(existingTask, live: live);
          _ref.read(activeDownloadsProvider.notifier).add(trackingUrl ?? url);
          return DownloadCommandOutcome.attached;
        }
        await _resumeUserPausedUnlocked(existingTask.taskId);
        return downloadCommandOutcomeForJobState(
          (await _jobStore.get(existingTask.taskId))?.state,
        );
      }

      final tracking = trackingUrl ?? url;
      final completeRecords = await _completeRecordsForEpisode(
        records,
        logicalId: logicalId,
        trackingUrl: tracking,
        item: item,
        episode: episode,
        filename: filename,
        directory: directory,
      );
      File? completeFile;
      for (final record in completeRecords) {
        completeFile = await getDownloadedFileForTask(record.task);
        if (completeFile != null) break;
        try {
          final path = await record.task.filePath();
          if (path.isNotEmpty) {
            final file = File(path);
            if (await file.exists() && await file.length() > 0) {
              completeFile = file;
              break;
            }
          }
        } catch (_) {}
      }
      completeFile ??= await getDownloadedFile(item, episode: episode);

      switch (decideCompleteDownloadAction(
        hasCompleteRecord: completeRecords.isNotEmpty,
        fileExists: completeFile != null,
      )) {
        case CompleteDownloadAction.reuse:
          if (kDebugMode) {
            debugPrint(
              '[DownloadService] Complete record already has a file for $tracking',
            );
          }
          return DownloadCommandOutcome.alreadyComplete;
        case CompleteDownloadAction.dropAndEnqueue:
          await _dropCompleteRecords(completeRecords);
          break;
        case CompleteDownloadAction.enqueue:
          break;
      }

      // Path Logic:
      // Android/Desktop: use BaseDirectory.root with absolute path.
      // iOS: use BaseDirectory.applicationDocuments with relative path for sandbox safety.
      BaseDirectory baseDir;
      String taskDirectory;

      if (isIOS) {
        baseDir = BaseDirectory.applicationDocuments;
        // Relative: "AnimeWitcher/Downloads/Title"
        taskDirectory = directory;
      } else {
        // Android, Windows, macOS, Linux: use absolute paths with BaseDirectory.root
        baseDir = BaseDirectory.root;
        if (isAndroid) {
          taskDirectory = p.join(await _getPublicDownloadsPath(), directory);
        } else {
          // Desktop: directory is already absolute
          // (e.g. /Users/…/Downloads/AnimeWitcher/Downloads/Title)
          taskDirectory = directory;
        }
      }

      final task = DownloadTask(
        url: url,
        filename: filename,
        displayName: filename,
        baseDirectory: baseDir,
        directory: taskDirectory,
        headers: headers ?? {},
        updates: Updates.statusAndProgress,
        retries: kDownloadTaskRetries,
        allowPause: true,
        group: kLogicalDownloadGroup,
        metaData: trackingUrl ?? url,
        transferHints: animeDownloadTransferHints(
          expectedBytes: totalBytes,
          useUserInitiated: shouldUseUserInitiatedDownloadHint(
            isAndroid: Platform.isAndroid,
            notificationsConfigured: !shouldClearDownloadNotificationConfigs(
              _ref.read(storageServiceProvider).getDownloadNotificationPrefs(),
            ),
            notificationPermissionGranted:
                !Platform.isAndroid ||
                await FileDownloader().permissions.status(
                      PermissionType.notifications,
                    ) ==
                    PermissionStatus.granted,
          ),
        ),
        stallTimeout: const Duration(seconds: 45),
      );

      int? refreshDescriptorGeneration;
      String? refreshDescriptorOwnerTaskId;

      if (kDebugMode) debugPrint('[DownloadService] Enqueuing task...');

      // Create the directory if it doesn't exist
      final String fullDirPath;
      if (isIOS) {
        final docsDir = await getApplicationDocumentsDirectory();
        fullDirPath = p.join(docsDir.path, taskDirectory);
      } else {
        // Android/Desktop: taskDirectory is already absolute
        fullDirPath = taskDirectory;
      }

      try {
        final dir = Directory(fullDirPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }

        String? path;
        try {
          path = await task.filePath();
        } catch (_) {}

        final storage = _ref.read(storageServiceProvider);
        final maxConcurrent = clampDownloadConcurrency(
          storage.getDownloadConcurrency(),
        );
        final occupied = await _occupiedSlotCount(
          await FileDownloader().database.allRecords(),
        );
        final startNow = occupied < maxConcurrent;
        final remoteFingerprint = await _probeResourceFingerprint(
          url,
          headers: headers,
        );
        final expectedBytes = knownDownloadSize(<int?>[
          totalBytes,
          remoteFingerprint?.expectedBytes,
        ]);
        final resourceFingerprint = fingerprintWithExpectedBytes(
          remote: remoteFingerprint,
          expectedBytes: expectedBytes,
          fallbackFinalUrl: url,
        );
        // Freeze the chosen transfer shape before queueing. This preserves a
        // manual/Auto multipart choice for episode 2+ instead of converting
        // only the first episode and leaving later FIFO rows single-part.
        final transferTask = await _adaptiveTaskForFreshStart(
          task,
          knownTotalBytes: expectedBytes,
        );
        refreshDescriptorOwnerTaskId = transferTask.taskId;
        final startIntent = await _jobStore.beginReplicaTransactionFromSeed(
          DownloadJobRecord(
            taskId: transferTask.taskId,
            logicalId: logicalId,
            trackingUrl: trackingUrl ?? url,
            state: startNow
                ? DownloadJobState.starting
                : DownloadJobState.queued,
            generation: 0,
            durableBytes: 0,
            expectedBytes: expectedBytes,
            userPaused: false,
            queueWaiting: !startNow,
            updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
            taskSnapshot: transferTask.toJson(),
            fingerprint: resourceFingerprint,
          ),
          operation: DownloadReplicaOperation.start,
          state: startNow ? DownloadJobState.starting : DownloadJobState.queued,
          intentData: <String, Object?>{
            if (refreshDescriptor != null)
              'refreshDescriptor': <String, Object?>{
                'trackingUrl': trackingUrl ?? url,
                'providerId': refreshDescriptor.providerId,
                'source': refreshDescriptor.source,
                if (refreshDescriptor.quality != null)
                  'quality': refreshDescriptor.quality,
                if (refreshDescriptor.refreshUrl != null)
                  'refreshUrl': refreshDescriptor.refreshUrl,
              },
          },
        );
        if (startIntent == null) {
          throw StateError('Failed to persist fresh download intent');
        }

        if (!startNow && refreshDescriptor != null) {
          final committed = await _commitRefreshDescriptorForGeneration(
            refreshDescriptor,
            trackingUrl: trackingUrl ?? url,
            ownerTaskId: transferTask.taskId,
            logicalId: logicalId,
            generation: startIntent.generation,
            claimOwnership: true,
          );
          if (!committed) {
            throw StateError('A newer refresh descriptor owns this download');
          }
          refreshDescriptorGeneration = 0;
        }

        _waitingPayloads[transferTask.taskId] = _waitingPayloadFor(
          transferTask,
        );
        _rememberSessionTask(transferTask.taskId);
        await storage.saveDownloadMetadata(
          task.taskId,
          item,
          episode: episode,
          trackingUrl: trackingUrl ?? url,
          filePath: path,
          logicalId: logicalId,
          taskSnapshot: transferTask.toJson(),
          queueWaiting: !startNow,
        );
        _ref.read(activeDownloadsProvider.notifier).add(trackingUrl ?? url);
        _telemetry.seed(transferTask.taskId, expectedBytes: expectedBytes);
        _publishProgress(
          trackingUrl: trackingUrl ?? url,
          taskId: transferTask.taskId,
          progress: 0,
          totalSize: expectedBytes,
          status: TaskStatus.enqueued,
        );

        if (!startNow) {
          _queueWaitingIds.add(task.taskId);
          await FileDownloader().database.updateRecord(
            TaskRecord(transferTask, TaskStatus.paused, 0, expectedBytes),
          );
          _updatesController.add(
            TaskStatusUpdate(transferTask, TaskStatus.enqueued),
          );
          await _persistNativeWaitingSnapshot();
          unawaited(_syncSessionOverlay());
          return DownloadCommandOutcome.queued;
        }

        _startingTaskIds.add(transferTask.taskId);
        _updatesController.add(
          TaskStatusUpdate(transferTask, TaskStatus.enqueued),
        );
        // The write-ahead start intent is also the execution generation fence.
        // Do not increment generation again before the executor effect or the
        // durable journal and refresh-descriptor owner would describe different
        // attempts after a crash.
        final startOperation = startIntent;
        if (refreshDescriptor != null) {
          final committed = await _commitRefreshDescriptorForGeneration(
            refreshDescriptor,
            trackingUrl: trackingUrl ?? url,
            ownerTaskId: transferTask.taskId,
            logicalId: logicalId,
            generation: startOperation.generation,
            claimOwnership: true,
          );
          if (!committed) {
            throw StateError('A newer refresh descriptor owns this download');
          }
          refreshDescriptorGeneration = startOperation.generation;
        }
        final success = await _enqueueTransfer(transferTask, expectedBytes);
        if (kDebugMode) {
          debugPrint(
            '[DownloadService] Enqueue result: $success '
            '(parts=${downloadTaskPartCount(transferTask)})',
          );
        }

        if (!success) {
          _waitingPayloads.remove(task.taskId);
          await _checkpointLogicalJob(
            transferTask,
            state: DownloadJobState.interrupted,
            expectedBytes: expectedBytes,
            userPaused: false,
            queueWaiting: false,
          );
          await FileDownloader().database.updateRecord(
            TaskRecord(transferTask, TaskStatus.paused, 0, expectedBytes),
          );
          _publishProgress(
            trackingUrl: trackingUrl ?? url,
            taskId: task.taskId,
            progress: 0,
            totalSize: expectedBytes,
            status: TaskStatus.paused,
          );
          _updatesController.add(
            TaskStatusUpdate(transferTask, TaskStatus.paused),
          );
          return DownloadCommandOutcome.recoverableFailure;
        }

        await _persistNativeWaitingSnapshot();
        unawaited(_syncSessionOverlay());
        return DownloadCommandOutcome.running;
      } catch (error) {
        _waitingPayloads.remove(task.taskId);
        _forgetSessionTask(task.taskId);
        final storage = _ref.read(storageServiceProvider);
        await storage.removeDownloadMetadata(task.taskId);
        if (refreshDescriptorGeneration != null &&
            refreshDescriptorOwnerTaskId != null) {
          await _ref
              .read(downloadUrlRefreshStoreProvider)
              .removeForOwnerGeneration(
                trackingUrl ?? url,
                refreshDescriptorOwnerTaskId,
                refreshDescriptorGeneration,
              );
        }
        // A start that never established recoverable ownership must not leave
        // an authoritative JobStore row that resurrects itself on relaunch.
        await _jobStore.remove(task.taskId);
        _ref.read(activeDownloadsProvider.notifier).remove(trackingUrl ?? url);
        _updatesController.add(TaskStatusUpdate(task, TaskStatus.canceled));
        await _syncSessionOverlay(completedSuccess: false);
        if (kDebugMode) {
          debugPrint('[DownloadService] Failed to enqueue download: $error');
        }
        return DownloadCommandOutcome.recoverableFailure;
      } finally {
        _startingTaskIds.remove(task.taskId);
      }
    });
  }

  Future<List<TaskRecord>> _completeRecordsForEpisode(
    List<TaskRecord> records, {
    required String logicalId,
    required String trackingUrl,
    required MultimediaItem item,
    Episode? episode,
    required String filename,
    required String directory,
  }) async {
    final storage = _ref.read(storageServiceProvider);
    final matches = <TaskRecord>[];
    for (final record in records) {
      if (record.status != TaskStatus.complete) continue;
      final metadata = await storage.getDownloadMetadata(record.task.taskId);
      final candidateLogicalId = logicalDownloadIdFromMetadata(metadata);
      if (candidateLogicalId != null) {
        if (candidateLogicalId == logicalId) matches.add(record);
        continue;
      }

      // Pre-logical-identity migration fallback. Only rows that genuinely lack
      // reconstructable presentation identity may use URL/path heuristics.
      final recordUrl = downloadTrackingUrl(record.task);
      var matched =
          recordUrl == trackingUrl ||
          (episode?.url.trim().isNotEmpty == true &&
              recordUrl == episode!.url.trim()) ||
          taskMatchesDownloadFile(
            task: record.task,
            filename: filename,
            directory: directory,
          );
      if (!matched && metadata != null && metadata['item'] is Map) {
        final storedTracking = (metadata['trackingUrl'] as String?)?.trim();
        matched =
            (storedTracking != null && storedTracking == trackingUrl) ||
            metadataMatchesDownload(
              item: item,
              episode: episode,
              candidateItem: MultimediaItem.fromJson(
                Map<String, dynamic>.from(metadata['item'] as Map),
              ),
              candidateEpisode: metadata['episode'] is Map
                  ? Episode.fromJson(
                      Map<String, dynamic>.from(metadata['episode'] as Map),
                    )
                  : null,
            );
      }
      if (matched) matches.add(record);
    }
    return matches;
  }

  /// Drop complete DB+Hive rows only. Never deletes the video file.
  Future<void> _dropCompleteRecords(List<TaskRecord> records) async {
    final storage = _ref.read(storageServiceProvider);
    for (final record in records) {
      await FileDownloader().database.deleteRecordWithId(record.task.taskId);
      await storage.removeDownloadMetadata(record.task.taskId);
      await _jobStore.remove(record.task.taskId);
    }
  }

  Future<void> _persistCompletedFilePath(Task task) async {
    try {
      final path = await task.filePath();
      var fileBytes = -1;
      File? completedFile;
      if (path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) {
          completedFile = file;
          fileBytes = await file.length();
        }
      }

      final record = await FileDownloader().database.recordForId(task.taskId);
      final storage = _ref.read(storageServiceProvider);
      final metadata = await storage.getDownloadMetadata(task.taskId);
      final job = await _jobStore.get(task.taskId);
      final currentFingerprint = task is DownloadTask
          ? await _probeResourceFingerprint(task.url, headers: task.headers)
          : null;

      // Never promote the observed file into its own expectation. Every value
      // here must pre-exist the final local length or come from remote evidence.
      final expectedBytes = knownDownloadSize(<int?>[
        job?.expectedBytes,
        record?.expectedFileSize,
        downloadMetadataExpectedBytes(metadata),
        _telemetry.expectedBytesFor(task.taskId),
        currentFingerprint?.expectedBytes,
      ]);

      if (task is DownloadTask) {
        var prefixMatches = false;
        if (completedFile != null && fileBytes > 0 && expectedBytes > 0) {
          final proof = await _rangeTransfers.verifyExistingPrefix(
            id: '${task.taskId}.final-proof',
            url: task.url,
            headers: task.headers,
            file: completedFile,
            written: fileBytes,
          );
          prefixMatches = proof.matches;
        }

        final verified = downloadCompletionEvidenceMatches(
          observedFileBytes: fileBytes,
          expectedResourceBytes: expectedBytes,
          prefixMatches: prefixMatches,
          persistedFingerprint: job?.fingerprint,
          currentFingerprint: currentFingerprint,
        );
        if (!verified) {
          diagnosticLog.record('completion.resourceIdentityRejected', {
            'taskId': task.taskId,
            'fileBytes': fileBytes,
            'expectedBytes': expectedBytes,
            'prefixMatches': prefixMatches,
          });
          await _checkpointLogicalJob(
            task,
            state: DownloadJobState.interrupted,
            expectedBytes: expectedBytes,
            userPaused: false,
            queueWaiting: false,
            fingerprint: currentFingerprint,
          );
          return;
        }

        final completedFingerprint = fingerprintWithExpectedBytes(
          remote: currentFingerprint ?? job?.fingerprint,
          expectedBytes: expectedBytes,
          fallbackFinalUrl: task.url,
        );
        final completedPersisted = await _checkpointLogicalJob(
          task,
          state: DownloadJobState.completed,
          durableBytes: fileBytes,
          durableByteProvenance:
              DownloadDurableByteProvenance.verifiedFinalFile,
          expectedBytes: expectedBytes,
          userPaused: false,
          queueWaiting: false,
          fingerprint: completedFingerprint,
        );
        if (!completedPersisted) {
          diagnosticLog.record('completion.persistenceBlocked', {
            'taskId': task.taskId,
          });
          return;
        }
      }

      await storage.patchDownloadMetadata(
        task.taskId,
        trackingUrl: downloadTrackingUrl(task),
        filePath: path,
        lastProgress: 1,
        lastExpectedBytes: expectedBytes,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DownloadService] persist filePath failed: $e');
      }
    }
  }

  Future<String> getDownloadPath(
    MultimediaItem? item, {
    Episode? episode,
    bool absolute = false,
  }) async {
    final dir =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    final sanitizedTitle =
        item?.title.replaceAll(RegExp(r'[^\w\s-]'), '').trim() ?? "Unknown";

    String path;
    final publicDir = await _getPublicDownloadsPath();
    // App download root: AnimeWitcher/Downloads/<title>
    final appDownloadRoot = p.join('AnimeWitcher', 'Downloads');

    if (Platform.isAndroid || Platform.isIOS) {
      path = p.join(appDownloadRoot, sanitizedTitle);
      if (absolute) {
        path = p.join(publicDir, path);
      }
    } else {
      path = p.join(dir.path, appDownloadRoot, sanitizedTitle);
    }

    // Add Season subdirectory if it's a series and we have an episode
    if (item != null &&
        episode != null &&
        item.contentType != MultimediaContentType.movie) {
      // Logic: If there's more than one season in the details, use subdirectories
      final seasonCount =
          item.episodes?.map((e) => e.season).toSet().length ?? 0;
      if (seasonCount > 1) {
        path = p.join(path, "Season ${episode.season}");
      }
    }

    return path;
  }

  Future<File?> getDownloadedFile(
    MultimediaItem item, {
    Episode? episode,
  }) async {
    final directoryPath = await getDownloadPath(
      item,
      episode: episode,
      absolute: true,
    );
    final directory = Directory(directoryPath);
    if (!await directory.exists()) return null;

    final sanitizedTitle = sanitizeDownloadFileName(
      item.title.replaceAll(RegExp(r'[^\w\s-]'), '').trim(),
    );
    final episodeData = episode;
    final useEpisodeName =
        episodeData != null &&
        usesEpisodeDownloadFileName(
          episode: episodeData.episode,
          title: episodeData.name,
          serverName: episodeData.serverName,
        );
    final String baseName;
    if (useEpisodeName) {
      baseName = sanitizeDownloadFileName(
        formatEpisodeFileName(
          episode: episodeData.episode,
          title: episodeData.name,
          isFinal: episodeData.isFinal,
          serverName: episodeData.serverName,
        ),
      );
    } else {
      baseName = sanitizedTitle;
    }

    // Prefer directory listing with normalized stems. Exact File(path) checks
    // fail when the OS stored Arabic as NFD (common on iOS) while we look up
    // NFC, even though the names look identical.
    final qualitySuffix = RegExp(r'\(\d{3,4}p\)$', caseSensitive: false);

    final extensions = ['.mp4', '.mkv', '.webm', '.avi'];
    File? qualityMatch;
    File? episodeMatch;
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final lower = name.toLowerCase();
      if (!extensions.any(lower.endsWith)) continue;
      if (await entity.length() <= 0) continue;

      final stem = sanitizeDownloadFileName(p.basenameWithoutExtension(name));
      if (stem == baseName) return entity;
      if (stem.startsWith('$baseName (') && qualitySuffix.hasMatch(stem)) {
        qualityMatch ??= entity;
        continue;
      }
      if (useEpisodeName &&
          episodeMatch == null &&
          isDownloadedEpisodeFileName(
            name,
            episodeData.episode,
            title: episodeData.name,
            serverName: episodeData.serverName,
            isFinal: episodeData.isFinal,
          )) {
        episodeMatch = entity;
      }
    }
    return qualityMatch ?? episodeMatch;
  }

  /// Resolve the on-disk file for a completed download task.
  ///
  /// Uses the task's own filename/path first so playback does not depend on
  /// reconstructing labels that may differ by Unicode form or quality suffix.
  Future<File?> getDownloadedFileForTask(
    Task task, {
    bool requireNonEmpty = true,
  }) async {
    try {
      final path = await task.filePath();
      if (path.isEmpty) return null;
      final file = File(path);
      if (!await file.exists()) return null;
      if (requireNonEmpty && await file.length() <= 0) return null;
      return file;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DownloadService] task.filePath failed: $e');
      }
    }
    return null;
  }

  /// Task path first, then reconstructed AnimeWitcher/Downloads labels.
  Future<File?> resolveDownloadedFile(
    Task task,
    MultimediaItem item, {
    Episode? episode,
  }) async {
    return resolveDownloadFileToDelete(
      fromTask: () => getDownloadedFileForTask(task, requireNonEmpty: false),
      taskFilePath: () async {
        try {
          final path = await task.filePath();
          return path.isEmpty ? null : path;
        } catch (_) {
          return null;
        }
      },
      fromLabels: () async {
        final stored = await _storedDownloadFile(task.taskId);
        if (stored != null) return stored;
        return getDownloadedFile(item, episode: episode);
      },
    );
  }

  Future<File?> _storedDownloadFile(String taskId) async {
    final metadata = await _ref
        .read(storageServiceProvider)
        .getDownloadMetadata(taskId);
    final stored = metadata?['filePath'] as String?;
    if (stored == null || stored.isEmpty) return null;
    final file = File(stored);
    if (await file.exists()) return file;
    return null;
  }

  /// Complete FileDownloader record with `metaData == trackingUrl`, even when
  /// label reconstruction misses. Used by the episode download icon.
  Future<File?> getFileForTrackingUrl(
    String trackingUrl, {
    MultimediaItem? item,
    Episode? episode,
  }) async {
    final key = trackingUrl.trim();
    if (key.isEmpty) {
      if (item == null) return null;
      return getDownloadedFile(item, episode: episode);
    }

    final records = await FileDownloader().database.allRecords();
    for (final record in records) {
      if (record.status != TaskStatus.complete) continue;
      if (downloadTrackingUrl(record.task) != key) continue;

      final fromTask = await getDownloadedFileForTask(record.task);
      if (fromTask != null) return fromTask;
      try {
        final path = await record.task.filePath();
        if (path.isNotEmpty) {
          final file = File(path);
          if (await file.exists()) return file;
        }
      } catch (_) {}
      final stored = await _storedDownloadFile(record.task.taskId);
      if (stored != null) return stored;
    }

    if (item == null) return null;
    return getDownloadedFile(item, episode: episode);
  }

  // Request user to disable battery optimizations for persistent downloads
  Future<void> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return;

    final status = await Permission.ignoreBatteryOptimizations.status;
    if (!status.isGranted) {
      if (kDebugMode) {
        debugPrint('[DownloadService] Requesting ignore battery optimizations');
      }
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  Future<bool> deleteDownloadedFile(File file) async {
    try {
      return await deleteDownloadedVideo(file);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DownloadService] Error deleting file: $e');
      }
    }
    return false;
  }

  Future<String> _getPublicDownloadsPath() async {
    if (Platform.isAndroid) {
      return "/storage/emulated/0/Download";
    }
    if (Platform.isIOS) {
      final dir = await getApplicationDocumentsDirectory();
      return dir.path;
    }
    final dir =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    return dir.path;
  }
}

class DownloadMetadata {
  final int? size;
  final String? mimeType;
  final bool supportsRanges;

  DownloadMetadata({this.size, this.mimeType, this.supportsRanges = false});

  String get sizeString {
    if (size == null) return "Unknown size";
    final double mb = size! / (1024 * 1024);
    if (mb > 1024) {
      return "${(mb / 1024).toStringAsFixed(2)} GB";
    }
    return "${mb.toStringAsFixed(2)} MB";
  }
}
