import 'download_diagnostic_log.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;

import 'download_connection_governor.dart';
import 'download_parallel.dart';
import 'download_telemetry.dart';
import '../utils/download_resume.dart';

/// Child connections tend to report progress in a tight burst at the native
/// progress cadence. Collapse that burst into one parent/UI sample so four or
/// sixteen connections do not make the displayed bytes and speed jump several
/// times back-to-back for the same measurement interval.
const Duration kParallelProgressCoalesceDelay = Duration(seconds: 1);

/// Automatic child recovery is intentionally unbounded while the logical
/// episode is active: transient URLSession/system/network interruptions must
/// never turn into a user-visible pause. Backoff is capped so an unavailable
/// origin does not create a tight retry loop. Any real forward progress resets
/// the attempt counter back to zero.
const int kParallelRecoveryMaxBackoffMultiplier = 15;

/// background_downloader deliberately keeps a child just below 1.0 until its
/// final status callback is delivered. This is a completion sentinel, not a
/// byte-accurate 99.9% sample. It may drive recovery, but it must never be
/// credited to the logical episode until exact bytes or a normal progress
/// sample prove what is actually durable.
const double kParallelNativeCompletionSentinel = 0.999;

/// A native URLSession child can remain listed as live even after it has stopped
/// delivering bytes. Near the tail this used to reserve the final connection
/// forever because reconcile trusted native ownership unconditionally. Give a
/// genuinely finishing worker enough time, then settle/recover that one range.
const Duration kParallelTailStallDelay = Duration(seconds: 20);

/// Persist host throughput samples at a low cadence so the next episode can
/// reuse a proven connection ceiling without writing Hive on every callback.
const Duration kParallelHostProfileSampleInterval = Duration(seconds: 5);

/// iOS URLSession can keep writing/finalizing a child Range while its Dart
/// progress/status callbacks are delayed or lost. Poll only visible final part
/// paths as a fallback so durable bytes can wake the logical parent, advance
/// slow-start and update the UI without restarting any Range.
const Duration kParallelDiskProgressPollInterval = Duration(seconds: 1);

/// Native DownloadTasks transfer the parts; this coordinator persists their
/// identity before starting them. A process restart must not create new parts
/// or ask the plugin to resume an already completed part.
///
/// Fresh sessions use Gopeed-style slow start: 1, 2, 4, 8... connections. A
/// batch is not expanded until every child in that batch has actually reached
/// running/progress (or completed). If a batch hits rate limiting, server
/// overload, or a retryable connection failure, growth is stopped and the
/// episode falls back to the last healthy connection level instead of forcing
/// the requested 16 connections.
class PersistentParallelDownload {
  PersistentParallelDownload({
    this.diagnosticLog,
    required this.startPart,
    required this.pausePart,
    required this.cancelParts,
    required this.saveRecord,
    required this.recordForId,
    required this.onUpdate,
    required this.onPartProgress,
    this.livePartIds,
    this.recoveryDelay = const Duration(seconds: 1),
    this.tailStallDelay = kParallelTailStallDelay,
    this.diskProgressPollInterval = kParallelDiskProgressPollInterval,
    this.maxActiveConnections = kDownloadGlobalConnectionBudget,
    this.onHostPressure,
    this.onHostSample,
  });

  final DownloadDiagnosticLog? diagnosticLog;
  final Future<bool> Function(DownloadTask task, double progress, int size)
  startPart;
  final Future<void> Function(DownloadTask task) pausePart;
  final Future<void> Function(List<String> ids) cancelParts;
  final Future<void> Function(TaskRecord record) saveRecord;
  final Future<TaskRecord?> Function(String id) recordForId;
  final void Function(TaskUpdate update) onUpdate;
  final void Function(String parent, String child, double progress)
  onPartProgress;
  final int maxActiveConnections;
  final Future<Set<String>> Function()? livePartIds;
  final Duration recoveryDelay;
  final Duration tailStallDelay;
  final Duration diskProgressPollInterval;
  final void Function(String url, int fallbackCeiling)? onHostPressure;
  final void Function(String url, int activeConnections, double bytesPerSecond)?
  onHostSample;

  final Map<String, _ParallelSession> _sessions = {};
  final Map<String, _ParallelSession> _children = {};
  final Set<String> _activeConnectionIds = {};
  final DownloadConnectionGovernor _connectionGovernor =
      DownloadConnectionGovernor();
  final DownloadTelemetryEstimator _speedTelemetry =
      DownloadTelemetryEstimator();
  Future<void>? _pumpFuture;
  bool _disposed = false;

  bool isActive(String id) => !_disposed && (_sessions[id]?.active ?? false);

  bool hasLiveConnections(String id) {
    final session = _sessions[id];
    return session != null && _activeConnectionsForSession(session) > 0;
  }

  /// The byte-credible aggregate for a restored/live multipart parent.
  /// Native 0.999 completion sentinels are intentionally excluded.
  double? progressFor(String id) => _sessions[id]?.progress;

  /// Replace only the remote source of a paused/restored multipart job.
  /// Every range identity, byte boundary, credible progress value and local
  /// part file is retained. This is used when a signed CDN URL expires.
  Future<ParallelDownloadTask?> replaceSource(
    ParallelDownloadTask task, {
    required String url,
    required Map<String, String> headers,
  }) async {
    if (_disposed || !await restore(task)) return null;
    final session = _sessions[task.taskId]!;
    _speedTelemetry.seed(
      task.taskId,
      transferredBytes: session.creditedBytes,
      expectedBytes: session.size,
    );
    return session.serialize(() async {
      if (_disposed || session.deleted || session.active) return null;
      final updated = task.copyWith(
        url: url,
        headers: Map<String, String>.from(headers),
      );
      session.task = updated;
      for (final part in session.parts) {
        final childHeaders = Map<String, String>.from(headers)
          ..removeWhere(
            (key, _) =>
                key.toLowerCase() == 'range' || key.toLowerCase() == 'if-range',
          );
        childHeaders['Range'] = 'bytes=${part.from}-${part.to}';
        childHeaders['Accept-Encoding'] = 'identity';
        part.task = part.task.copyWith(
          url: url,
          headers: childHeaders,
          retries: kDownloadPartRetries,
        );
      }
      await _persist(session);
      final record = await recordForId(task.taskId);
      await saveRecord(
        TaskRecord(
          session.task,
          record?.status ?? TaskStatus.paused,
          session.progress,
          session.size,
        ),
      );
      return session.task;
    });
  }

  /// Includes native tasks that were handed to the OS but are still waiting
  /// for a socket. Counting them is deliberate: the manager never queues more
  /// than the global connection budget into URLSession/background_downloader.
  int get activeConnectionCount => _activeConnectionIds.length;

  void seedHostCeilings(Map<String, int> ceilings) =>
      _connectionGovernor.seedHostCeilings(ceilings);

  int get _connectionBudget =>
      maxActiveConnections.clamp(1, kDownloadGlobalConnectionBudget).toInt();

  Future<File> _manifest(DownloadTask task) async =>
      File('${await task.filePath()}.parts/manifest.json');

  Future<void> dispose() async {
    if (_disposed) {
      final pump = _pumpFuture;
      if (pump != null) await pump;
      await Future.wait<void>(_sessions.values.map((session) => session.idle));
      return;
    }
    _disposed = true;
    _speedTelemetry.clear();
    for (final session in _sessions.values) {
      session.cancelAggregateProgress();
      session.cancelDiskProgressPoll();
      session.cancelCoordinatorRecovery();
      session.cancelPartRetries();
    }
    final pump = _pumpFuture;
    if (pump != null) await pump;
    await Future.wait<void>(_sessions.values.map((session) => session.idle));
  }

  Future<bool> restore(ParallelDownloadTask task) async {
    if (_disposed) return false;
    if (_sessions.containsKey(task.taskId)) return true;
    final manifest = await _manifest(task);
    final temp = File('${manifest.path}.tmp');

    for (final candidate in <File>[manifest, temp]) {
      try {
        if (!await candidate.exists()) continue;
        final raw = await candidate.readAsString();
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final partJson = json['parts'];
        if (partJson is! List || partJson.isEmpty) continue;
        final parts = partJson
            .map(
              (part) => _DownloadPart.fromJson(
                Map<String, dynamic>.from(part as Map),
              ),
            )
            .toList(growable: false);
        if (parts.length > kDownloadWorkUnitsMax ||
            parts.any((part) => part.from < 0 || part.to < part.from)) {
          continue;
        }
        final session = _ParallelSession(task, manifest, parts);
        _register(session);
        await _restoreNativeOwnership(session);

        // A kill can happen after the durable .tmp write and before rename.
        // Recover that checkpoint instead of throwing all saved ranges away.
        if (candidate.path == temp.path) {
          await manifest.parent.create(recursive: true);
          await manifest.writeAsString(raw, flush: true);
          try {
            if (await temp.exists()) await temp.delete();
          } catch (_) {}
        }

        // Manifests written before credibleProgress existed may contain 0.999
        // for an unfinished child. That value is background_downloader's tail
        // sentinel, not proof that ~one whole Range exists. Keep it as the raw
        // recovery hint, but rebuild the credited amount from visible bytes
        // when native no longer owns the child. Never copy/read a native temp
        // file that is still being written by URLSession.
        var repaired = false;
        for (final part in session.parts) {
          if (!part.needsCredibleProgressRepair) continue;
          repaired = true;
          if (!part.launched) {
            try {
              final partial = await findPartialDownloadFile(
                destinationPath: await part.task.filePath(),
              );
              final bytes = partial == null ? 0 : await partial.length();
              if (bytes == part.size && part.size > 0) {
                part.complete = true;
                part.progress = 1;
                part.credibleProgress = 1;
              } else if (bytes > 0 && bytes < part.size) {
                part.credibleProgress = bytes / part.size;
              }
            } catch (_) {}
          }
          part.needsCredibleProgressRepair = false;

          final childRecord = await recordForId(part.task.taskId);
          if (childRecord != null &&
              !part.complete &&
              childRecord.progress >= kParallelNativeCompletionSentinel) {
            await saveRecord(
              TaskRecord(
                part.task,
                childRecord.status,
                part.credibleProgress,
                part.size,
              ),
            );
          } else if (part.complete) {
            await saveRecord(
              TaskRecord(part.task, TaskStatus.complete, 1, part.size),
            );
          }
        }

        if (repaired) {
          await _persist(session);
          final parentRecord = await recordForId(task.taskId);
          if (parentRecord != null &&
              parentRecord.status != TaskStatus.complete) {
            await saveRecord(
              TaskRecord(
                task,
                parentRecord.status,
                session.progress,
                session.size,
              ),
            );
          }
        }
        return true;
      } catch (_) {
        // Try the .tmp checkpoint when the primary manifest was torn/corrupt.
      }
    }
    return false;
  }

  void _register(_ParallelSession session) {
    _sessions[session.task.taskId] = session;
    for (final part in session.parts) {
      _children[part.task.taskId] = session;
    }
  }

  Future<void> _restoreNativeOwnership(_ParallelSession session) async {
    final live = await livePartIds?.call() ?? <String>{};
    for (final part in session.parts) {
      part.launched = !part.complete && live.contains(part.task.taskId);
      if (part.launched) {
        _activeConnectionIds.add(part.task.taskId);
      } else {
        _activeConnectionIds.remove(part.task.taskId);
      }
    }
  }

  /// Imports legacy plugin checkpoints without cancelling/deleting their files.
  /// Completed parts keep their filenames; the remaining native resume blobs
  /// stay associated with the same child taskIds.
  Future<void> importLegacy(
    ParallelDownloadTask task,
    String resumeData,
  ) async {
    if (_disposed) return;
    if (await restore(task)) return;
    final chunks = jsonDecode(resumeData) as List;
    if (chunks.isEmpty) throw const FormatException('Empty chunk checkpoint');
    final parts = chunks.map((raw) {
      final chunk = Map<String, dynamic>.from(raw as Map);
      final child = Task.createFromJson(
        Map<String, dynamic>.from(chunk['task'] as Map),
      ) as DownloadTask;
      return _DownloadPart(
        child.copyWith(
          group: kPersistentDownloadChunkGroup,
          retries: kDownloadPartRetries,
        ),
        (chunk['fromByte'] as num).toInt(),
        (chunk['toByte'] as num).toInt(),
        progress: (chunk['progress'] as num? ?? 0).toDouble(),
        complete: chunk['status'] == TaskStatus.complete.index,
      );
    }).toList();
    final session = _ParallelSession(task, await _manifest(task), parts);
    await _persist(session);
    _register(session);
  }

  Future<bool> start(ParallelDownloadTask task, int totalBytes) async {
    if (_disposed) return false;
    final restored = await restore(task);
    if (!restored) {
      if (totalBytes <= 0) return false;
      final requestedConnections = task.chunks
          .clamp(kDownloadPartsMin, kDownloadPartsMax)
          .toInt();
      final count = selectDownloadWorkUnitCount(
        connections: requestedConnections,
        totalBytes: totalBytes,
      );
      final parts = <_DownloadPart>[];
      for (var index = 0; index < count; index++) {
        final from = totalBytes * index ~/ count;
        final to = totalBytes * (index + 1) ~/ count - 1;
        final headers = Map<String, String>.from(task.headers)
          ..removeWhere((key, _) => key.toLowerCase() == 'range');
        headers['Range'] = 'bytes=$from-$to';
        headers['Accept-Encoding'] = 'identity';
        parts.add(
          _DownloadPart(
            DownloadTask(
              taskId: '${task.taskId}.part.$index',
              url: task.url,
              filename: '$index.part',
              directory: p.join(task.directory, '${task.filename}.parts'),
              baseDirectory: task.baseDirectory,
              headers: headers,
              updates: Updates.statusAndProgress,
              retries: kDownloadPartRetries,
              allowPause: true,
              group: kPersistentDownloadChunkGroup,
              metaData: jsonEncode({'parentTaskId': task.taskId}),
            ),
            from,
            to,
          ),
        );
      }
      final session = _ParallelSession(task, await _manifest(task), parts);
      await _persist(session);
      _register(session);
    }

    final session = _sessions[task.taskId]!;
    return session.serialize(() async {
      if (_disposed) return false;
      if (session.active) return true;
      session.cancelAggregateProgress();
      session.generation++;
      session.active = true;
      session.resetRamp();
      try {
        await _status(session, TaskStatus.enqueued);

        // Crash window: assembly may already have atomically renamed the final
        // file before the parent complete record/cleanup was persisted. Adopt
        // that exact-size target instead of assembling or downloading again.
        if (await _adoptCompletedTarget(session)) return true;

        await _restoreNativeOwnership(session);
        for (final part in session.parts) {
          part.speed = 0;
          part.recoveryAttempts = 0;

          // iOS can leave a completed range reported as live/running if the
          // final native callback is lost. Exact on-disk bytes are stronger
          // evidence than that stale status. Settle the worker first, verify the
          // bytes again, then adopt the range without downloading it twice.
          if (part.launched) {
            if (await _adoptExactSizePart(
              session,
              part,
              settleNativeOwner: true,
            )) {
              continue;
            }
            _armTailStallWatch(session, part);
            continue;
          }

          final saved = await canonicalizePartialDownloadFile(
            destinationPath: await part.task.filePath(),
          );
          final file = saved?.file ?? File(await part.task.filePath());
          if (await file.exists() && await file.length() == part.size) {
            part.complete = true;
            part.progress = 1;
            part.credibleProgress = 1;
            _activeConnectionIds.remove(part.task.taskId);
            part.launched = false;
            await saveRecord(
              TaskRecord(part.task, TaskStatus.complete, 1, part.size),
            );
            continue;
          }
          if (saved != null && saved.bytes > 0 && saved.bytes < part.size) {
            final diskProgress = saved.bytes / part.size;
            if (diskProgress > part.credibleProgress) {
              part.credibleProgress = diskProgress;
            }
          }
          if (part.complete) {
            await _pause(session);
            return false;
          }
        }

        final pending = session.parts.where((part) => !part.complete).length;
        if (pending == 0) {
          await _assemble(session);
          return true;
        }

        final configured = task.chunks
            .clamp(kDownloadPartsMin, kDownloadPartsMax)
            .toInt();
        final requested = pending < configured ? pending : configured;
        session.connectionCeiling = _connectionGovernor.connectionCeilingFor(
          session.task.url,
          requested: requested,
        );
        final slowStartTarget = pending < session.connectionCeiling
            ? pending
            : session.connectionCeiling;
        session.rampBatches = downloadConnectionRampBatches(slowStartTarget);

        if (!await _pumpSession(session)) {
          throw StateError('Could not start initial download connection');
        }
        _scheduleDiskProgressPoll(session);
        await _persist(session);
        _schedulePumpAll();
        return true;
      } catch (_) {
        if (session.active && _activeConnectionsForSession(session) > 0) {
          _scheduleDiskProgressPoll(session);
          _scheduleCoordinatorRecovery(session);
          try {
            await _status(session, TaskStatus.running);
          } catch (_) {}
          return true;
        }
        await _pause(session);
        return false;
      }
    });
  }

  int _activeConnectionsForSession(_ParallelSession session) => session.parts
      .where(
        (part) =>
            part.launched &&
            !part.complete &&
            _activeConnectionIds.contains(part.task.taskId),
      )
      .length;

  Iterable<_DownloadPart> _launchableParts(_ParallelSession session) =>
      session.parts.where(
        (part) =>
            !part.complete && !part.launched && part.recoveryTimer == null,
      );

  int _launchablePartCount(_ParallelSession session) =>
      _launchableParts(session).length;

  Future<bool> _pumpSession(_ParallelSession session) async {
    if (_disposed || !session.active || session.deleted) return true;

    while (!_disposed && session.active && !session.deleted) {
      if (session.currentBatchRemaining == 0) {
        if (session.currentBatchPendingIds.isNotEmpty) return true;
        if (session.rampBatchIndex < session.rampBatches.length) {
          session.currentBatchRemaining =
              session.rampBatches[session.rampBatchIndex++];
        } else {
          // Slow start reached its safe ceiling. Keep the pipeline full by
          // replacing completed or backing-off ranges one-for-one, never
          // exceeding that cap.
          session.slowStartComplete = true;
          final sessionAvailable =
              session.connectionCeiling - _activeConnectionsForSession(session);
          if (sessionAvailable <= 0) return true;
          final remaining = _launchablePartCount(session);
          if (remaining <= 0) return true;
          session.currentBatchRemaining = remaining < sessionAvailable
              ? remaining
              : sessionAvailable;
        }
      }

      final globalAvailable = _connectionBudget - _activeConnectionIds.length;
      final sessionAvailable =
          session.connectionCeiling - _activeConnectionsForSession(session);
      final available = globalAvailable < sessionAvailable
          ? globalAvailable
          : sessionAvailable;
      if (available <= 0) return true;

      final launchCount = session.currentBatchRemaining < available
          ? session.currentBatchRemaining
          : available;
      final parts = _launchableParts(session)
          .take(launchCount)
          .toList(growable: false);

      // Every unlaunched range may currently be inside its recovery backoff.
      // Preserve the batch count and sleep until one timer makes work eligible;
      // otherwise a tight microtask pump can spin at 0 B/s.
      if (parts.isEmpty) return true;

      for (final part in parts) {
        if (_disposed) return true;
        final record = await recordForId(part.task.taskId);
        final progress = record?.progress ?? 0;
        if (progress > part.progress && progress <= 1) {
          part.progress = progress;
        }
        // A child DB checkpoint at 0.999 is the same native sentinel as the
        // callback. Preserve it as a resume/recovery hint, but never turn it
        // into credited bytes. Ordinary (< 0.999) checkpoints remain useful.
        if (progress > part.credibleProgress &&
            progress < kParallelNativeCompletionSentinel) {
          part.credibleProgress = progress;
        }

        // Reserve before enqueueing to close the enqueue->running race. This
        // also keeps 5 episodes x 16 parts from becoming 80 native requests.
        part.launched = true;
        _activeConnectionIds.add(part.task.taskId);
        session.currentBatchPendingIds.add(part.task.taskId);
        session.currentBatchRemaining--;

        void rollbackUnownedReservation() {
          // Reservation happens before startPart to close the enqueue/running
          // race. If native never accepts the child, put that slot back into
          // the same slow-start batch. Otherwise repeated transient enqueue
          // failures consume the batch counter and can strand the episode with
          // no launchable work even though its immutable Range still exists.
          if (session.currentBatchPendingIds.remove(part.task.taskId)) {
            session.currentBatchRemaining++;
          }
          _activeConnectionIds.remove(part.task.taskId);
          part.launched = false;
        }

        bool started;
        try {
          started = await startPart(part.task, part.progress, part.size);
        } catch (_) {
          // The task was never handed to native IO. This is a local enqueue
          // failure, not evidence that the origin cannot sustain the current
          // connection level. Restoring/capping slow-start here can pin the
          // session at its already-active connection count and silently prevent
          // this Range from ever being retried.
          rollbackUnownedReservation();
          _schedulePartRecovery(session, part);
          try {
            await _status(session, TaskStatus.running);
          } catch (_) {}
          return true;
        }
        if (!started) {
          // A false enqueue result has identical ownership semantics: no native
          // worker exists, so restore the scheduler reservation and retry the
          // exact same taskId/Range without teaching a lower host ceiling.
          rollbackUnownedReservation();
          _schedulePartRecovery(session, part);
          await _status(session, TaskStatus.running);
          return true;
        }

        _armTailStallWatch(session, part);

        // On process recovery a child may already be owned by native IO, so a
        // fresh running callback is not guaranteed.
        if (record != null &&
            (record.status == TaskStatus.running ||
                record.status == TaskStatus.waitingToRetry)) {
          session.currentBatchPendingIds.remove(part.task.taskId);
        }
      }

      if (session.currentBatchRemaining > 0) return true;
      if (session.currentBatchPendingIds.isNotEmpty) return true;
    }
    return true;
  }

  void _markConnectionReady(_ParallelSession session, _DownloadPart part) {
    if (!session.currentBatchPendingIds.remove(part.task.taskId)) return;
    if (session.currentBatchRemaining == 0 &&
        session.currentBatchPendingIds.isEmpty) {
      if (!session.slowStartComplete) {
        final active = _activeConnectionsForSession(session);
        if (active > session.lastHealthyConnections) {
          session.lastHealthyConnections = active;
        }
        if (session.rampBatchIndex >= session.rampBatches.length) {
          session.slowStartComplete = true;
        }
      }
      _schedulePumpAll();
    }
  }

  void _cancelTailStallWatch(_DownloadPart part) {
    part.tailStallTimer?.cancel();
    part.tailStallTimer = null;
  }

  void _releaseConnection(_DownloadPart part) {
    part.recoveryTimer?.cancel();
    part.recoveryTimer = null;
    _cancelTailStallWatch(part);
    _activeConnectionIds.remove(part.task.taskId);
    part.launched = false;
    part.speed = 0;
    _schedulePumpAll();
  }

  void _armTailStallWatch(_ParallelSession session, _DownloadPart part) {
    if (_disposed ||
        !session.active ||
        session.deleted ||
        part.complete ||
        !part.launched ||
        part.progress < kParallelNativeCompletionSentinel ||
        part.progress >= 1) {
      _cancelTailStallWatch(part);
      return;
    }

    final observedProgress = part.credibleProgress;
    if (part.tailStallTimer != null &&
        observedProgress <= part.tailWatchProgress) {
      return;
    }

    _cancelTailStallWatch(part);
    part.tailWatchProgress = observedProgress;
    final generation = session.generation;
    part.tailStallTimer = Timer(tailStallDelay, () {
      part.tailStallTimer = null;
      unawaited(
        session.serialize(() async {
          if (_disposed ||
              !session.active ||
              session.deleted ||
              session.generation != generation ||
              part.complete ||
              !part.launched) {
            return;
          }
          if (part.credibleProgress > observedProgress) {
            _armTailStallWatch(session, part);
            return;
          }
          await _recoverTailStall(session, part);
        }),
      );
    });
  }

  Future<void> _afterAdoptedPart(_ParallelSession session) async {
    await _persist(session);
    if (session.parts.every((child) => child.complete)) {
      await _assemble(session);
    } else {
      _scheduleAggregateProgress(session);
      _schedulePumpAll();
    }
  }

  /// A tail child that is still marked live but has made no forward progress
  /// must not own the final slot forever. First settle/pause the same child and
  /// preserve its native resume data. If that exact worker returns but remains
  /// stuck, recycle only that immutable Range; all completed sibling ranges are
  /// left untouched.
  Future<void> _recoverTailStall(
    _ParallelSession session,
    _DownloadPart part,
  ) async {
    if (_disposed || !session.active || session.deleted || part.complete)
      return;

    if (await _adoptExactSizePart(
      session,
      part,
      settleNativeOwner: part.launched,
    )) {
      await _afterAdoptedPart(session);
      return;
    }

    if (!part.tailRecoveryAttempted) {
      part.tailRecoveryAttempted = true;
      try {
        await pausePart(part.task);
      } catch (_) {
        // The worker can already be a stale URLSession bookkeeping entry.
      }

      if (await _adoptExactSizePart(session, part, settleNativeOwner: false)) {
        await _afterAdoptedPart(session);
        return;
      }

      _stabilizeSessionForRecovery(session);
      _schedulePartRecovery(session, part);
      await _persist(session);
      await _status(session, TaskStatus.running);
      return;
    }

    await _recycleStalledTailRange(session, part);
  }

  Future<void> _recycleStalledTailRange(
    _ParallelSession session,
    _DownloadPart part,
  ) async {
    final destinationPath = await part.task.filePath();
    final partial = await canonicalizePartialDownloadFile(
      destinationPath: destinationPath,
    );
    var savedBytes = partial?.bytes ?? 0;
    File? backup;

    // cancelTasksWithIds may remove URLSession's child file. Preserve a visible
    // prefix outside the plugin's temp names, then restore it under the same
    // child path so DownloadRangeTransfer can append only the missing suffix.
    if (savedBytes > 0 && savedBytes < part.size && partial != null) {
      backup = File('$destinationPath.aw-tail-recovery');
      try {
        if (await backup.exists()) await backup.delete();
        await partial.file.copy(backup.path);
      } catch (_) {
        backup = null;
      }
    } else if (savedBytes > part.size) {
      // An oversized child is not a safe prefix of its immutable Range.
      savedBytes = 0;
    }

    _cancelTailStallWatch(part);
    _activeConnectionIds.remove(part.task.taskId);
    part.launched = false;
    part.speed = 0;
    session.currentBatchPendingIds.remove(part.task.taskId);

    try {
      await cancelParts(<String>[part.task.taskId]);
    } catch (_) {
      // Recovery remains safe even if native already forgot this child.
    }

    if (backup != null) {
      try {
        if (await backup.exists()) {
          final destination = File(destinationPath);
          await destination.parent.create(recursive: true);
          await backup.copy(destination.path);
          await backup.delete();
        }
      } catch (_) {}
    }

    final restored = await canonicalizePartialDownloadFile(
      destinationPath: destinationPath,
    );
    savedBytes = restored?.bytes ?? 0;
    if (savedBytes == part.size && part.size > 0) {
      part.complete = true;
      part.progress = 1;
      part.credibleProgress = 1;
      await saveRecord(
        TaskRecord(part.task, TaskStatus.complete, 1, part.size),
      );
      onPartProgress(session.task.taskId, part.task.taskId, 1);
      await _afterAdoptedPart(session);
      return;
    }
    if (savedBytes < 0 || savedBytes > part.size) savedBytes = 0;

    // If native resume data/temp bytes are genuinely inaccessible, zero means
    // re-fetch only this one immutable Range. Never restart the parent episode
    // or any of its already-completed siblings.
    part.progress = part.size > 0 ? savedBytes / part.size : 0;
    part.credibleProgress = part.progress;
    part.recoveryAttempts = 0;
    await saveRecord(
      TaskRecord(part.task, TaskStatus.paused, part.progress, part.size),
    );
    onPartProgress(
      session.task.taskId,
      part.task.taskId,
      part.credibleProgress,
    );
    await _persist(session);
    _stabilizeSessionForRecovery(session);
    _schedulePartRecovery(session, part);
    await _status(session, TaskStatus.running);
  }

  /// Adopt a range whose complete callback was lost after every requested byte
  /// already reached the destination file. If native still owns the task, ask
  /// it to pause/finalize first; then verify the exact byte count again before
  /// changing durable state. Never infer completion from 99% alone.
  Future<bool> _adoptExactSizePart(
    _ParallelSession session,
    _DownloadPart part, {
    required bool settleNativeOwner,
  }) async {
    if (part.complete || session.deleted) return part.complete;

    final path = await part.task.filePath();
    final file = File(path);
    if (!await file.exists() || await file.length() != part.size) return false;

    if (settleNativeOwner) {
      try {
        await pausePart(part.task);
      } catch (_) {
        // A task that has already finished natively may no longer be pausable.
        // The second exact-size verification below remains the source of truth.
      }
    }

    if (!await file.exists() || await file.length() != part.size) return false;

    _markConnectionReady(session, part);
    _releaseConnection(part);
    part.complete = true;
    part.progress = 1;
    part.credibleProgress = 1;
    await saveRecord(TaskRecord(part.task, TaskStatus.complete, 1, part.size));
    onPartProgress(session.task.taskId, part.task.taskId, 1);
    return true;
  }

  void _capSessionAt(_ParallelSession session, int ceiling) {
    final safe = ceiling
        .clamp(kDownloadPartsMin, kDownloadGlobalConnectionBudget)
        .toInt();
    if (safe >= session.connectionCeiling) return;
    session.connectionCeiling = safe;
    session.slowStartComplete = true;
    session.rampBatches = const <int>[];
    session.rampBatchIndex = 0;
    // Do not clear pending IDs: already-launched native children must prove
    // they recovered before the scheduler considers opening replacements.
    session.currentBatchRemaining = 0;
  }

  /// Any automatic child recovery freezes slow-start at the last proven
  /// healthy level. This prevents one interrupted batch from immediately
  /// expanding again while still allowing spare tail work to replace the
  /// backing-off connection at that safe ceiling.
  void _stabilizeSessionForRecovery(_ParallelSession session) {
    final active = _activeConnectionsForSession(session);
    final safe = session.lastHealthyConnections > 0
        ? session.lastHealthyConnections
        : (active > 0 ? active : kDownloadPartsMin);
    _capSessionAt(session, safe);
  }

  void _applyConnectionPressure(
    _ParallelSession session,
    TaskStatusUpdate update,
  ) {
    final pressure = downloadConnectionPressureFor(update);
    if (pressure == DownloadConnectionPressure.none) return;

    final active = _activeConnectionsForSession(session).clamp(1, 1 << 30);
    final growthInFlight =
        session.currentBatchPendingIds.isNotEmpty ||
        session.currentBatchRemaining > 0;
    var fallback = growthInFlight && session.lastHealthyConnections > 0
        ? session.lastHealthyConnections
        : (active <= 1 ? 1 : (active + 1) ~/ 2);
    if (fallback > session.connectionCeiling) {
      fallback = session.connectionCeiling;
    }

    if (pressure == DownloadConnectionPressure.host) {
      final learned = _connectionGovernor.learnHostCeiling(
        session.task.url,
        fallback,
      );
      onHostPressure?.call(session.task.url, learned);
      for (final sibling in _sessions.values) {
        if (!sibling.active || sibling.deleted) continue;
        if (_connectionGovernor.sameOrigin(
          sibling.task.url,
          session.task.url,
        )) {
          _capSessionAt(sibling, learned);
        }
      }
    } else {
      final learned = _connectionGovernor.learnTransferCeiling(
        session.task.url,
        fallback,
      );
      _capSessionAt(session, learned);
    }
  }

  void _scheduleDiskProgressPoll(_ParallelSession session) {
    if (_disposed || !session.active || session.deleted) return;
    if (session.diskProgressTimer != null) return;

    if (session.lastDiskObservedBytes < 0) {
      session.lastDiskObservedBytes = session.creditedBytes;
      session.lastDiskObservedAt = DateTime.now();
    }
    session.diskProgressTimer = Timer(diskProgressPollInterval, () {
      session.diskProgressTimer = null;
      if (_disposed) return;
      unawaited(
        session.serialize(() async {
          if (_disposed || !session.active || session.deleted) return;
          try {
            await _pollDiskProgress(session);
          } catch (_) {
            // This is only a fallback for missing native callbacks. A transient
            // file move/read race must never pause a healthy parent download.
          } finally {
            if (!_disposed && session.active && !session.deleted) {
              _scheduleDiskProgressPoll(session);
            }
          }
        }),
      );
    });
  }

  Future<void> _pollDiskProgress(_ParallelSession session) async {
    var changed = false;

    for (final part in session.parts) {
      if (part.complete) continue;
      try {
        final file = File(await part.task.filePath());
        if (!await file.exists()) continue;
        final bytes = await file.length();
        if (bytes <= 0 || bytes > part.size) continue;

        if (bytes == part.size &&
            await _adoptExactSizePart(
              session,
              part,
              settleNativeOwner: part.launched,
            )) {
          changed = true;
          continue;
        }

        final diskProgress = (bytes / part.size).clamp(0.0, 1.0).toDouble();
        if (diskProgress <= part.credibleProgress) continue;

        part.credibleProgress = diskProgress;
        if (part.progress >= kParallelNativeCompletionSentinel ||
            diskProgress > part.progress) {
          part.progress = diskProgress;
        }
        part.recoveryAttempts = 0;
        part.tailRecoveryAttempted = false;
        if (part.launched) _markConnectionReady(session, part);
        onPartProgress(
          session.task.taskId,
          part.task.taskId,
          part.credibleProgress,
        );
        changed = true;
      } on FileSystemException {
        // URLSession may atomically move a child while it is sampled.
      }
    }

    final now = DateTime.now();
    final creditedBytes = session.creditedBytes;
    final previousBytes = session.lastDiskObservedBytes;
    final previousAt = session.lastDiskObservedAt;
    if (previousBytes >= 0 && previousAt != null) {
      final elapsedMicros = now.difference(previousAt).inMicroseconds;
      final deltaBytes = creditedBytes - previousBytes;
      if (elapsedMicros > 0 && deltaBytes > 0) {
        session.diskObservedSpeed =
            deltaBytes *
            Duration.microsecondsPerSecond /
            elapsedMicros /
            1000 /
            1000;
      } else if (deltaBytes <= 0) {
        session.diskObservedSpeed = 0;
      }
    }
    session.lastDiskObservedBytes = creditedBytes;
    session.lastDiskObservedAt = now;

    // Keep a one-second parent heartbeat even when the byte count did not
    // move. That lets the shared telemetry estimator expire a stale speed and
    // pushes 0 B/s to both Flutter and the iOS continued-processing task.
    if (!changed) {
      _scheduleAggregateProgress(session);
      return;
    }
    if (session.parts.every((part) => part.complete)) {
      // Completion is a durability boundary; never defer its manifest write.
      await _persist(session);
      await _assemble(session);
      return;
    }
    if (!session.parentRunningReported) {
      await _status(session, TaskStatus.running);
    }
    _scheduleAggregateProgress(session, persist: true);
  }

  void _scheduleAggregateProgress(
    _ParallelSession session, {
    bool persist = false,
  }) {
    if (_disposed || !session.active || session.deleted) return;
    session.aggregateProgressDirty = true;
    if (persist) session.aggregatePersistDirty = true;
    if (session.aggregateProgressTimer != null) return;

    session.aggregateProgressTimer = Timer(kParallelProgressCoalesceDelay, () {
      session.aggregateProgressTimer = null;
      if (_disposed) return;
      unawaited(
        session.serialize(() async {
          if (_disposed ||
              !session.active ||
              session.deleted ||
              !session.aggregateProgressDirty) {
            return;
          }
          final persistCheckpoint = session.aggregatePersistDirty;
          session.aggregateProgressDirty = false;
          session.aggregatePersistDirty = false;
          // Native child callbacks can arrive from every active Range. Writing
          // and fsyncing the whole manifest for each callback used to backlog
          // the session serializer and delay pause/resume/pump work by tens of
          // seconds. Checkpoint active progress once per parent sample instead.
          if (persistCheckpoint) await _persist(session);
          await _emitAggregateProgress(session);
        }),
      );
    });
  }

  Future<void> _emitAggregateProgress(_ParallelSession session) async {
    final progress = session.progress;
    final telemetry = _speedTelemetry.observe(
      taskId: session.task.taskId,
      transferredBytes: session.creditedBytes,
      expectedBytes: session.size,
    );
    final speed = telemetry.speedBytesPerSecond > 0
        ? telemetry.speedBytesPerSecond / 1000 / 1000
        : 0.0;
    final timeRemaining = telemetry.timeRemaining;

    if (speed > 0) {
      final now = DateTime.now();
      final previousSample = session.lastHostProfileSampleAt;
      if (previousSample == null ||
          now.difference(previousSample) >=
              kParallelHostProfileSampleInterval) {
        session.lastHostProfileSampleAt = now;
        onHostSample?.call(
          session.task.url,
          _activeConnectionsForSession(session).clamp(1, 1 << 30),
          speed * 1000 * 1000,
        );
      }
    }

    await saveRecord(
      TaskRecord(session.task, TaskStatus.running, progress, session.size),
    );
    onUpdate(
      TaskProgressUpdate(
        session.task,
        progress,
        session.size,
        speed,
        timeRemaining,
      ),
    );
  }

  Duration _aggregateTimeRemaining(_ParallelSession session, double speedMb) {
    if (speedMb <= 0 || session.progress >= 1) {
      return const Duration(seconds: -1);
    }
    final remainingBytes = session.parts.fold<double>(
      0,
      (sum, part) => sum + part.size * (1 - part.credibleProgress),
    );
    if (remainingBytes <= 0) return Duration.zero;

    final seconds = (remainingBytes / (speedMb * 1000 * 1000)).ceil();
    return Duration(seconds: seconds < 1 ? 1 : seconds);
  }

  void _scheduleCoordinatorRecovery(_ParallelSession session) {
    if (_disposed || !session.active || session.deleted) return;
    if (session.coordinatorRecoveryTimer != null) return;
    final generation = session.generation;
    session.coordinatorRecoveryTimer = Timer(recoveryDelay, () {
      session.coordinatorRecoveryTimer = null;
      if (_disposed) return;
      unawaited(
        session.serialize(() async {
          if (_disposed ||
              !session.active ||
              session.deleted ||
              session.generation != generation) {
            return;
          }
          try {
            await _restoreNativeOwnership(session);
          } catch (_) {}
          _scheduleDiskProgressPoll(session);
          try {
            if (!session.parentRunningReported) {
              await _status(session, TaskStatus.running);
            }
          } catch (_) {}
          try {
            await _pumpSession(session);
          } catch (_) {}
          try {
            await _persist(session);
          } catch (_) {}
          _schedulePumpAll();
        }),
      );
    });
  }

  void _schedulePumpAll() {
    if (_disposed || _pumpFuture != null) return;

    late final Future<void> pump;
    pump =
        Future<void>.microtask(() async {
              final sessions = List<_ParallelSession>.from(_sessions.values);
              for (final session in sessions) {
                if (_disposed) return;
                if (!session.active || session.deleted) continue;
                await session.serialize(() async {
                  if (_disposed || !session.active || session.deleted) return;
                  try {
                    if (!await _pumpSession(session)) {
                      _scheduleCoordinatorRecovery(session);
                    } else {
                      await _persist(session);
                    }
                  } catch (_) {
                    // Coordinator bookkeeping is not a user-visible pause.
                    // Keep native owners untouched and reconcile them shortly.
                    _scheduleCoordinatorRecovery(session);
                  }
                });
              }
            })
            .catchError((Object _, StackTrace _) {
              // Session-level failures park their parent. An unexpected lifecycle race
              // must not become an unhandled asynchronous exception.
            })
            .whenComplete(() {
              if (identical(_pumpFuture, pump)) _pumpFuture = null;
              if (!_disposed &&
                  _activeConnectionIds.length < _connectionBudget &&
                  _sessions.values.any(_hasImmediatelyPumpableWork)) {
                _schedulePumpAll();
              }
            });
    _pumpFuture = pump;
  }

  bool _hasImmediatelyPumpableWork(_ParallelSession session) {
    if (_disposed || !session.active || session.deleted) return false;
    if (_activeConnectionsForSession(session) >= session.connectionCeiling) {
      return false;
    }
    final launchable = _launchablePartCount(session);
    if (launchable <= 0) return false;
    if (session.currentBatchRemaining > 0) return true;
    if (session.currentBatchPendingIds.isNotEmpty) return false;
    if (session.rampBatchIndex < session.rampBatches.length) return true;
    return launchable > 0;
  }

  /// iOS writes DownloadTask bodies into URLSession-owned temporary files, so
  /// the final `.part` path can remain invisible until didFinishDownloadingTo.
  /// The native delegate bridge reports the bytes here while they are still in
  /// that temp file. This is byte evidence, not a guessed percentage: it wakes
  /// the logical parent, advances slow-start and keeps speed/progress live even
  /// when background_downloader's Dart callbacks are delayed or lost.
  Future<void> handleNativeChunkUpdate({
    required String parentTaskId,
    required String chunkTaskId,
    double? progress,
    int? writtenBytes,
    int? expectedBytes,
    double? speedBytesPerSecond,
    bool completed = false,
  }) async {
    if (_disposed) return;
    final session = _sessions[parentTaskId] ?? _children[chunkTaskId];
    if (session == null || session.deleted) return;

    await session.serialize(() async {
      if (_disposed ||
          session.deleted ||
          !identical(_sessions[session.task.taskId], session)) {
        return;
      }

      _DownloadPart? part;
      for (final candidate in session.parts) {
        if (candidate.task.taskId == chunkTaskId) {
          part = candidate;
          break;
        }
      }
      if (part == null || part.complete) return;

      // The immutable Range in the manifest is the authority. Never trust a
      // server-reported expected length enough to credit bytes outside it.
      int? observedBytes;
      double? credible;
      if (writtenBytes != null &&
          writtenBytes >= 0 &&
          writtenBytes <= part.size) {
        observedBytes = writtenBytes;
        credible = part.size > 0 ? writtenBytes / part.size : 0;
      } else if (progress != null && progress >= 0 && progress <= 1) {
        credible = progress;
      }

      // didFinishDownloadingTo is hooked after the plugin moves the temp body
      // to our final child path. Completion still requires exact local bytes.
      if (completed) {
        final file = File(await part.task.filePath());
        if (await file.exists() &&
            await file.length() == part.size &&
            await _adoptExactSizePart(
              session,
              part,
              settleNativeOwner: false,
            )) {
          await _afterAdoptedPart(session);
          return;
        }
      }

      if (credible == null) return;
      credible = credible.clamp(0.0, 1.0).toDouble();

      final previousCredible = part.credibleProgress;
      final now = DateTime.now();
      if (credible > previousCredible) {
        if (speedBytesPerSecond != null && speedBytesPerSecond > 0) {
          part.speed = speedBytesPerSecond / 1000 / 1000;
        } else if (observedBytes != null &&
            part.lastNativeBridgeBytes >= 0 &&
            part.lastNativeBridgeAt != null) {
          final elapsedMicros = now
              .difference(part.lastNativeBridgeAt!)
              .inMicroseconds;
          final deltaBytes = observedBytes - part.lastNativeBridgeBytes;
          if (elapsedMicros > 0 && deltaBytes > 0) {
            part.speed =
                deltaBytes *
                Duration.microsecondsPerSecond /
                elapsedMicros /
                1000 /
                1000;
          }
        }

        part.credibleProgress = credible;
        if (part.progress >= kParallelNativeCompletionSentinel ||
            credible > part.progress) {
          part.progress = credible;
        }
        part.recoveryAttempts = 0;
        part.tailRecoveryAttempted = false;
      } else if (speedBytesPerSecond != null && speedBytesPerSecond > 0) {
        part.speed = speedBytesPerSecond / 1000 / 1000;
      }

      if (observedBytes != null) {
        part.lastNativeBridgeBytes = observedBytes;
        part.lastNativeBridgeAt = now;
      }

      if (session.active) {
        part.launched = true;
        _activeConnectionIds.add(part.task.taskId);
        _markConnectionReady(session, part);
      }

      final progressChanged = credible > previousCredible || completed;
      if (progressChanged) {
        onPartProgress(
          session.task.taskId,
          part.task.taskId,
          part.credibleProgress,
        );
      }

      if (!session.active) {
        // A late native callback after pause still carries credible bytes. It
        // must be durable immediately because no active checkpoint timer runs.
        if (progressChanged) await _persist(session);
        return;
      }
      if (!session.parentRunningReported) {
        await _status(session, TaskStatus.running);
      }
      _scheduleAggregateProgress(session, persist: progressChanged);
    });
  }

  bool handleUpdate(TaskUpdate update) {
    if (update.task.group != kPersistentDownloadChunkGroup) return false;
    if (_disposed) return true;
    final session = _children[update.task.taskId];
    if (session == null) return true;
    final generation = session.generation;

    unawaited(
      session.serialize(() async {
        try {
          if (_disposed ||
              session.deleted ||
              !identical(_sessions[session.task.taskId], session))
            return;
          final part = session.parts.firstWhere(
            (part) => part.task.taskId == update.task.taskId,
          );
          // Completion is durable; a late running/progress/retry callback must
          // never reserve its connection again or park the remaining parts.
          if (part.complete) return;
          if (generation != session.generation &&
              !(update is TaskStatusUpdate &&
                  update.status == TaskStatus.complete))
            return;

          if (update is TaskProgressUpdate &&
              update.progress >= 0 &&
              update.progress <= 1) {
            if (session.active) {
              part.launched = true;
              _activeConnectionIds.add(part.task.taskId);
              _markConnectionReady(session, part);
            }
            final incoming = update.progress;
            final previousCredibleProgress = part.credibleProgress;

            if (incoming >= kParallelNativeCompletionSentinel) {
              // 0.999 (and a progress-only 1.0) is a native completion
              // sentinel. Keep it for exact-size adoption/watchdog recovery,
              // but do not count it as downloaded bytes.
              if (incoming > part.progress) part.progress = incoming;
            } else if (incoming > part.credibleProgress) {
              // A normal sample is byte-credible. If this connection is
              // recovering from a previously observed 0.999 sentinel, allow
              // the raw marker to move back below 0.999 so the tail watchdog
              // is canceled by genuine forward progress.
              part.credibleProgress = incoming;
              if (part.progress >= kParallelNativeCompletionSentinel ||
                  incoming > part.progress) {
                part.progress = incoming;
              }
            }

            if (part.credibleProgress > previousCredibleProgress) {
              // A recovered connection that actually writes bytes is healthy
              // again. Future interruptions start from the short backoff and
              // the tail watchdog gets a fresh grace period.
              part.recoveryAttempts = 0;
              part.tailRecoveryAttempted = false;
            }
            part.speed = update.networkSpeed > 0 ? update.networkSpeed : 0;

            // URLSession occasionally writes the complete range and reports
            // 0.999, then never delivers TaskStatus.complete. Only take over
            // when the exact requested byte count is already on disk; pausing
            // the child here settles native ownership before assembly deletes
            // the .part files.
            if (session.active &&
                incoming >= kParallelNativeCompletionSentinel &&
                await _adoptExactSizePart(
                  session,
                  part,
                  settleNativeOwner: part.launched,
                )) {
              await _afterAdoptedPart(session);
              return;
            }

            _armTailStallWatch(session, part);
            onPartProgress(
              session.task.taskId,
              part.task.taskId,
              part.credibleProgress,
            );
            if (session.active) {
              _scheduleAggregateProgress(
                session,
                persist: part.credibleProgress > previousCredibleProgress,
              );
            } else if (part.credibleProgress > previousCredibleProgress) {
              // Preserve late bytes immediately while the parent is inactive.
              await _persist(session);
            }
            return;
          }

          if (update is! TaskStatusUpdate) return;

          if (session.active && update.status == TaskStatus.waitingToRetry) {
            // Only legacy/native workers created before the unified retry
            // policy should reach here. Keep their real native ownership
            // reserved, but never turn this internal state into a paused parent
            // notification. Newly created/restored child definitions use zero
            // native retries and recover through the scheduler below.
            part.launched = true;
            part.speed = 0;
            _activeConnectionIds.add(part.task.taskId);
            _applyConnectionPressure(session, update);
            _armTailStallWatch(session, part);
            await _persist(session);
            await _status(session, TaskStatus.running);
            return;
          }

          if (update.status == TaskStatus.complete) {
            final file = File(await part.task.filePath());
            final exists = await file.exists();
            final length = exists ? await file.length() : -1;

            // Some origins advertise/probe as range-capable, then answer the
            // real ranged child with a full HTTP 200. background_downloader
            // writes that full body to the child file. Gopeed keeps its resolve
            // response as a sequential fallback in this exact situation. Do
            // the equivalent here: if the child already contains the complete
            // episode, promote those bytes directly instead of throwing them
            // away and downloading the file again with one connection.
            if (exists &&
                length == session.size &&
                length != part.size &&
                await _adoptIgnoredRangeFullBody(session, part, update)) {
              return;
            }

            if (!exists || length != part.size) {
              // A completed callback with the wrong durable byte count is a
              // data-integrity boundary, not a coordinator race. Keep the
              // bytes for diagnosis/resume and park the parent deterministically.
              await _pause(session);
              return;
            }
            _markConnectionReady(session, part);
            _releaseConnection(part);
            part.complete = true;
            part.progress = 1;
            part.credibleProgress = 1;
            onPartProgress(session.task.taskId, part.task.taskId, 1);
            await _persist(session);
            if (session.active &&
                session.parts.every((child) => child.complete)) {
              await _assemble(session);
            } else {
              _scheduleAggregateProgress(session);
              _schedulePumpAll();
            }
            return;
          }

          if (session.active && update.status == TaskStatus.running) {
            part.launched = true;
            _activeConnectionIds.add(part.task.taskId);
            _markConnectionReady(session, part);
            _armTailStallWatch(session, part);
            await _status(session, TaskStatus.running);
            _schedulePumpAll();
            return;
          }

          if (session.active &&
              (update.status == TaskStatus.failed ||
                  update.status == TaskStatus.notFound ||
                  update.status == TaskStatus.canceled ||
                  update.status == TaskStatus.paused)) {
            if (update.status == TaskStatus.failed) {
              _applyConnectionPressure(session, update);
            }

            if (_shouldAutomaticallyRecoverPart(update)) {
              // A native child finishing/pausing is not the same thing as the
              // logical episode stopping. Release only this child's connection
              // during backoff; healthy siblings/tail work keep moving. The
              // parent remains running so recovery never emits a fake pause.
              _stabilizeSessionForRecovery(session);
              _schedulePartRecovery(session, part);
              await _status(session, TaskStatus.running);
              return;
            }

            // Permanent client-side HTTP errors (for example 401/403/404) are
            // not helped by hammering the same signed URL forever. Preserve all
            // bytes and park the logical episode so a later source refresh/user
            // resume can obtain a new URL.
            _markConnectionReady(session, part);
            _releaseConnection(part);
            await _pause(session);
          }
        } catch (_) {
          if (!_disposed && session.active && !session.deleted) {
            _scheduleCoordinatorRecovery(session);
          }
        }
      }),
    );
    return true;
  }

  Future<bool> pause(ParallelDownloadTask task) async {
    if (_disposed) return false;
    if (!await restore(task)) return false;
    final session = _sessions[task.taskId]!;
    return session.serialize(() => _pause(session));
  }

  bool _shouldAutomaticallyRecoverPart(TaskStatusUpdate update) {
    switch (update.status) {
      case TaskStatus.paused:
      case TaskStatus.canceled:
      case TaskStatus.notFound:
        return true;
      case TaskStatus.failed:
        final exception = update.exception;
        final statusCode =
            update.responseStatusCode ??
            (exception is TaskHttpException
                ? exception.httpResponseCode
                : null);
        if (statusCode == null) return true;
        return statusCode == 408 ||
            statusCode == 425 ||
            statusCode == 429 ||
            (statusCode >= 500 && statusCode <= 599);
      case TaskStatus.enqueued:
      case TaskStatus.running:
      case TaskStatus.complete:
      case TaskStatus.waitingToRetry:
        return false;
    }
  }

  Duration _partRecoveryDelay(int attempts) {
    final multiplier = attempts
        .clamp(1, kParallelRecoveryMaxBackoffMultiplier)
        .toInt();
    return recoveryDelay * multiplier;
  }

  bool _schedulePartRecovery(_ParallelSession session, _DownloadPart part) {
    if (part.recoveryTimer != null) return true;
    if (!session.active || session.deleted || _disposed || part.complete) {
      return false;
    }
    _cancelTailStallWatch(part);
    part.recoveryAttempts++;
    part.speed = 0;

    // Backoff is not an active connection. Free the reserved slot immediately
    // so another durable range can use it. The failed range becomes launchable
    // only after its timer expires and then re-enters _pumpSession, where both
    // the per-session ceiling and the global governor are checked again.
    part.launched = false;
    _activeConnectionIds.remove(part.task.taskId);
    session.currentBatchPendingIds.remove(part.task.taskId);
    final generation = session.generation;
    part.recoveryTimer = Timer(_partRecoveryDelay(part.recoveryAttempts), () {
      unawaited(
        session.serialize(() async {
          if (_disposed ||
              !session.active ||
              session.deleted ||
              session.generation != generation ||
              part.complete)
            return;
          part.recoveryTimer = null;
          _schedulePumpAll();
        }),
      );
    });
    _schedulePumpAll();
    return true;
  }

  /// Reconcile after returning to the app, when the OS may have completed or
  /// removed workers without delivering their final callback to Dart.
  Future<void> reconcile(Future<Set<String>> Function() liveTaskIds) async {
    for (final session in List<_ParallelSession>.from(_sessions.values)) {
      await session.serialize(() async {
        if (_disposed || !session.active || session.deleted) return;
        final live = await liveTaskIds();
        var recovering = false;
        for (final part in session.parts) {
          if (part.complete || !part.launched || part.recoveryTimer != null) {
            continue;
          }

          final nativeOwnsPart = live.contains(part.task.taskId);
          if (await _adoptExactSizePart(
            session,
            part,
            settleNativeOwner: nativeOwnsPart,
          )) {
            continue;
          }

          // A genuinely live worker normally continues untouched. A live child
          // parked at the completion sentinel is different: arm the watchdog so
          // stale URLSession ownership cannot reserve the final slot forever.
          if (nativeOwnsPart) {
            _armTailStallWatch(session, part);
            continue;
          }

          // URLSession can temporarily drop a worker during hand-off without
          // delivering its final callback to Dart. Recover that one child;
          // never pause healthy siblings just because ownership vanished.
          _stabilizeSessionForRecovery(session);
          recovering = _schedulePartRecovery(session, part) || recovering;
        }
        if (session.parts.every((part) => part.complete)) {
          await _assemble(session);
        } else {
          if (recovering) {
            await _status(session, TaskStatus.running);
          }
          await _persist(session);
          _schedulePumpAll();
        }
      });
    }
  }

  Future<bool> _pause(_ParallelSession session) async {
    session.active = false;
    session.generation++;
    _speedTelemetry.resetSpeed(session.task.taskId);
    session.cancelAggregateProgress();
    session.cancelDiskProgressPoll();
    session.cancelCoordinatorRecovery();
    session.resetRamp();

    final unfinished = session.parts
        .where((part) => !part.complete)
        .toList(growable: false);
    var pauseFailed = false;

    // Pause every actual child identity concurrently. DownloadService routes
    // these child tasks to FileDownloader.pause, which owns their URLSession
    // resume data; it must never route them through the single-file Transfer.
    await Future.wait(
      unfinished.map((part) async {
        try {
          await pausePart(part.task);
        } catch (_) {
          pauseFailed = true;
        }
      }),
    );

    Set<String> live = <String>{};
    final lookupLive = livePartIds;
    if (lookupLive != null) {
      try {
        live = await lookupLive();
      } catch (_) {
        pauseFailed = true;
      }
    }

    var stillLive = unfinished
        .where((part) => live.contains(part.task.taskId))
        .toList(growable: false);

    // A pause acknowledgement and the URLSession state transition are
    // asynchronous on iOS. Retry only identities that are still demonstrably
    // live; never cancel them, because cancel can discard resume bytes.
    if (stillLive.isNotEmpty) {
      await Future.wait(
        stillLive.map((part) async {
          try {
            await pausePart(part.task);
          } catch (_) {
            pauseFailed = true;
          }
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (lookupLive != null) {
        try {
          live = await lookupLive();
        } catch (_) {
          pauseFailed = true;
        }
      }
      stillLive = unfinished
          .where((part) => live.contains(part.task.taskId))
          .toList(growable: false);
    }

    if (stillLive.isNotEmpty || (lookupLive == null && pauseFailed)) {
      final stillIds = stillLive.map((part) => part.task.taskId).toSet();
      session.active = true;
      for (final part in unfinished) {
        final owns = stillIds.contains(part.task.taskId);
        part.launched = owns;
        part.speed = 0;
        if (owns) {
          _activeConnectionIds.add(part.task.taskId);
        } else {
          _activeConnectionIds.remove(part.task.taskId);
        }
      }
      _scheduleDiskProgressPoll(session);
      await _persist(session);
      await _status(session, TaskStatus.running);
      return false;
    }

    for (final part in unfinished) {
      part.launched = false;
      part.speed = 0;
    }
    final ids = session.parts.map((part) => part.task.taskId).toSet();
    _activeConnectionIds.removeWhere(ids.contains);
    await _persist(session);
    await _status(session, TaskStatus.paused);
    _schedulePumpAll();
    return true;
  }

  Future<void> cancel(ParallelDownloadTask task) async {
    if (_disposed) return;
    if (!await restore(task)) return;
    final session = _sessions[task.taskId]!;
    session.deleted = true;
    session.active = false;
    session.cancelAggregateProgress();
    session.cancelDiskProgressPoll();
    session.cancelCoordinatorRecovery();
    _speedTelemetry.remove(task.taskId);
    session.resetRamp();
    await session.serialize(() async {
      for (final part in session.parts) {
        _activeConnectionIds.remove(part.task.taskId);
      }
      await cancelParts(session.parts.map((part) => part.task.taskId).toList());
      for (final part in session.parts) {
        _children.remove(part.task.taskId);
        final file = File(await part.task.filePath());
        if (await file.exists()) await file.delete();
      }
      if (await session.manifest.parent.exists()) {
        await session.manifest.parent.delete(recursive: true);
      }
      final staging = File('${await task.filePath()}.assembling');
      if (await staging.exists()) await staging.delete();
      _sessions.remove(task.taskId);
    });
    _schedulePumpAll();
  }

  Future<void> _status(_ParallelSession session, TaskStatus status) async {
    diagnosticLog?.record('parallel.status', {
      'taskId': session.task.taskId,
      'status': status.name,
      'progress': session.progress,
    });
    if (status == TaskStatus.running) {
      session.parentRunningReported = true;
    } else if (status == TaskStatus.enqueued || status == TaskStatus.paused) {
      session.parentRunningReported = false;
    }
    await saveRecord(
      TaskRecord(session.task, status, session.progress, session.size),
    );
    onUpdate(TaskStatusUpdate(session.task, status));
  }

  Future<void> _persist(_ParallelSession session) async {
    if (session.deleted) return;
    await session.manifest.parent.create(recursive: true);
    final payload = jsonEncode({
      'parts': session.parts.map((part) => part.toJson()).toList(),
    });
    final temp = File('${session.manifest.path}.tmp');
    await temp.writeAsString(payload, flush: true);
    try {
      await temp.rename(session.manifest.path);
    } on FileSystemException {
      await session.manifest.writeAsString(payload, flush: true);
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  Future<bool> _adoptCompletedTarget(_ParallelSession session) async {
    final target = File(await session.task.filePath());
    if (!await target.exists()) return false;
    if (await target.length() != session.size) return false;
    await _finishCompleteSession(session);
    return true;
  }

  bool _requestedByteRange(_DownloadPart part) => part.task.headers.entries.any(
    (entry) =>
        entry.key.toLowerCase() == 'range' &&
        entry.value.toLowerCase().startsWith('bytes='),
  );

  Future<bool> _adoptIgnoredRangeFullBody(
    _ParallelSession session,
    _DownloadPart sourcePart,
    TaskStatusUpdate update,
  ) async {
    if (update.responseStatusCode != 200 || !_requestedByteRange(sourcePart)) {
      return false;
    }

    final source = File(await sourcePart.task.filePath());
    if (!await source.exists() || await source.length() != session.size) {
      return false;
    }
    final target = File(await session.task.filePath());
    // An unexpected existing target is user-visible state. Never overwrite it
    // during an automatic fallback. Exact-size targets are adopted earlier in
    // start(); any other target remains untouched and the parent is paused.
    if (await target.exists()) return false;

    session.active = false;
    session.cancelAggregateProgress();
    session.resetRamp();
    for (final part in session.parts) {
      _activeConnectionIds.remove(part.task.taskId);
      part.launched = false;
      part.speed = 0;
    }

    final siblings = session.parts
        .where((part) => part.task.taskId != sourcePart.task.taskId)
        .map((part) => part.task.taskId)
        .toList(growable: false);
    if (siblings.isNotEmpty) {
      try {
        await cancelParts(siblings);
      } catch (_) {
        // The full source body is already durable. Late sibling callbacks are
        // swallowed after _finishCompleteSession removes child mappings.
      }
    }

    await source.rename(target.path);
    sourcePart.complete = true;
    sourcePart.progress = 1;
    sourcePart.credibleProgress = 1;
    await _finishCompleteSession(session);
    return true;
  }

  Future<void> _finishCompleteSession(_ParallelSession session) async {
    session.active = false;
    session.cancelAggregateProgress();
    session.cancelDiskProgressPoll();
    session.cancelCoordinatorRecovery();
    _speedTelemetry.remove(session.task.taskId);
    session.resetRamp();
    for (final part in session.parts) {
      _activeConnectionIds.remove(part.task.taskId);
    }
    onUpdate(
      TaskProgressUpdate(session.task, 1, session.size, 0, Duration.zero),
    );
    await _status(session, TaskStatus.complete);

    for (final part in session.parts) {
      _children.remove(part.task.taskId);
      final file = File(await part.task.filePath());
      if (await file.exists()) await file.delete();
    }
    if (await session.manifest.parent.exists()) {
      await session.manifest.parent.delete(recursive: true);
    }
    _sessions.remove(session.task.taskId);
    _schedulePumpAll();
  }

  Future<void> _assemble(_ParallelSession session) async {
    diagnosticLog?.record('assembly.begin', {
      'taskId': session.task.taskId,
      'total': session.size,
      'count': session.parts.length,
    });
    final target = File(await session.task.filePath());
    if (await target.exists()) {
      if (await target.length() == session.size) {
        await _finishCompleteSession(session);
        return;
      }
      // Never overwrite an unexpected user-visible file during automatic
      // recovery. The user can remove/rename it explicitly and resume later.
      await _pause(session);
      return;
    }

    final staging = File('${target.path}.assembling');
    final output = await staging.open(mode: FileMode.write);
    try {
      // Establish the final logical length up front. Besides reducing repeated
      // growth metadata work, this surfaces many disk-full failures before all
      // parts are copied into a staging file.
      await output.truncate(session.size);
      await output.setPosition(0);
      var assembledBytes = 0;
      for (final part in session.parts) {
        final file = File(await part.task.filePath());
        if (!await file.exists() || await file.length() != part.size) {
          await _pause(session);
          return;
        }
        await for (final bytes in file.openRead()) {
          if (session.deleted) return;
          if (assembledBytes + bytes.length > session.size) {
            await _pause(session);
            return;
          }
          await output.writeFrom(bytes);
          assembledBytes += bytes.length;
        }
      }
      if (assembledBytes != session.size) {
        await _pause(session);
        return;
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (session.deleted) return;
    if (!await staging.exists() || await staging.length() != session.size) {
      await _pause(session);
      return;
    }
    // The target was proven absent above. Rename staging atomically so a crash
    // leaves either the recoverable .assembling file or the full final file.
    await staging.rename(target.path);
    await _finishCompleteSession(session);
  }
}

class _ParallelSession {
  _ParallelSession(this.task, this.manifest, this.parts);

  ParallelDownloadTask task;
  final File manifest;
  final List<_DownloadPart> parts;
  bool active = false;
  bool deleted = false;
  int generation = 0;
  int connectionCeiling = kDownloadPartsMin;
  int lastHealthyConnections = 0;
  bool slowStartComplete = false;
  List<int> rampBatches = const <int>[];
  int rampBatchIndex = 0;
  int currentBatchRemaining = 0;
  final Set<String> currentBatchPendingIds = {};
  Timer? aggregateProgressTimer;
  bool aggregateProgressDirty = false;
  bool aggregatePersistDirty = false;
  Timer? diskProgressTimer;
  Timer? coordinatorRecoveryTimer;
  int lastDiskObservedBytes = -1;
  DateTime? lastDiskObservedAt;
  double diskObservedSpeed = 0;
  bool parentRunningReported = false;
  DateTime? lastHostProfileSampleAt;
  Future<void> _pending = Future<void>.value();

  int get size => parts.fold(0, (sum, part) => sum + part.size);
  int get creditedBytes => parts.fold<int>(
    0,
    (sum, part) =>
        sum +
        (part.complete
            ? part.size
            : (part.size * part.credibleProgress).floor()),
  );
  double get progress =>
      parts.fold<double>(
        0,
        (sum, part) => sum + part.size * part.credibleProgress,
      ) /
      size;
  Future<void> get idle => _pending;

  void cancelAggregateProgress() {
    aggregateProgressTimer?.cancel();
    aggregateProgressTimer = null;
    aggregateProgressDirty = false;
    aggregatePersistDirty = false;
  }

  void cancelDiskProgressPoll() {
    diskProgressTimer?.cancel();
    diskProgressTimer = null;
    lastDiskObservedBytes = -1;
    lastDiskObservedAt = null;
    diskObservedSpeed = 0;
  }

  void cancelCoordinatorRecovery() {
    coordinatorRecoveryTimer?.cancel();
    coordinatorRecoveryTimer = null;
  }

  void resetRamp() {
    cancelPartRetries();
    connectionCeiling = kDownloadPartsMin;
    lastHealthyConnections = 0;
    slowStartComplete = false;
    rampBatches = const <int>[];
    rampBatchIndex = 0;
    currentBatchRemaining = 0;
    currentBatchPendingIds.clear();
  }

  void cancelPartRetries() {
    for (final part in parts) {
      part.recoveryTimer?.cancel();
      part.recoveryTimer = null;
      part.tailStallTimer?.cancel();
      part.tailStallTimer = null;
    }
  }

  Future<T> serialize<T>(Future<T> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

class _DownloadPart {
  _DownloadPart(
    this.task,
    this.from,
    this.to, {
    this.progress = 0,
    this.complete = false,
    double? credibleProgress,
    this.needsCredibleProgressRepair = false,
  }) : credibleProgress = complete
           ? 1
           : (credibleProgress ??
                     (progress >= kParallelNativeCompletionSentinel
                         ? 0
                         : progress))
                 .clamp(0.0, 1.0)
                 .toDouble();

  DownloadTask task;
  final int from;
  final int to;

  /// Raw native/resume marker. This may legitimately be 0.999 while the
  /// complete callback is pending, so it is not used for parent byte totals.
  double progress;

  /// Byte-credible progress used by the logical episode/UI. A 0.999 sentinel
  /// never advances this field by itself.
  double credibleProgress;

  bool complete;
  bool launched = false;
  double speed = 0;
  int recoveryAttempts = 0;
  Timer? recoveryTimer;
  Timer? tailStallTimer;
  double tailWatchProgress = -1;
  bool tailRecoveryAttempted = false;
  bool needsCredibleProgressRepair;
  int lastNativeBridgeBytes = -1;
  DateTime? lastNativeBridgeAt;

  int get size => to - from + 1;

  factory _DownloadPart.fromJson(Map<String, dynamic> json) {
    final restored = Task.createFromJson(
      Map<String, dynamic>.from(json['task'] as Map),
    ) as DownloadTask;
    final complete = json['complete'] as bool;
    final rawProgress = (json['progress'] as num).toDouble();
    final savedCredible = json['credibleProgress'];
    final hasSavedCredible = savedCredible is num;
    final legacyTailSentinel =
        !complete &&
        !hasSavedCredible &&
        rawProgress >= kParallelNativeCompletionSentinel;
    return _DownloadPart(
      restored.copyWith(retries: kDownloadPartRetries),
      json['from'] as int,
      json['to'] as int,
      progress: complete ? 1 : rawProgress,
      complete: complete,
      credibleProgress: complete
          ? 1
          : (hasSavedCredible ? savedCredible.toDouble() : null),
      needsCredibleProgressRepair: legacyTailSentinel,
    );
  }

  Map<String, dynamic> toJson() => {
    'task': task.toJson(),
    'from': from,
    'to': to,
    'progress': progress,
    'credibleProgress': credibleProgress,
    'complete': complete,
  };
}
