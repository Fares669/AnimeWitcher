import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;

import 'download_connection_governor.dart';
import 'download_parallel.dart';
import '../utils/download_resume.dart';

/// Child connections tend to report progress in a tight burst at the native
/// progress cadence. Collapse that burst into one parent/UI sample so four or
/// sixteen connections do not make the displayed bytes and speed jump several
/// times back-to-back for the same measurement interval.
const Duration kParallelProgressCoalesceDelay = Duration(milliseconds: 350);

/// Automatic child recovery is intentionally unbounded while the logical
/// episode is active: transient URLSession/system/network interruptions must
/// never turn into a user-visible pause. Backoff is capped so an unavailable
/// origin does not create a tight retry loop. Any real forward progress resets
/// the attempt counter back to zero.
const int kParallelRecoveryMaxBackoffMultiplier = 15;

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
    required this.startPart,
    required this.pausePart,
    required this.cancelParts,
    required this.saveRecord,
    required this.recordForId,
    required this.onUpdate,
    required this.onPartProgress,
    this.livePartIds,
    this.recoveryDelay = const Duration(seconds: 1),
    this.maxActiveConnections = kDownloadGlobalConnectionBudget,
  });

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

  final Map<String, _ParallelSession> _sessions = {};
  final Map<String, _ParallelSession> _children = {};
  final Set<String> _activeConnectionIds = {};
  final DownloadConnectionGovernor _connectionGovernor =
      DownloadConnectionGovernor();
  Future<void>? _pumpFuture;
  bool _disposed = false;

  bool isActive(String id) => !_disposed && (_sessions[id]?.active ?? false);

  bool hasLiveConnections(String id) {
    final session = _sessions[id];
    return session != null && _activeConnectionsForSession(session) > 0;
  }

  /// Includes native tasks that were handed to the OS but are still waiting
  /// for a socket. Counting them is deliberate: the manager never queues more
  /// than the global connection budget into URLSession/background_downloader.
  int get activeConnectionCount => _activeConnectionIds.length;

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
    for (final session in _sessions.values) {
      session.cancelAggregateProgress();
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
  /// stay associated with the same child taskIds. Native retries are normalized
  /// away so imported downloads use the same single recovery owner as new ones.
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

        if (await _adoptCompletedTarget(session)) return true;

        await _restoreNativeOwnership(session);
        for (final part in session.parts) {
          part.speed = 0;
          part.recoveryAttempts = 0;
          if (part.launched) continue;
          final saved = await canonicalizePartialDownloadFile(
            destinationPath: await part.task.filePath(),
          );
          final file = saved?.file ?? File(await part.task.filePath());
          if (await file.exists() && await file.length() == part.size) {
            part.complete = true;
            part.progress = 1;
            _activeConnectionIds.remove(part.task.taskId);
            part.launched = false;
            continue;
          }
          if (part.complete) throw StateError('A completed part is missing');
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
        await _persist(session);
        _schedulePumpAll();
        return true;
      } catch (_) {
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

  int _unlaunchedPartCount(_ParallelSession session) =>
      session.parts.where((part) => !part.complete && !part.launched).length;

  Future<bool> _pumpSession(_ParallelSession session) async {
    if (_disposed || !session.active || session.deleted) return true;

    while (!_disposed && session.active && !session.deleted) {
      if (session.currentBatchRemaining == 0) {
        if (session.currentBatchPendingIds.isNotEmpty) return true;
        if (session.rampBatchIndex < session.rampBatches.length) {
          session.currentBatchRemaining =
              session.rampBatches[session.rampBatchIndex++];
        } else {
          session.slowStartComplete = true;
          final sessionAvailable =
              session.connectionCeiling - _activeConnectionsForSession(session);
          if (sessionAvailable <= 0) return true;
          final remaining = _unlaunchedPartCount(session);
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
      final parts = session.parts
          .where((part) => !part.complete && !part.launched)
          .take(launchCount)
          .toList(growable: false);

      if (parts.isEmpty) {
        session.currentBatchRemaining = 0;
        continue;
      }

      for (final part in parts) {
        if (_disposed) return true;
        final record = await recordForId(part.task.taskId);
        final progress = record?.progress ?? 0;
        if (progress > part.progress && progress <= 1) {
          part.progress = progress;
        }

        part.launched = true;
        _activeConnectionIds.add(part.task.taskId);
        session.currentBatchPendingIds.add(part.task.taskId);
        session.currentBatchRemaining--;

        if (!await startPart(part.task, part.progress, part.size)) {
          session.currentBatchPendingIds.remove(part.task.taskId);
          _schedulePartRecovery(session, part);
          // Automatic recovery is still an active logical download. Persisting
          // waitingToRetry here made the parent notification flash as paused.
          await _status(session, TaskStatus.running);
          return true;
        }

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

  void _releaseConnection(_DownloadPart part) {
    part.recoveryTimer?.cancel();
    part.recoveryTimer = null;
    _activeConnectionIds.remove(part.task.taskId);
    part.launched = false;
    part.speed = 0;
    _schedulePumpAll();
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
    session.currentBatchRemaining = 0;
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

  void _scheduleAggregateProgress(_ParallelSession session) {
    if (_disposed || !session.active || session.deleted) return;
    session.aggregateProgressDirty = true;
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
          session.aggregateProgressDirty = false;
          await _emitAggregateProgress(session);
        }),
      );
    });
  }

  Future<void> _emitAggregateProgress(_ParallelSession session) async {
    final progress = session.progress;
    final speed = session.parts.fold<double>(
      0,
      (sum, child) => sum + (child.complete ? 0 : child.speed),
    );
    final timeRemaining = _aggregateTimeRemaining(session, speed);

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
      (sum, part) => sum + part.size * (1 - part.progress),
    );
    if (remainingBytes <= 0) return Duration.zero;

    final seconds = (remainingBytes / (speedMb * 1000 * 1000)).ceil();
    return Duration(seconds: seconds < 1 ? 1 : seconds);
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
                      await _pause(session);
                    } else {
                      await _persist(session);
                    }
                  } catch (_) {
                    await _pause(session);
                  }
                });
              }
            })
            .catchError((Object _, StackTrace _) {})
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
    if (session.currentBatchRemaining > 0) return true;
    if (session.currentBatchPendingIds.isNotEmpty) return false;
    if (session.rampBatchIndex < session.rampBatches.length) return true;
    return _unlaunchedPartCount(session) > 0;
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
            final previousProgress = part.progress;
            part.progress = update.progress > part.progress
                ? update.progress
                : part.progress;
            if (part.progress > previousProgress) {
              part.recoveryAttempts = 0;
            }
            part.speed = update.networkSpeed > 0 ? update.networkSpeed : 0;
            onPartProgress(
              session.task.taskId,
              part.task.taskId,
              part.progress,
            );
            await _persist(session);
            if (session.active) {
              _scheduleAggregateProgress(session);
            }
            _schedulePumpAll();
            return;
          }

          if (update is! TaskStatusUpdate) return;

          if (session.active && update.status == TaskStatus.waitingToRetry) {
            // Old in-flight workers created before this update can still enter
            // native retry. Keep the slot reserved, but the logical episode is
            // running/reconnecting rather than user-paused.
            part.launched = true;
            part.speed = 0;
            _activeConnectionIds.add(part.task.taskId);
            _applyConnectionPressure(session, update);
            await _persist(session);
            await _status(session, TaskStatus.running);
            return;
          }

          if (update.status == TaskStatus.complete) {
            final file = File(await part.task.filePath());
            final exists = await file.exists();
            final length = exists ? await file.length() : -1;

            if (exists &&
                length == session.size &&
                length != part.size &&
                await _adoptIgnoredRangeFullBody(session, part, update)) {
              return;
            }

            if (!exists || length != part.size) {
              throw StateError(
                'Invalid byte count for part ${part.task.taskId}',
              );
            }
            _markConnectionReady(session, part);
            _releaseConnection(part);
            part.complete = true;
            part.progress = 1;
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
              _schedulePartRecovery(session, part);
              await _status(session, TaskStatus.running);
              return;
            }

            _markConnectionReady(session, part);
            _releaseConnection(part);
            await _pause(session);
          }
        } catch (_) {
          if (!_disposed && !session.deleted) await _pause(session);
        }
      }),
    );
    return true;
  }

  Future<void> pause(ParallelDownloadTask task) async {
    if (_disposed) return;
    if (!await restore(task)) return;
    final session = _sessions[task.taskId]!;
    await session.serialize(() => _pause(session));
  }

  bool _shouldAutomaticallyRecoverPart(TaskStatusUpdate update) {
    switch (update.status) {
      case TaskStatus.paused:
      case TaskStatus.canceled:
      case TaskStatus.notFound:
        return true;
      case TaskStatus.failed:
        final exception = update.exception;
        final statusCode = update.responseStatusCode ??
            (exception is TaskHttpException ? exception.httpResponseCode : null);
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
    part.recoveryAttempts++;
    part.speed = 0;
    part.launched = true;
    _activeConnectionIds.add(part.task.taskId);
    session.currentBatchPendingIds.add(part.task.taskId);
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
          try {
            if (await startPart(part.task, part.progress, part.size)) return;
          } catch (_) {}
          if (_schedulePartRecovery(session, part)) {
            await _status(session, TaskStatus.running);
          }
        }),
      );
    });
    return true;
  }

  Future<void> reconcile(Future<Set<String>> Function() liveTaskIds) async {
    for (final session in List<_ParallelSession>.from(_sessions.values)) {
      await session.serialize(() async {
        if (_disposed || !session.active || session.deleted) return;
        final live = await liveTaskIds();
        var recovering = false;
        for (final part in session.parts) {
          if (part.complete ||
              !part.launched ||
              part.recoveryTimer != null ||
              live.contains(part.task.taskId)) {
            continue;
          }
          final file = File(await part.task.filePath());
          if (await file.exists() && await file.length() == part.size) {
            _markConnectionReady(session, part);
            _releaseConnection(part);
            part.complete = true;
            part.progress = 1;
          } else {
            recovering = _schedulePartRecovery(session, part) || recovering;
          }
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

  Future<void> _pause(_ParallelSession session) async {
    session.active = false;
    session.generation++;
    session.cancelAggregateProgress();
    session.resetRamp();
    await Future.wait(
      session.parts.where((part) => !part.complete).map((part) async {
        try {
          await pausePart(part.task);
        } catch (_) {}
        part.launched = false;
        part.speed = 0;
      }),
    );
    final ids = session.parts.map((part) => part.task.taskId).toSet();
    _activeConnectionIds.removeWhere(ids.contains);
    await _persist(session);
    await _status(session, TaskStatus.paused);
    _schedulePumpAll();
  }

  Future<void> cancel(ParallelDownloadTask task) async {
    if (_disposed) return;
    if (!await restore(task)) return;
    final session = _sessions[task.taskId]!;
    session.deleted = true;
    session.active = false;
    session.cancelAggregateProgress();
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
      } catch (_) {}
    }

    await source.rename(target.path);
    sourcePart.complete = true;
    sourcePart.progress = 1;
    await _finishCompleteSession(session);
    return true;
  }

  Future<void> _finishCompleteSession(_ParallelSession session) async {
    session.active = false;
    session.cancelAggregateProgress();
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
    final target = File(await session.task.filePath());
    final staging = File('${target.path}.assembling');
    final output = await staging.open(mode: FileMode.write);
    try {
      for (final part in session.parts) {
        final file = File(await part.task.filePath());
        if (await file.length() != part.size) {
          throw StateError('Part size changed');
        }
        await for (final bytes in file.openRead()) {
          if (session.deleted) return;
          await output.writeFrom(bytes);
        }
      }
      await output.flush();
    } finally {
      await output.close();
    }
    if (session.deleted) return;
    if (await staging.length() != session.size) {
      throw StateError('Incomplete assembly');
    }
    if (await target.exists()) await target.delete();
    await staging.rename(target.path);
    await _finishCompleteSession(session);
  }
}

class _ParallelSession {
  _ParallelSession(this.task, this.manifest, this.parts);

  final ParallelDownloadTask task;
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
  Future<void> _pending = Future<void>.value();

  int get size => parts.fold(0, (sum, part) => sum + part.size);
  double get progress =>
      parts.fold<double>(0, (sum, part) => sum + part.size * part.progress) /
      size;
  Future<void> get idle => _pending;

  void cancelAggregateProgress() {
    aggregateProgressTimer?.cancel();
    aggregateProgressTimer = null;
    aggregateProgressDirty = false;
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
  });

  final DownloadTask task;
  final int from;
  final int to;
  double progress;
  bool complete;
  bool launched = false;
  double speed = 0;
  int recoveryAttempts = 0;
  Timer? recoveryTimer;

  int get size => to - from + 1;

  factory _DownloadPart.fromJson(Map<String, dynamic> json) {
    final restored = Task.createFromJson(
      Map<String, dynamic>.from(json['task'] as Map),
    ) as DownloadTask;
    return _DownloadPart(
      restored.copyWith(retries: kDownloadPartRetries),
      json['from'] as int,
      json['to'] as int,
      progress: (json['progress'] as num).toDouble(),
      complete: json['complete'] as bool,
    );
  }

  Map<String, dynamic> toJson() => {
    'task': task.toJson(),
    'from': from,
    'to': to,
    'progress': progress,
    'complete': complete,
  };
}
