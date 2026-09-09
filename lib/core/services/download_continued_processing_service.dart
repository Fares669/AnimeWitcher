import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'download_concurrency.dart';

typedef SystemDownloadCancellation = Future<void> Function(String taskId);
typedef SystemDownloadChunkUpdate = void Function({
  required String parentTaskId,
  required String chunkTaskId,
  double? progress,
  int? statusOrdinal,
  int? writtenBytes,
  int? expectedBytes,
  double? speedBytesPerSecond,
  required bool completed,
});

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
  final SystemDownloadChunkUpdate? onChunkUpdate;
  bool _handlerInstalled = false;

  DownloadContinuedProcessingService({
    required this.onSystemCancel,
    this.onChunkUpdate,
  }) {
    if (_isAvailable) {
      _channel.setMethodCallHandler(_handleNativeCall);
      _handlerInstalled = true;
    }
  }

  bool get _isAvailable => !kIsWeb && Platform.isIOS;

  Future<void> start({
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
    await _invoke('start', <String, Object>{
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
  }) async {
    await _invoke('update', <String, Object>{
      'taskId': taskId,
      'progress': progress.clamp(0.0, 1.0).toDouble(),
      'totalBytes': totalBytes,
      'transferredBytes': transferredBytes,
      'completedCount': completedCount,
      'batchTotal': batchTotal,
      'speedBytesPerSecond': speedBytesPerSecond,
      if (displayName.isNotEmpty) 'displayName': displayName,
      'currentIndex': currentIndex,
    });
  }

  Future<void> finish({
    required String taskId,
    required bool success,
    required String status,
    bool endSession = false,
  }) async {
    await _invoke('finish', <String, Object>{
      'taskId': taskId,
      'success': success,
      'status': status,
      'endSession': endSession,
    });
  }

  Future<void> stop({required String taskId, bool endSession = false}) async {
    await _invoke('stop', <String, Object>{
      'taskId': taskId,
      'endSession': endSession,
    });
  }

  /// Persist full waiter payloads (url, headers, filename, directory, task JSON)
  /// so iOS can start the next file from Swift without Flutter.
  Future<void> persistNativeQueue({
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
  }) async {
    await _invoke('persistNativeQueue', <String, Object>{
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
    });
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is! Map) return false;

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
      final rawSpeed = arguments['speedBytesPerSecond'];
      onChunkUpdate?.call(
        parentTaskId: parentTaskId,
        chunkTaskId: chunkTaskId,
        progress: rawProgress is num ? rawProgress.toDouble() : null,
        statusOrdinal: rawStatus is num ? rawStatus.toInt() : null,
        writtenBytes: rawWritten is num ? rawWritten.toInt() : null,
        expectedBytes: rawExpected is num ? rawExpected.toInt() : null,
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

  Future<void> _invoke(String method, Map<String, Object> arguments) async {
    if (!_isAvailable) return;

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
    if (_handlerInstalled) {
      _channel.setMethodCallHandler(null);
      _handlerInstalled = false;
    }
  }
}
