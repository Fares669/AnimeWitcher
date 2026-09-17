import 'dart:async';

import 'background_downloader_gateway.dart';
import 'download_v2_identity.dart';
import 'download_v2_models.dart';
import 'logical_download_store_v2.dart';

/// Application request for one logical episode download.
///
/// The URL/headers are the currently resolved source for this generation.
/// Task 7 replaces that transient source input with DownloadSourceResolver while
/// keeping the durable [sourceDescriptor] as the restart authority.
final class DownloadStartRequestV2 {
  const DownloadStartRequestV2({
    required this.logicalId,
    required this.animeId,
    required this.episodeKey,
    required this.variantKey,
    required this.destinationPath,
    required this.sourceDescriptor,
    required this.url,
    required this.headers,
    required this.allowPause,
    required this.retries,
    required this.parallelChunks,
    this.expectedBytes,
  }) : assert(animeId != ''),
       assert(episodeKey != ''),
       assert(variantKey != ''),
       assert(destinationPath != ''),
       assert(url != ''),
       assert(retries >= 0),
       assert(parallelChunks > 0);

  final DownloadLogicalId logicalId;
  final String animeId;
  final String episodeKey;
  final String variantKey;
  final String destinationPath;
  final Map<String, Object?> sourceDescriptor;
  final String url;
  final Map<String, String> headers;
  final int? expectedBytes;
  final bool allowPause;
  final int retries;
  final int parallelChunks;
}

/// V2 application coordinator.
///
/// Transport remains fully delegated to [BackgroundDownloaderGateway]. This
/// manager owns logical identity, user intent, duplicate command coalescing,
/// and the generation fence that rejects stale package callbacks.
final class DownloadManagerV2 {
  DownloadManagerV2({
    required LogicalDownloadStoreV2 store,
    required BackgroundDownloaderGateway gateway,
    int Function()? nowMillis,
  }) : _store = store,
       _gateway = gateway,
       _nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LogicalDownloadStoreV2 _store;
  final BackgroundDownloaderGateway _gateway;
  final int Function() _nowMillis;

  final _commands = _LogicalCommandQueue();
  final Map<DownloadLogicalId, DownloadStartRequestV2> _requests =
      <DownloadLogicalId, DownloadStartRequestV2>{};
  final Map<DownloadLogicalId, String> _currentTaskIds =
      <DownloadLogicalId, String>{};
  final Map<DownloadLogicalId, DownloadTransportSnapshot> _snapshots =
      <DownloadLogicalId, DownloadTransportSnapshot>{};
  final Map<String, DownloadTransportHandle> _handlesByTaskId =
      <String, DownloadTransportHandle>{};
  final Map<String, StreamSubscription<DownloadTransportSnapshot>>
  _subscriptionsByTaskId =
      <String, StreamSubscription<DownloadTransportSnapshot>>{};

  Future<void>? _initialization;

  Future<void> initialize() {
    return _initialization ??= _gateway.initialize();
  }

  /// Starts a logical download, coalescing concurrent duplicate starts into
  /// the same exact package writer.
  Future<DownloadTransportSnapshot> start(DownloadStartRequestV2 request) {
    _requests[request.logicalId] = request;
    return _commands.run(request.logicalId, () async {
      await initialize();
      final currentRecord = await _store.get(request.logicalId);

      if (currentRecord != null &&
          currentRecord.intent == DownloadUserIntent.active) {
        final existing = await _exactHandle(currentRecord.taskId);
        if (existing != null &&
            existing.current.status != DownloadTransportStatus.failed &&
            existing.current.status != DownloadTransportStatus.canceled) {
          _activateHandle(request.logicalId, existing);
          return existing.current;
        }
      }

      return _startFreshGeneration(request, currentRecord);
    });
  }

  /// Replaces the current transport with a new generation for this logical ID.
  ///
  /// The new generation is durably fenced before the obsolete transfer is
  /// canceled, so every late callback from the old task ID is ignored.
  Future<DownloadTransportSnapshot> restart(DownloadLogicalId logicalId) {
    return _commands.run(logicalId, () async {
      await initialize();
      final request = _requests[logicalId];
      if (request == null) {
        throw StateError(
          'Cannot restart $logicalId before a start request is available',
        );
      }
      final currentRecord = await _store.get(logicalId);
      if (currentRecord == null) {
        throw StateError('Cannot restart missing logical download $logicalId');
      }
      return _startFreshGeneration(request, currentRecord);
    });
  }

  DownloadTransportSnapshot? snapshotFor(DownloadLogicalId logicalId) =>
      _snapshots[logicalId];

  Future<DownloadTransportSnapshot> _startFreshGeneration(
    DownloadStartRequestV2 request,
    LogicalDownloadRecordV2? previous,
  ) async {
    final previousHandle = previous == null
        ? null
        : await _exactHandle(previous.taskId);
    final generation = (previous?.generation ?? 0) + 1;
    final taskId = taskIdForGeneration(request.logicalId, generation);
    final updatedAtMillis = _nowMillis();

    final nextRecord = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: request.logicalId,
      animeId: request.animeId,
      episodeKey: request.episodeKey,
      variantKey: request.variantKey,
      generation: generation,
      taskId: taskId,
      intent: DownloadUserIntent.active,
      destinationPath: request.destinationPath,
      sourceDescriptor: Map<String, Object?>.from(request.sourceDescriptor),
      expectedBytes: request.expectedBytes,
      updatedAtMillis: updatedAtMillis,
    );

    // Persist/fence before touching the obsolete writer. If the process dies
    // after this point, startup recovery sees an active generation with no
    // handle and can safely recreate only this generation.
    await _store.put(nextRecord);
    _currentTaskIds[request.logicalId] = taskId;
    final queued = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.queued,
      progress: 0,
      totalBytes: request.expectedBytes,
      transferredBytes: request.expectedBytes == null ? null : 0,
    );
    _snapshots[request.logicalId] = queued;

    if (previousHandle != null && !previousHandle.current.isFinal) {
      final accepted = await previousHandle.cancel();
      if (!accepted) {
        throw StateError(
          'Could not stop obsolete transport ${previousHandle.taskId}',
        );
      }
    }

    final handle = await _gateway.start(
      DownloadTaskSpecV2(
        taskId: taskId,
        url: request.url,
        destinationPath: request.destinationPath,
        headers: request.headers,
        allowPause: request.allowPause,
        retries: request.retries,
        parallelChunks: request.parallelChunks,
      ),
    );
    _activateHandle(request.logicalId, handle);
    return handle.current;
  }

  Future<DownloadTransportHandle?> _exactHandle(String taskId) async {
    final cached = _handlesByTaskId[taskId];
    if (cached != null) return cached;
    final attached = await _gateway.attach(taskId);
    if (attached != null) {
      _handlesByTaskId[taskId] = attached;
    }
    return attached;
  }

  void _activateHandle(
    DownloadLogicalId logicalId,
    DownloadTransportHandle handle,
  ) {
    _handlesByTaskId[handle.taskId] = handle;
    _currentTaskIds[logicalId] = handle.taskId;
    _acceptSnapshot(logicalId, handle.current);

    final oldSubscription = _subscriptionsByTaskId.remove(handle.taskId);
    if (oldSubscription != null) {
      unawaited(oldSubscription.cancel());
    }

    late final StreamSubscription<DownloadTransportSnapshot> subscription;
    subscription = handle.snapshots.listen((snapshot) {
      _acceptSnapshot(logicalId, snapshot);
      if (snapshot.isFinal) {
        final registered = _subscriptionsByTaskId[snapshot.taskId];
        if (identical(registered, subscription)) {
          _subscriptionsByTaskId.remove(snapshot.taskId);
          unawaited(subscription.cancel());
        }
      }
    });
    _subscriptionsByTaskId[handle.taskId] = subscription;
  }

  void _acceptSnapshot(
    DownloadLogicalId logicalId,
    DownloadTransportSnapshot snapshot,
  ) {
    if (_currentTaskIds[logicalId] != snapshot.taskId) return;
    _snapshots[logicalId] = snapshot;
  }
}

final class _LogicalCommandQueue {
  final Map<DownloadLogicalId, Future<void>> _tails =
      <DownloadLogicalId, Future<void>>{};

  Future<T> run<T>(DownloadLogicalId id, Future<T> Function() action) {
    final previous = _tails[id] ?? Future<void>.value();
    final result = previous.catchError((Object _) {}).then((_) => action());
    final barrier = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _tails[id] = barrier;
    return result.whenComplete(() {
      if (identical(_tails[id], barrier)) {
        _tails.remove(id);
      }
    });
  }
}
