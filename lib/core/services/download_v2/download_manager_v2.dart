import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../download_concurrency.dart';
import '../download_parallel.dart';
import '../../utils/download_cleanup.dart';
import '../../utils/local_file_io.dart';
import 'background_downloader_gateway.dart';
import 'download_continued_processing_v2.dart';
import 'download_artwork_store_v2.dart';
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
    required this.mediaId,
    required this.unitKey,
    required this.variantKey,
    required this.destinationPath,
    required this.sourceDescriptor,
    required this.allowPause,
    required this.retries,
    required this.parallelChunks,
    this.expectedBytes,
  }) : assert(mediaId != ''),
       assert(unitKey != ''),
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
  final Set<DownloadLogicalId> _parallelPausePending = <DownloadLogicalId>{};
  final Map<String, Future<bool>> _unsettledResumeAcks = <String, Future<bool>>{};
  final Map<DownloadLogicalId, int> _lastPositiveSpeedAtMillis =
      <DownloadLogicalId, int>{};
  final Map<String, int> _lastNativeSpeedProjectionAtMillis = <String, int>{};
  final Map<String, int> _lastParentSpeedAtMillis = <String, int>{};
  final Map<DownloadLogicalId, int> _sourceRefreshAttempts =
      <DownloadLogicalId, int>{};
  final Map<DownloadLogicalId, Set<int>> _mangaSourceRefreshVerifiedPages =
      <DownloadLogicalId, Set<int>>{};
  final Map<DownloadLogicalId, DownloadTransportSnapshot>
      _firstRenewedPositiveSample = <DownloadLogicalId, DownloadTransportSnapshot>{};
  final StreamController<List<LogicalDownloadRecordV2>> _recordChanges =
      StreamController<List<LogicalDownloadRecordV2>>.broadcast();
  final StreamController<void> _presentationChanges =
      StreamController<void>.broadcast(sync: true);

  Future<void>? _initialization;
  Completer<void>? _localReadiness;
  Future<void>? _admissionPromotion;
  bool _admissionPromotionRequested = false;
  Timer? _admissionPromotionRetryTimer;
  int _admissionPromotionRetryAttempts = 0;
  final Set<DownloadLogicalId> _admissionReservations = <DownloadLogicalId>{};

  /// Application-owned logical records for presentation. This never exposes
  /// package child transfers, URLs, headers or FileDownloader database rows.
  Stream<List<LogicalDownloadRecordV2>> get records async* {
    try {
      await _initializeForLocalAccess();
    } on _DownloadManagerDisposedDuringStartup {
      // Canceling a stream awaits its async* body. Normal manager disposal
      // must finish that cancellation without hiding real startup failures.
      return;
    }

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

  /// Signals the same in-memory snapshot sent to the platform presentation.
  Stream<void> get presentationChanges => _presentationChanges.stream;

  Future<void> initialize() {
    final existing = _initialization;
    if (existing != null) return existing;

    final ready = Completer<void>();
    _localReadiness = ready;
    ready.future.ignore();
    final attempt = _initialize();
    _initialization = attempt;
    unawaited(
      attempt.catchError((Object error, StackTrace stack) {
        if (!ready.isCompleted) ready.completeError(error, stack);
        if (identical(_initialization, attempt)) {
          _initialization = null;
        }
      }),
    );
    return attempt;
  }

  Future<void> _initializeForLocalAccess() {
    initialize().ignore();
    return _localReadiness!.future;
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
    final startupDestinationKeys = <DownloadLogicalId, String>{};
    final indexingErrors = <DownloadLogicalId, Object>{};
    // Preserve oldest-owner precedence before reconciling video rows first.
    for (final record in records) {
      _rememberRecord(record);
      if (record.intent == DownloadUserIntent.canceled) continue;
      try {
        final key = await _canonicalDestinationPath(record.destinationPath);
        startupDestinationKeys[record.logicalId] = key;
        startupDestinationOwners.putIfAbsent(key, () => record.logicalId);
      } catch (error) {
        indexingErrors[record.logicalId] = error;
      }
    }
    final recoveries = <Future<void> Function()>[];
    for (final record in [
      ...records.where((record) => record.mediaKind == DownloadMediaKind.videoEpisode),
      ...records.where((record) => record.mediaKind == DownloadMediaKind.mangaChapter),
    ]) {
      if (record.mediaKind == DownloadMediaKind.mangaChapter) {
        // An unrelated chapter's deep verification must not gate local video controls.
        await _publishLocalReadiness();
      }
      DownloadTransportHandle? startupOwnership;
      void recoverAfterLocalIndex(Future<void> Function() recover) {
        recoveries.add(() async {
          if (_recordChanges.isClosed) return;
          try {
            await recover();
          } catch (error) {
            await _recordStartupFailure(record, startupOwnership, error);
          }
        });
      }

      try {
        final olderParents = <int, String>{};
        for (final recovered in rehydrated) {
          final identity = parseDownloadTaskIdentityV2(recovered.taskId);
          if (identity == null || identity.logicalId != record.logicalId ||
              identity.generation >= record.generation) continue;
          olderParents[identity.generation] = taskIdForGeneration(
            identity.logicalId, identity.generation,
          );
        }
        for (final generation in olderParents.keys.toList()..sort()) {
          final id = olderParents[generation]!;
          startupOwnership = await _exactHandle(id);
          if (startupOwnership == null) continue;
          await _settleObsoleteHandle(startupOwnership, cancelEvenIfFinal: false);
          await _gateway.removeTracking(id);
          _forgetHandle(id);
          startupOwnership = null;
        }
        startupOwnership = record.mediaKind == DownloadMediaKind.mangaChapter
            ? await _exactHandle(record.taskId)
            : _handlesByTaskId[record.taskId];
        final indexingError = indexingErrors[record.logicalId];
        if (indexingError != null) throw indexingError;
        final destinationKey = startupDestinationKeys[record.logicalId];
        final duplicateStartupDestination = destinationKey != null &&
            startupDestinationOwners[destinationKey] != record.logicalId;
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
              completedPages: result.completedPages,
              totalPages: result.totalPages,
              transferredBytes: result.bytes ?? record.expectedBytes,
              totalBytes: record.expectedBytes ?? result.bytes,
            );
            _snapshots[record.logicalId] = snapshot;
            _recordDiagnostic(
              record.logicalId,
              snapshot,
              integrityResult: DownloadV2IntegrityResult.valid,
            );
            await _forgetCompletedTransport(record.taskId);
            continue;
          }

          if (record.mediaKind != DownloadMediaKind.mangaChapter) {
            await _deleteDestination(
            record.destinationPath,
            ownerLogicalId: record.logicalId,
          );
          }
          final invalidRecord = record.copyWith(
            intent: DownloadUserIntent.failed,
            awaitingAdmission: false,
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
            completedPages: result.completedPages,
            totalPages: result.totalPages,
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

        final exactHandle = startupOwnership;
        final pages = record.mediaKind == DownloadMediaKind.mangaChapter && record.intent != DownloadUserIntent.canceled
            ? await _verifyRecordDestination(record, repairManga: false)
            : null;
        final startupSnapshot = pages == null ? exactHandle?.current : _snapshotWithPages(
          exactHandle?.current ?? DownloadTransportSnapshot(
            taskId: record.taskId, status: DownloadTransportStatus.queued, progress: 0,
          ),
          pages.completedPages ?? 0, pages.totalPages,
        );
        if (startupSnapshot != null) _snapshots[record.logicalId] = startupSnapshot;
        if (duplicateStartupDestination &&
            record.intent == DownloadUserIntent.active) {
          final pausedRecord = record.copyWith(
            intent: DownloadUserIntent.paused,
            awaitingAdmission: false,
            updatedAtMillis: _nowMillis(),
          );
          await _store.put(pausedRecord);
          _rememberRecord(pausedRecord);

          DownloadTransportSnapshot? settled;
          if (exactHandle != null && !exactHandle.current.isFinal) {
            try {
              settled = await _pauseHandleAndSettle(exactHandle);
            } catch (_) {
              // A rejected pause is not proof the duplicate writer stopped.
              settled = exactHandle.current;
            }
          }
          final rawPauseBase =
              settled ??
              startupSnapshot ??
              DownloadTransportSnapshot(
                taskId: pausedRecord.taskId,
                status: DownloadTransportStatus.missing,
                progress: 0,
                completedPages: pages?.completedPages,
                totalPages: pages?.totalPages,
                totalBytes: pausedRecord.expectedBytes,
              );

          final pauseBase = pages == null ? rawPauseBase : _snapshotWithPages(
            rawPauseBase, pages.completedPages ?? 0, pages.totalPages,
          );
          if (exactHandle != null &&
              pauseBase.status != DownloadTransportStatus.paused) {
            // Startup found two logical records targeting the same canonical
            // artifact. A duplicate writer that cannot pause safely must not be
            // hidden behind paused presentation while it keeps writing into the
            // owner's destination. Canonical-writer safety wins here: settle that
            // duplicate transport destructively and expose the resulting truth.
            try {
              await _settleObsoleteHandle(exactHandle, cancelEvenIfFinal: false);
            } catch (_) {
              // If even cancel is rejected, the writer remains authoritative.
              // Preserve paused user intent but expose its running transport so
              // admission counts this exact writer until it really settles.
              _activateHandle(pausedRecord.logicalId, exactHandle);
              continue;
            }
            final settledTruth = pages == null ? exactHandle.current : _snapshotWithPages(
              exactHandle.current, pages.completedPages ?? 0, pages.totalPages,
            );
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
            DownloadTransportSnapshot? settledPause;
            if (exactHandle != null) {
              if (!exactHandle.current.isFinal &&
                  exactHandle.current.status !=
                      DownloadTransportStatus.paused) {
                try {
                  settledPause = await _pauseHandleAndSettle(exactHandle);
                } catch (_) {
                  // A rejected startup pause leaves the exact writer alive.
                  // Keep user intent paused and expose transport truth so it
                  // retains admission until a genuine pause callback arrives.
                  settledPause = exactHandle.current;
                }
              }
              _activateHandle(record.logicalId, exactHandle);
            }
            final pauseBase =
                settledPause ??
                startupSnapshot ??
                DownloadTransportSnapshot(
                  taskId: record.taskId,
                  status: DownloadTransportStatus.missing,
                  progress: 0,
                  completedPages: pages?.completedPages,
                  totalPages: pages?.totalPages,
                  totalBytes: record.expectedBytes,
                );
            final withPages = pauseBase.completedPages != null || pages == null
                ? pauseBase
                : _snapshotWithPages(pauseBase, pages.completedPages ?? 0, pages.totalPages);
            final projected =
                exactHandle != null &&
                    pauseBase.status != DownloadTransportStatus.paused
                ? withPages
                : _snapshotWithStatus(
                    withPages,
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
              completedPages: pages?.completedPages,
              totalPages: pages?.totalPages,
              totalBytes: record.expectedBytes,
              transferredBytes: record.expectedBytes == null ? null : 0,
            );
            _snapshots[record.logicalId] = projected;
            _recordDiagnostic(record.logicalId, projected);

          case DownloadUserIntent.failed:
            if (exactHandle != null && _hasLiveOwnership(exactHandle.current)) {
              _activateHandle(record.logicalId, exactHandle);
              continue;
            }
            final failed = DownloadTransportSnapshot(
              taskId: record.taskId,
              status: DownloadTransportStatus.failed,
              progress: 0,
              completedPages: pages?.completedPages,
              totalPages: pages?.totalPages,
              totalBytes: record.expectedBytes,
              failureCategory: record.failureCategory,
              failureMessage: record.failureMessage,
            );
            _snapshots[record.logicalId] = failed;
            _recordDiagnostic(record.logicalId, failed);

          case DownloadUserIntent.active:
            final request = _requestFromRecord(record);
            if (record.awaitingAdmission) {
              if (exactHandle != null &&
                  _isRecoverable(exactHandle.current) &&
                  exactHandle.current.status !=
                      DownloadTransportStatus.paused &&
                  exactHandle.current.status !=
                      DownloadTransportStatus.missing) {
                final admitted = record.copyWith(
                  awaitingAdmission: false,
                  updatedAtMillis: _nowMillis(),
                );
                await _store.put(admitted);
                _rememberRecord(admitted);
                if (exactHandle is MangaChapterTransportHandleV2 && exactHandle.recoveryOnly) {
                  recoverAfterLocalIndex(() async {
                    await _startExistingMangaGenerationUnsafe(request, admitted);
                  });
                } else {
                  _activateHandle(admitted.logicalId, exactHandle);
                }
              } else {
                final queued = _snapshotWithStatus(
                  startupSnapshot ??
                      DownloadTransportSnapshot(
                        taskId: record.taskId,
                        status: DownloadTransportStatus.queued,
                        progress: 0,
                        completedPages: pages?.completedPages,
                        totalPages: pages?.totalPages,
                        totalBytes: record.expectedBytes,
                        transferredBytes: record.expectedBytes == null
                            ? null
                            : 0,
                      ),
                  DownloadTransportStatus.queued,
                );
                _snapshots[record.logicalId] = queued;
                _recordDiagnostic(record.logicalId, queued);
              }
            } else if (exactHandle != null &&
                _isRecoverable(exactHandle.current)) {
              if (exactHandle is MangaChapterTransportHandleV2 && exactHandle.recoveryOnly) {
                recoverAfterLocalIndex(() async {
                  await _resumeRecordUnsafe(record, request);
                });
                continue;
              }
              if (exactHandle.current.status ==
                  DownloadTransportStatus.paused) {
                var resumed = false;
                try {
                  resumed = await _resumeHandleAndAwaitAcknowledgement(record.logicalId, exactHandle);
                } catch (_) {
                  // Preserve the exact generation if native resume throws.
                }
                if (!resumed) {
                  // Never turn a recoverable paused transfer into a failed row
                  // whose Retry action destroys its partial progress.
                  final pausedRecord = record.copyWith(
                    intent: DownloadUserIntent.paused,
                    awaitingAdmission: false,
                    updatedAtMillis: _nowMillis(),
                  );
                  await _store.put(pausedRecord);
                  _rememberRecord(pausedRecord);
                  _activateHandle(pausedRecord.logicalId, exactHandle);
                  continue;
                }
              }
              _activateHandle(record.logicalId, exactHandle);
            } else if (record.mediaKind == DownloadMediaKind.mangaChapter) {
              recoverAfterLocalIndex(() async {
                await _resumeRecordUnsafe(record, request);
              });
            } else {
              recoverAfterLocalIndex(() async {
                await _startFreshGeneration(
                  request,
                  record,
                  previousHandle: exactHandle,
                  lookUpPreviousHandle: false,
                );
              });
            }
        }
      } catch (error) {
        await _recordStartupFailure(record, startupOwnership, error);
      }
    }
    await _cleanupEmptyDownloadFolders(sweepOrphans: true);
    await _publishLocalReadiness();
    for (final recover in recoveries) {
      await recover();
    }
    await _publishRecords();
    _scheduleAdmissionPromotion();
  }

  Future<void> _publishLocalReadiness() async {
    final ready = _localReadiness;
    if (ready == null || ready.isCompleted) return;
    await _publishRecords();
    if (!ready.isCompleted) ready.complete();
  }

  Future<void> _recordStartupFailure(
    LogicalDownloadRecordV2 record,
    DownloadTransportHandle? startupOwnership,
    Object error,
  ) async {
    if (_recordChanges.isClosed) return;
    final current = await _store.get(record.logicalId) ?? record;
    // Recovery can fail for a passing reason, such as launching offline.
    // Keep the user's intent so the next launch tries again; this session
    // shows the failure below, and Retry still starts it at once.
    final failedRecord = current.copyWith(
      intent: record.intent,
      awaitingAdmission: false,
      failureCategory: DownloadFailureCategory.unknown,
      failureMessage: 'startup recovery failed: $error',
      updatedAtMillis: _nowMillis(),
    );
    await _store.put(failedRecord);
    _rememberRecord(failedRecord);
    if (startupOwnership != null && _hasLiveOwnership(startupOwnership.current)) {
      _activateHandle(record.logicalId, startupOwnership);
      return;
    }
    final failed = DownloadTransportSnapshot(
      taskId: current.taskId,
      status: DownloadTransportStatus.failed,
      progress: _snapshots[current.logicalId]?.progress ?? 0,
      completedPages: _snapshots[current.logicalId]?.completedPages,
      totalPages: _snapshots[current.logicalId]?.totalPages,
      totalBytes: current.expectedBytes,
      failureCategory: DownloadFailureCategory.unknown,
      failureMessage: 'startup recovery failed',
    );
    _snapshots[current.logicalId] = failed;
    _recordDiagnostic(current.logicalId, failed);
  }

  /// Starts a logical download, coalescing concurrent duplicate starts into
  /// the same exact package writer.
  Future<DownloadTransportSnapshot> start(DownloadStartRequestV2 request) {
    return _runControlCommand(request.logicalId, 'start', () async {
      await initialize();
      final currentRecord = await _store.get(request.logicalId);

      if (currentRecord != null) {
        if (currentRecord.completedAtMillis != null &&
            await hasCompletedDownload(request.logicalId)) {
          final completed = (currentRecord.mediaKind == DownloadMediaKind.mangaChapter
              ? _snapshots[request.logicalId] : null) ?? DownloadTransportSnapshot(
            taskId: currentRecord.taskId,
            status: DownloadTransportStatus.complete,
            progress: 1.0,
            totalBytes: currentRecord.expectedBytes,
            transferredBytes: currentRecord.expectedBytes,
          );
          _snapshots[request.logicalId] = completed;
          return completed;
        }

        if (currentRecord.intent == DownloadUserIntent.paused &&
            await _hasResumablePausedState(currentRecord)) {
          return _resumeRecordUnsafe(
            currentRecord,
            _requestFromRecord(currentRecord),
          );
        }

        if (currentRecord.intent == DownloadUserIntent.active) {
          _rememberRecord(currentRecord);
          if (currentRecord.awaitingAdmission) {
            final queued =
                _snapshots[request.logicalId] ??
                DownloadTransportSnapshot(
                  taskId: currentRecord.taskId,
                  status: DownloadTransportStatus.queued,
                  progress: 0,
                  totalBytes: currentRecord.expectedBytes,
                  transferredBytes: currentRecord.expectedBytes == null
                      ? null
                      : 0,
                );
            _snapshots[request.logicalId] = queued;
            _recordDiagnostic(request.logicalId, queued);
            await _publishRecords();
            _scheduleAdmissionPromotion();
            return queued;
          }

          final existing = await _recordHandle(currentRecord);
          if (existing != null && _isRecoverable(existing.current)) {
            if (existing is MangaChapterTransportHandleV2 && existing.recoveryOnly) {
              return _resumeRecordUnsafe(currentRecord, _requestFromRecord(currentRecord));
            }
            _activateHandle(request.logicalId, existing);
            await _publishRecords();
            return request.mediaKind == DownloadMediaKind.mangaChapter
                ? (_snapshots[request.logicalId] ?? existing.current) : existing.current;
          }
        }
      }

      _sourceRefreshAttempts.remove(request.logicalId);
      _mangaSourceRefreshVerifiedPages.remove(request.logicalId);

      _firstRenewedPositiveSample.remove(request.logicalId);
      return _startFreshGeneration(request, currentRecord);
    });
  }

  /// Replaces the current transport with a new generation for this logical ID.
  Future<DownloadTransportSnapshot> restart(DownloadLogicalId logicalId) {
    return _runControlCommand(logicalId, 'restart', () async {
      await initialize();
      final currentRecord = await _store.get(logicalId);
      if (currentRecord == null) {
        throw StateError('Cannot restart missing logical download $logicalId');
      }
      final request = _requestFromRecord(currentRecord);
      _sourceRefreshAttempts.remove(logicalId);
      _mangaSourceRefreshVerifiedPages.remove(logicalId);
      _firstRenewedPositiveSample.remove(logicalId);
      return _startFreshGeneration(request, currentRecord);
    });
  }

  /// Persists paused intent before asking the package to pause.
  Future<DownloadTransportSnapshot?> pause(DownloadLogicalId logicalId) {
    return _runControlCommand(logicalId, 'pause', () async {
      await initialize();
      final record = await _store.get(logicalId);
      if (record == null) return null;
      final existingHandle = await _recordHandle(record);
      final existingSnapshot = existingHandle?.current ?? _snapshots[logicalId];
      if (record.completedAtMillis != null || existingSnapshot?.isFinal == true ||
          record.intent == DownloadUserIntent.failed || record.intent == DownloadUserIntent.canceled) {
        return existingSnapshot;
      }
      final reservesWhilePausing =
          !record.awaitingAdmission && record.completedAtMillis == null;
      if (reservesWhilePausing) _admissionReservations.add(logicalId);
      try {
        final pausedRecord = record.copyWith(
          intent: DownloadUserIntent.paused,
          awaitingAdmission: record.awaitingAdmission,
          updatedAtMillis: _nowMillis(),
        );
        // Persist user intent before touching transport so a crash during
        // pause cannot relaunch this download automatically. Keep the in-memory
        // projection active until every package-owned child has actually paused.
        await _store.put(pausedRecord);

        final handle = await _recordHandle(record);
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

          packagePause =
              settledPause ?? handle?.current ?? _snapshots[logicalId];
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
        } catch (error) {
          // A timeout is ambiguous: a late native pause must not be resumed on
          // startup. Keep paused intent and expose live transport truth.
          final restored = _isControlTimeout(error) ? pausedRecord : record;
          await _store.put(restored);
          _rememberRecord(restored);
          final current = handle?.current;
          if (current != null &&
              current.status != DownloadTransportStatus.paused) {
            _snapshots[logicalId] = current;
            _recordDiagnostic(logicalId, current);
          }
          await _publishRecords();
          rethrow;
        } finally {
          _parallelPausePending.remove(logicalId);
        }

        _rememberRecord(pausedRecord);
        await _publishRecords();

        final rawBase =
            packagePause ??
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
          if (!base.isFinal) {
            await _store.put(record);
            _rememberRecord(record);
            await _publishRecords();
          }
          _snapshots[logicalId] = base;
          _recordDiagnostic(logicalId, base);
          _scheduleAdmissionPromotion();
          if (base.status == DownloadTransportStatus.complete) return record.mediaKind == DownloadMediaKind.mangaChapter
              ? (_snapshots[logicalId] ?? base) : base;
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
      } finally {
        if (reservesWhilePausing) _admissionReservations.remove(logicalId);
        _scheduleAdmissionPromotion();
      }
    });
  }

  /// Resumes the exact current package transfer when possible.
  ///
  /// Paused intent never falls back to a fresh generation: losing the exact
  /// package handle must preserve the user's existing progress. Active records
  /// may still use normal missing-transfer recovery.
  Future<DownloadTransportSnapshot> resume(DownloadLogicalId logicalId) {
    return _runControlCommand(logicalId, 'resume', () async {
      await initialize();
      final record = await _store.get(logicalId);
      if (record == null) {
        throw StateError('Cannot resume missing logical download $logicalId');
      }
      final request = _requestFromRecord(record);
      return _resumeRecordUnsafe(record, request);
    });
  }

  /// Whether a paused record still has something to resume: a place in the
  /// queue, Manga pages kept on disk, or its exact transfer. A video whose
  /// transfer the system dropped has none, and starts again instead.
  Future<bool> _hasResumablePausedState(LogicalDownloadRecordV2 record) async {
    if (record.awaitingAdmission ||
        record.mediaKind == DownloadMediaKind.mangaChapter) {
      return true;
    }
    final handle = await _recordHandle(record);
    return handle != null &&
        !handle.current.isFinal &&
        handle.current.status != DownloadTransportStatus.missing;
  }

  Future<DownloadTransportSnapshot> _resumeRecordUnsafe(
    LogicalDownloadRecordV2 record,
    DownloadStartRequestV2 request,
  ) async {
    final logicalId = record.logicalId;
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

    final handle = await _recordHandle(record);
    if (handle is MangaChapterTransportHandleV2 &&
        !handle.recoveryOnly &&
        {
          DownloadTransportStatus.queued,
          DownloadTransportStatus.running,
          DownloadTransportStatus.held,
        }.contains(handle.current.status)) {
      final activeRecord = record.copyWith(
        intent: DownloadUserIntent.active,
        awaitingAdmission: false,
        clearFailure: true,
        updatedAtMillis: _nowMillis(),
      );
      await _store.put(activeRecord);
      _rememberRecord(activeRecord);
      _activateHandle(logicalId, handle);
      await _publishRecords();
      return handle.current;
    }
    if (handle != null &&
        !(handle is MangaChapterTransportHandleV2 && handle.recoveryOnly) &&
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
      return _destinationCommands.run(destinationKey, () async {
        final conflict = await _findDestinationConflict(
          destinationKey,
          logicalId,
        );
        if (conflict != null) {
          throw StateError(
            'Canonical destination is already owned by ${conflict.logicalId}',
          );
        }

        if (!await _reserveAdmission(logicalId)) {
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
          _scheduleAdmissionPromotion();
          return queued;
        }

        try {
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

          final resumed = await _resumeHandleAndAwaitAcknowledgement(logicalId, handle);
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
            return record.mediaKind == DownloadMediaKind.mangaChapter
                ? (_snapshots[logicalId] ?? handle.current) : handle.current;
          }

          // A failed explicit resume must never silently destroy
          // partial progress by creating a fresh generation from byte zero.
          // Keep the exact paused generation so a later retry can use any
          // resume data that becomes available.
          throw StateError(
            'Download could not resume without restarting; '
            'the existing progress was kept paused',
          );
        } finally {
          _admissionReservations.remove(logicalId);
          _scheduleAdmissionPromotion();
        }
      });
    }

    if (record.mediaKind == DownloadMediaKind.mangaChapter) {
      final alreadyWorking =
          handle is MangaChapterTransportHandleV2 &&
          handle.recoveryOnly &&
          {
            DownloadTransportStatus.queued,
            DownloadTransportStatus.running,
            DownloadTransportStatus.held,
          }.contains(handle.current.status);
      if (alreadyWorking) {
        _admissionReservations.add(logicalId);
        _activateHandle(logicalId, handle);
      }
      try {
        final destinationKey = await _canonicalDestinationPath(
          request.destinationPath,
        );
        return await _destinationCommands.run(destinationKey, () async {
          final conflict = await _findDestinationConflict(
            destinationKey,
            logicalId,
          );
          if (conflict != null) {
            throw StateError(
              'Canonical destination is already owned by ${conflict.logicalId}',
            );
          }
          if (!alreadyWorking && !await _reserveAdmission(logicalId)) {
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
              completedPages: _snapshots[logicalId]?.completedPages,
              totalPages: _snapshots[logicalId]?.totalPages,
              configuredConnections: mangaChapterPageConnectionsFromPreference(
                request.parallelChunks,
              ),
              activeConnections: 0,
            );
            _snapshots[logicalId] = queued;
            _recordDiagnostic(logicalId, queued);
            _scheduleAdmissionPromotion();
            return queued;
          }
          try {
            return await _startExistingMangaGenerationUnsafe(request, record);
          } finally {
            if (!alreadyWorking) _admissionReservations.remove(logicalId);
            _scheduleAdmissionPromotion();
          }
        });
      } finally {
        if (alreadyWorking) {
          _admissionReservations.remove(logicalId);
          _scheduleAdmissionPromotion();
        }
      }
    }
    if (record.intent == DownloadUserIntent.paused) {
      throw StateError(
        'Download cannot resume safely without its exact paused transfer; '
        'existing progress was kept paused',
      );
    }

    return _startFreshGeneration(request, record);
  }

  /// Cancels the logical download.
  Future<void> cancel(DownloadLogicalId logicalId) {
    return _runControlCommand(logicalId, 'cancel', () async {
      await initialize();
      final record = await _store.get(logicalId);
      if (record == null) return;
      final destinationKey = await _canonicalDestinationPath(
        record.destinationPath,
      );
      await _destinationCommands.run(destinationKey, () async {
        _admissionReservations.add(logicalId);
        try {
          await _cancelRecord(record);
          await _cleanupEmptyDownloadFolders(removed: record);
        } finally {
          _admissionReservations.remove(logicalId);
          _scheduleAdmissionPromotion();
        }
      });
    });
  }

  /// Deletes the logical item and final artifact. Missing artifacts are treated
  /// as already deleted.
  Future<void> delete(DownloadLogicalId logicalId) {
    return _runControlCommand(logicalId, 'delete', () async {
      await _initializeForLocalAccess();
      var record = await _store.get(logicalId);
      if (record == null) return;
      if (record.completedAtMillis == null ||
          record.mediaKind != DownloadMediaKind.videoEpisode) {
        await initialize();
        record = await _store.get(logicalId);
        if (record == null) return;
      }
      final deleting = record;
      final destinationKey = await _canonicalDestinationPath(
        deleting.destinationPath,
      );
      await _destinationCommands.run(destinationKey, () async {
        _admissionReservations.add(logicalId);
        try {
          if (deleting.completedAtMillis != null) {
            // Keep the completed item retryable until its bytes are deleted.
            final handle = deleting.mediaKind == DownloadMediaKind.videoEpisode
                ? _handlesByTaskId[deleting.taskId]
                : await _recordHandle(deleting);
            if (handle != null) {
              await _settleObsoleteHandle(handle, cancelEvenIfFinal: false);
            }
            await _gateway.removeTracking(deleting.taskId);
            _forgetHandle(deleting.taskId);
          } else {
            await _cancelRecord(deleting);
          }
          await _deleteDestination(
            deleting.destinationPath,
            ownerLogicalId: deleting.logicalId,
            mediaKind: deleting.mediaKind,
            mangaRecord: deleting,
          );
          if (deleting.mediaKind == DownloadMediaKind.videoEpisode) {
            await deleteDownloadArtworkV2(deleting.logicalId.value, legacyTaskId: deleting.taskId);
          }
          await _store.remove(logicalId);
          _currentTaskIds.remove(logicalId);
          _currentGenerations.remove(logicalId);
          _currentIntents.remove(logicalId);
          _recordsByLogicalId.remove(logicalId);
          _snapshots.remove(logicalId);
          _lastPositiveSpeedAtMillis.remove(logicalId);
          await _cleanupEmptyDownloadFolders(removed: deleting);
          await _publishRecords();
        } catch (_) {
          final retained = await _store.get(logicalId);
          final settled = _snapshots[logicalId];
          if (retained?.intent == DownloadUserIntent.canceled &&
              retained?.taskId == deleting.taskId &&
              settled?.taskId == deleting.taskId &&
              settled?.status == DownloadTransportStatus.canceled) {
            await _markCanceledCleanupFailure(retained!);
          }
          rethrow;
        } finally {
          _admissionReservations.remove(logicalId);
          _scheduleAdmissionPromotion();
        }
      });
    });
  }

  /// Legacy files still share title folders with current V2 downloads.
  Future<bool> deleteLegacyDownloadedVideo(File file) async {
    await _initializeForLocalAccess();
    final destinationKey = await _canonicalDestinationPath(file.path);
    return _destinationCommands.run(destinationKey, () async {
      if (_hasUnmappedDownloadWriter() ||
          await _findDestinationConflict(destinationKey, null) != null) {
        return false;
      }
      final deleted = await deleteDownloadedVideo(
        file,
        isProtected: (_) => true,
      );
      if (deleted) {
        await _cleanupEmptyDownloadFolders(deletedFile: file);
      }
      return deleted;
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
    if (taskId.isEmpty || !bytesPerSecond.isFinite || bytesPerSecond < 0) {
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
    // All bytes have arrived; late child samples cannot revive network speed
    // while the parent is assembling or verifying the local file.
    if (current.progress >= 1) return;

    // Native emits one speed sample per live child. With 16 connections those
    // samples arrive in a burst and used to create up to 16 parent snapshots,
    // diagnostic writes, and presentation updates in the same second.
    final now = _nowMillis();
    final parentSampleAt = _lastParentSpeedAtMillis[taskId];
    // Parent telemetry already aggregates every child. Native rates are a
    // fallback, not a second writer that can replace a fresh aggregate ETA.
    if (parentSampleAt != null &&
        now >= parentSampleAt &&
        now - parentSampleAt < 3000) {
      return;
    }
    if (bytesPerSecond > 0) {
      final lastProjection = _lastNativeSpeedProjectionAtMillis[taskId];
      if (lastProjection != null &&
          now >= lastProjection &&
          now - lastProjection < 1000) {
        return;
      }
      _lastNativeSpeedProjectionAtMillis[taskId] = now;
      _lastPositiveSpeedAtMillis[logicalId] = now;
    } else {
      // Zero is a state transition, not burst telemetry. Publish it
      // immediately and let the next positive sample recover immediately too.
      _lastNativeSpeedProjectionAtMillis.remove(taskId);
    }

    final speedMBps = bytesPerSecond / 1000000.0;
    final totalBytes = current.totalBytes;
    final transferredBytes = current.completedPages != null ? current.transferredBytes : _presentationTransferredBytes(
      transferredBytes: current.transferredBytes,
      totalBytes: totalBytes,
      progress: current.progress,
    );
    final remainingBytes =
        totalBytes != null &&
            transferredBytes != null &&
            totalBytes > transferredBytes
        ? totalBytes - transferredBytes
        : 0;
    final timeRemaining = remainingBytes > 0 && bytesPerSecond > 0
        ? Duration(
            milliseconds: ((remainingBytes / bytesPerSecond) * 1000).round(),
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
      completedPages: current.completedPages,
      totalPages: current.totalPages,
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
    final result = await _verifyRecordDestination(record!, repairManga: true);
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
    return _destinationCommands.run(destinationKey, () async {
      final conflict = await _findDestinationConflict(
        destinationKey,
        request.logicalId,
      );
      if (conflict != null) {
        throw StateError(
          'Canonical destination is already owned by ${conflict.logicalId}',
        );
      }

      if (!await _reserveAdmission(request.logicalId)) {
        return _queueFreshGenerationUnsafe(
          request,
          previous,
          cancelPreviousEvenIfFinal: cancelPreviousEvenIfFinal,
          previousHandle: previousHandle,
          lookUpPreviousHandle: lookUpPreviousHandle,
        );
      }

      try {
        return await _startFreshGenerationUnsafe(
          request,
          previous,
          cancelPreviousEvenIfFinal: cancelPreviousEvenIfFinal,
          previousHandle: previousHandle,
          lookUpPreviousHandle: lookUpPreviousHandle,
        );
      } finally {
        _admissionReservations.remove(request.logicalId);
        _scheduleAdmissionPromotion();
      }
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
              (lookUpPreviousHandle
                  ? await _recordHandle(previous)
                  : null);
    if (obsoleteHandle != null) {
      await _settleObsoleteHandle(
        obsoleteHandle,
        cancelEvenIfFinal: cancelPreviousEvenIfFinal,
      );
    }

    if (previous != null && previous.mediaKind == DownloadMediaKind.mangaChapter) {
      final oldId = obsoleteHandle?.taskId ?? previous.taskId;
      await _gateway.removeTracking(oldId);
      _forgetHandle(oldId);
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
      completedPages: isManga ? (_snapshots[request.logicalId]?.completedPages ?? 0) : null,
      totalPages: isManga ? _snapshots[request.logicalId]?.totalPages : null,
      totalBytes: request.expectedBytes,
      transferredBytes: request.expectedBytes == null ? null : 0,
      configuredConnections: isManga ? parallelChunks : null,
      activeConnections: isManga ? 0 : null,
    );
    _snapshots[request.logicalId] = queued;
    _recordDiagnostic(request.logicalId, queued);
    _scheduleAdmissionPromotion();
    return queued;
  }

  Future<bool> _hasAdmissionSlot({DownloadLogicalId? excluding}) async {
    final limit = clampDownloadConcurrency(_maxConcurrentDownloads());
    final occupied = _admissionReservations
        .where((id) => id != excluding)
        .toSet();
    for (final record in await _store.all()) {
      if (record.logicalId == excluding || record.completedAtMillis != null) {
        continue;
      }

      final snapshot = _snapshots[record.logicalId];
      final transport = _handlesByTaskId[_currentTaskIds[record.logicalId] ?? record.taskId]?.current;
      final ownsWorkingTransport = transport != null &&
          {DownloadTransportStatus.queued, DownloadTransportStatus.running,
            DownloadTransportStatus.held}.contains(transport.status);
      final pausedWriterIsLive =
          (record.intent == DownloadUserIntent.paused ||
              record.intent == DownloadUserIntent.canceled ||
              record.intent == DownloadUserIntent.failed) &&
          (snapshot?.status == DownloadTransportStatus.queued ||
              snapshot?.status == DownloadTransportStatus.running ||
              snapshot?.status == DownloadTransportStatus.held);
      if (!ownsWorkingTransport && !pausedWriterIsLive &&
          (record.intent != DownloadUserIntent.active ||
              record.awaitingAdmission)) {
        continue;
      }
      final reservesSlot =
          ownsWorkingTransport || snapshot == null ||
          snapshot.status == DownloadTransportStatus.queued ||
          snapshot.status == DownloadTransportStatus.running ||
          snapshot.status == DownloadTransportStatus.held ||
          snapshot.status == DownloadTransportStatus.paused;
      if (!reservesSlot) continue;
      occupied.add(record.logicalId);
    }
    return occupied.length < limit;
  }

  Future<bool> _reserveAdmission(DownloadLogicalId logicalId) {
    return _admissionCommands.run('episodes', () async {
      if (!await _hasAdmissionSlot(excluding: logicalId)) return false;
      _admissionReservations.add(logicalId);
      return true;
    });
  }

  void _scheduleAdmissionPromotion() {
    if (_recordChanges.isClosed) return;
    final existing = _admissionPromotion;
    final promotion = _promoteAdmissions();
    if (existing != null && identical(existing, promotion)) return;

    unawaited(
      promotion
          .then<void>((_) {
            _admissionPromotionRetryAttempts = 0;
            _admissionPromotionRetryTimer?.cancel();
            _admissionPromotionRetryTimer = null;
          })
          .catchError((Object error, StackTrace _) {
            final attempt = _admissionPromotionRetryAttempts + 1;
            _admissionPromotionRetryAttempts = attempt;
            _diagnostics.recordTransport('admission.promotionFailed', {
              'errorType': error.runtimeType.toString(),
              'count': attempt,
            });
            if (_recordChanges.isClosed ||
                attempt >= 3 ||
                _admissionPromotionRetryTimer != null) {
              return;
            }
            _admissionPromotionRetryTimer = Timer(
              Duration(milliseconds: 100 << (attempt - 1)),
              () {
                _admissionPromotionRetryTimer = null;
                _scheduleAdmissionPromotion();
              },
            );
          }),
    );
  }

  Future<void> reconcileAdmission() async {
    await initialize();
    await _promoteAdmissions();
  }

  Future<void> _promoteAdmissions() {
    _admissionPromotionRequested = true;
    final existing = _admissionPromotion;
    if (existing != null) return existing;
    late final Future<void> attempt;
    attempt = _drainAdmissionPromotions().whenComplete(() {
      if (identical(_admissionPromotion, attempt)) _admissionPromotion = null;
    });
    _admissionPromotion = attempt;
    return attempt;
  }

  Future<void> _drainAdmissionPromotions() async {
    do {
      _admissionPromotionRequested = false;
      await _promoteAdmissionsPass();
    } while (_admissionPromotionRequested);
  }

  Future<void> _promoteAdmissionsPass() async {
    while (true) {
      final waiting =
          (await _store.all())
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
          return _destinationCommands.run(destinationKey, () async {
            final latest = await _store.get(candidate.logicalId);
            if (latest == null ||
                latest.intent != DownloadUserIntent.active ||
                !latest.awaitingAdmission) {
              return false;
            }

            final conflict = await _findDestinationConflict(
              destinationKey,
              latest.logicalId,
            );
            if (conflict != null) return false;
            if (!await _reserveAdmission(latest.logicalId)) return false;
            try {
              await _promoteQueuedAdmissionUnsafe(latest);
              return true;
            } catch (_) {
              final current = await _store.get(latest.logicalId);
              if (current == null ||
                  current.intent == DownloadUserIntent.failed)
                return true;
              final failedRecord = current.copyWith(
                intent: DownloadUserIntent.failed,
                awaitingAdmission: false,
                clearCompletedAtMillis: true,
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
                completedPages: _snapshots[failedRecord.logicalId]?.completedPages,
                totalPages: _snapshots[failedRecord.logicalId]?.totalPages,
                totalBytes: failedRecord.expectedBytes,
                failureCategory: DownloadFailureCategory.unknown,
                failureMessage: 'admission start failed',
              );
              _snapshots[failedRecord.logicalId] = failed;
              _recordDiagnostic(failedRecord.logicalId, failed);
              await _publishRecords();
              return true;
            } finally {
              _admissionReservations.remove(latest.logicalId);
              _scheduleAdmissionPromotion();
            }
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
    final request = _requestFromRecord(record);
    final existing = await _recordHandle(record);
    if (existing != null) {
      if (existing is MangaChapterTransportHandleV2 && existing.recoveryOnly) {
        await _startExistingMangaGenerationUnsafe(request, record);
        return;
      }
      if (existing.current.status == DownloadTransportStatus.paused) {
        if (Platform.isIOS &&
            record.mediaKind != DownloadMediaKind.mangaChapter &&
            record.parallelChunks > 1 &&
            existing is! SelfSettlingParallelDownloadTransportHandleV2) {
          await _preservePausedResumeFailure(record, existing);
          return;
        }
        final bool resumed;
        try {
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
          resumed = await _resumeHandleAndAwaitAcknowledgement(record.logicalId, existing);
        } catch (_) {
          // A thrown resume is no proof the progress is gone. Keep it paused
          // rather than failed, whose Retry would start from byte zero.
          await _preservePausedResumeFailure(record, existing);
          return;
        }
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
      completedPages: isManga ? (_snapshots[request.logicalId]?.completedPages ?? 0) : null,
      totalPages: isManga ? _snapshots[request.logicalId]?.totalPages : null,
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
      completedPages: _snapshots[admitted.logicalId]?.completedPages,
      totalPages: _snapshots[admitted.logicalId]?.totalPages,
      configuredConnections: admitted.parallelChunks,
      activeConnections: 0,
    );
    _snapshots[admitted.logicalId] = queued;
    _recordDiagnostic(admitted.logicalId, queued);

    try {
      final handle = await _startTransportForRequest(
        request: request,
        taskId: admitted.taskId,
        parallelChunks: admitted.parallelChunks,
        expectedBytes: admitted.expectedBytes,
      );
      _activateHandle(admitted.logicalId, handle);
      return _snapshots[admitted.logicalId] ?? handle.current;
    } catch (e) {
      final failedRecord = admitted.copyWith(
        intent: DownloadUserIntent.failed,
        awaitingAdmission: false,
        failureCategory: DownloadFailureCategory.unknown,
        failureMessage: e.toString(),
        updatedAtMillis: _nowMillis(),
      );
      await _store.put(failedRecord);
      _rememberRecord(failedRecord);
      await _publishRecords();
      final failedSnapshot = DownloadTransportSnapshot(
        taskId: admitted.taskId,
        status: DownloadTransportStatus.failed,
        progress: _snapshots[admitted.logicalId]?.progress ?? 0,
        completedPages: _snapshots[admitted.logicalId]?.completedPages,
        totalPages: _snapshots[admitted.logicalId]?.totalPages,
        totalBytes: admitted.expectedBytes,
        failureCategory: DownloadFailureCategory.unknown,
        failureMessage: e.toString(),
      );
      _snapshots[admitted.logicalId] = failedSnapshot;
      _recordDiagnostic(admitted.logicalId, failedSnapshot);
      _scheduleAdmissionPromotion();
      rethrow;
    }
  }

  Future<DownloadTransportHandle> _startTransportForRequest({
    required DownloadStartRequestV2 request,
    required String taskId,
    required int parallelChunks,
    int? expectedBytes,
    ResolvedDownloadSourceV2? videoSource,
  }) async {
    try {
      if (request.mediaKind == DownloadMediaKind.mangaChapter) {
        final resolver = _mangaChapterPageResolver;
        final gateway = _gateway;
        if (resolver == null || gateway is! MangaChapterGatewayV2) {
          throw StateError('Manga chapter transport is unavailable.');
        }
        final mangaGateway = gateway as MangaChapterGatewayV2;
        final pages = await resolver.resolve(request.sourceDescriptor);
        return await mangaGateway.startMangaChapter(
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
      return await _gateway.start(
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
    } catch (_) {
      // A native writer may begin before its start acknowledgement fails.
      // Adopt that exact generation instead of freeing admission for a live writer.
      DownloadTransportHandle? started;
      try {
        started = await _exactHandle(taskId);
      } catch (_) {
        // Without proven ownership the original failure remains authoritative.
      }
      if (started != null &&
          !started.current.isFinal &&
          started.current.status != DownloadTransportStatus.missing) {
        return started;
      }
      rethrow;
    }
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
    // A native resume may start the writer and then throw before confirming.
    // Preserve paused *intent*, but never invent a paused transport snapshot.
    final truth = handle.current;
    _snapshots[record.logicalId] = truth;
    _recordDiagnostic(record.logicalId, truth);
    await _publishRecords();
    if (!truth.isFinal && truth.status != DownloadTransportStatus.paused &&
        truth.status != DownloadTransportStatus.missing) {
      _activateHandle(record.logicalId, handle);
    }
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
              (lookUpPreviousHandle
                  ? await _recordHandle(previous)
                  : null);

    if (obsoleteHandle != null) {
      await _settleObsoleteHandle(
        obsoleteHandle,
        cancelEvenIfFinal: cancelPreviousEvenIfFinal,
      );
    }

    final isManga = request.mediaKind == DownloadMediaKind.mangaChapter;
    ResolvedDownloadSourceV2? source;
    try {
      source = isManga
          ? null
          : await _sourceResolver.resolve(request.sourceDescriptor);
    } catch (error) {
      if (!_recordChanges.isClosed && previous != null &&
          previous.intent != DownloadUserIntent.canceled) {
        await _persistFailure(
          previous,
          DownloadTransportSnapshot(
            taskId: previous.taskId,
            status: DownloadTransportStatus.failed,
            progress: _snapshots[previous.logicalId]?.progress ?? 0,
            completedPages: _snapshots[previous.logicalId]?.completedPages,
            totalPages: _snapshots[previous.logicalId]?.totalPages,
            totalBytes: previous.expectedBytes,
            failureCategory: DownloadFailureCategory.unknown,
            failureMessage: 'source resolution failed: $error',
          ),
        );
      }
      rethrow;
    }
    if (_recordChanges.isClosed) {
      throw StateError('Download manager disposed during source recovery');
    }
    if (previous != null && previous.mediaKind == DownloadMediaKind.mangaChapter) {
      final oldId = obsoleteHandle?.taskId ?? previous.taskId;
      await _gateway.removeTracking(oldId);
      _forgetHandle(oldId);
    }

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
      completedPages: isManga ? (_snapshots[request.logicalId]?.completedPages ?? 0) : null,
      totalPages: isManga ? _snapshots[request.logicalId]?.totalPages : null,
      totalBytes: expectedBytes,
      transferredBytes: expectedBytes == null ? null : 0,
    );
    _snapshots[request.logicalId] = queued;
    _recordDiagnostic(request.logicalId, queued);

    try {
      final handle = await _startTransportForRequest(
        request: request,
        taskId: taskId,
        parallelChunks: parallelChunks,
        expectedBytes: expectedBytes,
        videoSource: source,
      );
      _activateHandle(request.logicalId, handle);
      return request.mediaKind == DownloadMediaKind.mangaChapter
          ? (_snapshots[request.logicalId] ?? handle.current) : handle.current;
    } catch (e) {
      final failedRecord = nextRecord.copyWith(
        intent: DownloadUserIntent.failed,
        awaitingAdmission: false,
        failureCategory: DownloadFailureCategory.unknown,
        failureMessage: e.toString(),
        updatedAtMillis: _nowMillis(),
      );
      await _store.put(failedRecord);
      _rememberRecord(failedRecord);
      await _publishRecords();
      final failedSnapshot = DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.failed,
        progress: 0,
        completedPages: isManga ? (_snapshots[request.logicalId]?.completedPages ?? 0) : null,
        totalPages: isManga ? _snapshots[request.logicalId]?.totalPages : null,
        totalBytes: expectedBytes,
        failureCategory: DownloadFailureCategory.unknown,
        failureMessage: e.toString(),
      );
      _snapshots[request.logicalId] = failedSnapshot;
      _recordDiagnostic(request.logicalId, failedSnapshot);
      _scheduleAdmissionPromotion();
      rethrow;
    }
  }

  Future<T> _runControlCommand<T>(
    DownloadLogicalId logicalId,
    String action,
    Future<T> Function() command,
  ) {
    final elapsed = Stopwatch()..start();
    var taskId = _currentTaskIds[logicalId];
    void record(String phase, [Object? error]) {
      taskId = _currentTaskIds[logicalId] ?? taskId;
      _diagnostics.recordTransport('command.$phase', {
        'logicalId': logicalId.value,
        'taskId': ?taskId,
        'action': action,
        'durationMs': elapsed.elapsedMilliseconds,
        if (error case final cause?) 'errorType': cause.runtimeType.toString(),
      });
    }

    record('requested');
    return _commands
        .run(logicalId, () {
          record('started');
          return command();
        })
        .then(
          (value) {
            record('accepted');
            return value;
          },
          onError: (Object error, StackTrace stack) {
            record(_isControlTimeout(error) ? 'timedOut' : 'rejected', error);
            Error.throwWithStackTrace(error, stack);
          },
        );
  }

  Future<bool> _resumeHandleAndAwaitAcknowledgement(
    DownloadLogicalId logicalId,
    DownloadTransportHandle handle,
  ) async {
    final acknowledgement = _unsettledResumeAcks.putIfAbsent(
      handle.taskId,
      handle.resume,
    );
    try {
      final accepted = await _awaitControlAcknowledgement(
        'resume',
        acknowledgement,
      );
      _unsettledResumeAcks.remove(handle.taskId)?.ignore();
      return accepted;
    } catch (error) {
      if (!_isControlTimeout(error)) {
        _unsettledResumeAcks.remove(handle.taskId)?.ignore();
      } else {
        // A lost resume reply may still create a native writer. Keep ownership
        // visible and fence destructive cleanup until the original call settles.
        _consumeSnapshot(logicalId, handle.current);
      }
      rethrow;
    }
  }

  Future<bool> _awaitControlAcknowledgement(
    String action,
    Future<bool> acknowledgement,
  ) => acknowledgement.timeout(
    const Duration(seconds: 30),
    onTimeout: () => throw _DownloadControlTimeout(action),
  );

  Future<DownloadTransportSnapshot> _pauseHandleAndSettle(
    DownloadTransportHandle handle,
  ) async {
    if (handle.current.status == DownloadTransportStatus.paused ||
        handle.current.status == DownloadTransportStatus.missing ||
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
      final accepted = await _awaitControlAcknowledgement(
        'pause', handle.pause(),
      );
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
        // A late pause may still settle; keep durable paused user intent.
        throw _DownloadControlTimeout('pause settlement');
      }
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _settleObsoleteHandle(
    DownloadTransportHandle handle, {
    required bool cancelEvenIfFinal,
  }) async {
    final unresolvedResume = _unsettledResumeAcks[handle.taskId];
    if (unresolvedResume != null) {
      // A timeout cannot revoke resume. Deleting before its original ACK could
      // let that operation enqueue a writer after the logical item disappeared.
      await _awaitControlAcknowledgement('resume', unresolvedResume);
    }
    final initiallySettled = handle.isSettled;
    if (initiallySettled && unresolvedResume == null) {
      if (cancelEvenIfFinal) {
        // Already-settled manga parents reject cancel; their terminal snapshot
        // still proves ownership ended. Preserve explicit renewal cleanup.
        await _awaitControlAcknowledgement('cancel', handle.cancel());
      }
      return;
    }

    final settlement = StreamIterator(handle.settlement(
      // A completed result from before an unresolved resume cannot prove that
      // the resumed writer has stopped. Retain the fresh-observation barrier.
      requireNewSnapshot: initiallySettled && unresolvedResume != null,
    ));
    final settled = settlement.moveNext()..ignore();

    try {
      final accepted = await _awaitControlAcknowledgement(
        'cancel',
        handle.cancel(),
      );
      if (!accepted) {
        throw StateError('Could not stop obsolete transport ${handle.taskId}');
      }
      if (handle.isSettled &&
          (unresolvedResume == null || !initiallySettled ||
              handle is SelfSettlingParallelDownloadTransportHandleV2)) {
        _unsettledResumeAcks.remove(handle.taskId)?.ignore();
        return;
      }

      try {
        if (!await settled.timeout(const Duration(seconds: 10))) {
          throw StateError('Obsolete transport ${handle.taskId} closed before settling');
        }
        _unsettledResumeAcks.remove(handle.taskId)?.ignore();
      } on TimeoutException {
        throw _DownloadControlTimeout('cancel settlement');
      }
    } finally {
      await settlement.cancel();
    }
  }

  Future<void> _cancelRecord(LogicalDownloadRecordV2 record) async {
    final logicalId = record.logicalId;
    final handle = await _recordHandle(record);
    final obsoleteTaskId = handle?.taskId ?? record.taskId;
    final ownedIdentity = parseDownloadTaskIdentityV2(obsoleteTaskId);
    final canceledRecord = record.copyWith(
      taskId: obsoleteTaskId,
      generation: ownedIdentity?.generation ?? record.generation,
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
      taskId: obsoleteTaskId,
      status: DownloadTransportStatus.canceled,
      progress: 0,
      totalBytes: record.expectedBytes,
      transferredBytes: record.expectedBytes == null ? null : 0,
    );
    if (handle != null) {
      try {
        await _settleObsoleteHandle(handle, cancelEvenIfFinal: false);
      } catch (error) {
        // A timeout may still settle later. Retain canceled intent so startup
        // cannot revive it, while the exact live writer keeps its ownership.
        final restored = _isControlTimeout(error) ? canceledRecord : record;
        await _store.put(restored);
        _rememberRecord(restored);
        _activateHandle(logicalId, handle);
        await _publishRecords();
        rethrow;
      }
    }
    // Durable cancel intent fences recovery immediately; terminal presentation
    // requires proof the exact writer has stopped.
    _snapshots[logicalId] = snapshot;
    _recordDiagnostic(logicalId, snapshot);
    try {
      await _gateway.removeTracking(obsoleteTaskId);
    } catch (_) {
      await _markCanceledCleanupFailure(canceledRecord);
      rethrow;
    }
    _forgetHandle(obsoleteTaskId);
    _sourceRefreshAttempts.remove(logicalId);
    _mangaSourceRefreshVerifiedPages.remove(logicalId);
    _firstRenewedPositiveSample.remove(logicalId);
    _scheduleAdmissionPromotion();
  }

  Future<void> _markCanceledCleanupFailure(LogicalDownloadRecordV2 record) async {
    // Cleanup failure must remain retryable without reviving a stopped writer.
    const message = 'Download cleanup could not finish; delete again to retry';
    final failedRecord = record.copyWith(
      failureCategory: DownloadFailureCategory.filesystem,
      failureMessage: message,
      updatedAtMillis: _nowMillis(),
    );
    await _store.put(failedRecord);
    _rememberRecord(failedRecord);
    final previous = _snapshots[record.logicalId];
    final failed = DownloadTransportSnapshot(
      taskId: record.taskId,
      status: DownloadTransportStatus.failed,
      progress: previous?.progress ?? 0,
      totalBytes: previous?.totalBytes ?? record.expectedBytes,
      transferredBytes: previous?.transferredBytes,
      activeConnections: 0,
      failureCategory: DownloadFailureCategory.filesystem,
      failureMessage: message,
    );
    _snapshots[record.logicalId] = failed;
    _recordDiagnostic(record.logicalId, failed);
    await _publishRecords();
  }

  Future<String> _canonicalDestinationPath(String destinationPath) async {
    final file = !p.isAbsolute(destinationPath) && !Platform.isIOS
        ? File(p.absolute(destinationPath))
        : await _destinationFile(destinationPath);
    return runLocalFileIo(() {
      var ancestor = p.normalize(file.absolute.path);
      final missing = <String>[];
      while (FileSystemEntity.typeSync(ancestor, followLinks: false) ==
          FileSystemEntityType.notFound) {
        try {
          File(ancestor).resolveSymbolicLinksSync();
          break;
        } on FileSystemException catch (error) {
          // Only proven missing components may be appended to a resolved key.
          if (![2, 3].contains(error.osError?.errorCode)) rethrow;
        }
        final parent = p.dirname(ancestor);
        if (parent == ancestor) {
          throw FileSystemException('No existing destination ancestor', destinationPath);
        }
        missing.insert(0, p.basename(ancestor));
        ancestor = parent;
      }
      final resolved = File(ancestor).resolveSymbolicLinksSync();
      final canonical = p.normalize(p.joinAll([resolved, ...missing]));
      return Platform.isWindows ? canonical.toLowerCase() : canonical;
    });
  }

  Future<LogicalDownloadRecordV2?> _findDestinationConflict(
    String canonicalDestination,
    DownloadLogicalId? logicalId,
  ) async {
    final records = await _store.all();
    for (final record in records) {
      if (record.logicalId == logicalId ||
          (record.intent == DownloadUserIntent.canceled &&
              !_hasLiveOwnership(_snapshots[record.logicalId]))) {
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

  bool _hasUnmappedDownloadWriter() {
    for (final handle in _handlesByTaskId.values) {
      if (!_hasLiveOwnership(handle.current)) {
        continue;
      }
      final identity = parseDownloadTaskIdentityV2(handle.taskId);
      final owner = identity == null ? null : _recordsByLogicalId[identity.logicalId];
      if (identity == null || owner == null ||
          owner.generation != identity.generation || owner.taskId != handle.taskId) {
        return true;
      }
    }
    return false;
  }

  Future<void> _cleanupEmptyDownloadFolders({
    LogicalDownloadRecordV2? removed,
    File? deletedFile,
    bool sweepOrphans = false,
  }) async {
    try {
      final roots = await platformConfiguredAppDownloadRoots();
      if (roots.isEmpty) {
        return;
      }
      String key(String path) {
        final normalized = p.normalize(p.absolute(path));
        return Platform.isWindows ? normalized.toLowerCase() : normalized;
      }

      bool needsFolder(LogicalDownloadRecordV2 record) =>
          (record.intent != DownloadUserIntent.canceled &&
              record.completedAtMillis == null) ||
          _hasLiveOwnership(_snapshots[record.logicalId]) ||
          _hasLiveOwnership(_handlesByTaskId[record.taskId]?.current);

      final records = _recordsByLogicalId.values.toList();
      final protectedPaths = <DownloadLogicalId, (String, String)>{};
      for (final record in records.where(needsFolder)) {
        protectedPaths[record.logicalId] = (
          record.destinationPath,
          await _canonicalDestinationPath(
            (await _destinationFile(record.destinationPath)).path,
          ),
        );
      }
      final canonicalRoots = <String, String>{};
      for (final root in roots) {
        final canonicalRoot = await localCanonicalDirectory(root);
        if (canonicalRoot != null) {
          canonicalRoots[key(root)] = key(canonicalRoot);
        }
      }
      bool isProtected(String directory) {
        if (_hasUnmappedDownloadWriter()) {
          return true;
        }
        final lexical = key(directory);
        String? canonical;
        for (final root in canonicalRoots.entries) {
          if (p.isWithin(root.key, lexical)) {
            canonical = key(
              p.join(root.value, p.relative(lexical, from: root.key)),
            );
            break;
          }
        }
        if (canonical == null) {
          return true;
        }
        // Recheck current state immediately before rmdir, after all filesystem awaits.
        for (final record in _recordsByLogicalId.values.where(needsFolder)) {
          final saved = protectedPaths[record.logicalId];
          if (saved == null || saved.$1 != record.destinationPath) {
            return true;
          }
          if (saved.$2 == canonical || p.isWithin(canonical, saved.$2)) {
            return true;
          }
        }
        return false;
      }

      final candidates = <String>{if (deletedFile != null) deletedFile.path};
      for (final record in <LogicalDownloadRecordV2>[
        ...records.where(
          (record) => record.intent == DownloadUserIntent.canceled,
        ),
        if (removed != null) removed,
      ]) {
        final destination = (await _destinationFile(record.destinationPath))
            .path;
        candidates.add(
          record.mediaKind == DownloadMediaKind.mangaChapter
              ? p.join(destination, '.empty-folder-check')
              : destination,
        );
      }
      if (sweepOrphans) {
        // Public Downloads/anime and manga can contain unrelated user folders.
        for (final root in await platformConfiguredAppDownloadRoots(
          includeSharedRoots: false,
        )) {
          if (!canonicalRoots.containsKey(key(root))) {
            continue;
          }
          final children = await localDirectoryEntries(root);
          for (final child in children) {
            if (child is Directory) {
              candidates.add(p.join(child.path, '.empty-folder-check'));
            }
          }
        }
      }
      for (final candidate in candidates) {
        await deleteSeriesFolderIfNoVideosRemain(
          File(candidate),
          appDownloadRoots: roots,
          isProtected: isProtected,
        );
      }
    } catch (_) {
      // Cosmetic cleanup must not fail a settled download or delete operation.
    }
  }

  Future<void> _deleteDestination(
    String destinationPath, {
    required DownloadLogicalId ownerLogicalId,
    DownloadMediaKind mediaKind = DownloadMediaKind.videoEpisode,
    LogicalDownloadRecordV2? mangaRecord,
  }) async {
    final trimmed = destinationPath.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '/') return;
    // Legacy logical records may share a destination. Never delete another
    // record's bytes when removing or invalidating just this record.
    if (await _findDestinationConflict(
          await _canonicalDestinationPath(trimmed),
          ownerLogicalId,
        ) !=
        null) {
      return;
    }
    final file = await _destinationFile(trimmed);
    final deleted = await localDeleteFileIfPresent(file);
    if (deleted || mediaKind != DownloadMediaKind.mangaChapter) return;
    final directory = Directory(file.path);
    if (!await directory.exists()) return;
    final destination = p.normalize(directory.absolute.path);
    for (final root in await platformConfiguredAppDownloadRoots()) {
      final normalizedRoot = p.normalize(p.absolute(root));
      if (!p.isWithin(normalizedRoot, destination)) continue;
      if (await FileSystemEntity.type(normalizedRoot, followLinks: false) !=
          FileSystemEntityType.directory)
        continue;
      // Both lexical and resolved containment must hold. A chapter symlink
      // cannot grant authority over an unrelated directory or the media root.
      final canonicalRoot = await Directory(normalizedRoot)
          .resolveSymbolicLinks();
      final canonicalDestination = await directory.resolveSymbolicLinks();
      if (p.isWithin(canonicalRoot, canonicalDestination)) {
        if (await directory.list(followLinks: false).isEmpty) {
          await directory.delete();
          return;
        }
        final manifest = await MangaChapterManifestV2.readFrom(directory);
        if (manifest == null ||
            mangaRecord == null ||
            manifest.mangaId != mangaRecord.mediaId ||
            manifest.chapterId != mangaRecord.unitKey)
          return;
        await directory.delete(recursive: true);
        return;
      }
    }
  }

  Future<DownloadIntegrityResult> _verifyRecordDestination(
    LogicalDownloadRecordV2 record, {
    required bool repairManga,
    bool rejectNonVideoPayload = false,
  }) async {
    if (record.mediaKind != DownloadMediaKind.mangaChapter) {
      return _integrityVerifier.verify(
        await _destinationFile(record.destinationPath),
        expectedBytes: record.expectedBytes,
        rejectNonVideoPayload: rejectNonVideoPayload,
      );
    }

    final destination = await _destinationFile(record.destinationPath);
    final directory = Directory(destination.path);
    if (!await directory.exists()) {
      return const DownloadIntegrityResult.invalid('missing', completedPages: 0);
    }
    var result = const DownloadIntegrityResult.invalid('manifest-incomplete', completedPages: 0);
    for (var attempt = 0; attempt < (repairManga ? 3 : 1); attempt++) {
      final manifest = await MangaChapterManifestV2.readFrom(directory);
      if (manifest == null || manifest.mangaId != record.mediaId ||
          manifest.chapterId != record.unitKey || manifest.pageCount <= 0) {
        return result;
      }
      final files = await _verifiedMangaPageFiles(directory, manifest, checkpointOnly: !repairManga);
      final complete = files.length == manifest.pageCount;
      final checkpointComplete = manifest.isComplete &&
          manifest.completedIndexes.length == manifest.pageCount;
      if (complete && (checkpointComplete || repairManga)) {
        if (!checkpointComplete) {
          await manifest.copyWith(completedIndexes: files.keys.toSet(), isComplete: true)
              .writeTo(directory);
        }
        var bytes = 0;
        for (final file in files.values) {
          bytes += await file.length();
        }
        return DownloadIntegrityResult.valid(bytes,
          completedPages: files.length, totalPages: manifest.pageCount);
      }
      result = DownloadIntegrityResult.invalid(
        checkpointComplete ? 'corrupt-page' : 'manifest-incomplete',
        completedPages: files.length, totalPages: manifest.pageCount,
      );
      if (!repairManga) return result;
      // Retain rejected digest provenance independently of the completed set.
      await manifest.copyWith(
        completedIndexes: files.keys.toSet(), isComplete: false,
      ).writeTo(directory);
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }
    return result;
  }

  Future<Map<int, File>> _verifiedMangaPageFiles(
    Directory directory, MangaChapterManifestV2 manifest, {
    bool checkpointOnly = false,
  }) async {
    final valid = <int, File>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final match = RegExp(r'^([0-9]+)\.[^.]+$').firstMatch(p.basename(entity.path));
      final page = match == null ? null : int.tryParse(match.group(1)!);
      if (page == null || page <= 0 || page > manifest.pageCount ||
          valid.containsKey(page - 1)) continue;
      final index = page - 1;
      if (checkpointOnly && !manifest.completedIndexes.contains(index)) continue;
      if (await manifest.isPageValid(index, entity)) {
        valid[index] = entity;
      } else if (!checkpointOnly && await entity.exists() && await entity.length() == 0) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
    return valid;
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

  Future<DownloadTransportHandle?> _recordHandle(LogicalDownloadRecordV2 record) async {
    final ownedId = _currentTaskIds[record.logicalId];
    if (ownedId != null && ownedId != record.taskId) {
      final identity = parseDownloadTaskIdentityV2(ownedId);
      if (identity != null && identity.logicalId == record.logicalId &&
          identity.generation <= record.generation) {
        final owned = await _exactHandle(ownedId);
        if (owned != null && _hasLiveOwnership(owned.current)) return owned;
      }
    }
    return _exactHandle(record.taskId);
  }

  void _forgetHandle(String taskId) {
    final parent = parseDownloadTaskIdentityV2(taskId);
    final ids = <String>[taskId];
    if (parent != null && parent.pageIndex == null && parent.logicalId.value.startsWith('manga_')) {
      for (final id in _handlesByTaskId.keys) {
        final child = parseDownloadTaskIdentityV2(id);
        if (child != null && child.pageIndex != null &&
            child.logicalId == parent.logicalId && child.generation == parent.generation) {
          ids.add(id);
        }
      }
    }
    for (final id in ids) {
      _handlesByTaskId.remove(id);
      _lastParentSpeedAtMillis.remove(id);
      final subscription = _subscriptionsByTaskId.remove(id);
      if (subscription != null) unawaited(subscription.cancel());
    }
  }

  Future<DownloadTransportHandle?> _exactHandle(String taskId) async {
    final cached = _handlesByTaskId[taskId];
    if (cached != null) return cached;
    var attached = await _gateway.attach(taskId);
    final identity = parseDownloadTaskIdentityV2(taskId);
    final gateway = _gateway;
    if (attached == null && gateway is MangaChapterGatewayV2 &&
        identity != null && identity.pageIndex == null &&
        identity.logicalId.value.startsWith('manga_')) {
      attached = await (gateway as MangaChapterGatewayV2).attachMangaChapterOwnershipV2(
        taskId, configuredConnections: _recordsByLogicalId[identity.logicalId]?.parallelChunks ?? 4,
      );
    }
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
      if (snapshot.isFinal && !_unsettledResumeAcks.containsKey(snapshot.taskId)) {
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
    if (_unsettledResumeAcks.containsKey(snapshot.taskId) &&
        snapshot.status != DownloadTransportStatus.running &&
        snapshot.status != DownloadTransportStatus.queued) {
      snapshot = _snapshotWithStatus(snapshot, DownloadTransportStatus.held);
    }
    final intent = _currentIntents[logicalId];
    if (intent == DownloadUserIntent.failed || intent == DownloadUserIntent.canceled) {
      final truth = _hasLiveOwnership(snapshot)
          ? snapshot
          : _snapshotWithStatus(snapshot, intent == DownloadUserIntent.canceled
              ? DownloadTransportStatus.canceled : DownloadTransportStatus.failed);
      _acceptSnapshot(logicalId, truth);
      if (!_hasLiveOwnership(truth)) _scheduleAdmissionPromotion();
      return;
    }
    if (snapshot.isFinal) {
      _lastParentSpeedAtMillis.remove(snapshot.taskId);
      _lastNativeSpeedProjectionAtMillis.remove(snapshot.taskId);
    }

    if (snapshot.status == DownloadTransportStatus.complete) {
      _scheduleCompletionVerification(logicalId, snapshot);
      _scheduleAdmissionPromotion();
      return;
    }

    final accepted = _acceptSnapshot(logicalId, snapshot);
    if (!accepted) return;

    // A resumed transfer may initially report *old* positive progress.
    // For video, progress beyond the first sample proves new source bytes.
    // Manga replenishes only from validated page checkpoints after settlement.
    if (_recordsByLogicalId[logicalId]?.mediaKind != DownloadMediaKind.mangaChapter &&
        _sourceRefreshAttempts.containsKey(logicalId) &&
        snapshot.status == DownloadTransportStatus.running &&
        (snapshot.progress > 0 || (snapshot.transferredBytes ?? 0) > 0)) {
      final baseline = _firstRenewedPositiveSample.putIfAbsent(
        logicalId,
        () => snapshot,
      );
      final newBytes = snapshot.transferredBytes != null &&
          baseline.transferredBytes != null &&
          snapshot.transferredBytes! > baseline.transferredBytes!;
      if (newBytes || snapshot.progress > baseline.progress) {
        _sourceRefreshAttempts.remove(logicalId);
        _firstRenewedPositiveSample.remove(logicalId);
      }
    }

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

    if (snapshot.status == DownloadTransportStatus.failed) {
      unawaited(
        _commands.run(logicalId, () async {
          final record = await _store.get(logicalId);
          if (record == null ||
              record.taskId != snapshot.taskId ||
              record.intent == DownloadUserIntent.canceled ||
              record.intent == DownloadUserIntent.failed ||
              record.completedAtMillis != null)
            return;
          await _persistFailure(record, snapshot);
        }),
      );
      return;
    }

    if (snapshot.isFinal ||
        (intent == DownloadUserIntent.paused &&
            snapshot.status == DownloadTransportStatus.paused)) {
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

    if (snapshot.status != DownloadTransportStatus.running) {
      _lastParentSpeedAtMillis.remove(snapshot.taskId);
    } else if (snapshot.networkSpeedMBps > 0) {
      _lastParentSpeedAtMillis[snapshot.taskId] = _nowMillis();
    }

    final previous = _snapshots[logicalId];
    if (snapshot.completedPages == null && previous?.completedPages != null &&
        previous?.taskId == snapshot.taskId) {
      snapshot = _snapshotWithPages(snapshot, previous!.completedPages!, previous.totalPages);
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
        snapshot.progress < 1 &&
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
        completedPages: snapshot.completedPages,
        totalPages: snapshot.totalPages,
        transferredBytes: transferredBytes,
        totalBytes: totalBytes,
        networkSpeedMBps: current.networkSpeedMBps,
        timeRemaining: speedBytesPerSecond > 0 && remainingBytes > 0
            ? Duration(
                milliseconds: ((remainingBytes / speedBytesPerSecond) * 1000)
                    .round(),
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
    if (snapshot.networkSpeedMBps > 0) {
      _lastPositiveSpeedAtMillis[logicalId] = _nowMillis();
    }
    _recordDiagnostic(logicalId, projected);
    return true;
  }

  Future<void> _forgetCompletedTransport(String taskId) async {
    try {
      await _gateway.removeTracking(taskId);
    } catch (error) {
      // Keep the verified final file and retry metadata cleanup on startup.
      _diagnostics.recordTransport('completion.trackingCleanupFailed', {
        'errorType': error.runtimeType.toString(),
      });
      return;
    }
    _handlesByTaskId.remove(taskId);
    _lastParentSpeedAtMillis.remove(taskId);
    final subscription = _subscriptionsByTaskId.remove(taskId);
    if (subscription != null) await subscription.cancel();
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
            record.intent == DownloadUserIntent.failed ||
            record.taskId != completedSnapshot.taskId) {
          return;
        }

        if (record.completedAtMillis != null) {
          final snapshot = DownloadTransportSnapshot(
            taskId: record.taskId,
            status: DownloadTransportStatus.complete,
            progress: 1,
            completedPages: completedSnapshot.completedPages,
            totalPages: completedSnapshot.totalPages,
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
          await _forgetCompletedTransport(record.taskId);
          _scheduleAdmissionPromotion();
          return;
        }

        final result = await _verifyRecordDestination(
          record,
          repairManga: true,
          // Only a newly completed transfer may reject these payloads here.
          // Existing completion claims use the original byte-only verification
          // on startup; playback can report a recoverable error without cleanup.
          rejectNonVideoPayload: true,
        );
        if (!result.isValid &&
            record.mediaKind != DownloadMediaKind.mangaChapter) {
          await _deleteDestination(
            record.destinationPath,
            ownerLogicalId: record.logicalId,
          );
        }
        final now = _nowMillis();

        final updated = await _store.mutate(logicalId, (current) {
          if (current == null ||
              current.intent == DownloadUserIntent.canceled ||
              current.intent == DownloadUserIntent.failed ||
              current.taskId != completedSnapshot.taskId) {
            return current;
          }

          if (result.isValid) {
            return current.copyWith(
              completedAtMillis: now,
              awaitingAdmission: false,
              clearFailure: true,
              updatedAtMillis: now,
            );
          }

          return current.copyWith(
            intent: DownloadUserIntent.failed,
            awaitingAdmission: false,
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
          _sourceRefreshAttempts.remove(logicalId);
          _mangaSourceRefreshVerifiedPages.remove(logicalId);
          _firstRenewedPositiveSample.remove(logicalId);
          final bytes = result.bytes!;
          final snapshot = DownloadTransportSnapshot(
            taskId: completedSnapshot.taskId,
            status: DownloadTransportStatus.complete,
            progress: 1,
            completedPages: result.completedPages,
            totalPages: result.totalPages,
            transferredBytes: bytes,
            totalBytes: updated.expectedBytes ?? bytes,
          );
          _snapshots[logicalId] = snapshot;
          _recordDiagnostic(
            logicalId,
            snapshot,
            integrityResult: DownloadV2IntegrityResult.valid,
          );
          await _forgetCompletedTransport(updated.taskId);
          _scheduleAdmissionPromotion();
          return;
        }

        final snapshot = DownloadTransportSnapshot(
          taskId: completedSnapshot.taskId,
          status: DownloadTransportStatus.failed,
          progress: completedSnapshot.progress,
          completedPages: result.completedPages,
          totalPages: result.totalPages,
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
        _scheduleAdmissionPromotion();
      }),
    );
  }

  Future<Set<int>> _verifiedMangaCheckpointIndexes(LogicalDownloadRecordV2 record) async {
    try {
      final directory = Directory((await _destinationFile(record.destinationPath)).path);
      if (!await directory.exists()) return {};
      final manifest = await MangaChapterManifestV2.readFrom(directory);
      if (manifest == null || manifest.mangaId != record.mediaId ||
          manifest.chapterId != record.unitKey || manifest.pageCount <= 0) return {};
      final files = await _verifiedMangaPageFiles(directory, manifest);
      return {
        for (final index in files.keys)
          if (manifest.completedIndexes.contains(index) && manifest.pageDigests.containsKey(index)) index,
      };
    } on FileSystemException {
      // An unreadable checkpoint supplies no new verified renewal evidence.
      return {};
    }
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
        if (record.mediaKind == DownloadMediaKind.mangaChapter) {
          // Source-expiry callbacks arrive after all page writers settle.
          final verified = await _verifiedMangaCheckpointIndexes(record);
          final previous = _mangaSourceRefreshVerifiedPages.putIfAbsent(
            logicalId, () => <int>{},
          );
          if (verified.any((index) => !previous.contains(index))) {
            _sourceRefreshAttempts.remove(logicalId);
          }
          previous.addAll(verified);
        }
        final attempts = _sourceRefreshAttempts[logicalId] ?? 0;
        if (attempts >= 3) {
          await _persistFailure(
            record,
            DownloadTransportSnapshot(
              taskId: record.taskId,
              status: DownloadTransportStatus.failed,
              progress: _snapshots[logicalId]?.progress ?? 0,
              completedPages: _snapshots[logicalId]?.completedPages,
              totalPages: _snapshots[logicalId]?.totalPages,
              totalBytes: record.expectedBytes,
              failureCategory: DownloadFailureCategory.sourceExpired,
              failureMessage: 'Max source refresh attempts exceeded',
            ),
          );
          return;
        }
        // Count only fenced renewal commands, never duplicate/stale callbacks.
        _sourceRefreshAttempts[logicalId] = attempts + 1;
        _firstRenewedPositiveSample.remove(logicalId);
        await Future<void>.delayed(
          Duration(milliseconds: 200 * (1 << attempts)),
        );
        final request = _requestFromRecord(record);
        try {
          await _startFreshGeneration(
            request,
            record,
            cancelPreviousEvenIfFinal: true,
          );
        } catch (error) {
          final current = await _store.get(logicalId);
          // The fresh start may already have saved this as an unknown failure;
          // it is the expired source that failed, and the UI says so.
          if (current == null ||
              current.intent == DownloadUserIntent.canceled ||
              current.completedAtMillis != null) {
            return;
          }
          await _persistFailure(
            current,
            DownloadTransportSnapshot(
              taskId: current.taskId,
              status: DownloadTransportStatus.failed,
              progress: _snapshots[logicalId]?.progress ?? 0,
              completedPages: _snapshots[logicalId]?.completedPages,
              totalPages: _snapshots[logicalId]?.totalPages,
              totalBytes: current.expectedBytes,
              failureCategory: DownloadFailureCategory.sourceExpired,
              failureMessage: error.toString(),
            ),
          );
        }
      }),
    );
  }

  Future<void> _persistFailure(
    LogicalDownloadRecordV2 record,
    DownloadTransportSnapshot snapshot,
  ) async {
    final failed = record.copyWith(
      intent: DownloadUserIntent.failed,
      awaitingAdmission: false,
      clearCompletedAtMillis: true,
      failureCategory:
          snapshot.failureCategory ?? DownloadFailureCategory.unknown,
      failureMessage: snapshot.failureMessage,
      updatedAtMillis: _nowMillis(),
    );
    await _store.put(failed);
    _rememberRecord(failed);
    _snapshots[record.logicalId] = snapshot;
    _recordDiagnostic(record.logicalId, snapshot);
    await _publishRecords();
    _scheduleAdmissionPromotion();
  }

  void _recordDiagnostic(
    DownloadLogicalId logicalId,
    DownloadTransportSnapshot snapshot, {
    DownloadV2SourceRefreshReason? sourceRefreshReason,
    DownloadV2IntegrityResult? integrityResult,
  }) {
    final generation = _currentGenerations[logicalId];
    if (generation == null || generation <= 0) return;
    final record = _recordsByLogicalId[logicalId];
    // Commands can race a terminal transport callback; only verified logical
    // completion may reach UI or the iOS session observer.
    if (record?.mediaKind == DownloadMediaKind.mangaChapter &&
        record?.completedAtMillis == null &&
        snapshot.status == DownloadTransportStatus.complete) {
      snapshot = _snapshotWithStatus(snapshot, DownloadTransportStatus.held);
      if (snapshot.completedPages == null) snapshot = _snapshotWithPages(snapshot, 0, null);
      _snapshots[logicalId] = snapshot;
    }
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
    if (record != null && record.taskId == snapshot.taskId) {
      if (!_presentationChanges.isClosed) _presentationChanges.add(null);
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
    final ready = _localReadiness;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(_DownloadManagerDisposedDuringStartup());
    }
    final presentationDisposal = Future.wait<void>(
      _presentationObservers.map((observer) async {
        try {
          await observer.dispose();
        } catch (_) {
          // Presentation disposal cannot prevent transport cleanup.
        }
      }),
    );
    _admissionPromotionRetryTimer?.cancel();
    _admissionPromotionRetryTimer = null;
    for (final subscription in _subscriptionsByTaskId.values) {
      await subscription.cancel();
    }
    _subscriptionsByTaskId.clear();
    for (final handle
        in _handlesByTaskId.values.whereType<MangaChapterTransportHandleV2>()) {
      await handle.dispose();
    }
    _handlesByTaskId.clear();
    await presentationDisposal;
    _unsettledResumeAcks.clear();
    _recordsByLogicalId.clear();
    _lastPositiveSpeedAtMillis.clear();
    _lastNativeSpeedProjectionAtMillis.clear();
    _lastParentSpeedAtMillis.clear();
    _firstRenewedPositiveSample.clear();
    _mangaSourceRefreshVerifiedPages.clear();
    await _presentationChanges.close();
    await _recordChanges.close();
  }
}

bool _isControlTimeout(Object error) =>
    error is _DownloadControlTimeout || error is TimeoutException;

final class _DownloadControlTimeout extends StateError {
  _DownloadControlTimeout(String action)
    : super('Download $action timed out; existing progress was preserved');
}

final class _DownloadManagerDisposedDuringStartup extends StateError {
  _DownloadManagerDisposedDuringStartup()
    : super('Download manager disposed during startup');
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

bool _hasLiveOwnership(DownloadTransportSnapshot? snapshot) =>
    snapshot != null && !snapshot.isFinal &&
    snapshot.status != DownloadTransportStatus.missing;

bool _isRecoverable(DownloadTransportSnapshot snapshot) {
  return snapshot.status != DownloadTransportStatus.failed &&
      snapshot.status != DownloadTransportStatus.canceled &&
      snapshot.status != DownloadTransportStatus.missing;
}

DownloadTransportSnapshot _snapshotWithPages(
  DownloadTransportSnapshot snapshot, int completedPages, int? totalPages,
) => DownloadTransportSnapshot(
  taskId: snapshot.taskId, status: snapshot.status, progress: snapshot.progress,
  completedPages: completedPages, totalPages: totalPages,
  transferredBytes: snapshot.transferredBytes, totalBytes: snapshot.totalBytes,
  networkSpeedMBps: snapshot.networkSpeedMBps, timeRemaining: snapshot.timeRemaining,
  configuredConnections: snapshot.configuredConnections, activeConnections: snapshot.activeConnections,
  failureCategory: snapshot.failureCategory, failureMessage: snapshot.failureMessage,
);

DownloadTransportSnapshot _snapshotWithPresentationBytes(
  DownloadTransportSnapshot snapshot,
) {
  if (snapshot.completedPages != null) return snapshot;
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
    completedPages: snapshot.completedPages,
    totalPages: snapshot.totalPages,
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
    completedPages: snapshot.completedPages,
    totalPages: snapshot.totalPages,
    transferredBytes: snapshot.completedPages != null ? snapshot.transferredBytes : _presentationTransferredBytes(
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
