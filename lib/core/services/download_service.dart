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
import '../network/dio_client_provider.dart';
import '../utils/download_resume.dart';
import '../utils/download_cleanup.dart';
import '../utils/episode_label.dart';
import 'download_concurrency.dart';
import 'download_continued_processing_service.dart';

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
      return '${(networkSpeed * 1024).toStringAsFixed(2)} KB/s';
    }
    return '${networkSpeed.toStringAsFixed(2)} MB/s';
  }
}

@Riverpod(keepAlive: true)
class DownloadProgressNotifier extends _$DownloadProgressNotifier {
  @override
  Map<String, DownloadProgressData> build() => {};

  void update(String url, DownloadProgressData data) {
    state = {...state, url: data};
  }

  void remove(String url) {
    state = {...state}..remove(url);
  }
}

@Riverpod(keepAlive: true)
class ActiveDownloadsNotifier extends _$ActiveDownloadsNotifier {
  @override
  Set<String> build() => {};

  void add(String url) => state = {...state, url};
  void remove(String url) => state = {...state}..remove(url);
}

class DownloadService {
  // FileDownloader().updates is a single-subscription stream that rejects
  // re-subscription even after cancel. Subscribe once as a static bridge so
  // each DownloadService instance can listen via the broadcast proxy instead.
  static StreamSubscription<TaskUpdate>? _fdSubscription;
  static final _sharedEvents = StreamController<TaskUpdate>.broadcast();

  final Ref _ref;
  final Dio _dio;
  final Set<String> _cancellingUrls = {};
  late final DownloadContinuedProcessingService _continuedProcessing;
  final _updatesController = StreamController<TaskUpdate>.broadcast();
  StreamSubscription<TaskUpdate>? _updatesSubscription;
  bool _isInitialized = false;
  Future<void> _queueChain = Future<void>.value();
  final Set<String> _queueWaitingIds = {};
  final Set<String> _startingTaskIds = {};
  final Set<String> _liveActivityTaskIds = {};
  final Map<String, Map<String, Object>> _waitingPayloads = {};

  DownloadService(this._ref) : _dio = _ref.read(dioClientProvider) {
    _continuedProcessing = DownloadContinuedProcessingService(
      onSystemCancel: _cancelFromSystemUI,
    );
  }

  Stream<TaskUpdate> get updates => _updatesController.stream;

  void dispose() {
    _updatesSubscription?.cancel();
    unawaited(_continuedProcessing.dispose());
    _updatesController.close();
    // Do NOT cancel _fdSubscription — it matches FileDownloader()'s singleton
    // lifetime and cannot be re-subscribed after cancellation.
  }

  Future<void> init() async {
    if (_isInitialized) {
      if (kDebugMode) debugPrint('[DownloadService] Already initialized.');
      return;
    }
    // 1. Configure the downloader (chainable API)
    final concurrency = _ref
        .read(storageServiceProvider)
        .getDownloadConcurrency();
    await FileDownloader()
        .configure(
          globalConfig: [
            (Config.requestTimeout, const Duration(seconds: 100)),
            ...downloadHoldingQueueGlobalConfig(concurrency),
          ],
          androidConfig: [(Config.runInForeground, Config.always)],
          iOSConfig: [(Config.excludeFromCloudBackup, Config.always)],
        )
        .then((result) => debugPrint('Configuration result = $result'));

    // 2. Register callbacks and configure notifications
    final notificationConfig = TaskNotification(
      '{displayName}',
      Platform.isIOS
          ? 'جارٍ التنزيل...'
          : '{progress} • {networkSpeed} • {timeRemaining}',
    );

    FileDownloader()
        .registerCallbacks(
          taskNotificationTapCallback: _myNotificationTapCallback,
        )
        .configureNotification(
          running: notificationConfig,
          complete: const TaskNotification('{displayName}', 'اكتمل التنزيل'),
          error: const TaskNotification('{displayName}', 'فشل التنزيل'),
          paused: const TaskNotification(
            '{displayName}',
            'التنزيل متوقف مؤقتاً',
          ),
          progressBar: !Platform.isIOS,
        )
        .configureNotificationForGroup(
          'downloads',
          running: notificationConfig,
          complete: const TaskNotification('{displayName}', 'اكتمل التنزيل'),
          error: const TaskNotification('{displayName}', 'فشل التنزيل'),
          paused: const TaskNotification(
            '{displayName}',
            'التنزيل متوقف مؤقتاً',
          ),
          progressBar: !Platform.isIOS,
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
      final trackingUrl = update.task.metaData.isNotEmpty
          ? update.task.metaData
          : update.task.url;

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
      // episode: attach, do not park as paused.
      if (update is TaskStatusUpdate &&
          (update.status == TaskStatus.failed ||
              update.status == TaskStatus.canceled)) {
        unawaited(_retainLiveNativeOrPause(update, trackingUrl));
        return;
      }

      _updatesController.add(update);

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

          // Bytes on the wire mean native is transferring. Never keep the row
          // frozen at في الانتظار while Speed: 1.9MB/s (Rivera case 1).
          if (progressMeansNativeTransfer(update.progress)) {
            _queueWaitingIds.remove(update.task.taskId);
          } else if (_queueWaitingIds.contains(update.task.taskId) ||
              current?.status == TaskStatus.enqueued) {
            return;
          }

          final progressData = DownloadProgressData(
            taskId: update.task.taskId,
            progress: update.progress,
            networkSpeed: update.networkSpeed,
            timeRemaining: update.timeRemaining,
            totalSize: update.expectedFileSize > 0
                ? update.expectedFileSize
                : (current?.totalSize ?? -1),
            status: TaskStatus.running,
          );

          if (update.progress < 1.0) {
            _ref.read(activeDownloadsProvider.notifier).add(trackingUrl);
          } else {
            _ref.read(activeDownloadsProvider.notifier).remove(trackingUrl);
          }

          _ref
              .read(downloadProgressProvider.notifier)
              .update(trackingUrl, progressData);

          if (_liveActivityTaskIds.contains(update.task.taskId)) {
            unawaited(
              _continuedProcessing.update(
                taskId: update.task.taskId,
                progress: progressData.progress,
                totalBytes: progressData.totalSize,
              ),
            );
          } else if (progressMeansNativeTransfer(progressData.progress)) {
            unawaited(
              _ensureLiveActivity(
                update.task,
                progress: progressData.progress,
                totalBytes: progressData.totalSize,
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
          if (current != null) {
            _ref
                .read(downloadProgressProvider.notifier)
                .update(
                  trackingUrl,
                  DownloadProgressData(
                    taskId: current.taskId,
                    progress: current.progress.clamp(0.0, 1.0),
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
              _liveActivityTaskIds.remove(update.task.taskId);
              _queueWaitingIds.remove(update.task.taskId);
              unawaited(
                _continuedProcessing.finish(
                  taskId: update.task.taskId,
                  success: true,
                  status: 'completed',
                ),
              );
              unawaited(_persistCompletedFilePath(update.task));
              unawaited(_persistNativeWaitingSnapshot());
            case TaskStatus.paused:
              unawaited(_stopLiveActivity(update.task.taskId));
            case TaskStatus.running:
              _queueWaitingIds.remove(update.task.taskId);
              unawaited(
                _ensureLiveActivity(
                  update.task,
                  progress: current?.progress ?? 0,
                  totalBytes: current?.totalSize ?? -1,
                ),
              );
            case TaskStatus.enqueued:
              // Waiting rows stay في الانتظار. Never create or keep a Live
              // Activity / "Downloading 0%" system task.
              if (update.task is DownloadTask) {
                _waitingPayloads[update.task.taskId] = _waitingPayloadFor(
                  update.task as DownloadTask,
                );
              }
              unawaited(_stopLiveActivity(update.task.taskId));
              unawaited(_persistNativeWaitingSnapshot());
            case TaskStatus.failed:
            case TaskStatus.canceled:
            case TaskStatus.notFound:
              unawaited(_stopLiveActivity(update.task.taskId));
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
    await FileDownloader().start(doRescheduleKilledTasks: false);

    // 6. Restore UI rows and continue any download that was running when
    //    the process died, keeping already-written bytes.
    await _recoverPersistedDownloads();

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

  Future<T> _serializeQueue<T>(Future<T> Function() action) {
    final done = Completer<void>();
    final previous = _queueChain;
    _queueChain = previous.catchError((_) {}).whenComplete(() => done.future);
    return previous.catchError((_) {}).then((_) async {
      try {
        return await action();
      } finally {
        if (!done.isCompleted) done.complete();
      }
    });
  }

  Future<void> _recoverPersistedDownloads() async {
    final records = await FileDownloader().database.allRecords();
    final nativeIds = <String>{
      for (final task in await FileDownloader().allTasks(allGroups: true))
        task.taskId,
    };
    final storage = _ref.read(storageServiceProvider);

    for (final record in records) {
      if (record.task is! DownloadTask) continue;
      if (record.status == TaskStatus.complete ||
          record.status == TaskStatus.canceled) {
        continue;
      }
      final task = record.task as DownloadTask;
      final trackingUrl = downloadTrackingUrl(task);
      final metadata = await storage.getDownloadMetadata(task.taskId);
      final queueWaiting = isQueueWaitingMetadata(metadata);
      if (queueWaiting) {
        _queueWaitingIds.add(task.taskId);
        _waitingPayloads[task.taskId] = _waitingPayloadFor(task);
      }

      final isFailed =
          record.status == TaskStatus.failed ||
          record.status == TaskStatus.notFound;
      var progress = record.progress;
      if (progress < 0 || progress > 1) progress = 0.0;

      final wasRunning =
          record.status == TaskStatus.running ||
          record.status == TaskStatus.enqueued ||
          record.status == TaskStatus.waitingToRetry;
      final stillNative = nativeIds.contains(task.taskId);
      final userPaused =
          record.status == TaskStatus.paused && !isFailed && !queueWaiting;

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

      final shouldReenqueue = shouldReenqueueWaitingAfterProcessKill(
        persisted: record.status,
        queueWaiting: queueWaiting,
        userPaused: userPaused,
        stillInNativeQueue: stillNative,
      );
      if (shouldReenqueue) {
        _queueWaitingIds.add(task.taskId);
        _waitingPayloads[task.taskId] = _waitingPayloadFor(task);
        await storage.patchDownloadMetadata(task.taskId, queueWaiting: true);
      }

      final shouldContinue = shouldAutoResumeInterruptedDownload(
        wasRunningOrFailed: wasRunning || isFailed,
        userPaused: userPaused,
        stillInNativeQueue: stillNative,
        queueWaiting: queueWaiting || shouldReenqueue,
      );
      if (shouldContinue) {
        unawaited(_resumeDownloadTask(task));
      }

      final showAsWaiting = _queueWaitingIds.contains(task.taskId);
      final showAsRunning =
          (record.status == TaskStatus.running && stillNative) ||
          (shouldContinue && !showAsWaiting);
      _publishProgress(
        trackingUrl: trackingUrl,
        taskId: task.taskId,
        progress: progress,
        totalSize: record.expectedFileSize,
        status: showAsWaiting
            ? TaskStatus.enqueued
            : (showAsRunning
                  ? TaskStatus.running
                  : (stillNative && wasRunning
                        ? record.status
                        : TaskStatus.paused)),
      );
    }

    await _syncQueueToCapUnlocked();
    await _attachLiveActivitiesToRunningTasks();
    await _persistNativeWaitingSnapshot();
  }

  int _occupiedSlotCount(List<TaskRecord> records) {
    final occupying = <String>{};
    for (final record in records) {
      if (occupiesDownloadSlot(
        status: record.status,
        queueWaiting: _queueWaitingIds.contains(record.task.taskId),
      )) {
        occupying.add(record.task.taskId);
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
      if (record.task is! DownloadTask) continue;
      if (record.status == TaskStatus.complete ||
          record.status == TaskStatus.canceled) {
        continue;
      }
      final metadata = await storage.getDownloadMetadata(record.task.taskId);
      final queueWaiting =
          _queueWaitingIds.contains(record.task.taskId) ||
          isQueueWaitingMetadata(metadata);
      entries.add(
        DownloadQueueEntry(
          taskId: record.task.taskId,
          status: record.status,
          timestamp: (metadata?['timestamp'] as int?) ?? 0,
          queueWaiting: queueWaiting,
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
    );

    // Always promote leftover parked waiters while the isolate is alive.
    // Native HoldingQueue already owns OS-enqueued waiters — do not enqueue
    // a second copy of the same episode.
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

  /// Attach Live Activities to running transfers. Never park a live
  /// URLSession task. Promote leftover parked waiters only if native does
  /// not already own that episode.
  Future<void> onAppForegrounded() async {
    if (!_isInitialized) return;
    await _serializeQueue(() async {
      await _attachUiToLiveNativeTasks();
      await _syncQueueToCapUnlocked();
    });
    await _attachLiveActivitiesToRunningTasks();
  }

  Future<void> _attachLiveActivitiesToRunningTasks() async {
    final records = await FileDownloader().database.allRecords();
    for (final record in records) {
      if (record.task is! DownloadTask) continue;
      if (record.status != TaskStatus.running) continue;
      if (_queueWaitingIds.contains(record.task.taskId)) continue;
      await _ensureLiveActivity(
        record.task,
        progress: record.progress,
        totalBytes: record.expectedFileSize,
      );
    }
  }

  Future<void> _ensureLiveActivity(
    Task task, {
    required double progress,
    required int totalBytes,
  }) async {
    if (!shouldStartDownloadLiveActivity(TaskStatus.running)) return;
    if (_queueWaitingIds.contains(task.taskId)) {
      if (!progressMeansNativeTransfer(progress)) return;
      _queueWaitingIds.remove(task.taskId);
    }
    var storedProgress = progress;
    if (storedProgress < 0 || storedProgress > 1) storedProgress = 0.0;
    await _continuedProcessing.start(
      taskId: task.taskId,
      displayName: task.displayName,
      progress: storedProgress,
      totalBytes: totalBytes,
    );
    _liveActivityTaskIds.add(task.taskId);
  }

  Future<void> _stopLiveActivity(String taskId) async {
    _liveActivityTaskIds.remove(taskId);
    await _continuedProcessing.stop(taskId: taskId);
  }

  Future<void> _persistNativeWaitingSnapshot() async {
    final max = clampDownloadConcurrency(
      _ref.read(storageServiceProvider).getDownloadConcurrency(),
    );
    final records = await FileDownloader().database.allRecords();
    final waiters = <Map<String, Object>>[];
    final transferring = <String>[];
    final paused = <String>[];
    final waiterIds = <String>{};
    for (final record in records) {
      if (record.task is! DownloadTask) continue;
      final task = record.task as DownloadTask;
      final leftoverWaiting = _queueWaitingIds.contains(task.taskId);
      final userPaused = record.status == TaskStatus.paused && !leftoverWaiting;
      if (isNativeWaitingSnapshotWaiter(
        status: record.status,
        queueWaiting: leftoverWaiting,
        userPaused: userPaused,
      )) {
        waiters.add(_waitingPayloads[task.taskId] ?? _waitingPayloadFor(task));
        waiterIds.add(task.taskId);
        continue;
      }
      if (userPaused) {
        paused.add(task.taskId);
        continue;
      }
      if (occupiesDownloadSlot(status: record.status, queueWaiting: false)) {
        transferring.add(task.taskId);
      }
    }
    for (final entry in _waitingPayloads.entries) {
      if (waiterIds.contains(entry.key) ||
          paused.contains(entry.key) ||
          transferring.contains(entry.key)) {
        continue;
      }
      waiters.add(entry.value);
    }
    await _continuedProcessing.persistNativeQueue(
      maxConcurrent: max,
      waiters: waiters,
      transferringTaskIds: transferring,
      pausedTaskIds: paused,
    );
  }

  String? _notificationConfigJson(DownloadTask task) {
    try {
      // ignore: invalid_use_of_visible_for_testing_member
      final config = FileDownloader().downloaderForTesting
          .notificationConfigForTask(task);
      if (config == null) return null;
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

  Future<List<LiveNativeDownload>> _liveNativeDownloads() async {
    final live = <LiveNativeDownload>[];
    for (final task in await FileDownloader().allTasks(allGroups: true)) {
      if (task is! DownloadTask) continue;
      live.add(
        LiveNativeDownload(
          taskId: task.taskId,
          trackingUrl: downloadTrackingUrl(task),
        ),
      );
    }
    return live;
  }

  Future<DownloadTask?> _liveNativeTaskFor({
    required String taskId,
    String? trackingUrl,
  }) async {
    final byId = await FileDownloader().taskForId(taskId);
    if (byId is DownloadTask) return byId;
    final track = trackingUrl ?? '';
    for (final task in await FileDownloader().allTasks(allGroups: true)) {
      if (task is! DownloadTask) continue;
      if (task.taskId == taskId) return task;
      if (track.isNotEmpty && downloadTrackingUrl(task) == track) {
        return task;
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
    var progress = record?.progress ?? 0.0;
    if (progress < 0 || progress > 1) progress = 0.0;
    final totalSize = record?.expectedFileSize ?? -1;
    final transferring =
        record?.status == TaskStatus.running ||
        record?.status == TaskStatus.waitingToRetry ||
        progressMeansNativeTransfer(progress);
    final status = transferring
        ? TaskStatus.running
        : (record?.status ?? TaskStatus.enqueued);
    _publishProgress(
      trackingUrl: trackingUrl,
      taskId: attached.taskId,
      progress: progress,
      totalSize: totalSize,
      status: displayDownloadStatus(persisted: status, queueWaiting: false),
    );
    if (transferring) {
      await _ensureLiveActivity(
        attached,
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
    for (final task in await FileDownloader().allTasks(allGroups: true)) {
      if (task is! DownloadTask) continue;
      _queueWaitingIds.remove(task.taskId);
      await _ref
          .read(storageServiceProvider)
          .patchDownloadMetadata(task.taskId, queueWaiting: false);
      final record = byId[task.taskId];
      var progress = record?.progress ?? 0.0;
      if (progress < 0 || progress > 1) progress = 0.0;
      final totalSize = record?.expectedFileSize ?? -1;
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
      if (transferring) {
        await _ensureLiveActivity(
          task,
          progress: progress,
          totalBytes: totalSize,
        );
      }
    }
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
      if (live != null) {
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
    if (live != null ||
        shouldAttachToLiveNativeTask(
          taskId: task.taskId,
          trackingUrl: downloadTrackingUrl(task),
          live: await _liveNativeDownloads(),
        )) {
      await _attachToLiveNativeTask(task, live: live);
      return true;
    }
    _queueWaitingIds.remove(task.taskId);
    _waitingPayloads.remove(task.taskId);
    await _ref
        .read(storageServiceProvider)
        .patchDownloadMetadata(task.taskId, queueWaiting: false);
    _startingTaskIds.add(task.taskId);
    try {
      var started = await _resumeDownloadTask(task);
      if (!started) {
        started = await FileDownloader().enqueue(task);
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
    _ref.read(activeDownloadsProvider.notifier).add(trackingUrl);
    _ref
        .read(downloadProgressProvider.notifier)
        .update(
          trackingUrl,
          DownloadProgressData(
            taskId: taskId,
            progress: progress,
            networkSpeed: networkSpeed,
            timeRemaining: timeRemaining,
            status: status,
            totalSize: totalSize,
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
  Future<void> _preserveDownloadAsPaused(
    TaskStatusUpdate update,
    String trackingUrl,
  ) async {
    if (update.task is! DownloadTask) return;
    final task = update.task as DownloadTask;

    unawaited(_stopLiveActivity(task.taskId));

    final current = _ref.read(downloadProgressProvider)[trackingUrl];
    final record = await FileDownloader().database.recordForId(task.taskId);

    var progress = current?.progress ?? 0.0;
    if (progress < 0 || progress > 1) progress = 0.0;
    if ((progress == 0.0) && record != null) {
      final recorded = record.progress;
      if (recorded > 0 && recorded <= 1) progress = recorded;
    }

    final totalSize = current?.totalSize ?? record?.expectedFileSize ?? -1;

    // Never delete the DB record or metadata here — only mark paused.
    await FileDownloader().database.updateRecord(
      TaskRecord(task, TaskStatus.paused, progress, totalSize),
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
    unawaited(_serializeQueue(_syncQueueToCapUnlocked));
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

    final didPause = await FileDownloader().pause(downloadTask);
    if (didPause) {
      await _stopLiveActivity(taskId);
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
    _cancellingUrls.add(trackingUrl);
    try {
      await _serializeQueue(() async {
        _queueWaitingIds.remove(taskId);
        _waitingPayloads.remove(taskId);
        final ids = <String>{taskId};
        for (final task in await FileDownloader().allTasks(allGroups: true)) {
          if (task.taskId == taskId ||
              downloadTrackingUrl(task) == trackingUrl) {
            ids.add(task.taskId);
          }
        }
        await FileDownloader().cancelTasksWithIds(ids.toList());
        _ref.read(activeDownloadsProvider.notifier).remove(trackingUrl);
        _ref.read(downloadProgressProvider.notifier).remove(trackingUrl);
        if (notifyContinuedProcessing) {
          await _continuedProcessing.finish(
            taskId: taskId,
            success: false,
            status: 'canceled',
          );
        }

        // Proactive cleanup
        await FileDownloader().database.deleteRecordWithId(taskId);
        await _ref.read(storageServiceProvider).removeDownloadMetadata(taskId);
        await _syncQueueToCapUnlocked();
      });
    } finally {
      // Small delay to let final updates clear
      Future.delayed(const Duration(milliseconds: 500), () {
        _cancellingUrls.remove(trackingUrl);
      });
    }
  }

  Future<void> pauseDownload(String taskId) async {
    await _serializeQueue(() async {
      final wasWaiting = _queueWaitingIds.remove(taskId);
      _waitingPayloads.remove(taskId);
      await _ref
          .read(storageServiceProvider)
          .patchDownloadMetadata(taskId, queueWaiting: false);

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
        await FileDownloader().pause(downloadTask);
        final trackingUrl = downloadTrackingUrl(downloadTask);
        final current = _ref.read(downloadProgressProvider)[trackingUrl];
        final record = await FileDownloader().database.recordForId(taskId);
        var progress = current?.progress ?? record?.progress ?? 0.0;
        if (progress < 0 || progress > 1) progress = 0.0;
        await FileDownloader().database.updateRecord(
          TaskRecord(
            downloadTask,
            TaskStatus.paused,
            progress,
            current?.totalSize ?? record?.expectedFileSize ?? -1,
          ),
        );
        _publishProgress(
          trackingUrl: trackingUrl,
          taskId: taskId,
          progress: progress,
          totalSize: current?.totalSize ?? record?.expectedFileSize ?? -1,
          status: TaskStatus.paused,
        );
        _updatesController.add(
          TaskStatusUpdate(downloadTask, TaskStatus.paused),
        );
      }
      await _stopLiveActivity(taskId);
      await _persistNativeWaitingSnapshot();
      if (!wasWaiting) {
        await _syncQueueToCapUnlocked();
      }
    });
  }

  Future<void> resumeDownload(String taskId) async {
    await _serializeQueue(() async {
      DownloadTask? downloadTask = await _liveNativeTaskFor(taskId: taskId);
      if (downloadTask == null) {
        final record = await FileDownloader().database.recordForId(taskId);
        if (record?.task is DownloadTask) {
          downloadTask = record!.task as DownloadTask;
        }
      }
      if (downloadTask == null) return;
      _queueWaitingIds.remove(taskId);
      _waitingPayloads.remove(taskId);
      await _ref
          .read(storageServiceProvider)
          .patchDownloadMetadata(taskId, queueWaiting: false);
      await _resumeDownloadTask(downloadTask);
    });
  }

  Future<bool> _resumeDownloadTask(DownloadTask task) async {
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
    final resumedOrRestarted = await resumeOrRestartDownload(
      canResume: () => FileDownloader().taskCanResume(task),
      resume: () => FileDownloader().resume(task),
      resumeFromPartial: () => _resumeUsingPartialFile(task),
      restart: () => FileDownloader().enqueue(task),
    );
    // Live Activity starts only when native reports [TaskStatus.running].
    return resumedOrRestarted;
  }

  Future<bool> _resumeUsingPartialFile(DownloadTask task) async {
    String destinationPath;
    try {
      destinationPath = await task.filePath();
    } catch (_) {
      return false;
    }
    if (destinationPath.isEmpty) return false;

    final partial = await findPartialDownloadFile(
      destinationPath: destinationPath,
    );
    if (partial == null) return false;
    final existingBytes = await partial.length();
    final record = await FileDownloader().database.recordForId(task.taskId);
    final expectedBytes = record?.expectedFileSize ?? -1;
    if (!shouldResumeFromPartialBytes(
      existingPartialBytes: existingBytes,
      expectedBytes: expectedBytes,
    )) {
      return false;
    }

    final dest = File(destinationPath);
    if (partial.path != dest.path) {
      await dest.parent.create(recursive: true);
      await partial.copy(dest.path);
    }

    if (!Platform.isIOS) {
      final tempPath = '$destinationPath.download';
      if (p.normalize(dest.path) != p.normalize(tempPath)) {
        await dest.copy(tempPath);
      }
      try {
        // Plugin resume data is stored on BaseDownloader. After a kill the
        // temp file is often still on disk even when native resume blobs are
        // gone; reuse that prefix instead of downloading from byte 0.
        // ignore: invalid_use_of_visible_for_testing_member
        await FileDownloader().downloaderForTesting.setResumeData(
          ResumeData(task, tempPath, existingBytes, null),
        );
        if (await FileDownloader().resume(task)) {
          return true;
        }
      } catch (_) {
        // Fall through to a Range append when native resume data is rejected.
      }
    }

    return _appendRemainingWithDio(
      task,
      dest: dest,
      existingBytes: existingBytes,
      expectedBytes: expectedBytes,
    );
  }

  Future<bool> _appendRemainingWithDio(
    DownloadTask task, {
    required File dest,
    required int existingBytes,
    required int expectedBytes,
  }) async {
    final trackingUrl = downloadTrackingUrl(task);
    try {
      final response = await _dio.get<ResponseBody>(
        task.url,
        options: Options(
          headers: rangeResumeHeaders(
            existing: task.headers,
            existingBytes: existingBytes,
          ),
          followRedirects: true,
          responseType: ResponseType.stream,
          validateStatus: (status) =>
              status != null && (status == 206 || status == 200),
        ),
      );

      // A 200 means the host ignored Range and sent the whole file. Do not
      // append that onto the prefix — fall back to a full restart.
      if (response.statusCode != 206) return false;

      final body = response.data;
      if (body is! ResponseBody) return false;

      var totalSize = expectedBytes;
      final contentRange = response.headers.value('content-range');
      if (contentRange != null) {
        final total = contentRange.split('/').last;
        totalSize = int.tryParse(total) ?? totalSize;
      }

      await dest.parent.create(recursive: true);
      await _ensureLiveActivity(
        task,
        progress: existingBytes > 0 && expectedBytes > 0
            ? existingBytes / expectedBytes
            : 0,
        totalBytes: expectedBytes,
      );
      final written = await appendDownloadChunks(
        dest: dest,
        chunks: body.stream,
        existingBytes: existingBytes,
        onBytes: (written) {
          final progress = totalSize > 0 ? written / totalSize : 0.0;
          _publishProgress(
            trackingUrl: trackingUrl,
            taskId: task.taskId,
            progress: progress,
            totalSize: totalSize,
            status: TaskStatus.running,
          );
          unawaited(
            _continuedProcessing.update(
              taskId: task.taskId,
              progress: progress,
              totalBytes: totalSize,
            ),
          );
        },
      );

      await FileDownloader().database.updateRecord(
        TaskRecord(task, TaskStatus.complete, 1.0, written),
      );
      unawaited(_persistCompletedFilePath(task));
      unawaited(
        _continuedProcessing.finish(
          taskId: task.taskId,
          success: true,
          status: 'completed',
        ),
      );
      _updatesController.add(TaskStatusUpdate(task, TaskStatus.complete));
      _handleStatusUpdate(
        TaskStatusUpdate(task, TaskStatus.complete),
        trackingUrl,
      );
      return true;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[DownloadService] Range append failed: $error');
      }
      return false;
    }
  }

  Future<DownloadMetadata?> getMetadata(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      // 1. Try HEAD request first
      int? size;
      String? mimeType;

      try {
        final response = await _dio
            .head<dynamic>(
              url,
              options: Options(headers: headers, followRedirects: true),
            )
            .timeout(const Duration(seconds: 10));

        final contentLength = response.headers.value('content-length');
        if (contentLength != null) {
          size = int.tryParse(contentLength);
        }
        mimeType = response.headers.value('content-type');
      } catch (e) {
        // HEAD failed, will try GET fallback
      }

      // 2. Fallback to GET with Range if size unknown
      if (size == null) {
        try {
          // Some media hosts reject HEAD but honor a byte-range GET. Use a
          // streaming response here so a server that ignores Range cannot
          // buffer an entire movie/episode into memory just to discover its
          // size. We only need the response headers.
          final getResponse = await _dio
              .get<dynamic>(
                url,
                options: Options(
                  headers: {...?headers, 'Range': 'bytes=0-0'},
                  followRedirects: true,
                  responseType: ResponseType.stream,
                ),
              )
              .timeout(const Duration(seconds: 10));

          final rangeContentLength = getResponse.headers.value('content-range');
          if (rangeContentLength != null) {
            final totalSize = rangeContentLength.split('/').last;
            size = int.tryParse(totalSize);
          } else {
            // A compliant 200 response may still expose the full size. Do not
            // infer it from the streamed body; that would defeat the point of
            // this metadata-only request.
            final contentLength = getResponse.headers.value('content-length');
            final parsedLength = int.tryParse(contentLength ?? '');
            if (parsedLength != null && parsedLength > 1) {
              size = parsedLength;
            }
          }
          mimeType ??= getResponse.headers.value('content-type');

          final body = getResponse.data;
          if (body is ResponseBody) {
            // Close the streamed response without reading a potentially huge
            // body when the server ignored the Range header.
            final subscription = body.stream.listen(null);
            await subscription.cancel();
          }
        } catch (e) {
          // GET fallback failed
        }
      }

      return DownloadMetadata(size: size, mimeType: mimeType);
    } catch (e) {
      return null;
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
    if (kDebugMode) {
      debugPrint('[DownloadService] startDownload called');
      debugPrint('[DownloadService] - URL: $url');
      debugPrint('[DownloadService] - Tracking URL: $trackingUrl');
      debugPrint('[DownloadService] - Filename: $filename');
      debugPrint('[DownloadService] - Directory: $directory');
    }

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
            (r.status == TaskStatus.enqueued ||
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
        if (occupying) {
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
        _queueWaitingIds.remove(existingTask.taskId);
        _waitingPayloads.remove(existingTask.taskId);
        await _ref
            .read(storageServiceProvider)
            .patchDownloadMetadata(existingTask.taskId, queueWaiting: false);
        final resumedOrRestarted = await _resumeDownloadTask(existingTask);
        if (!resumedOrRestarted) {
          return false;
        }

        _ref.read(activeDownloadsProvider.notifier).add(trackingUrl ?? url);
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
        retries: 3, // Align with example
        allowPause: true,
        metaData: trackingUrl ?? url,
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

        _startingTaskIds.add(task.taskId);

        final success = await FileDownloader().enqueue(task);
        if (kDebugMode) {
          debugPrint('[DownloadService] Enqueue result: $success');
        }

        if (success) {
          _ref.read(activeDownloadsProvider.notifier).add(trackingUrl ?? url);
          _waitingPayloads[task.taskId] = _waitingPayloadFor(task);
          await _ref
              .read(storageServiceProvider)
              .saveDownloadMetadata(
                task.taskId,
                item,
                episode: episode,
                trackingUrl: trackingUrl ?? url,
                filePath: path,
                queueWaiting: false,
              );
          await _persistNativeWaitingSnapshot();
        }
        return success;
      } catch (error) {
        await _stopLiveActivity(task.taskId);
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
    }
  }

  Future<void> _persistCompletedFilePath(Task task) async {
    try {
      final path = await task.filePath();
      await _ref
          .read(storageServiceProvider)
          .patchDownloadMetadata(
            task.taskId,
            trackingUrl: downloadTrackingUrl(task),
            filePath: path,
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

  DownloadMetadata({this.size, this.mimeType});

  String get sizeString {
    if (size == null) return "Unknown size";
    final double mb = size! / (1024 * 1024);
    if (mb > 1024) {
      return "${(mb / 1024).toStringAsFixed(2)} GB";
    }
    return "${mb.toStringAsFixed(2)} MB";
  }
}
