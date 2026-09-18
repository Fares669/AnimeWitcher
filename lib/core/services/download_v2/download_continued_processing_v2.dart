import 'dart:async';

import 'package:path/path.dart' as p;

import '../download_continued_processing_service.dart';
import 'download_v2_models.dart';

/// Presentation-only observer for V2 transport snapshots.
///
/// Implementations may mirror package state into platform UI, but must never
/// enqueue, retry, promote, pause, resume, or cancel the package-owned transfer.
abstract interface class DownloadPresentationObserverV2 {
  Future<void> observe(
    LogicalDownloadRecordV2 record,
    DownloadTransportSnapshot snapshot,
  );

  Future<void> dispose();
}

/// Bridges V2 parent-transfer progress into iOS 26 Continued Processing.
///
/// The native system task is deliberately an overlay only. Its callback cannot
/// mutate V2 transport; background_downloader remains the sole URLSession owner.
final class IosDownloadContinuedProcessingObserverV2
    implements DownloadPresentationObserverV2 {
  IosDownloadContinuedProcessingObserverV2({
    DownloadContinuedProcessingService? service,
  }) : _service =
           service ??
           DownloadContinuedProcessingService(
             // V2 system UI is observation-only. A native overlay callback
             // must not become a second cancel/transport control path.
             onSystemCancel: (_) async {},
           );

  final DownloadContinuedProcessingService _service;
  final Map<String, _ContinuedEntryV2> _outstanding =
      <String, _ContinuedEntryV2>{};
  final Set<String> _sessionMembers = <String>{};
  final Set<String> _completedMembers = <String>{};

  Future<void> _tail = Future<void>.value();
  bool _sessionActive = false;
  bool _disposed = false;

  @override
  Future<void> observe(
    LogicalDownloadRecordV2 record,
    DownloadTransportSnapshot snapshot,
  ) {
    if (_disposed) return Future<void>.value();
    final result = _tail
        .catchError((Object _) {})
        .then((_) => _observeNow(record, snapshot));
    _tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _observeNow(
    LogicalDownloadRecordV2 record,
    DownloadTransportSnapshot snapshot,
  ) async {
    if (_disposed || record.taskId != snapshot.taskId) return;
    final logicalId = record.logicalId.value;
    final entry = _ContinuedEntryV2(record, snapshot);

    switch (snapshot.status) {
      case DownloadTransportStatus.queued:
      case DownloadTransportStatus.running:
      case DownloadTransportStatus.held:
        _sessionMembers.add(logicalId);
        _outstanding[logicalId] = entry;
      case DownloadTransportStatus.complete:
        _sessionMembers.add(logicalId);
        _completedMembers.add(logicalId);
        _outstanding.remove(logicalId);
      case DownloadTransportStatus.paused:
      case DownloadTransportStatus.failed:
      case DownloadTransportStatus.canceled:
      case DownloadTransportStatus.missing:
        _outstanding.remove(logicalId);
    }

    final running = _outstanding.values
        .where(
          (candidate) =>
              candidate.snapshot.status == DownloadTransportStatus.running,
        )
        .toList(growable: false);

    if (snapshot.status == DownloadTransportStatus.complete && _sessionActive) {
      // Update the native snapshot to an unequivocal final value before asking
      // the completion guard to close the session.
      await _service.update(
        taskId: snapshot.taskId,
        displayName: _displayName(record),
        progress: 1,
        totalBytes: snapshot.totalBytes ?? record.expectedBytes ?? -1,
        transferredBytes:
            snapshot.transferredBytes ??
            snapshot.totalBytes ??
            record.expectedBytes ??
            0,
        completedCount: (_completedMembers.length - 1).clamp(
          0,
          _sessionMembers.length,
        ),
        batchTotal: _sessionMembers.isEmpty ? 1 : _sessionMembers.length,
        speedBytesPerSecond: _speedBytesPerSecond(snapshot),
        currentIndex: _sessionMembers.isEmpty
            ? 1
            : _completedMembers.length.clamp(1, _sessionMembers.length),
      );
    }

    if (running.isNotEmpty) {
      final current = snapshot.status == DownloadTransportStatus.running
          ? entry
          : running.first;
      final currentSnapshot = current.snapshot;
      final currentRecord = current.record;
      final batchTotal = _sessionMembers.isEmpty ? 1 : _sessionMembers.length;
      final completedCount = _completedMembers.length.clamp(0, batchTotal);
      final currentIndex = (completedCount + 1).clamp(1, batchTotal);
      final totalBytes =
          currentSnapshot.totalBytes ?? currentRecord.expectedBytes ?? -1;
      final transferredBytes =
          currentSnapshot.transferredBytes ??
          (totalBytes > 0
              ? (totalBytes * currentSnapshot.progress).round()
              : 0);

      if (!_sessionActive) {
        _sessionActive = await _service.start(
          taskId: currentSnapshot.taskId,
          displayName: _displayName(currentRecord),
          progress: currentSnapshot.progress,
          totalBytes: totalBytes,
          transferredBytes: transferredBytes,
          completedCount: completedCount,
          batchTotal: batchTotal,
          speedBytesPerSecond: _speedBytesPerSecond(currentSnapshot),
          currentIndex: currentIndex,
        );
      } else {
        await _service.update(
          taskId: currentSnapshot.taskId,
          displayName: _displayName(currentRecord),
          progress: currentSnapshot.progress,
          totalBytes: totalBytes,
          transferredBytes: transferredBytes,
          completedCount: completedCount,
          batchTotal: batchTotal,
          speedBytesPerSecond: _speedBytesPerSecond(currentSnapshot),
          currentIndex: currentIndex,
        );
      }
      return;
    }

    if (!_sessionActive || _outstanding.isNotEmpty) return;

    final allCompleted =
        _sessionMembers.isNotEmpty &&
        _sessionMembers.every(_completedMembers.contains);
    if (allCompleted) {
      await _service.finish(
        taskId: snapshot.taskId,
        success: true,
        status: 'completed',
        endSession: true,
      );
    } else {
      await _service.stop(taskId: snapshot.taskId, endSession: true);
    }
    _resetSession();
  }

  String _displayName(LogicalDownloadRecordV2 record) {
    final name = p.basenameWithoutExtension(record.destinationPath).trim();
    return name.isEmpty ? 'Download' : name;
  }

  double _speedBytesPerSecond(DownloadTransportSnapshot snapshot) =>
      snapshot.networkSpeedMBps > 0 ? snapshot.networkSpeedMBps * 1000000 : 0;

  void _resetSession() {
    _sessionActive = false;
    _sessionMembers.clear();
    _completedMembers.clear();
    _outstanding.clear();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _tail.catchError((Object _) {});
    await _service.dispose();
    _resetSession();
  }
}

final class _ContinuedEntryV2 {
  const _ContinuedEntryV2(this.record, this.snapshot);

  final LogicalDownloadRecordV2 record;
  final DownloadTransportSnapshot snapshot;
}
