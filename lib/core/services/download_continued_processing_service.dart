import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'download_concurrency.dart';

typedef SystemDownloadCancellation = Future<void> Function(String taskId);
typedef SystemDownloadSessionLost = void Function();
typedef SystemDownloadTaskUpdate = void Function({
  required String taskId,
  required String trackingUrl,
  required int writtenBytes,
  required int expectedBytes,
  double? speedBytesPerSecond,
});

typedef SystemDownloadChunkUpdate = void Function({
  required String parentTaskId,
  required String chunkTaskId,
  double? progress,
  int? statusOrdinal,
  int? writtenBytes,
  int? expectedBytes,
  int? attemptGeneration,
  double? speedBytesPerSecond,
  required bool completed,
});

@visibleForTesting
class DownloadGlobalHandlerLease {
  DownloadGlobalHandlerLease._(this.generation);

  static int _nextGeneration = 0;
  static int? _activeGeneration;

  final int generation;

  static DownloadGlobalHandlerLease acquire() {
    final lease = DownloadGlobalHandlerLease._(++_nextGeneration);
    _activeGeneration = lease.generation;
    return lease;
  }

  bool releaseIfCurrent() {
    if (_activeGeneration != generation) return false;
    _activeGeneration = null;
    return true;
  }
}

/// Bridges AnimeWitcher downloads to iOS 26's system-managed continued
/// processing task UI. On older iOS versions the native side returns false
/// and background_downloader continues to work normally.
///
/// One session identifier for the whole queue. `finish` / `stop` are
/// no-ops unless [endSession] is true — finishing ep1's overlay is what
/// suspended the process and broke ep2 promotion.
class DownloadContinuedProcessingService {
  static const MethodChannel _channel = MethodChannel(
    'com.animewitcher.app/download_continued_processing',
  );

  final SystemDownloadCancellation onSystemCancel;
  final SystemDownloadSessionLost? onSessionLost;
  final SystemDownloadTaskUpdate? onTaskUpdate;
  final SystemDownloadChunkUpdate? onChunkUpdate;
  final bool forceAvailableForTesting;
  bool _handlerInstalled = false;
  bool _disposed = false;
  int _nativeQueueSnapshotVersion = 0;

  /// False means queued work stays with the foreground scheduler. A persisted
  /// checkpoint is not proof that native background promotion is available.
  bool nativePromotionAvailable = false;
  DownloadGlobalHandlerLease? _handlerLease;
  static const Duration _updateSampleInterval = Duration(seconds: 1);
  Timer? _updateTimer;
  DateTime? _lastUpdateAt;
  Map<String, Object>? _pendingUpdate;

  DownloadContinuedProcessingService({
    required this.onSystemCancel,
    this.onSessionLost,
    this.onTaskUpdate,
    this.onChunkUpdate,
    @visibleForTesting this.forceAvailableForTesting = false,
  }) {
    if (_isAvailable) {
      _handlerLease = DownloadGlobalHandlerLease.acquire();
      _channel.setMethodCallHandler(_handleNativeCall);
      _handlerInstalled = true;
    }
  }

  bool get _isAvailable =>
      forceAvailableForTesting || (!kIsWeb && Platform.isIOS);

  Future<void> configureDiagnosticLog(bool enabled) =>
      _invoke('configureDiagnosticLog', {'enabled': enabled});

  Future<bool> start({
    required String taskId,
    required String displayName,
    double progress = 0.0,
    int totalBytes = -1,
    int transferredBytes = 0,
    int completedCount = 0,
    int batchTotal = 1,
    double speedBytesPerSecond = 0,
    int currentIndex = 0,
  }) async {
    _cancelPendingUpdate();
    final result = await _invokeForResult<Object?>('start', <String, Object>{
      'taskId': taskId,
      'displayName': displayName,
      'progress': progress.clamp(0.0, 1.0).toDouble(),
      'totalBytes': totalBytes,
      'transferredBytes': transferredBytes,
      'completedCount': completedCount,
      'batchTotal': batchTotal,
      'speedBytesPerSecond': speedBytesPerSecond,
      'currentIndex': currentIndex,
    });
    final accepted = switch (result) {
      final String identifier => identifier.trim().isNotEmpty,
      final bool value => value,
      _ => false,
    };
    if (accepted) _lastUpdateAt = DateTime.now();
    return accepted;
  }

  Future<void> update({
    required String taskId,
    required double progress,
    required int totalBytes,
    int transferredBytes = 0,
    int completedCount = 0,
    int batchTotal = 1,
    double speedBytesPerSecond = 0,
    String displayName = '',
    int currentIndex = 0,
    bool foregroundHandoff = false,
  }) async {
    final arguments = <String, Object>{
      'taskId': taskId,
      'progress': progress.clamp(0.0, 1.0).toDouble(),
      'totalBytes': totalBytes,
      'transferredBytes': transferredBytes,
      'completedCount': completedCount,
      'batchTotal': batchTotal,
      'speedBytesPerSecond': speedBytesPerSecond,
      if (displayName.isNotEmpty) 'displayName': displayName,
      'currentIndex': currentIndex,
      'foregroundHandoff': foregroundHandoff,
    };

    // Foreground reattachment is a lifecycle synchronization point, not a
    // metric sample. Do not leave it behind the one-second presentation timer:
    // the scene can become active before another network progress event arrives.
    if (foregroundHandoff) {
      _updateTimer?.cancel();
      _updateTimer = null;
      _pendingUpdate = null;
      _lastUpdateAt = DateTime.now();
      await _sendUpdate(arguments);
      return;
    }
    await _queueUpdate(arguments);
  }

  Future<void> _queueUpdate(Map<String, Object> arguments) async {
    if (!_isAvailable) return;
    _pendingUpdate = arguments;
    final now = DateTime.now();
    final last = _lastUpdateAt;
    if (last == null || now.difference(last) >= _updateSampleInterval) {
      _updateTimer?.cancel();
      _updateTimer = null;
      final pending = _pendingUpdate;
      _pendingUpdate = null;
      _lastUpdateAt = now;
      if (pending != null) await _sendUpdate(pending);
      return;
    }

    final delay = _updateSampleInterval - now.difference(last);
    _updateTimer ??= Timer(delay, () async {
      _updateTimer = null;
      final pending = _pendingUpdate;
      _pendingUpdate = null;
      if (pending == null || !_isAvailable || _disposed) return;
      _lastUpdateAt = DateTime.now();
      await _sendUpdate(pending);
    });
  }

  Future<void> _sendUpdate(Map<String, Object> arguments) async {
    final response = await _invokeForResult<Object?>('update', arguments);
    bool? accepted;
    if (response is bool) {
      accepted = response;
    } else if (response is Map) {
      final rawAccepted = response['accepted'];
      if (rawAccepted is bool) accepted = rawAccepted;
    }
    if (accepted == false && !_disposed) {
      onSessionLost?.call();
    }
  }

  void _cancelPendingUpdate() {
    _updateTimer?.cancel();
    _updateTimer = null;
    _pendingUpdate = null;
  }

  Future<void> finish({
    required String taskId,
    required bool success,
    required String status,
    bool endSession = false,
  }) async {
    _cancelPendingUpdate();
    await _invoke('finish', <String, Object>{
      'taskId': taskId,
      'success': success,
      'status': status,
      'endSession': endSession,
    });
  }

  Future<void> stop({required String taskId, bool endSession = false}) async {
    _cancelPendingUpdate();
    await _invoke('stop', <String, Object>{
      'taskId': taskId,
      'endSession': endSession,
    });
  }

  /// Persist full waiter payloads (url, headers, filename, directory, task JSON)
  /// so iOS can start the next file from Swift without Flutter.
  Future<int?> persistNativeQueue({
    required int maxConcurrent,
    required List<Map<String, Object>> waiters,
    required List<String> transferringTaskIds,
    required List<String> pausedTaskIds,
    List<String> queueWaitingTaskIds = const [],
    List<String> sessionTaskIds = const [],
    int sessionCompletedCount = 0,
    int sessionBatchTotal = 0,
    String sessionCurrentTaskId = '',
    String sessionDisplayName = '',
    double sessionProgress = 0,
    int sessionTotalBytes = -1,
    int sessionTransferredBytes = 0,
    double sessionSpeedBytesPerSecond = 0,
    int sessionCurrentIndex = 0,
    List<Map<String, Object>> multipartPlans = const [],
  }) async {
    int nextVersion() {
      final wallClock = DateTime.now().microsecondsSinceEpoch;
      final next = _nativeQueueSnapshotVersion + 1;
      _nativeQueueSnapshotVersion = wallClock > next ? wallClock : next;
      return _nativeQueueSnapshotVersion;
    }

    Future<int?> write(int snapshotVersion) async {
      final ack = await _invokeForResult<Object?>(
        'persistNativeQueue',
        <String, Object>{
          'snapshotVersion': snapshotVersion,
          'maxConcurrent': maxConcurrent,
          'waiters': waiters,
          'transferringTaskIds': transferringTaskIds,
          'pausedTaskIds': pausedTaskIds,
          'queueWaitingTaskIds': queueWaitingTaskIds,
          'sessionTaskIds': sessionTaskIds,
          'sessionCompletedCount': sessionCompletedCount,
          'sessionBatchTotal': sessionBatchTotal,
          'sessionCurrentTaskId': sessionCurrentTaskId.isEmpty
              ? kDownloadSessionOverlayTaskId
              : sessionCurrentTaskId,
          'sessionDisplayName': sessionDisplayName,
          'sessionProgress': sessionProgress,
          'sessionTotalBytes': sessionTotalBytes,
          'sessionTransferredBytes': sessionTransferredBytes,
          'sessionSpeedBytesPerSecond': sessionSpeedBytesPerSecond,
          'sessionCurrentIndex': sessionCurrentIndex,
          'multipartPlans': multipartPlans,
        },
      );
      if (ack is! Map) return null;
      nativePromotionAvailable = ack['nativePromotionAvailable'] == true;
      final rawAcceptedVersion = ack['acceptedVersion'];
      if (rawAcceptedVersion is! num) return null;
      return rawAcceptedVersion.toInt();
    }

    final snapshotVersion = nextVersion();
    var accepted = await write(snapshotVersion);

    // A lost reply is ambiguous: native may have durably accepted the write.
    // Retry the exact same version once. Native treats an equal version as an
    // idempotent acknowledgement, so this cannot advance or duplicate state.
    if (accepted == null) {
      accepted = await write(snapshotVersion);
    }
    if (accepted == null) return null;

    if (accepted > _nativeQueueSnapshotVersion) {
      _nativeQueueSnapshotVersion = accepted;
    }
    if (accepted == snapshotVersion) return accepted;

    // Native is durably newer (for example it promoted/completed work while
    // Flutter slept). Fail closed. Never relabel this stale Dart payload with
    // a higher version; the caller must rebuild/reconcile a fresh snapshot.
    return null;
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (_disposed) return false;
    final arguments = call.arguments;
    if (arguments is! Map) return false;

    if (call.method == 'taskUpdate') {
      final taskId = arguments['taskId'];
      final trackingUrl = arguments['trackingUrl'];
      final rawWritten = arguments['writtenBytes'];
      final rawExpected = arguments['expectedBytes'];
      final rawSpeed = arguments['speedBytesPerSecond'];
      if (taskId is! String ||
          taskId.isEmpty ||
          trackingUrl is! String ||
          trackingUrl.isEmpty ||
          rawWritten is! num) {
        return false;
      }
      onTaskUpdate?.call(
        taskId: taskId,
        trackingUrl: trackingUrl,
        writtenBytes: rawWritten.toInt(),
        expectedBytes: rawExpected is num ? rawExpected.toInt() : -1,
        speedBytesPerSecond: rawSpeed is num ? rawSpeed.toDouble() : null,
      );
      return true;
    }

    if (call.method == 'chunkUpdate') {
      final parentTaskId = arguments['parentTaskId'];
      final chunkTaskId = arguments['chunkTaskId'];
      if (parentTaskId is! String ||
          parentTaskId.isEmpty ||
          chunkTaskId is! String ||
          chunkTaskId.isEmpty) {
        return false;
      }
      final rawProgress = arguments['progress'];
      final rawStatus = arguments['status'];
      final rawWritten = arguments['writtenBytes'];
      final rawExpected = arguments['expectedBytes'];
      final rawAttempt = arguments['attemptGeneration'];
      final rawSpeed = arguments['speedBytesPerSecond'];
      onChunkUpdate?.call(
        parentTaskId: parentTaskId,
        chunkTaskId: chunkTaskId,
        progress: rawProgress is num ? rawProgress.toDouble() : null,
        statusOrdinal: rawStatus is num ? rawStatus.toInt() : null,
        writtenBytes: rawWritten is num ? rawWritten.toInt() : null,
        expectedBytes: rawExpected is num ? rawExpected.toInt() : null,
        attemptGeneration: rawAttempt is num ? rawAttempt.toInt() : null,
        speedBytesPerSecond: rawSpeed is num ? rawSpeed.toDouble() : null,
        completed: arguments['completed'] == true,
      );
      return true;
    }

    if (call.method != 'cancel') return false;
    final taskId = arguments['taskId'];
    if (taskId is! String || taskId.isEmpty) return false;

    await onSystemCancel(taskId);
    return true;
  }

  Future<T?> _invokeForResult<T>(
    String method,
    Map<String, Object> arguments,
  ) async {
    if (!_isAvailable || _disposed) return null;

    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[DownloadContinuedProcessing] $method failed: '
          '${error.code} ${error.message}',
        );
      }
      return null;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[DownloadContinuedProcessing] $method failed: $error');
      }
      return null;
    }
  }

  Future<void> _invoke(String method, Map<String, Object> arguments) async {
    if (!_isAvailable || _disposed) return;

    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // The current build does not include the iOS 26 bridge.
    } on PlatformException catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[DownloadContinuedProcessing] $method failed: '
          '${error.code} ${error.message}',
        );
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[DownloadContinuedProcessing] $method failed: $error');
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelPendingUpdate();
    if (_handlerInstalled) {
      final ownsHandler = _handlerLease?.releaseIfCurrent() ?? false;
      if (ownsHandler) {
        _channel.setMethodCallHandler(null);
      }
      _handlerInstalled = false;
      _handlerLease = null;
    }
  }
}
