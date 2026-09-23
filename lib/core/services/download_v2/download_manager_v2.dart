import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../download_concurrency.dart';
import '../download_parallel.dart';
import 'background_downloader_gateway.dart';
import 'download_continued_processing_v2.dart';
import 'download_integrity_verifier_v2.dart';
import 'download_source_resolver_v2.dart';
import 'download_v2_diagnostics.dart';
import 'download_v2_identity.dart';
import 'download_v2_models.dart';
import 'logical_download_store_v2.dart';
import 'manga_chapter_manifest_v2.dart';
import 'manga_chapter_transport_v2.dart';

/// Application request for one logical episode download.
///
/// Transport URLs and headers are deliberately absent. Every fresh generation
/// resolves them from [sourceDescriptor] through [DownloadSourceResolverV2].
final class DownloadStartRequestV2 {
  const DownloadStartRequestV2({
    required this.logicalId,
    this.mediaKind = DownloadMediaKind.videoEpisode,
    String? mediaId,
    String? unitKey,
    String? animeId,
    String? episodeKey,
    required this.variantKey,
    required this.destinationPath,
    required this.sourceDescriptor,
    required this.allowPause,
    required this.retries,
    required this.parallelChunks,
    this.expectedBytes,
  }) : mediaId = mediaId ?? animeId ?? '',
       unitKey = unitKey ?? episodeKey ?? '',
       assert((mediaId ?? animeId ?? '') != ''),
       assert((unitKey ?? episodeKey ?? '') != ''),
       assert(variantKey != ''),
       assert(destinationPath != ''),
       assert(retries >= 0),
       assert(parallelChunks > 0);

  final DownloadLogicalId logicalId;
  final DownloadMediaKind mediaKind;
  final String mediaId;
  final String unitKey;
  final String variantKey;
  final String destinationPath;
  final Map<String, Object?> sourceDescriptor;
  final int? expectedBytes;
  final bool allowPause;
  final int retries;
  final int parallelChunks;

  @Deprecated('Use mediaId')
  String get animeId => mediaId;

  @Deprecated('Use unitKey')
  String get episodeKey => unitKey;
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
    MangaChapterPageResolverV2? mangaChapterPageResolver,
    DownloadDiagnosticsV2? diagnostics,
    Iterable<DownloadPresentationObserverV2> presentationObservers =
        const <DownloadPresentationObserverV2>[],
    NativeParallelPauseReadinessV2? parallelPauseReadiness,
    int Function()? maxConcurrentDownloads,
    int Function()? nowMillis,
  }) : _store = store,
       _gateway = gateway,
       _sourceResolver = sourceResolver,
       _integrityVerifier =
           integrityVerifier ?? const DownloadIntegrityVerifierV2(),
       _mangaChapterPageResolver = mangaChapterPageResolver,
       _diagnostics = diagnostics ?? const NoopDownloadDiagnosticsV2(),
       _presentationObservers =
           List<DownloadPresentationObserverV2>.unmodifiable(
             presentationObservers,
           ),
       _parallelPauseReadiness = parallelPauseReadiness,
       _maxConcurrentDownloads =
           maxConcurrentDownloads ?? (() => kDownloadConcurrencyMax),
       _nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LogicalDownloadStoreV2 _store;
  final BackgroundDownloaderGateway _gateway;
  final DownloadSourceResolverV2 _sourceResolver;
  final DownloadIntegrityVerifierV2 _integrityVerifier;
  final MangaChapterPageResolverV2? _mangaChapterPageResolver;
  final DownloadDiagnosticsV2 _diagnostics;
  final List<DownloadPresentationObserverV2> _presentationObservers;
  final NativeParallelPauseReadinessV2? _parallelPauseReadiness;
  final int Function() _maxConcurrentDownloads;
  final int Function() _nowMillis;

  final _commands = _KeyedCommandQueue<DownloadLogicalId>();
  final _destinationCommands = _KeyedCommandQueue<String>();
  final _admissionCommands = _KeyedCommandQueue<String>();
  final Map<DownloadLogicalId, DownloadStartRequestV2> _requests =
      <DownloadLogicalId, DownloadStartRequestV2>{};
  final Map<DownloadLogicalId, String> _currentTaskIds =
      <DownloadLogicalId, String>{};
  final Map<DownloadLogicalId, int> _currentGenerations =
      <DownloadLogicalId, int>{};
  final Map<DownloadLogicalId, DownloadUserIntent> _currentIntents =
      <DownloadLogicalId, DownloadUserIntent>{};
  final Map<DownloadLogicalId, LogicalDownloadRecordV2> _recordsByLogicalId =
      <DownloadLogicalId, LogicalDownloadRecordV2>{};
  final Map<DownloadLogicalId, DownloadTransportSnapshot> _snapshots =
      <DownloadLogicalId, DownloadTransportSnapshot>{};
  final Map<String, DownloadTransportHandle> _handlesByTaskId =
      <String, DownloadTransportHandle>{};
  final Map<String, StreamSubscription<DownloadTransportSnapshot>>
  _subscriptionsByTaskId =
      <String, StreamSubscription<DownloadTransportSnapshot>>{};
  final Set<DownloadLogicalId> _parallelPausePending =
      <DownloadLogicalId>{};
  final Map<DownloadLogicalId, int> _lastPositiveSpeedAtMillis =
      <DownloadLogicalId, int>{};
  final Map<String, int> _lastNativeSpeedProjectionAtMillis = <String, int>{};
  final StreamController<List<LogicalDownloadRecordV2>> _recordChanges =
      StreamController<List<LogicalDownloadRecordV2>>.broadcast();

  Future<void>? _initialization;

  /// Application-owned logical records for presentation. This never exposes
  /// package child transfers, URLs, headers or FileDownloader database rows.
  Stream<List<LogicalDownloadRecordV2>> get records async* {
    await initialize();

    // Subscribe before reading the initial snapshot. A start can persist and
    // publish while Hive is being read; a broadcast event emitted in that gap
    // would otherwise be lost until process recreation.
    final buffered = StreamController<List<LogicalDownloadRecordV2>>();
    final subscription = _recordChanges.stream.listen(
      buffered.add,
      onError: buffered.addError,
    );
    try {
      yield List<LogicalDownloadRecordV2>.unmodifiable(await _store.all());
      yield* buffered.stream;
    } finally {
      await subscription.cancel();
      // A single-subscription controller's close future does not complete until
      // a listener has observed done. records.first can cancel immediately
      // after the initial yield, before yield* ever listens to this buffer.
      // Closing is still required, but awaiting it here would deadlock cancel.
      unawaited(buffered.close());
    }
  }

  Future<void> initialize() {
    final existing = _initialization;
    if (existing != null) return existing;

    final attempt = _initialize();
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

  Future<void> _initialize() async {
    await _gateway.initialize();
    final rehydrated = await _gateway.rehydrate();
    final byTaskId = <String, DownloadTransportHandle>{
      for (final handle in rehydrated) handle.taskId: handle,
    };
    _handlesByTaskId.addAll(byTaskId);

    final records = await _store.all()
      ..sort((a, b) => a.updatedAtMillis.compareTo(b.updatedAtMillis));
    final startupDestinationOwners = <String, DownloadLogicalId>{};
    for (final record in records) {
      _rememberRecord(record);

      try {
        var duplicateStartupDestination = false;
        if (record.intent != DownloadUserIntent.canceled) {
          final destinationKey = await _canonicalDestinationPath(
            record.destinationPath,
          );
          final owner = startupDestinationOwners[destinationKey];
          if (owner == null) {
            startupDestinationOwners[destinationKey] = record.logicalId;
          } else if (owner != record.logicalId) {
            duplicateStartupDestination = true;
          }
        }
        if (record.completedAtMillis != null) {
        final result = await _verifyRecordDestination(
          record,
          repairManga: true,
        );
        if (result.isValid) {
          final snapshot = DownloadTransportSnapshot(
            taskId: record.taskId,
            status: DownloadTransportStatus.complete,
            progress: 1,
            transferredBytes: result.bytes ?? record.expectedBytes,
            totalBytes: record.expectedBytes ?? result.bytes,
          );
          _snapshots[record.logicalId] = snapshot;
          _recordDiagnostic(
            record.logicalId,
            snapshot,
            integrityResult: DownloadV2IntegrityResult.valid,
          );
          continue;
        }

        if (record.mediaKind != DownloadMediaKind.mangaChapter) {
          await _deleteDestination(record.destinationPath);
        }
        final invalidRecord = record.copyWith(
          clearCompletedAtMillis: true,
          failureCategory: DownloadFailureCategory.integrity,
          failureMessage: result.reason,
          updatedAtMillis: _nowMillis(),
        );
        await _store.put(invalidRecord);
        _rememberRecord(invalidRecord);
        final snapshot = DownloadTransportSnapshot(
          taskId: invalidRecord.taskId,
          status: DownloadTransportStatus.failed,
          progress: 0,
          totalBytes: invalidRecord.expectedBytes,
          failureCategory: DownloadFailureCategory.integrity,
          failureMessage: result.reason,
        );
        _snapshots[invalidRecord.logicalId] = snapshot;
        _recordDiagnostic(
          invalidRecord.logicalId,
          snapshot,
          integrityResult: _diagnosticIntegrityResult(result.reason),
        );
        continue;
      }

      final exactHandle = byTaskId[record.taskId];
      if (duplicateStartupDestination &&
          record.intent == DownloadUserIntent.active) {
        final pausedRecord = record.copyWith(
          intent: DownloadUserIntent.paused,
          awaitingAdmission: false,
          updatedAtMillis: _nowMillis(),
        );
        await _store.put(pausedRecord);
        _rememberRecord(pausedRecord);
        _requests.putIfAbsent(
          pausedRecord.logicalId,
          () => _requestFromRecord(pausedRecord),
        );

        DownloadTransportSnapshot? settled;
        if (exactHandle != null && !exactHandle.current.isFinal) {
          settled = await _pauseHandleAndSettle(exactHandle);
        }
        final pauseBase =
            settled ??
            exactHandle?.current ??
            DownloadTransportSnapshot(
              taskId: pausedRecord.taskId,
              status: DownloadTransportStatus.missing,
              progress: 0,
              totalBytes: pausedRecord.expectedBytes,
            );

        if (exactHandle != null &&
            pauseBase.status != DownloadTransportStatus.paused) {
          // Startup found two logical records targeting the same canonical
          // artifact. A duplicate writer that cannot pause safely must not be
          // hidden behind paused presentation while it keeps writing into the
          // owner's destination. Canonical-writer safety wins here: settle that
          // duplicate transport destructively and expose the resulting truth.
          await _settleObsoleteHandle(
            exactHandle,
            cancelEvenIfFinal: false,
          );
          final settledTruth = exactHandle.current;
          _snapshots[pausedRecord.logicalId] = settledTruth;
          _recordDiagnostic(pausedRecord.logicalId, settledTruth);
          continue;
        }

        final projected = _snapshotWithStatus(
          pauseBase,
          DownloadTransportStatus.paused,
        );
        _snapshots[pausedRecord.logicalId] = projected;
        _recordDiagnostic(pausedRecord.logicalId, projected);
        continue;
      }

      switch (record.intent) {
        case DownloadUserIntent.paused:
          _requests.putIfAbsent(
            record.logicalId,
            () => _requestFromRecord(record),
          );
          DownloadTransportSnapshot? settledPause;
          if (exactHandle != null) {
            if (!exactHandle.current.isFinal &&
                exactHandle.current.status != DownloadTransportStatus.paused) {
              settledPause = await _pauseHandleAndSettle(exactHandle);
            }
            _activateHandle(record.logicalId, exactHandle);
          }
          final pauseBase =
              settledPause ??
              exactHandle?.current ??
              DownloadTransportSnapshot(
                taskId: record.taskId,
                status: DownloadTransportStatus.missing,
                progress: 0,
                totalBytes: record.expectedBytes,
              );
          final projected = exactHandle != null &&
                  pauseBase.status != DownloadTransportStatus.paused
              ? pauseBase
              : _snapshotWithStatus(
                  pauseBase,
                  DownloadTransportStatus.paused,
                );
          _snapshots[record.logicalId] = projected;
          _recordDiagnostic(record.logicalId, projected);

        case DownloadUserIntent.canceled:
          if (exactHandle != null) {
            await _settleObsoleteHandle(
              exactHandle,
              cancelEvenIfFinal: false,
            );
            await _gateway.removeTracking(record.taskId);
            _handlesByTaskId.remove(record.taskId);
          }
          final projected = DownloadTransportSnapshot(
            taskId: record.taskId,
            status: DownloadTransportStatus.canceled,
            progress: 0,
            totalBytes: record.expectedBytes,
            transferredBytes: record.expectedBytes == null ? null : 0,
          );
          _snapshots[record.logicalId] = projected;
          _recordDiagnostic(record.logicalId, projected);

        case DownloadUserIntent.active:
          final request = _requests.putIfAbsent(
            record.logicalId,
            () => _requestFromRecord(record),
          );
          if (record.awaitingAdmission) {
            if (exactHandle != null &&
                _isRecoverable(exactHandle.current) &&
                exactHandle.current.status != DownloadTransportStatus.paused &&
                exactHandle.current.status != DownloadTransportStatus.missing) {
              final admitted = record.copyWith(
                awaitingAdmission: false,
                updatedAtMillis: _nowMillis(),
              );
              await _store.put(admitted);
              _rememberRecord(admitted);
              _activateHandle(admitted.logicalId, exactHandle);
            } else {
              final queued = _snapshotWithStatus(
                exactHandle?.current ??
                    DownloadTransportSnapshot(
                      taskId: record.taskId,
                      status: DownloadTransportStatus.queued,
                      progress: 0,
                      totalBytes: record.expectedBytes,
                      transferredBytes:
                          record.expectedBytes == null ? null : 0,
                    ),
                DownloadTransportStatus.queued,
              );
              _snapshots[record.logicalId] = queued;
              _recordDiagnostic(record.logicalId, queued);
            }
          } else if (exactHandle != null &&
              _isRecoverable(exactHandle.current)) {
            if (exactHandle.current.status == DownloadTransportStatus.paused) {
              final resumed = await exactHandle.resume();
              if (!resumed) {
                throw StateError(
                  'Active download could not resume its exact paused transfer',
                );
              }
            }
            _activateHandle(record.logicalId, exactHandle);
          } else if (record.mediaKind == DownloadMediaKind.mangaChapter) {
            await _startExistingMangaGenerationUnsafe(request, record);
          } else {
            await _startFreshGeneration(
              request,
              record,
              previousHandle: exactHandle,
              lookUpPreviousHandle: false,
            );
          }
        }
      } catch (_) {
        final current = await _store.get(record.logicalId) ?? record;
        _rememberRecord(current);
        final failed = DownloadTransportSnapshot(
          taskId: current.taskId,
          status: DownloadTransportStatus.failed,
          progress: _snapshots[current.logicalId]?.progress ?? 0,
          totalBytes: current.expectedBytes,
          failureCategory: DownloadFailureCategory.unknown,
          failureMessage: 'startup recovery failed',
        );
        _snapshots[current.logicalId] = failed;
        _recordDiagnostic(current.logicalId, failed);
      }
    }
    await _publishRecords();
    _scheduleAdmissionPromotion();
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
        if (currentRecord.awaitingAdmission) {
          final queued =
              _snapshots[request.logicalId] ??
              DownloadTransportSnapshot(
                taskId: currentRecord.taskId,
                status: DownloadTransportStatus.queued,
                progress: 0,
                totalBytes: currentRecord.expectedBytes,
                transferredBytes:
                    currentRecord.expectedBytes == null ? null : 0,
              );
          _snapshots[request.logicalId] = queued;
          _recordDiagnostic(request.logicalId, queued);
          _scheduleAdmissionPromotion();
          return queued;
        }

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
  Future<DownloadTransportSnapshot?> pause(DownloadLogicalId logicalId) {
    return _commands.run(logicalId, () async {
      await initialize();
      final record = await _store.get(logicalId);
      if (record == null) return null;

      final pausedRecord = record.copyWith(
        intent: DownloadUserIntent.paused,
        awaitingAdmission: record.awaitingAdmission,
        updatedAtMillis: _nowMillis(),
      );
      // Persist user intent before touching transport so a crash during
      // pause cannot relaunch this download automatically. Keep the in-memory
      // projection active until every package-owned child has actually paused.
      await _store.put(pausedRecord);

      final handle = await _exactHandle(record.taskId);
      DownloadTransportSnapshot? settledPause;
      final readiness = _parallelPauseReadiness;
      final waitsForParallelChildren =
          record.mediaKind != DownloadMediaKind.mangaChapter &&
          record.parallelChunks > 1 &&
          readiness != null &&
          handle is! SelfSettlingParallelDownloadTransportHandleV2;
      if (waitsForParallelChildren) {
        _parallelPausePending.add(logicalId);
      }
      DownloadTransportSnapshot? packagePause;
      try {
        if (handle != null && !handle.current.isFinal) {
          settledPause = await _pauseHandleAndSettle(handle);
        }

        packagePause = settledPause ?? handle?.current ?? _snapshots[logicalId];
        if (waitsForParallelChildren &&
            packagePause?.status == DownloadTransportStatus.paused) {
          final ready = await readiness.waitUntilReady(
            taskId: record.taskId,
            expectedChildren: record.parallelChunks,
            timeout: const Duration(seconds: 15),
          );
          if (!ready) {
            throw StateError(
              'Download parts did not finish pausing; '
              'the download was not exposed as safely paused',
            );
          }
        }
      } finally {
        _parallelPausePending.remove(logicalId);
      }

      _rememberRecord(pausedRecord);
      await _publishRecords();

      final rawBase = packagePause ??
          settledPause ??
          handle?.current ??
          _snapshots[logicalId] ??
          DownloadTransportSnapshot(
            taskId: record.taskId,
            status: DownloadTransportStatus.missing,
            progress: 0,
            totalBytes: record.expectedBytes,
          );
      final base = _snapshotWithPresentationBytes(rawBase);

      if (!record.awaitingAdmission &&
          base.status != DownloadTransportStatus.paused) {
        _snapshots[logicalId] = base;
        _recordDiagnostic(logicalId, base);
        _scheduleAdmissionPromotion();
        if (base.status == DownloadTransportStatus.complete) return base;
        throw StateError(
          'Download did not pause safely; existing progress was preserved',
        );
      }

      final projected = _snapshotWithStatus(
        base,
        DownloadTransportStatus.paused,
      );
      _snapshots[logicalId] = projected;
      _recordDiagnostic(logicalId, projected);
      _scheduleAdmissionPromotion();
      return projected;
    });
  }

  /// Resumes the exact current package transfer when possible.
  ///
  /// Paused intent never falls back to a fresh generation: losing the exact
  /// package handle must preserve the user's existing progress. Active records
  /// may still use normal missing-transfer recovery.
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

      if (record.awaitingAdmission) {
        final activeRecord = record.intent == DownloadUserIntent.active
            ? record
            : record.copyWith(
                intent: DownloadUserIntent.active,
                updatedAtMillis: _nowMillis(),
              );
        if (!identical(activeRecord, record)) {
          await _store.put(activeRecord);
          _rememberRecord(activeRecord);
          await _publishRecords();
        }
        final queued =
            _snapshots[logicalId] ??
            DownloadTransportSnapshot(
              taskId: activeRecord.taskId,
              status: DownloadTransportStatus.queued,
              progress: 0,
              totalBytes: activeRecord.expectedBytes,
              transferredBytes: activeRecord.expectedBytes == null ? null : 0,
            );
        final projected = _snapshotWithStatus(
          queued,
          DownloadTransportStatus.queued,
        );
        _snapshots[logicalId] = projected;
        _recordDiagnostic(logicalId, projected);
        _scheduleAdmissionPromotion();
        return projected;
      }

      final handle = await _exactHandle(record.taskId);
      if (handle != null &&
          handle.current.status == DownloadTransportStatus.paused) {
        if (Platform.isIOS &&
            record.mediaKind != DownloadMediaKind.mangaChapter &&
            record.parallelChunks > 1 &&
            handle is! SelfSettlingParallelDownloadTransportHandleV2) {
          throw StateError(
            'This older iOS package-parallel download cannot be resumed safely. '
            'Existing progress was kept paused; restart it once to migrate to '
            'the durable ranged transport.',
          );
        }
        final destinationKey = await _canonicalDestinationPath(
          request.destinationPath,
        );
        return _destinationCommands.run(destinationKey, () {
          return _admissionCommands.run('episodes', () async {
            final conflict = await _findDestinationConflict(
              destinationKey,
              logicalId,
            );
            if (conflict != null) {
              throw StateError(
                'Canonical destination is already owned by ${conflict.logicalId}',
              );
            }

            if (!await _hasAdmissionSlot(excluding: logicalId)) {
              final waitingRecord = record.copyWith(
                intent: DownloadUserIntent.active,
                awaitingAdmission: true,
                updatedAtMillis: _nowMillis(),
              );
              await _store.put(waitingRecord);
              _rememberRecord(waitingRecord);
              await _publishRecords();
              final queued = _snapshotWithStatus(
                handle.current,
                DownloadTransportStatus.queued,
              );
              _snapshots[logicalId] = queued;
              _recordDiagnostic(logicalId, queued);
              return queued;
            }

            final readiness = _parallelPauseReadiness;
            if (record.mediaKind != DownloadMediaKind.mangaChapter &&
                record.parallelChunks > 1 &&
                readiness != null &&
                handle is! SelfSettlingParallelDownloadTransportHandleV2) {
              final ready = await readiness.waitUntilReady(
                taskId: record.taskId,
                expectedChildren: record.parallelChunks,
              );
              if (!ready) {
                throw StateError(
                  'Download parts are still finishing pause; '
                  'existing progress was kept paused',
                );
              }
            }

            final resumed = await handle.resume();
            if (resumed) {
              final activeRecord = record.copyWith(
                intent: DownloadUserIntent.active,
                awaitingAdmission: false,
                clearFailure: true,
                updatedAtMillis: _nowMillis(),
              );
              await _store.put(activeRecord);
              _rememberRecord(activeRecord);
              await _publishRecords();
              _activateHandle(logicalId, handle);
              return handle.current;
            }

            // A failed explicit resume must never silently destroy
            // partial progress by creating a fresh generation from byte zero.
            // Keep the exact paused generation so a later retry can use any
            // resume data that becomes available.
            throw StateError(
              'Download could not resume without restarting; '
              'the existing progress was kept paused',
            );
          });
        });
      }

      if (record.intent == DownloadUserIntent.paused) {
        if (record.mediaKind == DownloadMediaKind.mangaChapter) {
          final destinationKey = await _canonicalDestinationPath(
            request.destinationPath,
          );
          return _destinationCommands.run(destinationKey, () {
            return _admissionCommands.run('episodes', () async {
              final conflict = await _findDestinationConflict(
                destinationKey,
                logicalId,
              );
              if (conflict != null) {
                throw StateError(
                  'Canonical destination is already owned by ${conflict.logicalId}',
                );
              }
              if (!await _hasAdmissionSlot(excluding: logicalId)) {
                final waitingRecord = record.copyWith(
                  intent: DownloadUserIntent.active,
                  awaitingAdmission: true,
                  parallelChunks: mangaChapterPageConnectionsFromPreference(
                    request.parallelChunks,
                  ),
                  clearFailure: true,
                  updatedAtMillis: _nowMillis(),
                );
                await _store.put(waitingRecord);
                _rememberRecord(waitingRecord);
                await _publishRecords();
                final queued = DownloadTransportSnapshot(
                  taskId: waitingRecord.taskId,
                  status: DownloadTransportStatus.queued,
                  progress: _snapshots[logicalId]?.progress ?? 0,
                  configuredConnections:
                      mangaChapterPageConnectionsFromPreference(
                        request.parallelChunks,
                      ),
                  activeConnections: 0,
                );
                _snapshots[logicalId] = queued;
                _recordDiagnostic(logicalId, queued);
                _scheduleAdmissionPromotion();
                return queued;
              }
              return _startExistingMangaGenerationUnsafe(request, record);
            });
          });
        }
        throw StateError(
          'Download cannot resume safely without its exact paused transfer; '
          'existing progress was kept paused',
        );
      }

      if (record.mediaKind == DownloadMediaKind.mangaChapter) {
        return _startExistingMangaGenerationUnsafe(request, record);
      }
      return _startFreshGeneration(request, record);
    });
  }

  /// Cancels the logical download.
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
      _currentGenerations.remove(logicalId);
      _currentIntents.remove(logicalId);
      _recordsByLogicalId.remove(logicalId);
      _snapshots.remove(logicalId);
      _lastPositiveSpeedAtMillis.remove(logicalId);
      _requests.remove(logicalId);
      await _publishRecords();
    });
  }

  DownloadTransportSnapshot? snapshotFor(DownloadLogicalId logicalId) =>
      _snapshots[logicalId];

  /// Applies read-only native throughput telemetry to the current generation.
  ///
  /// This never changes transport ownership. A child URLSession callback is
  /// accepted only while its parent task ID is the current active V2 writer.
  void observeNativeNetworkSpeed({
    required String taskId,
    required double bytesPerSecond,
  }) {
    if (taskId.isEmpty ||
        !bytesPerSecond.isFinite ||
        bytesPerSecond < 0) {
      return;
    }

    DownloadLogicalId? logicalId;
    for (final entry in _currentTaskIds.entries) {
      if (entry.value == taskId) {
        logicalId = entry.key;
        break;
      }
    }
    if (logicalId == null ||
        _currentIntents[logicalId] != DownloadUserIntent.active) {
      return;
    }

    final current = _snapshots[logicalId];
    if (current == null || current.taskId != taskId || current.isFinal) return;

    // Native emits one speed sample per live child. With 16 connections those
    // samples arrive in a burst and used to create up to 16 parent snapshots,
    // diagnostic writes, and presentation updates in the same second.
    final now = _nowMillis();
    final lastProjection = _lastNativeSpeedProjectionAtMillis[taskId];
    if (lastProjection != null &&
        now >= lastProjection &&
        now - lastProjection < 1000) {
      return;
    }
    _lastNativeSpeedProjectionAtMillis[taskId] = now;

    final speedMBps = bytesPerSecond / 1000000.0;
    if (bytesPerSecond > 0) {
      _lastPositiveSpeedAtMillis[logicalId] = now;
    }
    final totalBytes = current.totalBytes;
    final transferredBytes = _presentationTransferredBytes(
      transferredBytes: current.transferredBytes,
      totalBytes: totalBytes,
      progress: current.progress,
    );
    final remainingBytes =
        totalBytes != null && transferredBytes != null && totalBytes > transferredBytes
        ? totalBytes - transferredBytes
        : 0;
    final timeRemaining = remainingBytes > 0 && bytesPerSecond > 0
        ? Duration(
            milliseconds:
                ((remainingBytes / bytesPerSecond) * 1000).round(),
          )
        : Duration.zero;

    final projected = DownloadTransportSnapshot(
      taskId: current.taskId,
      status:
          bytesPerSecond > 0 &&
              (current.status == DownloadTransportStatus.queued ||
                  current.status == DownloadTransportStatus.held)
          ? DownloadTransportStatus.running
          : current.status,
      progress: current.progress,
      transferredBytes: transferredBytes,
      totalBytes: totalBytes,
      networkSpeedMBps: speedMBps,
      timeRemaining: timeRemaining,
      configuredConnections: current.configuredConnections,
      activeConnections: current.activeConnections,
      failureCategory: current.failureCategory,
      failureMessage: current.failureMessage,
    );
    _snapshots[logicalId] = projected;
    _recordDiagnostic(logicalId, projected);
  }

  /// Returns true only when V2 has a logically completed record and its final
  /// artifact still passes the stable final-file integrity check.
  Future<bool> hasCompletedDownload(DownloadLogicalId logicalId) async {
    await initialize();
    final record = await _store.get(logicalId);
    if (record?.completedAtMillis == null) return false;
    final result = await _verifyRecordDestination(
      record!,
      repairManga: true,
    );
    return result.isValid;
  }

  Future<DownloadTransportSnapshot> _startFreshGeneration(
    DownloadStartRequestV2 request,
    LogicalDownloadRecordV2? previous, {
    bool cancelPreviousEvenIfFinal = false,
    DownloadTransportHandle? previousHandle,
    bool lookUpPreviousHandle = true,
  }) async {
    final destinationKey = await _canonicalDestinationPath(
      request.destinationPath,
    );
    return _destinationCommands.run(destinationKey, () {
      return _admissionCommands.run('episodes', () async {
        final conflict = await _findDestinationConflict(
          destinationKey,
          request.logicalId,
        );
        if (conflict != null) {
          throw StateError(
            'Canonical destination is already owned by ${conflict.logicalId}',
          );
        }

        if (!await _hasAdmissionSlot(excluding: request.logicalId)) {
          return _queueFreshGenerationUnsafe(
            request,
            previous,
            cancelPreviousEvenIfFinal: cancelPreviousEvenIfFinal,
            previousHandle: previousHandle,
            lookUpPreviousHandle: lookUpPreviousHandle,
          );
        }

        return _startFreshGenerationUnsafe(
          request,
          previous,
          cancelPreviousEvenIfFinal: cancelPreviousEvenIfFinal,
          previousHandle: previousHandle,
          lookUpPreviousHandle: lookUpPreviousHandle,
        );
      });
    });
  }

  Future<DownloadTransportSnapshot> _queueFreshGenerationUnsafe(
    DownloadStartRequestV2 request,
    LogicalDownloadRecordV2? previous, {
    bool cancelPreviousEvenIfFinal = false,
    DownloadTransportHandle? previousHandle,
    bool lookUpPreviousHandle = true,
  }) async {
    if (previous != null &&
        previous.intent == DownloadUserIntent.active &&
        previous.awaitingAdmission) {
      _rememberRecord(previous);
      final existing =
          _snapshots[request.logicalId] ??
          DownloadTransportSnapshot(
            taskId: previous.taskId,
            status: DownloadTransportStatus.queued,
            progress: 0,
            totalBytes: previous.expectedBytes,
            transferredBytes: previous.expectedBytes == null ? null : 0,
          );
      _snapshots[request.logicalId] = existing;
      _recordDiagnostic(request.logicalId, existing);
      return existing;
    }

    final obsoleteHandle = previous == null
        ? null
        : previousHandle ??
              (lookUpPreviousHandle ? await _exactHandle(previous.taskId) : null);
    if (obsoleteHandle != null &&
        (cancelPreviousEvenIfFinal || !obsoleteHandle.current.isFinal)) {
      await _settleObsoleteHandle(
        obsoleteHandle,
        cancelEvenIfFinal: cancelPreviousEvenIfFinal,
      );
    }

    final generation = (previous?.generation ?? 0) + 1;
    final taskId = taskIdForGeneration(request.logicalId, generation);
    final isManga = request.mediaKind == DownloadMediaKind.mangaChapter;
    final parallelChunks = isManga
        ? mangaChapterPageConnectionsFromPreference(request.parallelChunks)
        : effectivePackageParallelChunksV2(request.parallelChunks);
    final queuedRecord = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: request.logicalId,
      mediaKind: request.mediaKind,
      mediaId: request.mediaId,
      unitKey: request.unitKey,
      variantKey: request.variantKey,
      generation: generation,
      taskId: taskId,
      intent: DownloadUserIntent.active,
      destinationPath: request.destinationPath,
      sourceDescriptor: Map<String, Object?>.from(request.sourceDescriptor),
      expectedBytes: request.expectedBytes,
      allowPause: request.allowPause,
      retries: request.retries,
      parallelChunks: parallelChunks,
      awaitingAdmission: true,
      updatedAtMillis: _nowMillis(),
    );
    await _store.put(queuedRecord);
    _rememberRecord(queuedRecord);
    await _publishRecords();

    final queued = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.queued,
      progress: 0,
      totalBytes: request.expectedBytes,
      transferredBytes: request.expectedBytes == null ? null : 0,
      configuredConnections: isManga ? parallelChunks : null,
      activeConnections: isManga ? 0 : null,
    );
    _snapshots[request.logicalId] = queued;
    _recordDiagnostic(request.logicalId, queued);
    return queued;
  }

  Future<bool> _hasAdmissionSlot({DownloadLogicalId? excluding}) async {
    final limit = clampDownloadConcurrency(_maxConcurrentDownloads());
    var occupied = 0;
    for (final record in await _store.all()) {
      if (record.logicalId == excluding ||
          record.intent != DownloadUserIntent.active ||
          record.awaitingAdmission ||
          record.completedAtMillis != null) {
        continue;
      }

      final snapshot = _snapshots[record.logicalId];
      final reservesSlot = snapshot == null ||
          snapshot.status == DownloadTransportStatus.queued ||
          snapshot.status == DownloadTransportStatus.running ||
          snapshot.status == DownloadTransportStatus.held ||
          snapshot.status == DownloadTransportStatus.paused;
      if (!reservesSlot) continue;
      occupied++;
      if (occupied >= limit) return false;
    }
    return true;
  }

  void _scheduleAdmissionPromotion() {
    unawaited(_promoteAdmissions());
  }

  Future<void> reconcileAdmission() async {
    await initialize();
    await _promoteAdmissions();
  }

  Future<void> _promoteAdmissions() async {
    while (true) {
      final waiting = (await _store.all())
          .where(
            (record) =>
                record.intent == DownloadUserIntent.active &&
                record.awaitingAdmission,
          )
          .toList()
        ..sort((a, b) => a.updatedAtMillis.compareTo(b.updatedAtMillis));
      if (waiting.isEmpty) return;

      var promoted = false;
      for (final candidate in waiting) {
        final didPromote = await _commands.run(candidate.logicalId, () async {
          final current = await _store.get(candidate.logicalId);
          if (current == null ||
              current.intent != DownloadUserIntent.active ||
              !current.awaitingAdmission) {
            return false;
          }
          final destinationKey = await _canonicalDestinationPath(
            current.destinationPath,
          );
          return _destinationCommands.run(destinationKey, () {
            return _admissionCommands.run('episodes', () async {
              final latest = await _store.get(candidate.logicalId);
              if (latest == null ||
                  latest.intent != DownloadUserIntent.active ||
                  !latest.awaitingAdmission ||
                  !await _hasAdmissionSlot(excluding: latest.logicalId)) {
                return false;
              }

              final conflict = await _findDestinationConflict(
                destinationKey,
                latest.logicalId,
              );
              if (conflict != null) return false;
              try {
                await _promoteQueuedAdmissionUnsafe(latest);
                return true;
              } catch (_) {
                final failedRecord = latest.copyWith(
                  awaitingAdmission: false,
                  failureCategory: DownloadFailureCategory.unknown,
                  failureMessage: 'admission start failed',
                  updatedAtMillis: _nowMillis(),
                );
                await _store.put(failedRecord);
                _rememberRecord(failedRecord);
                final failed = DownloadTransportSnapshot(
                  taskId: failedRecord.taskId,
                  status: DownloadTransportStatus.failed,
                  progress: 0,
                  totalBytes: failedRecord.expectedBytes,
                  failureCategory: DownloadFailureCategory.unknown,
                  failureMessage: 'admission start failed',
                );
                _snapshots[failedRecord.logicalId] = failed;
                _recordDiagnostic(failedRecord.logicalId, failed);
                await _publishRecords();
                return true;
              }
            });
          });
        });
        if (didPromote) {
          promoted = true;
          break;
        }
      }
      if (!promoted) return;
    }
  }

  Future<void> _promoteQueuedAdmissionUnsafe(
    LogicalDownloadRecordV2 record,
  ) async {
    final request = _requests.putIfAbsent(
      record.logicalId,
      () => _requestFromRecord(record),
    );
    final existing = await _exactHandle(record.taskId);
    if (existing != null) {
      if (existing.current.status == DownloadTransportStatus.paused) {
        if (Platform.isIOS &&
            record.mediaKind != DownloadMediaKind.mangaChapter &&
            record.parallelChunks > 1 &&
            existing is! SelfSettlingParallelDownloadTransportHandleV2) {
          await _preservePausedResumeFailure(record, existing);
          return;
        }
        final readiness = _parallelPauseReadiness;
        if (record.mediaKind != DownloadMediaKind.mangaChapter &&
            record.parallelChunks > 1 &&
            readiness != null &&
            existing is! SelfSettlingParallelDownloadTransportHandleV2) {
          final ready = await readiness.waitUntilReady(
            taskId: record.taskId,
            expectedChildren: record.parallelChunks,
          );
          if (!ready) {
            await _preservePausedResumeFailure(record, existing);
            return;
          }
        }

        final resumed = await existing.resume();
        if (resumed) {
          final admitted = record.copyWith(
            awaitingAdmission: false,
            clearFailure: true,
            updatedAtMillis: _nowMillis(),
          );
          await _store.put(admitted);
          _rememberRecord(admitted);
          await _publishRecords();
          _activateHandle(record.logicalId, existing);
          return;
        }

        await _preservePausedResumeFailure(record, existing);
        return;
      }

      if (!existing.current.isFinal &&
          existing.current.status != DownloadTransportStatus.missing) {
        final admitted = record.copyWith(
          awaitingAdmission: false,
          updatedAtMillis: _nowMillis(),
        );
        await _store.put(admitted);
        _rememberRecord(admitted);
        await _publishRecords();
        _activateHandle(record.logicalId, existing);
        return;
      }

      if (record.mediaKind == DownloadMediaKind.mangaChapter) {
        await _startExistingMangaGenerationUnsafe(request, record);
      } else {
        await _startFreshGenerationUnsafe(
          request,
          record,
          previousHandle: existing,
          lookUpPreviousHandle: false,
        );
      }
      return;
    }

    final isManga = request.mediaKind == DownloadMediaKind.mangaChapter;
    final source = isManga
        ? null
        : await _sourceResolver.resolve(request.sourceDescriptor);
    final admitted = record.copyWith(
      awaitingAdmission: false,
      parallelChunks: isManga
          ? mangaChapterPageConnectionsFromPreference(request.parallelChunks)
          : effectivePackageParallelChunksV2(record.parallelChunks),
      expectedBytes: source?.expectedBytes ?? record.expectedBytes,
      clearFailure: true,
      updatedAtMillis: _nowMillis(),
    );
    await _store.put(admitted);
    _rememberRecord(admitted);
    await _publishRecords();

    final queued = DownloadTransportSnapshot(
      taskId: admitted.taskId,
      status: DownloadTransportStatus.queued,
      progress: 0,
      totalBytes: admitted.expectedBytes,
      transferredBytes: admitted.expectedBytes == null ? null : 0,
    );
    _snapshots[admitted.logicalId] = queued;
    _recordDiagnostic(admitted.logicalId, queued);

    final handle = await _startTransportForRequest(
      request: request,
      taskId: admitted.taskId,
      parallelChunks: admitted.parallelChunks,
      expectedBytes: admitted.expectedBytes,
      videoSource: source,
    );
    _activateHandle(admitted.logicalId, handle);
  }

  Future<DownloadTransportSnapshot> _startExistingMangaGenerationUnsafe(
    DownloadStartRequestV2 request,
    LogicalDownloadRecordV2 record,
  ) async {
    if (request.mediaKind != DownloadMediaKind.mangaChapter ||
        record.mediaKind != DownloadMediaKind.mangaChapter) {
      throw StateError('Existing-generation resume is Manga-only.');
    }

    final admitted = record.copyWith(
      intent: DownloadUserIntent.active,
      awaitingAdmission: false,
      parallelChunks: mangaChapterPageConnectionsFromPreference(
        request.parallelChunks,
      ),
      clearFailure: true,
      updatedAtMillis: _nowMillis(),
    );
    await _store.put(admitted);
    _rememberRecord(admitted);
    await _publishRecords();

    final queued = DownloadTransportSnapshot(
      taskId: admitted.taskId,
      status: DownloadTransportStatus.queued,
      progress: _snapshots[admitted.logicalId]?.progress ?? 0,
      configuredConnections: admitted.parallelChunks,
      activeConnections: 0,
    );
    _snapshots[admitted.logicalId] = queued;
    _recordDiagnostic(admitted.logicalId, queued);

    final handle = await _startTransportForRequest(
      request: request,
      taskId: admitted.taskId,
      parallelChunks: admitted.parallelChunks,
      expectedBytes: admitted.expectedBytes,
    );
    _activateHandle(admitted.logicalId, handle);
    return handle.current;
  }

  Future<DownloadTransportHandle> _startTransportForRequest({
    required DownloadStartRequestV2 request,
    required String taskId,
    required int parallelChunks,
    int? expectedBytes,
    ResolvedDownloadSourceV2? videoSource,
  }) async {
    if (request.mediaKind == DownloadMediaKind.mangaChapter) {
      final resolver = _mangaChapterPageResolver;
      final gateway = _gateway;
      if (resolver == null || gateway is! MangaChapterGatewayV2) {
        throw StateError('Manga chapter transport is unavailable.');
      }
      final mangaGateway = gateway as MangaChapterGatewayV2;
      final pages = await resolver.resolve(request.sourceDescriptor);
      return mangaGateway.startMangaChapter(
        MangaChapterTransportSpecV2(
          taskId: taskId,
          mangaId: request.mediaId,
          chapterId: request.unitKey,
          destinationDirectory: request.destinationPath,
          pages: pages,
          retries: request.retries,
          maxConcurrentPages: mangaChapterPageConnectionsFromPreference(
            parallelChunks,
          ),
        ),
      );
    }

    final source =
        videoSource ?? await _sourceResolver.resolve(request.sourceDescriptor);
    return _gateway.start(
      DownloadTaskSpecV2(
        taskId: taskId,
        url: source.url,
        destinationPath: request.destinationPath,
        headers: source.headers,
        allowPause: request.allowPause,
        retries: request.retries,
        parallelChunks: parallelChunks,
        expectedBytes: expectedBytes ?? source.expectedBytes,
      ),
    );
  }

  Future<void> _preservePausedResumeFailure(
    LogicalDownloadRecordV2 record,
    DownloadTransportHandle handle,
  ) async {
    final pausedRecord = record.copyWith(
      intent: DownloadUserIntent.paused,
      awaitingAdmission: false,
      updatedAtMillis: _nowMillis(),
    );
    await _store.put(pausedRecord);
    _rememberRecord(pausedRecord);
    final paused = _snapshotWithStatus(
      handle.current,
      DownloadTransportStatus.paused,
    );
    _snapshots[record.logicalId] = paused;
    _recordDiagnostic(record.logicalId, paused);
    await _publishRecords();
  }

  Future<DownloadTransportSnapshot> _startFreshGenerationUnsafe(
    DownloadStartRequestV2 request,
    LogicalDownloadRecordV2? previous, {
    bool cancelPreviousEvenIfFinal = false,
    DownloadTransportHandle? previousHandle,
    bool lookUpPreviousHandle = true,
  }) async {
    final obsoleteHandle = previous == null
        ? null
        : previousHandle ??
              (lookUpPreviousHandle ? await _exactHandle(previous.taskId) : null);

    if (obsoleteHandle != null &&
        (cancelPreviousEvenIfFinal || !obsoleteHandle.current.isFinal)) {
      await _settleObsoleteHandle(
        obsoleteHandle,
        cancelEvenIfFinal: cancelPreviousEvenIfFinal,
      );
    }

    final isManga = request.mediaKind == DownloadMediaKind.mangaChapter;
    final source = isManga
        ? null
        : await _sourceResolver.resolve(request.sourceDescriptor);
    final generation = (previous?.generation ?? 0) + 1;
    final taskId = taskIdForGeneration(request.logicalId, generation);
    final updatedAtMillis = _nowMillis();
    final expectedBytes = source?.expectedBytes ?? request.expectedBytes;
    final parallelChunks = isManga
        ? mangaChapterPageConnectionsFromPreference(request.parallelChunks)
        : effectivePackageParallelChunksV2(request.parallelChunks);

    final nextRecord = LogicalDownloadRecordV2(
      schemaVersion: kLogicalDownloadSchemaVersionV2,
      logicalId: request.logicalId,
      mediaKind: request.mediaKind,
      mediaId: request.mediaId,
      unitKey: request.unitKey,
      variantKey: request.variantKey,
      generation: generation,
      taskId: taskId,
      intent: DownloadUserIntent.active,
      destinationPath: request.destinationPath,
      sourceDescriptor: Map<String, Object?>.from(request.sourceDescriptor),
      expectedBytes: expectedBytes,
      allowPause: request.allowPause,
      retries: request.retries,
      parallelChunks: parallelChunks,
      updatedAtMillis: updatedAtMillis,
    );

    await _store.put(nextRecord);
    _rememberRecord(nextRecord);
    await _publishRecords();
    final queued = DownloadTransportSnapshot(
      taskId: taskId,
      status: DownloadTransportStatus.queued,
      progress: 0,
      totalBytes: expectedBytes,
      transferredBytes: expectedBytes == null ? null : 0,
    );
    _snapshots[request.logicalId] = queued;
    _recordDiagnostic(request.logicalId, queued);

    final handle = await _startTransportForRequest(
      request: request,
      taskId: taskId,
      parallelChunks: parallelChunks,
      expectedBytes: expectedBytes,
      videoSource: source,
    );
    _activateHandle(request.logicalId, handle);
    return handle.current;
  }

  Future<DownloadTransportSnapshot> _pauseHandleAndSettle(
    DownloadTransportHandle handle,
  ) async {
    if (handle.current.status == DownloadTransportStatus.paused ||
        handle.current.isFinal) {
      return handle.current;
    }

    final settled = Completer<DownloadTransportSnapshot>();
    final subscription = handle.snapshots.listen((snapshot) {
      if ((snapshot.status == DownloadTransportStatus.paused ||
              snapshot.isFinal) &&
          !settled.isCompleted) {
        settled.complete(snapshot);
      }
    });

    try {
      final accepted = await handle.pause();
      if (!accepted) {
        // On iOS a failed pause can mean URLSession could not produce resume
        // data. Canceling here destroys the exact writer and makes a later
        // Resume impossible. Keep transport truth untouched and let pause()
        // surface the failure instead of fabricating a paused state.
        return handle.current;
      }

      final current = handle.current;
      if (current.status == DownloadTransportStatus.paused || current.isFinal) {
        return current;
      }

      try {
        return await settled.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        // Command acceptance is not proof of a durable paused transfer.
        // Never turn a pause timeout into a destructive cancel.
        return handle.current;
      }
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _settleObsoleteHandle(
    DownloadTransportHandle handle, {
    required bool cancelEvenIfFinal,
  }) async {
    if (handle.current.isFinal ||
        handle.current.status == DownloadTransportStatus.missing) {
      if (cancelEvenIfFinal && handle.current.isFinal) {
        await handle.cancel();
      }
      return;
    }

    final settled = Completer<void>();
    final subscription = handle.snapshots.listen((snapshot) {
      if ((snapshot.isFinal ||
              snapshot.status == DownloadTransportStatus.missing) &&
          !settled.isCompleted) {
        settled.complete();
      }
    });

    try {
      final accepted = await handle.cancel();
      if (!accepted) {
        throw StateError(
          'Could not stop obsolete transport ${handle.taskId}',
        );
      }
      if (handle.current.isFinal) return;

      try {
        await settled.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        throw StateError(
          'Obsolete transport ${handle.taskId} did not settle after cancel',
        );
      }
    } finally {
      await subscription.cancel();
    }
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
      awaitingAdmission: false,
      clearCompletedAtMillis: true,
      clearFailure: true,
      updatedAtMillis: _nowMillis(),
    );

    await _store.put(canceledRecord);
    _rememberRecord(canceledRecord);
    await _publishRecords();
    final snapshot = DownloadTransportSnapshot(
      taskId: fenceTaskId,
      status: DownloadTransportStatus.canceled,
      progress: 0,
      totalBytes: record.expectedBytes,
      transferredBytes: record.expectedBytes == null ? null : 0,
    );
    _snapshots[logicalId] = snapshot;
    _recordDiagnostic(logicalId, snapshot);

    if (handle != null) {
      try {
        await _settleObsoleteHandle(
          handle,
          cancelEvenIfFinal: false,
        );
      } catch (_) {
        // A rejected cancel leaves the exact writer authoritative. Restore
        // its durable record and projection instead of claiming it stopped.
        await _store.put(record);
        _rememberRecord(record);
        _activateHandle(logicalId, handle);
        await _publishRecords();
        rethrow;
      }
    }
    await _gateway.removeTracking(obsoleteTaskId);
    _handlesByTaskId.remove(obsoleteTaskId);
    _scheduleAdmissionPromotion();
  }

  Future<String> _canonicalDestinationPath(String destinationPath) async {
    // Android/desktop production paths are absolute. iOS intentionally keeps
    // app-documents-relative paths stable across container relocation; resolve
    // those against Documents only on iOS. Unit tests on other platforms do
    // not need a path_provider plugin just to compare relative keys.
    final normalized = p.normalize(destinationPath);
    if (!p.isAbsolute(normalized) && !Platform.isIOS) {
      return 'relative:$normalized';
    }
    final file = await _destinationFile(normalized);
    final canonical = p.normalize(file.absolute.path);
    return Platform.isWindows ? canonical.toLowerCase() : canonical;
  }

  Future<LogicalDownloadRecordV2?> _findDestinationConflict(
    String canonicalDestination,
    DownloadLogicalId logicalId,
  ) async {
    final records = await _store.all();
    for (final record in records) {
      if (record.logicalId == logicalId ||
          record.intent == DownloadUserIntent.canceled) {
        continue;
      }
      if (await _canonicalDestinationPath(record.destinationPath) ==
          canonicalDestination) {
        return record;
      }
    }
    return null;
  }

  Future<File> _destinationFile(String destinationPath) async {
    if (p.isAbsolute(destinationPath)) return File(destinationPath);
    final documents = await getApplicationDocumentsDirectory();
    return File(p.join(documents.path, destinationPath));
  }

  Future<void> _deleteDestination(String destinationPath) async {
    final file = await _destinationFile(destinationPath);
    if (await file.exists()) {
      await file.delete();
      return;
    }
    final directory = Directory(file.path);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<DownloadIntegrityResult> _verifyRecordDestination(
    LogicalDownloadRecordV2 record, {
    required bool repairManga,
  }) async {
    if (record.mediaKind != DownloadMediaKind.mangaChapter) {
      return _integrityVerifier.verify(
        await _destinationFile(record.destinationPath),
        expectedBytes: record.expectedBytes,
      );
    }

    var result = await _verifyMangaDirectory(record);
    if (result.isValid || !repairManga) return result;

    // The package can publish its terminal callback a few milliseconds before
    // every page/manifest write is visible. Reconcile first, then give those
    // final filesystem writes a bounded settle window instead of deleting the
    // entire completed chapter.
    await _reconcileMangaDirectory(record);
    for (var attempt = 0; attempt < 3; attempt++) {
      result = await _verifyMangaDirectory(record);
      if (result.isValid) return result;
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await _reconcileMangaDirectory(record);
      }
    }
    return result;
  }

  Future<File?> _mangaPageFile(
    Directory directory,
    int index,
  ) async {
    final prefix = (index + 1).toString().padLeft(4, '0');
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      if (p.basename(entity.path).startsWith('$prefix.')) return entity;
    }
    return null;
  }

  Future<void> _reconcileMangaDirectory(
    LogicalDownloadRecordV2 record,
  ) async {
    final destination = await _destinationFile(record.destinationPath);
    final directory = Directory(destination.path);
    if (!await directory.exists()) return;

    final manifest = await MangaChapterManifestV2.readFrom(directory);
    if (manifest == null ||
        manifest.mangaId != record.mediaId ||
        manifest.chapterId != record.unitKey ||
        manifest.pageCount <= 0) {
      return;
    }

    final valid = <int>{};
    for (var index = 0; index < manifest.pageCount; index++) {
      final pageFile = await _mangaPageFile(directory, index);
      if (pageFile == null || !await pageFile.exists()) continue;
      final length = await pageFile.length();
      if (length > 0) {
        valid.add(index);
      } else {
        try {
          await pageFile.delete();
        } catch (_) {}
      }
    }

    await manifest
        .copyWith(
          completedIndexes: valid,
          isComplete: valid.length == manifest.pageCount,
        )
        .writeTo(directory);
  }

  Future<DownloadIntegrityResult> _verifyMangaDirectory(
    LogicalDownloadRecordV2 record,
  ) async {
    final destination = await _destinationFile(record.destinationPath);
    final directory = Directory(destination.path);
    if (!await directory.exists()) {
      return const DownloadIntegrityResult.invalid('missing');
    }

    final manifest = await MangaChapterManifestV2.readFrom(directory);
    if (manifest == null ||
        manifest.mangaId != record.mediaId ||
        manifest.chapterId != record.unitKey ||
        !manifest.isComplete ||
        manifest.pageCount <= 0 ||
        manifest.completedIndexes.length != manifest.pageCount) {
      return const DownloadIntegrityResult.invalid('manifest-incomplete');
    }

    var bytes = 0;
    for (final index in manifest.completedIndexes) {
      final pageFile = await _mangaPageFile(directory, index);
      if (pageFile == null || !await pageFile.exists()) {
        return const DownloadIntegrityResult.invalid('missing-page');
      }
      final length = await pageFile.length();
      if (length <= 0) {
        return const DownloadIntegrityResult.invalid('empty-page');
      }
      bytes += length;
    }
    return bytes > 0
        ? DownloadIntegrityResult.valid(bytes)
        : const DownloadIntegrityResult.invalid('empty');
  }

  DownloadStartRequestV2 _requestFromRecord(LogicalDownloadRecordV2 record) {
    return DownloadStartRequestV2(
      logicalId: record.logicalId,
      mediaKind: record.mediaKind,
      mediaId: record.mediaId,
      unitKey: record.unitKey,
      variantKey: record.variantKey,
      destinationPath: record.destinationPath,
      sourceDescriptor: Map<String, Object?>.from(record.sourceDescriptor),
      expectedBytes: record.expectedBytes,
      allowPause: record.allowPause,
      retries: record.retries,
      parallelChunks: record.parallelChunks,
    );
  }

  void _rememberRecord(LogicalDownloadRecordV2 record) {
    _recordsByLogicalId[record.logicalId] = record;
    _currentTaskIds[record.logicalId] = record.taskId;
    _currentGenerations[record.logicalId] = record.generation;
    _currentIntents[record.logicalId] = record.intent;
  }

  Future<DownloadTransportHandle?> _exactHandle(String taskId) async {
    final cached = _handlesByTaskId[taskId];
    if (cached != null) return cached;
    final attached = await _gateway.attach(taskId);
    if (attached != null) _handlesByTaskId[taskId] = attached;
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
    if (oldSubscription != null) unawaited(oldSubscription.cancel());

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
    if (snapshot.isFinal) {
      _lastNativeSpeedProjectionAtMillis.remove(snapshot.taskId);
    }

    if (snapshot.status == DownloadTransportStatus.complete) {
      _scheduleCompletionVerification(logicalId, snapshot);
      _scheduleAdmissionPromotion();
      return;
    }

    final accepted = _acceptSnapshot(logicalId, snapshot);
    if (!accepted) return;

    if (snapshot.status == DownloadTransportStatus.failed &&
        snapshot.failureCategory == DownloadFailureCategory.sourceExpired) {
      _recordDiagnostic(
        logicalId,
        snapshot,
        sourceRefreshReason: DownloadV2SourceRefreshReason.authorizationExpired,
      );
      _scheduleSourceRefresh(logicalId, snapshot.taskId);
      return;
    }

    if (snapshot.isFinal) {
      _scheduleAdmissionPromotion();
    }
  }

  bool _acceptSnapshot(
    DownloadLogicalId logicalId,
    DownloadTransportSnapshot snapshot,
  ) {
    if (_currentTaskIds[logicalId] != snapshot.taskId) return false;
    if (_parallelPausePending.contains(logicalId) &&
        snapshot.status == DownloadTransportStatus.paused) {
      return false;
    }

    var accepted = snapshot;
    final record = _recordsByLogicalId[logicalId];
    final current = _snapshots[logicalId];
    final lastPositiveSpeedAt = _lastPositiveSpeedAtMillis[logicalId];
    final freshZeroHandoff =
        snapshot.networkSpeedMBps == 0 &&
        snapshot.status == DownloadTransportStatus.running &&
        current != null &&
        current.networkSpeedMBps > 0 &&
        lastPositiveSpeedAt != null &&
        _nowMillis() - lastPositiveSpeedAt < 3000;
    if (record != null &&
        record.mediaKind != DownloadMediaKind.mangaChapter &&
        record.parallelChunks > 1 &&
        (snapshot.networkSpeedMBps < 0 || freshZeroHandoff) &&
        current != null &&
        current.taskId == snapshot.taskId &&
        current.networkSpeedMBps >= 0) {
      final totalBytes = snapshot.totalBytes ?? current.totalBytes;
      final transferredBytes = _presentationTransferredBytes(
        transferredBytes: snapshot.transferredBytes,
        totalBytes: totalBytes,
        progress: snapshot.progress,
      );
      final speedBytesPerSecond = current.networkSpeedMBps * 1000000;
      final remainingBytes =
          totalBytes != null &&
              transferredBytes != null &&
              totalBytes > transferredBytes
          ? totalBytes - transferredBytes
          : 0;
      accepted = DownloadTransportSnapshot(
        taskId: snapshot.taskId,
        status: snapshot.status,
        progress: snapshot.progress,
        transferredBytes: transferredBytes,
        totalBytes: totalBytes,
        networkSpeedMBps: current.networkSpeedMBps,
        timeRemaining: speedBytesPerSecond > 0 && remainingBytes > 0
            ? Duration(
                milliseconds:
                    ((remainingBytes / speedBytesPerSecond) * 1000).round(),
              )
            : Duration.zero,
        configuredConnections:
            snapshot.configuredConnections ?? current.configuredConnections,
        activeConnections:
            snapshot.activeConnections ?? current.activeConnections,
        failureCategory: snapshot.failureCategory,
        failureMessage: snapshot.failureMessage,
      );
    }

    // Transport status stays authoritative even when durable user intent is
    // paused. A failed iOS pause may leave the exact writer running; relabeling
    // later progress/cancel callbacks as paused recreates the same unsafe
    // "fake paused" state that explicit Resume correctly refuses to trust.
    final projected = accepted;
    _snapshots[logicalId] = projected;
    if (projected.networkSpeedMBps > 0) {
      _lastPositiveSpeedAtMillis[logicalId] = _nowMillis();
    }
    _recordDiagnostic(logicalId, projected);
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
          final snapshot = DownloadTransportSnapshot(
            taskId: record.taskId,
            status: DownloadTransportStatus.complete,
            progress: 1,
            transferredBytes:
                completedSnapshot.transferredBytes ?? record.expectedBytes,
            totalBytes: record.expectedBytes ?? completedSnapshot.totalBytes,
          );
          _snapshots[logicalId] = snapshot;
          _recordDiagnostic(
            logicalId,
            snapshot,
            integrityResult: DownloadV2IntegrityResult.valid,
          );
          return;
        }

        final result = await _verifyRecordDestination(
          record,
          repairManga: true,
        );
        if (!result.isValid &&
            record.mediaKind != DownloadMediaKind.mangaChapter) {
          await _deleteDestination(record.destinationPath);
        }
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
        await _publishRecords();

        if (updated == null ||
            updated.taskId != completedSnapshot.taskId ||
            _currentTaskIds[logicalId] != completedSnapshot.taskId) {
          return;
        }

        _rememberRecord(updated);
        if (result.isValid) {
          final bytes = result.bytes!;
          final snapshot = DownloadTransportSnapshot(
            taskId: completedSnapshot.taskId,
            status: DownloadTransportStatus.complete,
            progress: 1,
            transferredBytes: bytes,
            totalBytes: updated.expectedBytes ?? bytes,
          );
          _snapshots[logicalId] = snapshot;
          _recordDiagnostic(
            logicalId,
            snapshot,
            integrityResult: DownloadV2IntegrityResult.valid,
          );
          return;
        }

        final snapshot = DownloadTransportSnapshot(
          taskId: completedSnapshot.taskId,
          status: DownloadTransportStatus.failed,
          progress: completedSnapshot.progress,
          transferredBytes: completedSnapshot.transferredBytes,
          totalBytes: updated.expectedBytes ?? completedSnapshot.totalBytes,
          failureCategory: DownloadFailureCategory.integrity,
          failureMessage: result.reason,
        );
        _snapshots[logicalId] = snapshot;
        _recordDiagnostic(
          logicalId,
          snapshot,
          integrityResult: _diagnosticIntegrityResult(result.reason),
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

  void _recordDiagnostic(
    DownloadLogicalId logicalId,
    DownloadTransportSnapshot snapshot, {
    DownloadV2SourceRefreshReason? sourceRefreshReason,
    DownloadV2IntegrityResult? integrityResult,
  }) {
    final generation = _currentGenerations[logicalId];
    if (generation == null || generation <= 0) return;
    _diagnostics.record(
      DownloadDiagnosticEventV2(
        logicalId: logicalId,
        generation: generation,
        taskId: snapshot.taskId,
        status: snapshot.status,
        progress: snapshot.progress,
        transferredBytes: snapshot.transferredBytes,
        totalBytes: snapshot.totalBytes,
        networkSpeedMBps: snapshot.networkSpeedMBps >= 0
            ? snapshot.networkSpeedMBps
            : null,
        timeRemainingSeconds: snapshot.timeRemaining > Duration.zero
            ? snapshot.timeRemaining.inSeconds
            : null,
        configuredConnections: snapshot.configuredConnections,
        activeConnections: snapshot.activeConnections,
        failureCategory: snapshot.failureCategory,
        holdCategory: snapshot.status == DownloadTransportStatus.held
            ? DownloadV2HoldCategory.packageHeld
            : null,
        sourceRefreshReason: sourceRefreshReason,
        integrityResult: integrityResult,
      ),
    );
    final record = _recordsByLogicalId[logicalId];
    if (record != null && record.taskId == snapshot.taskId) {
      for (final observer in _presentationObservers) {
        unawaited(_observePresentation(observer, record, snapshot));
      }
    }
  }

  Future<void> _observePresentation(
    DownloadPresentationObserverV2 observer,
    LogicalDownloadRecordV2 record,
    DownloadTransportSnapshot snapshot,
  ) async {
    try {
      await observer.observe(record, snapshot);
    } catch (_) {
      // Presentation must never become a transport/lifecycle failure source.
    }
  }

  DownloadV2IntegrityResult _diagnosticIntegrityResult(String? reason) {
    return switch (reason) {
      'missing' => DownloadV2IntegrityResult.missing,
      'empty' => DownloadV2IntegrityResult.empty,
      'size-mismatch' => DownloadV2IntegrityResult.sizeMismatch,
      _ => DownloadV2IntegrityResult.invalid,
    };
  }

  Future<void> _publishRecords() async {
    if (_recordChanges.isClosed) return;
    final records = await _store.all();
    records.sort((a, b) => a.updatedAtMillis.compareTo(b.updatedAtMillis));
    if (!_recordChanges.isClosed) {
      _recordChanges.add(List<LogicalDownloadRecordV2>.unmodifiable(records));
    }
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptionsByTaskId.values) {
      await subscription.cancel();
    }
    _subscriptionsByTaskId.clear();
    for (final observer in _presentationObservers) {
      await observer.dispose();
    }
    _recordsByLogicalId.clear();
    _lastPositiveSpeedAtMillis.clear();
    _lastNativeSpeedProjectionAtMillis.clear();
    await _recordChanges.close();
  }
}

int? _presentationTransferredBytes({
  required int? transferredBytes,
  required int? totalBytes,
  required double progress,
}) {
  if (totalBytes == null || totalBytes <= 0) return transferredBytes;
  final progressBytes = (totalBytes * progress).round();
  if (transferredBytes == null) return progressBytes;
  return transferredBytes >= progressBytes ? transferredBytes : progressBytes;
}

bool _isRecoverable(DownloadTransportSnapshot snapshot) {
  return snapshot.status != DownloadTransportStatus.failed &&
      snapshot.status != DownloadTransportStatus.canceled &&
      snapshot.status != DownloadTransportStatus.missing;
}

DownloadTransportSnapshot _snapshotWithPresentationBytes(
  DownloadTransportSnapshot snapshot,
) {
  final transferredBytes = _presentationTransferredBytes(
    transferredBytes: snapshot.transferredBytes,
    totalBytes: snapshot.totalBytes,
    progress: snapshot.progress,
  );
  if (transferredBytes == snapshot.transferredBytes) return snapshot;
  return DownloadTransportSnapshot(
    taskId: snapshot.taskId,
    status: snapshot.status,
    progress: snapshot.progress,
    transferredBytes: transferredBytes,
    totalBytes: snapshot.totalBytes,
    networkSpeedMBps: snapshot.networkSpeedMBps,
    timeRemaining: snapshot.timeRemaining,
    configuredConnections: snapshot.configuredConnections,
    activeConnections: snapshot.activeConnections,
    failureCategory: snapshot.failureCategory,
    failureMessage: snapshot.failureMessage,
  );
}

DownloadTransportSnapshot _snapshotWithStatus(
  DownloadTransportSnapshot snapshot,
  DownloadTransportStatus status,
) {
  return DownloadTransportSnapshot(
    taskId: snapshot.taskId,
    status: status,
    progress: snapshot.progress,
    transferredBytes: _presentationTransferredBytes(
      transferredBytes: snapshot.transferredBytes,
      totalBytes: snapshot.totalBytes,
      progress: snapshot.progress,
    ),
    totalBytes: snapshot.totalBytes,
    networkSpeedMBps: snapshot.networkSpeedMBps,
    timeRemaining: snapshot.timeRemaining,
    configuredConnections: snapshot.configuredConnections,
    activeConnections: snapshot.activeConnections,
    failureCategory: snapshot.failureCategory,
    failureMessage: snapshot.failureMessage,
  );
}

final class _KeyedCommandQueue<K> {
  final Map<K, Future<void>> _tails = <K, Future<void>>{};

  Future<T> run<T>(K id, Future<T> Function() action) {
    final previous = _tails[id] ?? Future<void>.value();
    final result = previous.catchError((Object _) {}).then((_) => action());
    final barrier = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _tails[id] = barrier;
    return result.whenComplete(() {
      if (identical(_tails[id], barrier)) _tails.remove(id);
    });
  }
}
