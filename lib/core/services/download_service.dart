import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:collection/collection.dart';
import 'package:permission_handler/permission_handler.dart'
    hide PermissionStatus;
import 'package:device_info_plus/device_info_plus.dart';

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

class DownloadService {
  final diagnosticLog = DownloadDiagnosticLog(
    () async => Directory(
      p.join((await getApplicationDocumentsDirectory()).path, 'log'),
    ),
  );

  Future<void> setDiagnosticLogging(bool enabled) async {
    await init();
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

  final Ref _ref;
  final Dio _dio;
  final Set<String> _cancellingUrls = {};
  final Set<String> _userPausedIds = {};
  final Set<String> _dequeuingPausedIds = {};
  final Set<String> _restackingWaiterIds = {};
  late final DownloadContinuedProcessingService _continuedProcessing;
  final _updatesController = StreamController<TaskUpdate>.broadcast();
  StreamSubscription<TaskUpdate>? _updatesSubscription;
  bool _isInitialized = false;
  bool _disposed = false;
  Future<void>? _initializing;
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
        for (final id in ids) {
          await FileDownloader().database.deleteRecordWithId(id);
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
        diagnosticLog.record('parallel.pauseDrainQueueRelease', {
          'taskId': parentTaskId,
        });
        unawaited(_serializeQueue(_syncQueueToCapUnlocked));
        unawaited(_syncSessionOverlay(completedSuccess: false));
      },
      onUpdate: (update) {
        if (!_disposed) _sharedEvents.add(update);
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
        diagnosticLog.record('parallel.hostPressure', {'count': ceiling});
        unawaited(
          _hostProfiles.recordPressure(url: url, fallbackCeiling: ceiling),
        );
      },
      onHostSample: (url, connections, bytesPerSecond) {
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
    if (_userPausedIds.contains(taskId) ||
        _terminalJobIds.contains(taskId) ||
        _cancellingUrls.contains(trackingUrl)) {
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
    if (_terminalJobIds.contains(parentTaskId)) return;
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
    _disposed = true;
    unawaited(_parallel.dispose());
    _rangeTransfers.dispose();
    _telemetry.clear();
    _expectedSizePersistedIds.clear();
    _terminalJobIds.clear();
    unawaited(_nativeTransport.dispose());
    _updatesSubscription?.cancel();
    unawaited(_continuedProcessing.dispose());
    _updatesController.close();
    // Do NOT cancel _fdSubscription — it matches FileDownloader()'s singleton
    // lifetime and cannot be re-subscribed after cancellation.
  }

  Future<void> init() => _initializing ??= _initialize().catchError((
    Object error,
    StackTrace stack,
  ) {
    _initializing = null;
    Error.throwWithStackTrace(error, stack);
  });

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

      // Restacking later HQ waiters behind a resumed episode. Swallow only
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

      // User-initiated cancels are cleaned up in [cancelDownload]; ignore their
      // follow-up events so they cannot race with pause-on-failure handling.
      if (_cancellingUrls.contains(trackingUrl)) {
        if (update is TaskStatusUpdate &&
            update.status == TaskStatus.canceled) {
          _updatesController.add(update);
        }
        return;
      }

      // Ghost cancel/fail from HQ dequeue while URLSession still owns this
      // episode: attach, do not park as paused. A real fail/system-cancel
      // parks that one file and the queue continues — never finish the
      // whole session as an error.
      if (update is TaskStatusUpdate &&
          shouldParkSystemCanceledDownload(
            status: update.status,
            userCancel: _cancellingUrls.contains(trackingUrl),
          )) {
        unawaited(_retainLiveNativeOrPause(update, trackingUrl));
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

  Future<void> _restoreAuthoritativeJobIntent() async {
    for (final job in await _jobStore.all()) {
      final paused =
          job.userPaused ||
          job.state == DownloadJobState.pausing ||
          job.state == DownloadJobState.pausedByUser;
      final terminal =
          job.state == DownloadJobState.completed ||
          job.state == DownloadJobState.canceled ||
          job.state == DownloadJobState.orphaned;
      if (paused) _userPausedIds.add(job.taskId);
      if (job.queueWaiting || job.state == DownloadJobState.queued) {
        _queueWaitingIds.add(job.taskId);
      }
      if (terminal) _terminalJobIds.add(job.taskId);
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
        fingerprint: DownloadResourceFingerprint(
          expectedBytes: expectedBytes ?? -1,
          finalUrl: task.url,
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
    final records = await FileDownloader().database.allRecords();
    diagnosticLog.record('recovery.begin', {'count': records.length});
    for (final record in records) {
      diagnosticLog.record('recovery.record', {
        'taskId': record.task.taskId,
        'status': record.status.name,
        'progress': record.progress,
      });
    }
    final nativeIds = <String>{
      for (final task in await _liveTransferTasks())
        if (isLogicalEpisodeDownloadTask(task)) task.taskId,
    };
    final storage = _ref.read(storageServiceProvider);

    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
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
          : oldJob.queueWaiting || oldJob.state == DownloadJobState.queued;
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
      final userPaused =
          isUserPausedMetadata(metadata) ||
          _userPausedIds.contains(task.taskId) ||
          oldJob?.userPaused == true ||
          oldJob?.state == DownloadJobState.pausedByUser ||
          oldJob?.state == DownloadJobState.pausing;
      final recoveryPlan = planDownloadRecoveryWithJobAuthority(
        persisted: record.status,
        queueWaiting: queueWaiting,
        userPaused: userPaused,
        stillInNativeQueue: stillNative,
        hasMetadata: metadata != null,
        authoritativeState: oldJob?.state,
        authoritativeUserPaused: oldJob?.userPaused ?? false,
        authoritativeQueueWaiting: oldJob?.queueWaiting ?? false,
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
        userPaused: userPaused,
        queueWaiting: recoveryPlan.shouldRequeue,
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
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

      if (oldJob != null &&
          recoveryPlan.action == DownloadRecoveryAction.ignore) {
        _queueWaitingIds.remove(task.taskId);
        _waitingPayloads.remove(task.taskId);
        _forgetSessionTask(task.taskId);
        continue;
      }

      if (userPaused) {
        _userPausedIds.add(task.taskId);
        _queueWaitingIds.remove(task.taskId);
        _waitingPayloads.remove(task.taskId);
        _rememberSessionTask(task.taskId);
        if (shouldNativePauseAfterUserPause(
          userPaused: true,
          stillInNativeQueue:
              stillNative || _parallel.hasLiveConnections(task.taskId),
        )) {
          try {
            await _pauseTransfer(task);
          } catch (_) {}
        }
        await FileDownloader().database.updateRecord(
          TaskRecord(
            task,
            TaskStatus.paused,
            progress,
            record.expectedFileSize,
          ),
        );
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

      final showAsWaiting = _queueWaitingIds.contains(task.taskId);
      final showAsRunning =
          !userPaused &&
          ((record.status == TaskStatus.running && stillNative) ||
              (shouldContinue && !showAsWaiting));
      _publishProgress(
        trackingUrl: trackingUrl,
        taskId: task.taskId,
        progress: progress,
        totalSize: expectedBytes,
        status: showAsWaiting
            ? TaskStatus.enqueued
            : (userPaused
                  ? TaskStatus.paused
                  : (showAsRunning
                        ? TaskStatus.running
                        : (stillNative && wasRunning
                              ? record.status
                              : TaskStatus.paused))),
      );
    }

    await _syncQueueToCapUnlocked();
    await _syncSessionOverlay();
  }

  int _occupiedSlotCount(List<TaskRecord> records) {
    final occupying = <String>{};
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final taskId = record.task.taskId;
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
    occupying.removeAll(_restackingWaiterIds);
    return occupying.length;
  }

  Future<List<DownloadQueueEntry>> _queueEntries(
    List<TaskRecord> records,
  ) async {
    final storage = _ref.read(storageServiceProvider);
    final entries = <DownloadQueueEntry>[];
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      if (record.status == TaskStatus.complete ||
          record.status == TaskStatus.canceled) {
        continue;
      }
      final metadata = await storage.getDownloadMetadata(record.task.taskId);
      final queueWaiting =
          _queueWaitingIds.contains(record.task.taskId) ||
          isQueueWaitingMetadata(metadata);
      final userPaused =
          _userPausedIds.contains(record.task.taskId) ||
          isUserPausedMetadata(metadata);
      entries.add(
        DownloadQueueEntry(
          taskId: record.task.taskId,
          status: record.status,
          timestamp: (metadata?['timestamp'] as int?) ?? 0,
          queueWaiting: queueWaiting,
          userPaused: userPaused,
        ),
      );
    }
    return entries;
  }

  Future<void> _syncQueueToCapUnlocked() async {
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
      if (_occupiedSlotCount(await FileDownloader().database.allRecords()) >=
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
    if (!_isInitialized) return;
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
    final liveProgress = _ref.read(downloadProgressProvider);
    final entries = <DownloadOverlayEntry>[];
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final trackingUrl = downloadTrackingUrl(record.task);
      final live = liveProgress[trackingUrl];
      final leftoverWaiting = _queueWaitingIds.contains(record.task.taskId);
      final liveRunning = live?.status == TaskStatus.running;
      final inSession =
          _sessionOrder.contains(record.task.taskId) ||
          occupiesDownloadSlot(
            status: record.status,
            queueWaiting: leftoverWaiting,
          ) ||
          leftoverWaiting ||
          liveRunning ||
          record.status == TaskStatus.enqueued;
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
      final displayStatus = displayDownloadStatus(
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
          episodeKey: _overlayEpisodeKeyForTask(record.task),
        ),
      );
    }
    final seen = {for (final entry in entries) entry.taskId};
    for (final payload in _waitingPayloads.entries) {
      if (seen.contains(payload.key)) continue;
      _rememberSessionTask(payload.key);
      entries.add(
        DownloadOverlayEntry(
          taskId: payload.key,
          status: TaskStatus.enqueued,
          displayName: payload.value['displayName'] as String? ?? '',
          queueWaiting: true,
          episodeKey: _overlayEpisodeKeyFromParts(
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
    final completedIds = <String>{};
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final task = record.task as DownloadTask;
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
      final leftoverWaiting = _queueWaitingIds.contains(task.taskId);
      final userPaused =
          _userPausedIds.contains(task.taskId) ||
          (record.status == TaskStatus.paused && !leftoverWaiting);
      if (userPaused) {
        paused.add(task.taskId);
        continue;
      }
      // Swift's fallback waiter starts one raw URLSession task.
      // Never pass it a ParallelDownloadTask: doing so silently turns a
      // requested four-part episode into one part. Dart/PersistentParallelDownload
      // owns multipart promotion and all child checkpoint/assembly semantics.
      if (isNativeWaitingSnapshotWaiter(
            status: record.status,
            queueWaiting: leftoverWaiting,
            userPaused: false,
          ) &&
          task is! ParallelDownloadTask) {
        waiters.add(await _waitingPayloadPreservingBytes(task));
        waiterIds.add(task.taskId);
        continue;
      }
      if (occupiesDownloadSlot(status: record.status, queueWaiting: false)) {
        transferring.add(task.taskId);
        _waitingPayloads.remove(task.taskId);
      }
    }
    for (final id in _userPausedIds) {
      if (!paused.contains(id) && !completedIds.contains(id)) {
        paused.add(id);
        transferring.remove(id);
      }
    }
    for (final entry in _waitingPayloads.entries) {
      if (waiterIds.contains(entry.key) ||
          paused.contains(entry.key) ||
          transferring.contains(entry.key) ||
          completedIds.contains(entry.key)) {
        continue;
      }
      final record = records.firstWhereOrNull(
        (record) => record.task.taskId == entry.key,
      );
      if (record?.task is ParallelDownloadTask ||
          _rangeTransfers.isActive(entry.key))
        continue;
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
      queueWaitingTaskIds: _queueWaitingIds.toList(),
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
      if (_occupiedSlotCount(await FileDownloader().database.allRecords()) >=
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
    diagnosticLog.record('command.cancel', {'taskId': taskId});
    // Persist terminal intent before stopping any writer. The durable row is
    // removed only after native/plugin cleanup below has returned; DM-07 will
    // further extend this into a cleanup-acknowledged tombstone protocol.
    final existingJob = await _jobStore.get(taskId);
    final parentRecord = await FileDownloader().database.recordForId(taskId);
    DownloadTask? cancelTask = parentRecord?.task is DownloadTask
        ? parentRecord!.task as DownloadTask
        : await _liveNativeTaskFor(taskId: taskId, trackingUrl: trackingUrl);
    if (existingJob != null &&
        existingJob.state != DownloadJobState.completed) {
      if (cancelTask != null) {
        final cancelPersisted = await _checkpointLogicalJob(
          cancelTask,
          state: DownloadJobState.canceled,
          userPaused: false,
          queueWaiting: false,
        );
        if (!cancelPersisted) {
          throw StateError('Failed to persist cancel intent for $taskId');
        }
      } else {
        final cancelPersisted = await _jobStore.checkpoint(
          taskId: existingJob.taskId,
          trackingUrl: existingJob.trackingUrl,
          state: DownloadJobState.canceled,
          durableBytes: existingJob.durableBytes,
          durableByteProvenance: existingJob.durableByteProvenance,
          expectedBytes: existingJob.expectedBytes,
          userPaused: false,
          queueWaiting: false,
          fingerprint: existingJob.fingerprint,
        );
        if (!cancelPersisted) {
          throw StateError('Failed to persist cancel intent for $taskId');
        }
        _terminalJobIds.add(taskId);
      }
    }

    // Project the tombstone only after durable cancel intent is secured.
    _cancellingUrls.add(trackingUrl);
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
    try {
      await _serializeQueue(() async {
        _queueWaitingIds.remove(taskId);
        _waitingPayloads.remove(taskId);
        _forgetSessionTask(taskId);
        final ids = <String>{taskId};
        for (final task in await FileDownloader().allTasks(allGroups: true)) {
          if (task.taskId == taskId ||
              downloadTrackingUrl(task) == trackingUrl) {
            ids.add(task.taskId);
          }
        }
        if (parentRecord?.task is ParallelDownloadTask) {
          await _parallel.cancel(parentRecord!.task as ParallelDownloadTask);
        } else if (parentRecord?.task is DownloadTask &&
            isNativeSingleDownloadTask(parentRecord!.task)) {
          await _nativeTransport.cancel(parentRecord.task as DownloadTask);
          ids.remove(taskId);
        }
        if (ids.isNotEmpty) {
          await FileDownloader().cancelTasksWithIds(ids.toList());
        }
        _nativeTransport.forget(taskId);
        _userPausedIds.remove(taskId);
        _dequeuingPausedIds.remove(taskId);
        _ref.read(activeDownloadsProvider.notifier).remove(trackingUrl);
        _ref.read(downloadProgressProvider.notifier).remove(trackingUrl);
        // Proactive cleanup
        await FileDownloader().database.deleteRecordWithId(taskId);
        await _ref.read(storageServiceProvider).removeDownloadMetadata(taskId);
        await _jobStore.remove(taskId);
        await _ref.read(downloadUrlRefreshStoreProvider).remove(trackingUrl);
        await _syncQueueToCapUnlocked();
        if (notifyContinuedProcessing) {
          await _syncSessionOverlay(completedSuccess: false);
        }
      });
    } finally {
      // Small delay to let final updates clear
      Future.delayed(const Duration(milliseconds: 500), () {
        _cancellingUrls.remove(trackingUrl);
      });
    }
  }

  Future<void> pauseDownload(String taskId) async {
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
          _userPausedIds.remove(taskId);
          await _ref
              .read(storageServiceProvider)
              .patchDownloadMetadata(
                taskId,
                queueWaiting: false,
                userPaused: false,
                lastProgress: progress,
                lastExpectedBytes: totalSize,
              );
          await _checkpointLogicalJob(
            downloadTask,
            state: DownloadJobState.running,
            expectedBytes: totalSize,
            userPaused: false,
            queueWaiting: false,
          );
          _publishProgress(
            trackingUrl: trackingUrl,
            taskId: taskId,
            progress: progress,
            totalSize: totalSize,
            status: TaskStatus.running,
            networkSpeed: current?.networkSpeed ?? 0,
            timeRemaining: current?.timeRemaining ?? Duration.zero,
          );
          _updatesController.add(
            TaskStatusUpdate(downloadTask, TaskStatus.running),
          );
          await _syncSessionOverlay(completedSuccess: false);
          await _persistNativeWaitingSnapshot();
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
        await _checkpointLogicalJob(
          downloadTask,
          state: DownloadJobState.pausedByUser,
          expectedBytes: totalSize,
          userPaused: true,
          queueWaiting: false,
        );
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

    await _cancelNativeWaitersForRestackUnlocked(plan.waitersToRestack);

    final reservedEarlier = <String>{};
    try {
      for (final earlierId in plan.earlierWaiterIds) {
        if (_occupiedSlotCount(await FileDownloader().database.allRecords()) >=
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
      final occupiedAfterEarlier = _occupiedSlotCount(latestRecords);
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

      for (final waiterId in plan.waitersToRestack) {
        final record = byId[waiterId];
        if (record == null || record.task is! DownloadTask) continue;
        await _enqueueExistingTaskAsWaiterUnlocked(record.task as DownloadTask);
      }
    } finally {
      _startingTaskIds.removeAll(reservedEarlier);
    }

    Future<void>.delayed(const Duration(milliseconds: 800), () {
      _restackingWaiterIds.removeAll(plan.waitersToRestack);
    });

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

  Future<void> _cancelNativeWaitersForRestackUnlocked(List<String> ids) async {
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

  Future<bool> _resumeDownloadTask(DownloadTask task) async {
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

    final saved = await _savedProgressFor(task);
    final refreshResult = await _refreshTaskBeforeResume(
      task,
      expectedBytes: saved.totalSize,
      partialBytes: saved.partialBytes,
    );
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
      if (saved.progress > 0 || saved.partialBytes > 0) return false;
      return _enqueueTransfer(task, saved.totalSize);
    }

    // A refreshed signed URL cannot use native resume data that embeds the
    // expired URL. When a verified partial file exists, go directly to the
    // prefix-validated Range append path.
    if (refreshResult.refreshed && saved.partialBytes > 0) {
      return _resumeUsingPartialFile(task);
    }

    return resumeOrRestartDownload(
      canResume: () async {
        try {
          return await FileDownloader()
              .taskCanResume(task)
              .timeout(const Duration(seconds: 3));
        } catch (_) {
          return false;
        }
      },
      resume: () => _nativeTransport.resume(task),
      resumeFromPartial: () => _resumeUsingPartialFile(task),
      restart: () =>
          _enqueueFreshAdaptiveTask(task, knownTotalBytes: saved.totalSize),
      savedProgress: saved.progress,
      existingPartialBytes: saved.partialBytes,
      expectedBytes: saved.totalSize,
    );
  }

  Future<bool> _resumeUsingPartialFile(DownloadTask task) async {
    if (task is ParallelDownloadTask) return false;
    String destinationPath;
    try {
      destinationPath = await task.filePath();
    } catch (_) {
      return false;
    }
    if (destinationPath.isEmpty) return false;

    final partial = await canonicalizePartialDownloadFile(
      destinationPath: destinationPath,
    );
    if (partial == null) return false;
    final existingBytes = partial.bytes;
    final expectedBytes = (await _savedProgressFor(task)).totalSize;
    if (expectedBytes > 0 && existingBytes == expectedBytes) {
      await FileDownloader().database.updateRecord(
        TaskRecord(task, TaskStatus.complete, 1, expectedBytes),
      );
      _sharedEvents.add(TaskProgressUpdate(task, 1, expectedBytes));
      _sharedEvents.add(TaskStatusUpdate(task, TaskStatus.complete));
      return true;
    }
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
          if (_cancellingUrls.contains(trackingUrl)) return;

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
              failure.action == DownloadFailureAction.refreshUrl) {
            _scheduleParallelParentRefresh(parallelParent.taskId);
          }
          return;
        }
        final activeToken = token;
        if (!await _jobStore.accepts(activeToken)) return;
        if (failure.action == DownloadFailureAction.refreshUrl) {
          // DownloadRangeTransfer removes its ownership immediately after this
          // callback returns. Queue the retry on the next event turn so the
          // same taskId can start a new fenced generation safely.
          Future<void>.delayed(Duration.zero, () async {
            if (_disposed ||
                _userPausedIds.contains(task.taskId) ||
                _cancellingUrls.contains(downloadTrackingUrl(task))) {
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
          await _jobStore.updateForAttempt(
            activeToken,
            state: DownloadJobState.completed,
            durableBytes: failure.resourceSize,
            durableByteProvenance: DownloadDurableByteProvenance.rangeFlushed,
            expectedBytes: failure.resourceSize,
          );
          await FileDownloader().database.updateRecord(
            TaskRecord(task, TaskStatus.complete, 1, failure.resourceSize),
          );
          _sharedEvents.add(TaskProgressUpdate(task, 1, failure.resourceSize));
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
        fingerprint: DownloadResourceFingerprint(
          expectedBytes: expectedBytes,
          finalUrl: task.url,
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

  Future<({DownloadTask task, bool refreshed})> _refreshTaskBeforeResume(
    DownloadTask task, {
    required int expectedBytes,
    required int partialBytes,
  }) async {
    diagnosticLog.record('source.check', {
      'taskId': task.taskId,
      'bytes': partialBytes,
      'total': expectedBytes,
    });
    // Native single-file resume data may be the only durable representation of
    // its bytes. Do not replace that URL unless a visible partial prefix exists.
    // Multipart manifests own their own durable child files, so they are safe.
    if (task is! ParallelDownloadTask && partialBytes <= 0) {
      return (task: task, refreshed: false);
    }

    final trackingUrl = downloadTrackingUrl(task);
    final store = _ref.read(downloadUrlRefreshStoreProvider);
    final descriptor = await store.get(trackingUrl);
    if (descriptor == null) return (task: task, refreshed: false);

    // Keep a still-valid URL. This avoids provider extraction work on every
    // short pause/resume while still detecting expired signed links.
    final current = await getMetadata(task.url, headers: task.headers);
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
        currentRangeOk) {
      return (task: task, refreshed: false);
    }

    final refreshed = await _ref
        .read(downloadUrlRefresherProvider)
        .refresh(descriptor, currentUrl: task.url);
    diagnosticLog.record('source.refresh', {
      'taskId': task.taskId,
      'result': refreshed != null,
    });
    if (refreshed == null) return (task: task, refreshed: false);
    final metadata = await getMetadata(
      refreshed.url,
      headers: refreshed.headers,
    );
    if (metadata?.size == null ||
        (expectedBytes > 0 && metadata!.size != expectedBytes) ||
        ((task is ParallelDownloadTask || partialBytes > 0) &&
            metadata?.supportsRanges != true)) {
      return (task: task, refreshed: false);
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
    );
    if (!refreshCheckpointed) {
      throw StateError(
        'Failed to persist source refresh boundary for ${task.taskId}',
      );
    }

    if (task is ParallelDownloadTask) {
      final replaced = await _parallel.replaceSource(
        task,
        url: refreshed.url,
        headers: refreshed.headers,
      );
      return replaced == null
          ? (task: task, refreshed: false)
          : (task: replaced, refreshed: true);
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
    return (task: updated, refreshed: true);
  }

  Future<List<Task>> _liveTransferTasks() =>
      FileDownloader().allTasks(allGroups: true);

  Future<DownloadRuntimeOwnership> _runtimeOwnershipFor(String taskId) async {
    if (_rangeTransfers.isActive(taskId)) {
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

      if (isInternalDownloaderChunk(task)) {
        // Verify the child really left the live native set. If the first pause
        // raced URLSession hand-off, retry the same identity once; never cancel.
        var ownership = await _runtimeOwnershipFor(task.taskId);
        if (ownership == DownloadRuntimeOwnership.owned) {
          if (!await FileDownloader().pause(task)) return false;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          ownership = await _runtimeOwnershipFor(task.taskId);
        }
        if (ownership != DownloadRuntimeOwnership.notOwned) return false;
      }
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
    if (task is! ParallelDownloadTask) return _nativeTransport.start(task);
    if (totalBytes <= 0) {
      totalBytes =
          (await getMetadata(task.url, headers: task.headers))?.size ?? -1;
    }
    return _parallel.start(task, totalBytes);
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

  Future<bool> startDownload({
    required String url,
    required String filename,
    required String directory, // Relative for mobile/mac, absolute for others
    required MultimediaItem item,
    Episode? episode,
    String? trackingUrl,
    Map<String, String>? headers,
    int totalBytes = -1,
  }) async {
    diagnosticLog.record('command.start', {'total': totalBytes});
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
      // Prevention: Check if task is ALREADY running (using database for robustness)
      final records = await FileDownloader().database.allRecords();
      final existingRecord = records.firstWhereOrNull(
        (r) =>
            (isLogicalEpisodeDownloadTask(r.task)) &&
            (r.status == TaskStatus.failed ||
                r.status == TaskStatus.notFound ||
                r.status == TaskStatus.enqueued ||
                r.status == TaskStatus.running ||
                r.status == TaskStatus.paused ||
                r.status == TaskStatus.waitingToRetry) &&
            (r.task.metaData.isNotEmpty ? r.task.metaData : r.task.url) ==
                (trackingUrl ?? url),
      );

      if (existingRecord != null) {
        if (kDebugMode) {
          debugPrint(
            '[DownloadService] Task already exists in database with status: ${existingRecord.status}',
          );
        }

        final occupying = occupiesDownloadSlot(
          status: existingRecord.status,
          queueWaiting: _queueWaitingIds.contains(existingRecord.task.taskId),
        );
        if (occupying &&
            (_parallel.isActive(existingRecord.task.taskId) ||
                _rangeTransfers.isActive(existingRecord.task.taskId) ||
                await _liveNativeTaskFor(taskId: existingRecord.task.taskId) !=
                    null)) {
          _ref.read(activeDownloadsProvider.notifier).add(trackingUrl ?? url);
          return true;
        }

        if (existingRecord.task is! DownloadTask) {
          return false;
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
          return true;
        }
        await _resumeUserPausedUnlocked(existingTask.taskId);
        return true;
      }

      final tracking = trackingUrl ?? url;
      final completeRecords = await _completeRecordsForEpisode(
        records,
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
          return true;
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
        transferHints: animeDownloadTransferHints(expectedBytes: totalBytes),
        stallTimeout: const Duration(seconds: 45),
      );

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
        final occupied = _occupiedSlotCount(
          await FileDownloader().database.allRecords(),
        );
        final startNow = occupied < maxConcurrent;
        final expectedBytes = totalBytes > 0 ? totalBytes : -1;
        // Freeze the chosen transfer shape before queueing. This preserves a
        // manual/Auto multipart choice for episode 2+ instead of converting
        // only the first episode and leaving later FIFO rows single-part.
        final transferTask = await _adaptiveTaskForFreshStart(
          task,
          knownTotalBytes: expectedBytes,
        );
        final jobPersisted = await _jobStore.put(
          DownloadJobRecord(
            taskId: transferTask.taskId,
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
            fingerprint: DownloadResourceFingerprint(
              expectedBytes: expectedBytes,
              finalUrl: url,
            ),
          ),
        );
        if (!jobPersisted) {
          throw StateError('Failed to persist fresh download intent');
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
          return true;
        }

        _startingTaskIds.add(transferTask.taskId);
        _updatesController.add(
          TaskStatusUpdate(transferTask, TaskStatus.enqueued),
        );
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
          return false;
        }

        await _persistNativeWaitingSnapshot();
        unawaited(_syncSessionOverlay());
        return true;
      } catch (error) {
        _waitingPayloads.remove(task.taskId);
        _forgetSessionTask(task.taskId);
        final storage = _ref.read(storageServiceProvider);
        await storage.removeDownloadMetadata(task.taskId);
        // A start that never established recoverable ownership must not leave
        // an authoritative JobStore row that resurrects itself on relaunch.
        await _jobStore.remove(task.taskId);
        _ref.read(activeDownloadsProvider.notifier).remove(trackingUrl ?? url);
        _updatesController.add(TaskStatusUpdate(task, TaskStatus.canceled));
        await _syncSessionOverlay(completedSuccess: false);
        if (kDebugMode) {
          debugPrint('[DownloadService] Failed to enqueue download: $error');
        }
        return false;
      } finally {
        _startingTaskIds.remove(task.taskId);
      }
    });
  }

  Future<List<TaskRecord>> _completeRecordsForEpisode(
    List<TaskRecord> records, {
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
      if (!matched) {
        final metadata = await storage.getDownloadMetadata(record.task.taskId);
        if (metadata != null) {
          final storedTracking = (metadata['trackingUrl'] as String?)?.trim();
          matched =
              (storedTracking != null && storedTracking == trackingUrl) ||
              metadataMatchesDownload(
                item: item,
                episode: episode,
                candidateItem: MultimediaItem.fromJson(
                  Map<String, dynamic>.from(metadata['item'] as Map),
                ),
                candidateEpisode: metadata['episode'] != null
                    ? Episode.fromJson(
                        Map<String, dynamic>.from(metadata['episode'] as Map),
                      )
                    : null,
              );
        }
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
      if (path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) fileBytes = await file.length();
      }
      final record = await FileDownloader().database.recordForId(task.taskId);
      final expectedBytes = knownDownloadSize(<int?>[
        fileBytes,
        record?.expectedFileSize,
        _telemetry.expectedBytesFor(task.taskId),
      ]);
      if (task is DownloadTask) {
        final completedPersisted = await _checkpointLogicalJob(
          task,
          state: DownloadJobState.completed,
          durableBytes: fileBytes > 0 ? fileBytes : null,
          durableByteProvenance: fileBytes > 0
              ? DownloadDurableByteProvenance.verifiedFinalFile
              : null,
          expectedBytes: expectedBytes,
          userPaused: false,
          queueWaiting: false,
        );
        if (!completedPersisted) {
          diagnosticLog.record('completion.persistenceBlocked', {
            'taskId': task.taskId,
          });
          return;
        }
      }
      await _ref
          .read(storageServiceProvider)
          .patchDownloadMetadata(
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
