import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
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

/// Transient observation-only barrier for package-managed parallel pauses.
///
/// background_downloader can publish the parent paused state before every non-complete child
/// has finished persisting its own resume data. V2 never stores child ranges or
/// resume bytes; it only waits for the package's child status callbacks.
final class NativeParallelPauseReadinessV2 {
  final Map<String, Set<String>> _settledChildrenByParent =
      <String, Set<String>>{};
  final Map<String, List<_ParallelPauseWaiterV2>> _waitersByParent =
      <String, List<_ParallelPauseWaiterV2>>{};

  void observe({
    required String parentTaskId,
    required String childTaskId,
    int? statusOrdinal,
  }) {
    if (!parentTaskId.startsWith('aw_v2_') ||
        childTaskId.isEmpty ||
        statusOrdinal == null ||
        statusOrdinal < 0 ||
        statusOrdinal >= TaskStatus.values.length) {
      return;
    }

    final status = TaskStatus.values[statusOrdinal];
    final settledChildren = _settledChildrenByParent.putIfAbsent(
      parentTaskId,
      () => <String>{},
    );
    if (status == TaskStatus.paused || status == TaskStatus.complete) {
      // A child that completed before the user's pause is already settled and
      // will never emit paused. Count it while every non-complete child stops.
      settledChildren.add(childTaskId);
    } else {
      settledChildren.remove(childTaskId);
      if (settledChildren.isEmpty) {
        _settledChildrenByParent.remove(parentTaskId);
      }
    }
    _completeReadyWaiters(parentTaskId);
  }

  Future<bool> waitUntilReady({
    required String taskId,
    required int expectedChildren,
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (!taskId.startsWith('aw_v2_') || expectedChildren <= 1) {
      return Future<bool>.value(true);
    }
    if ((_settledChildrenByParent[taskId]?.length ?? 0) >= expectedChildren) {
      return Future<bool>.value(true);
    }

    final waiter = _ParallelPauseWaiterV2(expectedChildren);
    final waiters = _waitersByParent.putIfAbsent(
      taskId,
      () => <_ParallelPauseWaiterV2>[],
    );
    waiters.add(waiter);
    waiter.timer = Timer(timeout, () {
      final current = _waitersByParent[taskId];
      current?.remove(waiter);
      if (current?.isEmpty ?? false) {
        _waitersByParent.remove(taskId);
      }
      if (!waiter.completer.isCompleted) {
        waiter.completer.complete(false);
      }
    });
    return waiter.completer.future.then((ready) {
      waiter.timer?.cancel();
      return ready;
    });
  }

  void _completeReadyWaiters(String parentTaskId) {
    final settledCount = _settledChildrenByParent[parentTaskId]?.length ?? 0;
    final waiters = _waitersByParent[parentTaskId];
    if (waiters == null || waiters.isEmpty) return;

    final ready = waiters
        .where((waiter) => settledCount >= waiter.expectedChildren)
        .toList(growable: false);
    for (final waiter in ready) {
      waiters.remove(waiter);
      waiter.timer?.cancel();
      if (!waiter.completer.isCompleted) {
        waiter.completer.complete(true);
      }
    }
    if (waiters.isEmpty) {
      _waitersByParent.remove(parentTaskId);
    }
  }
}

final class _ParallelPauseWaiterV2 {
  _ParallelPauseWaiterV2(this.expectedChildren);

  final int expectedChildren;
  final Completer<bool> completer = Completer<bool>();
  Timer? timer;
}

/// Aggregates read-only iOS child throughput for one V2 parallel parent.
///
/// Missing/zero samples do not erase the last stable child speed. Final child
/// status removes that child from the aggregate.
final class NativeParallelSpeedAccumulatorV2 {
  final Map<String, Map<String, double>> _childrenByParent =
      <String, Map<String, double>>{};

  double? update({
    required String parentTaskId,
    required String childTaskId,
    double? speedBytesPerSecond,
    required bool completed,
  }) {
    if (!parentTaskId.startsWith('aw_v2_') || childTaskId.isEmpty) return null;

    final children = _childrenByParent.putIfAbsent(
      parentTaskId,
      () => <String, double>{},
    );
    if (completed) {
      children.remove(childTaskId);
    } else if (speedBytesPerSecond != null &&
        speedBytesPerSecond.isFinite) {
      if (speedBytesPerSecond > 0) {
        children[childTaskId] = speedBytesPerSecond;
      } else if (speedBytesPerSecond == 0) {
        // Native emits an explicit zero only after this child has produced no
        // bytes for the stale window. Missing/null samples are different and
        // intentionally keep the previous stable value.
        children.remove(childTaskId);
      }
    }

    if (children.isEmpty) {
      _childrenByParent.remove(parentTaskId);
      // Completing the last immutable Range is a handoff to the next Range,
      // not evidence that the logical parent network speed became zero.
      return !completed && speedBytesPerSecond == 0 ? 0 : null;
    }
    return children.values.fold<double>(0, (sum, speed) => sum + speed);
  }
}

DownloadContinuedProcessingService _newV2ContinuedProcessingService(
  void Function({
    required String taskId,
    required double bytesPerSecond,
  })? onNativeNetworkSpeed,
  NativeParallelPauseReadinessV2? pauseReadiness,
) {
  final speeds = NativeParallelSpeedAccumulatorV2();
  return DownloadContinuedProcessingService(
    // V2 system UI is observation-only. A native overlay callback must not
    // become a second cancel/transport control path.
    onSystemCancel: (_) async {},
    onChunkUpdate:
        ({
          required parentTaskId,
          required chunkTaskId,
          progress,
          statusOrdinal,
          writtenBytes,
          expectedBytes,
          attemptGeneration,
          speedBytesPerSecond,
          required completed,
        }) {
          pauseReadiness?.observe(
            parentTaskId: parentTaskId,
            childTaskId: chunkTaskId,
            statusOrdinal: statusOrdinal,
          );
          final aggregate = speeds.update(
            parentTaskId: parentTaskId,
            childTaskId: chunkTaskId,
            speedBytesPerSecond: speedBytesPerSecond,
            completed: completed,
          );
          if (aggregate == null) return;
          onNativeNetworkSpeed?.call(
            taskId: parentTaskId,
            bytesPerSecond: aggregate,
          );
        },
  );
}

/// Bridges V2 progress into iOS 26 Continued Processing and checkpoints the
/// coordinator's generation-fenced zero-byte Range candidates for native refill.
///
/// background_downloader remains the URLSession writer. This observer never
/// invents ranges or durable bytes: it only snapshots candidates already
/// prepared by [PersistentParallelDownload] so Apple's background session can
/// refill completed slots while Flutter is suspended.
final class IosDownloadContinuedProcessingObserverV2
    implements DownloadPresentationObserverV2 {
  IosDownloadContinuedProcessingObserverV2({
    DownloadContinuedProcessingService? service,
    void Function({
      required String taskId,
      required double bytesPerSecond,
    })? onNativeNetworkSpeed,
    NativeParallelPauseReadinessV2? pauseReadiness,
    List<Map<String, Object>> Function()? nativeBackgroundPlans,
    void Function()? releaseNativeBackgroundOffers,
  }) : _service =
           service ??
           _newV2ContinuedProcessingService(
             onNativeNetworkSpeed,
             pauseReadiness,
           ),
       _nativeBackgroundPlans = nativeBackgroundPlans,
       _releaseNativeBackgroundOffers = releaseNativeBackgroundOffers;

  final DownloadContinuedProcessingService _service;
  final List<Map<String, Object>> Function()? _nativeBackgroundPlans;
  final void Function()? _releaseNativeBackgroundOffers;
  final Map<String, _ContinuedEntryV2> _outstanding =
      <String, _ContinuedEntryV2>{};
  final Set<String> _sessionMembers = <String>{};
  final Set<String> _completedMembers = <String>{};

  Future<void> _tail = Future<void>.value();
  bool _sessionActive = false;
  bool _disposed = false;
  String? _nativeQueueSignature;

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
        // Startup replays durable completed records through presentation
        // observers. A terminal record that was never active in this observer's
        // current session must not inflate the iOS "N of N" batch count.
        if (!_sessionMembers.contains(logicalId)) return;
        _completedMembers.add(logicalId);
        _outstanding.remove(logicalId);
      case DownloadTransportStatus.paused:
      case DownloadTransportStatus.failed:
      case DownloadTransportStatus.canceled:
      case DownloadTransportStatus.missing:
        _outstanding.remove(logicalId);
    }

    final presentableActive = _outstanding.values
        .where(_isPackageOwnedActive)
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

    if (presentableActive.isNotEmpty) {
      final current = _isPackageOwnedActive(entry)
          ? entry
          : presentableActive.first;
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

      await _checkpointNativeQueue(
        activeEntries: presentableActive,
        current: current,
        batchTotal: batchTotal,
        completedCount: completedCount,
        currentIndex: currentIndex,
      );

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

    await _checkpointNativeQueue(
      activeEntries: const <_ContinuedEntryV2>[],
      current: entry,
      batchTotal: _sessionMembers.isEmpty ? 1 : _sessionMembers.length,
      completedCount: _completedMembers.length.clamp(
        0,
        _sessionMembers.isEmpty ? 1 : _sessionMembers.length,
      ),
      currentIndex: _sessionMembers.isEmpty
          ? 1
          : _completedMembers.length.clamp(1, _sessionMembers.length),
      paused: snapshot.status == DownloadTransportStatus.paused,
    );

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

  Future<void> _checkpointNativeQueue({
    required List<_ContinuedEntryV2> activeEntries,
    required _ContinuedEntryV2 current,
    required int batchTotal,
    required int completedCount,
    required int currentIndex,
    bool paused = false,
  }) async {
    final planProvider = _nativeBackgroundPlans;
    if (planProvider == null) return;

    List<Map<String, Object>> plans = const <Map<String, Object>>[];
    try {
      if (activeEntries.isNotEmpty) {
        plans = planProvider();
      }

      final activeTaskIds = <String>[
        for (final active in activeEntries) active.snapshot.taskId,
      ];
      final signature = activeEntries.isEmpty
          ? 'clear:${current.snapshot.taskId}:${paused ? 'paused' : 'idle'}'
          : 'active:${_nativePlanSignature(plans)}:${activeTaskIds.join(',')}';
      if (signature == _nativeQueueSignature) return;

      var maxConcurrent = 1;
      for (final active in activeEntries) {
        final configured = active.snapshot.configuredConnections;
        final live = active.snapshot.activeConnections;
        final candidate = configured ?? live ?? 1;
        if (candidate > maxConcurrent) maxConcurrent = candidate;
      }

      final snapshot = current.snapshot;
      final record = current.record;
      final totalBytes = snapshot.totalBytes ?? record.expectedBytes ?? -1;
      final transferredBytes =
          snapshot.transferredBytes ??
          (totalBytes > 0 ? (totalBytes * snapshot.progress).round() : 0);
      final accepted = await _service.persistNativeQueue(
        maxConcurrent: maxConcurrent,
        waiters: const <Map<String, Object>>[],
        transferringTaskIds: activeTaskIds,
        pausedTaskIds: paused ? <String>[snapshot.taskId] : const <String>[],
        sessionTaskIds: activeTaskIds,
        sessionCompletedCount: completedCount,
        sessionBatchTotal: batchTotal,
        sessionCurrentTaskId: snapshot.taskId,
        sessionDisplayName: _displayName(record),
        sessionProgress: snapshot.progress,
        sessionTotalBytes: totalBytes,
        sessionTransferredBytes: transferredBytes,
        sessionSpeedBytesPerSecond: _speedBytesPerSecond(snapshot),
        sessionCurrentIndex: currentIndex,
        multipartPlans: plans,
      );

      // A durable ACK with an unavailable native hook is not proof that iOS can
      // refill. Leave the signature unset so the next foreground sample retries
      // capability negotiation. Clearing a previously accepted plan is safe
      // regardless of current hook availability.
      if (accepted != null &&
          (activeEntries.isEmpty || _service.nativePromotionAvailable)) {
        _nativeQueueSignature = signature;
      }
    } finally {
      // Exporting a plan temporarily fences those children in Dart. Once the
      // native snapshot has been attempted, release that fence so foreground
      // slow-start continues. Swift rechecks URLSession task IDs before any
      // background promotion, preventing duplicate writers.
      _releaseNativeBackgroundOffers?.call();
    }
  }

  String _nativePlanSignature(List<Map<String, Object>> plans) {
    final parents = <String>[];
    for (final plan in plans) {
      final parentId = plan['parentTaskId']?.toString() ?? '';
      final maxConcurrent = plan['maxConcurrent']?.toString() ?? '';
      final children = <String>[];
      final rawWaiters = plan['waiters'];
      if (rawWaiters is List) {
        for (final raw in rawWaiters) {
          if (raw is! Map) continue;
          final taskId = raw['taskId']?.toString() ?? '';
          final generation = raw['generation']?.toString() ?? '';
          if (taskId.isNotEmpty) children.add('$taskId:g$generation');
        }
      }
      children.sort();
      parents.add('$parentId:w$maxConcurrent:${children.join(',')}');
    }
    parents.sort();
    return parents.join('|');
  }

  bool _isPackageOwnedActive(_ContinuedEntryV2 entry) {
    if (entry.record.awaitingAdmission) return false;
    return switch (entry.snapshot.status) {
      DownloadTransportStatus.queued ||
      DownloadTransportStatus.running ||
      DownloadTransportStatus.held => true,
      _ => false,
    };
  }

  String _displayName(LogicalDownloadRecordV2 record) {
    final name = p.basenameWithoutExtension(record.destinationPath).trim();
    return name.isEmpty ? 'Download' : name;
  }

  double _speedBytesPerSecond(DownloadTransportSnapshot snapshot) =>
      snapshot.networkSpeedMBps > 0 ? snapshot.networkSpeedMBps * 1000000 : 0;

  void _resetSession() {
    _sessionActive = false;
    _nativeQueueSignature = null;
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
