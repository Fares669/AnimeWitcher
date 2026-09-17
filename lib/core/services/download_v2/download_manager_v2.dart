import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'background_downloader_gateway.dart';
import 'download_integrity_verifier_v2.dart';
import 'download_source_resolver_v2.dart';
import 'download_v2_identity.dart';
import 'download_v2_models.dart';
import 'logical_download_store_v2.dart';

/// Application request for one logical episode download.
///
/// Transport URLs and headers are deliberately absent. Every fresh generation
/// resolves them from [sourceDescriptor] through [DownloadSourceResolverV2].
final class DownloadStartRequestV2 {
  const DownloadStartRequestV2({
    required this.logicalId,
    required this.animeId,
    required this.episodeKey,
    required this.variantKey,
    required this.destinationPath,
    required this.sourceDescriptor,
    required this.allowPause,
    required this.retries,
    required this.parallelChunks,
    this.expectedBytes,
  }) : assert(animeId != ''),
       assert(episodeKey != ''),
       assert(variantKey != ''),
       assert(destinationPath != ''),
       assert(retries >= 0),
       assert(parallelChunks > 0);

  final DownloadLogicalId logicalId;
  final String animeId;
  final String episodeKey;
  final String variantKey;
  final String destinationPath;
  final Map<String, Object?> sourceDescriptor;
  final int? expectedBytes;
  final bool allowPause;
  final int retries;
  final int parallelChunks;
}

/// V2 application coordinator.
///
/// Transport remains fully delegated to [BackgroundDownloaderGateway]. This
/// manager owns logical identity, user intent, duplicate command coalescing,
/// lifecycle ordering, source renewal, startup recovery, integrity validation,
/// and the generation fence that rejects stale package callbacks.
final class DownloadManagerV2 {
  DownloadManagerV2({
    required LogicalDownloadStoreV2 store,
    required BackgroundDownloaderGateway gateway,
    required DownloadSourceResolverV2 sourceResolver,
    DownloadIntegrityVerifierV2? integrityVerifier,
    int Function()? nowMillis,
  }) : _store = store,
       _gateway = gateway,
       _sourceResolver = sourceResolver,
       _integrityVerifier =
           integrityVerifier ?? const DownloadIntegrityVerifierV2(),
       _nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LogicalDownloadStoreV2 _store;
  final BackgroundDownloaderGateway _gateway;
  final DownloadSourceResolverV2 _sourceResolver;
  final DownloadIntegrityVerifierV2 _integrityVerifier;
  final int Function() _nowMillis;

  final _commands = _LogicalCommandQueue();
  final Map<DownloadLogicalId, DownloadStartRequestV2> _requests =
      <DownloadLogicalId, DownloadStartRequestV2>{};
  final Map<DownloadLogicalId, String> _currentTaskIds =
      <DownloadLogicalId, String>{};
  final Map<DownloadLogicalId, DownloadUserIntent> _currentIntents =
      <DownloadLogicalId, DownloadUserIntent>{};
  final Map<DownloadLogicalId, DownloadTransportSnapshot> _snapshots =
      <DownloadLogicalId, DownloadTransportSnapshot>{};
  final Map<String, DownloadTransportHandle> _handlesByTaskId =
      <String, DownloadTransportHandle>{};
  final Map<String, StreamSubscription<DownloadTransportSnapshot>>
  _subscriptionsByTaskId =
      <String, StreamSubscription<DownloadTransportSnapshot>>{};

  Future<void>? _initialization;

  Future<void> initialize() {
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    await _gateway.initialize();
    final rehydrated = await _gateway.rehydrate();
    final byTaskId = <String, DownloadTransportHandle>{
      for (final handle in rehydrated) handle.taskId: handle,
    };
    _handlesByTaskId.addAll(byTaskId);

    final records = await _store.all();
    for (final record in records) {
      _rememberRecord(record);

      if (record.completedAtMillis != null) {
        _snapshots[record.logicalId] = DownloadTransportSnapshot(
          taskId: record.taskId,
          status: DownloadTransportStatus.complete,
          progress: 1,
          transferredBytes: record.expectedBytes,
          totalBytes: record.expectedBytes,
        );
        continue;
      }

      final exactHandle = byTaskId[record.taskId];
      switch (record.intent) {
        case DownloadUserIntent.paused:
          _requests.putIfAbsent(
            record.logicalId,
            () => _requestFromRecord(record),
          );
          if (exactHandle != null) {
            if (!exactHandle.current.isFinal &&
                exactHandle.current.status != DownloadTransportStatus.paused) {
              final paused = await exactHandle.pause();
              if (!paused) await exactHandle.cancel();
            }
            _activateHandle(record.logicalId, exactHandle);
          }
          _snapshots[record.logicalId] = _snapshotWithStatus(
            exactHandle?.current ??
                DownloadTransportSnapshot(
                  taskId: record.taskId,
                  status: DownloadTransportStatus.missing,
                  progress: 0,
                  totalBytes: record.expectedBytes,
                ),
            DownloadTransportStatus.paused,
          );

        case DownloadUserIntent.canceled:
          if (exactHandle != null) {
            if (!exactHandle.current.isFinal) {
              await exactHandle.cancel();
            }
            await _gateway.removeTracking(record.taskId);
            _handlesByTaskId.remove(record.taskId);
          }
          _snapshots[record.logicalId] = DownloadTransportSnapshot(
            taskId: record.taskId,
            status: DownloadTransportStatus.canceled,
            progress: 0,
            totalBytes: record.expectedBytes,
            transferredBytes: record.expectedBytes == null ? null : 0,
          );

        case DownloadUserIntent.active:
          final request = _requests.putIfAbsent(
            record.logicalId,
            () => _requestFromRecord(record),
          );
          if (exactHandle != null && _isRecoverable(exactHandle.current)) {
            _activateHandle(record.logicalId, exactHandle);
          } else {
            await _startFreshGeneration(
              request,
              record,
              previousHandle: exactHandle,
              lookUpPreviousHandle: false,
            );
          }
      }
    }
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
        _rememberRecord(currentRecord);
        final existing = await _exactHandle(currentRecord.taskId);
        if (existing != null && _isRecoverable(existing.current)) {
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
          'Cannot restart $logicalId before source metadata is available',
        );
      }
      final currentRecord = await _store.get(logicalId);
      if (currentRecord == null) {
        throw StateError('Cannot restart missing logical download $logicalId');
      }
      return _startFreshGeneration(request, currentRecord);
    });
  }

  /// Persists paused intent before asking the package to pause.
  ///
  /// If package pause is unsupported or non-resumable, the current transport
  /// is canceled while the durable user intent remains paused. A later resume
  /// will create a fresh generation.
  Future<DownloadTransportSnapshot?> pause(DownloadLogicalId logicalId) {
    return _commands.run(logicalId, () async {
      await initialize();
      final record = await _store.get(logicalId);
      if (record == null) return null;

      final pausedRecord = record.copyWith(
        intent: DownloadUserIntent.paused,
        updatedAtMillis: _nowMillis(),
      );
      await _store.put(pausedRecord);
      _rememberRecord(pausedRecord);

      final handle = await _exactHandle(record.taskId);
      if (handle != null && !handle.current.isFinal) {
        final paused = await handle.pause();
        if (!paused) {
          await handle.cancel();
        }
      }

      final base = handle?.current ??
          _snapshots[logicalId] ??
          DownloadTransportSnapshot(
            taskId: record.taskId,
            status: DownloadTransportStatus.missing,
            progress: 0,
            totalBytes: record.expectedBytes,
          );
      final projected = _snapshotWithStatus(
        base,
        DownloadTransportStatus.paused,
      );
      _snapshots[logicalId] = projected;
      return projected;
    });
  }

  /// Resumes the exact current package transfer when possible, otherwise starts
  /// a fresh generation from byte zero using a newly resolved source.
  Future<DownloadTransportSnapshot> resume(DownloadLogicalId logicalId) {
    return _commands.run(logicalId, () async {
      await initialize();
      final record = await _store.get(logicalId);
      if (record == null) {
        throw StateError('Cannot resume missing logical download $logicalId');
      }
      final request = _requests.putIfAbsent(
        logicalId,
        () => _requestFromRecord(record),
      );

      final activeRecord = record.copyWith(
        intent: DownloadUserIntent.active,
        updatedAtMillis: _nowMillis(),
      );
      await _store.put(activeRecord);
      _rememberRecord(activeRecord);

      final handle = await _exactHandle(record.taskId);
      if (handle != null &&
          handle.current.status == DownloadTransportStatus.paused) {
        final resumed = await handle.resume();
        if (resumed) {
          _activateHandle(logicalId, handle);
          return handle.current;
        }
      }

      return _startFreshGeneration(request, activeRecord);
    });
  }

  /// Cancels the logical download. Cancellation advances the generation fence
  /// before touching the package transport, so late callbacks cannot resurrect
  /// the canceled item.
  Future<void> cancel(DownloadLogicalId logicalId) {
    return _commands.run(logicalId, () async {
      await initialize();
      final record = await _store.get(logicalId);
      if (record == null) return;
      await _cancelRecord(record);
    });
  }

  /// Deletes the logical item and final artifact. Missing artifacts are treated
  /// as already deleted.
  Future<void> delete(DownloadLogicalId logicalId) {
    return _commands.run(logicalId, () async {
      await initialize();
      final record = await _store.get(logicalId);
      if (record == null) return;

      await _cancelRecord(record);
      await _deleteDestination(record.destinationPath);
      await _store.remove(logicalId);
      _currentTaskIds.remove(logicalId);
      _currentIntents.remove(logicalId);
      _snapshots.remove(logicalId);
      _requests.remove(logicalId);
    });
  }

  DownloadTransportSnapshot? snapshotFor(DownloadLogicalId logicalId) =>
      _snapshots[logicalId];

  Future<DownloadTransportSnapshot> _startFreshGeneration(
    DownloadStartRequestV2 request,
    LogicalDownloadRecordV2? previous, {
    bool cancelPreviousEvenIfFinal = false,
    DownloadTransportHandle? previousHandle,
    bool lookUpPreviousHandle = true,
  }) async {
    final obsoleteHandle = previous == null
        ? null
        : previousHandle ??
              (lookUpPreviousHandle
                  ? await _exactHandle(previous.taskId)
                  : null);
    final source = await _sourceResolver.resolve(request.sourceDescriptor);
    final generation = (previous?.generation ?? 0) + 1;
    final taskId = taskIdForGeneration(request.logicalId, generation);
    final updatedAtMillis = _nowMillis();
    final expectedBytes = source.expectedBytes ?? request.expectedBytes;

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
      expectedBytes: expectedBytes,
      updatedAtMillis: updatedAtMillis,
    );

    // Persist/fence before touching the obsolete writer. If the process dies
    // after this point, startup recovery sees an active generation with no
    // handle and can safely recreate only this generation.
    await _store.put(nextRecord);
    _rememberRecord(nextRecord);
    final queued = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.queued,
      progress: 0,
      totalBytes: expectedBytes,
      transferredBytes: expectedBytes == null ? null : 0,
    );
    _snapshots[request.logicalId] = queued;

    if (obsoleteHandle != null &&
        (cancelPreviousEvenIfFinal || !obsoleteHandle.current.isFinal)) {
      final accepted = await obsoleteHandle.cancel();
      if (!accepted && !cancelPreviousEvenIfFinal) {
        throw StateError(
          'Could not stop obsolete transport ${obsoleteHandle.taskId}',
        );
      }
    }

    final handle = await _gateway.start(
      DownloadTaskSpecV2(
        taskId: taskId,
        url: source.url,
        destinationPath: request.destinationPath,
        headers: source.headers,
        allowPause: request.allowPause,
        retries: request.retries,
        parallelChunks: request.parallelChunks,
      ),
    );
    _activateHandle(request.logicalId, handle);
    return handle.current;
  }

  Future<void> _cancelRecord(LogicalDownloadRecordV2 record) async {
    final logicalId = record.logicalId;
    final obsoleteTaskId = record.taskId;
    final handle = await _exactHandle(obsoleteTaskId);
    final fenceGeneration = record.generation + 1;
    final fenceTaskId = taskIdForGeneration(logicalId, fenceGeneration);
    final canceledRecord = record.copyWith(
      generation: fenceGeneration,
      taskId: fenceTaskId,
      intent: DownloadUserIntent.canceled,
      clearCompletedAtMillis: true,
      clearFailure: true,
      updatedAtMillis: _nowMillis(),
    );

    await _store.put(canceledRecord);
    _rememberRecord(canceledRecord);
    _snapshots[logicalId] = DownloadTransportSnapshot(
      taskId: fenceTaskId,
      status: DownloadTransportStatus.canceled,
      progress: 0,
      totalBytes: record.expectedBytes,
      transferredBytes: record.expectedBytes == null ? null : 0,
    );

    if (handle != null && !handle.current.isFinal) {
      await handle.cancel();
    }
    await _gateway.removeTracking(obsoleteTaskId);
    _handlesByTaskId.remove(obsoleteTaskId);
  }

  Future<File> _destinationFile(String destinationPath) async {
    if (p.isAbsolute(destinationPath)) {
      return File(destinationPath);
    }
    final documents = await getApplicationDocumentsDirectory();
    return File(p.join(documents.path, destinationPath));
  }

  Future<void> _deleteDestination(String destinationPath) async {
    final file = await _destinationFile(destinationPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  DownloadStartRequestV2 _requestFromRecord(LogicalDownloadRecordV2 record) {
    return DownloadStartRequestV2(
      logicalId: record.logicalId,
      animeId: record.animeId,
      episodeKey: record.episodeKey,
      variantKey: record.variantKey,
      destinationPath: record.destinationPath,
      sourceDescriptor: Map<String, Object?>.from(record.sourceDescriptor),
      expectedBytes: record.expectedBytes,
      allowPause: true,
      retries: 2,
      parallelChunks: 1,
    );
  }

  void _rememberRecord(LogicalDownloadRecordV2 record) {
    _currentTaskIds[record.logicalId] = record.taskId;
    _currentIntents[record.logicalId] = record.intent;
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
    _consumeSnapshot(logicalId, handle.current);

    final oldSubscription = _subscriptionsByTaskId.remove(handle.taskId);
    if (oldSubscription != null) {
      unawaited(oldSubscription.cancel());
    }

    late final StreamSubscription<DownloadTransportSnapshot> subscription;
    subscription = handle.snapshots.listen((snapshot) {
      _consumeSnapshot(logicalId, snapshot);
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

  void _consumeSnapshot(
    DownloadLogicalId logicalId,
    DownloadTransportSnapshot snapshot,
  ) {
    if (_currentTaskIds[logicalId] != snapshot.taskId) return;

    if (snapshot.status == DownloadTransportStatus.complete) {
      _scheduleCompletionVerification(logicalId, snapshot);
      return;
    }

    final accepted = _acceptSnapshot(logicalId, snapshot);
    if (accepted &&
        snapshot.status == DownloadTransportStatus.failed &&
        snapshot.failureCategory == DownloadFailureCategory.sourceExpired) {
      _scheduleSourceRefresh(logicalId, snapshot.taskId);
    }
  }

  bool _acceptSnapshot(
    DownloadLogicalId logicalId,
    DownloadTransportSnapshot snapshot,
  ) {
    if (_currentTaskIds[logicalId] != snapshot.taskId) return false;
    if (_currentIntents[logicalId] == DownloadUserIntent.paused) {
      _snapshots[logicalId] = _snapshotWithStatus(
        snapshot,
        DownloadTransportStatus.paused,
      );
      return true;
    }
    _snapshots[logicalId] = snapshot;
    return true;
  }

  void _scheduleCompletionVerification(
    DownloadLogicalId logicalId,
    DownloadTransportSnapshot completedSnapshot,
  ) {
    unawaited(
      _commands.run(logicalId, () async {
        final record = await _store.get(logicalId);
        if (record == null ||
            record.intent == DownloadUserIntent.canceled ||
            record.taskId != completedSnapshot.taskId) {
          return;
        }

        if (record.completedAtMillis != null) {
          _snapshots[logicalId] = DownloadTransportSnapshot(
            taskId: record.taskId,
            status: DownloadTransportStatus.complete,
            progress: 1,
            transferredBytes:
                completedSnapshot.transferredBytes ?? record.expectedBytes,
            totalBytes: record.expectedBytes ?? completedSnapshot.totalBytes,
          );
          return;
        }

        final file = await _destinationFile(record.destinationPath);
        final result = await _integrityVerifier.verify(
          file,
          expectedBytes: record.expectedBytes,
        );
        final now = _nowMillis();

        final updated = await _store.mutate(logicalId, (current) {
          if (current == null ||
              current.intent == DownloadUserIntent.canceled ||
              current.taskId != completedSnapshot.taskId) {
            return current;
          }

          if (result.isValid) {
            return current.copyWith(
              completedAtMillis: now,
              clearFailure: true,
              updatedAtMillis: now,
            );
          }

          return current.copyWith(
            clearCompletedAtMillis: true,
            failureCategory: DownloadFailureCategory.integrity,
            failureMessage: result.reason,
            updatedAtMillis: now,
          );
        });

        if (updated == null ||
            updated.taskId != completedSnapshot.taskId ||
            _currentTaskIds[logicalId] != completedSnapshot.taskId) {
          return;
        }

        _rememberRecord(updated);
        if (result.isValid) {
          final bytes = result.bytes!;
          _snapshots[logicalId] = DownloadTransportSnapshot(
            taskId: completedSnapshot.taskId,
            status: DownloadTransportStatus.complete,
            progress: 1,
            transferredBytes: bytes,
            totalBytes: updated.expectedBytes ?? bytes,
          );
          return;
        }

        _snapshots[logicalId] = DownloadTransportSnapshot(
          taskId: completedSnapshot.taskId,
          status: DownloadTransportStatus.failed,
          progress: completedSnapshot.progress,
          transferredBytes: completedSnapshot.transferredBytes,
          totalBytes: updated.expectedBytes ?? completedSnapshot.totalBytes,
          failureCategory: DownloadFailureCategory.integrity,
          failureMessage: result.reason,
        );
      }),
    );
  }

  void _scheduleSourceRefresh(
    DownloadLogicalId logicalId,
    String failedTaskId,
  ) {
    unawaited(
      _commands.run(logicalId, () async {
        final record = await _store.get(logicalId);
        if (record == null ||
            record.intent != DownloadUserIntent.active ||
            record.taskId != failedTaskId) {
          return;
        }
        final request = _requests.putIfAbsent(
          logicalId,
          () => _requestFromRecord(record),
        );
        await _startFreshGeneration(
          request,
          record,
          cancelPreviousEvenIfFinal: true,
        );
      }),
    );
  }
}

bool _isRecoverable(DownloadTransportSnapshot snapshot) {
  return snapshot.status != DownloadTransportStatus.failed &&
      snapshot.status != DownloadTransportStatus.canceled &&
      snapshot.status != DownloadTransportStatus.missing;
}

DownloadTransportSnapshot _snapshotWithStatus(
  DownloadTransportSnapshot snapshot,
  DownloadTransportStatus status,
) {
  return DownloadTransportSnapshot(
    taskId: snapshot.taskId,
    status: status,
    progress: snapshot.progress,
    transferredBytes: snapshot.transferredBytes,
    totalBytes: snapshot.totalBytes,
    failureCategory: snapshot.failureCategory,
    failureMessage: snapshot.failureMessage,
  );
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
