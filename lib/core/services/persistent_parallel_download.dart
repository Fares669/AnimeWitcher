import 'download_diagnostic_log.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:path/path.dart' as p;

import 'download_connection_governor.dart';
import 'download_parallel.dart';
import 'download_retry_policy.dart';
import 'download_telemetry.dart';
import '../utils/download_resume.dart';

/// Child connections can report progress independently and in bursts. The
/// logical episode, Flutter UI and iOS continued-processing task all publish
/// one aggregate sample per second so they show the same bytes/speed/ETA.
const Duration kParallelProgressCoalesceDelay = Duration(seconds: 1);

/// Progress manifests are durable recovery checkpoints, not a telemetry bus.
/// Persist at most once per second while bytes are flowing; exact completion,
/// pause and cancel boundaries still persist synchronously. This prevents 5-16
/// child callbacks from creating a serialized fsync backlog that starves the
/// parent progress stream.
const Duration kParallelProgressPersistInterval = Duration(seconds: 1);

/// Keep a small reserve beyond the remaining staging allocation so assembly
/// does not consume the filesystem down to its last metadata blocks.
const int kParallelAssemblyStorageReserveBytes = 8 * 1024 * 1024;

enum ParallelAssemblyFailureReason { insufficientStorage }

class ParallelAssemblyFailure {
  const ParallelAssemblyFailure({
    required this.parentTaskId,
    required this.reason,
  });

  final String parentTaskId;
  final ParallelAssemblyFailureReason reason;
}

/// Durable multipart manifest schema. Version 1 was the legacy payload that
/// contained only `parts`. Version 2 added logical generation/expected byte
/// identity. Version 3 also pins the first strong ETag (or Last-Modified)
/// observed from a validated child response, so later/relaunched ranges
/// cannot silently assemble bytes from a different resource generation.
/// Version 4 also persists whether a child must bypass old native resumeData
/// after its parent source URL was refreshed. Version 5 adds exact per-part
/// durable byte counters. Version 6 also persists the complete logical parent
/// task descriptor so a manifest can participate in startup inventory even if
/// executor/JobStore projections were lost. Floating-point progress remains
/// presentation/history only and is never recovery byte authority.
const int kParallelManifestSchemaVersion = 6;

class ParallelManifestRecoveryEvidence {
  const ParallelManifestRecoveryEvidence({
    required this.manifestFile,
    required this.schemaVersion,
    required this.parentTaskId,
    required this.parentTask,
    required this.childTasks,
    required this.expectedBytes,
    required this.durableBytes,
    required this.checkpointSequence,
  });

  final File manifestFile;
  final int schemaVersion;
  final String parentTaskId;
  final ParallelDownloadTask? parentTask;
  final List<DownloadTask> childTasks;
  final int expectedBytes;
  final int durableBytes;
  final int checkpointSequence;
}

class _DiscoveredParallelManifestCandidate {
  const _DiscoveredParallelManifestCandidate({
    required this.evidence,
    required this.modifiedMillis,
    required this.isTemp,
  });

  final ParallelManifestRecoveryEvidence evidence;
  final int modifiedMillis;
  final bool isTemp;
}

/// Enumerates durable multipart checkpoints below explicitly trusted roots.
///
/// Discovery never infers logical identity from a filename. Schema-v6
/// manifests can carry a verified parent task descriptor; older manifests
/// remain visible as unresolved evidence so startup can avoid silently
/// discarding their children without fabricating a parent.
Future<List<ParallelManifestRecoveryEvidence>>
discoverParallelManifestRecoveryEvidence(Iterable<Directory> roots) async {
  final grouped = <String, List<_DiscoveredParallelManifestCandidate>>{};

  for (final root in roots) {
    try {
      if (!await root.exists()) continue;
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name != 'manifest.json' && name != 'manifest.json.tmp') {
          continue;
        }
        final isTemp = name.endsWith('.tmp');
        final canonicalPath = p.normalize(
          isTemp
              ? entity.path.substring(0, entity.path.length - 4)
              : entity.path,
        );

        try {
          final decoded = jsonDecode(await entity.readAsString());
          if (decoded is! Map) continue;
          final snapshot = Map<String, dynamic>.from(decoded);
          final schemaVersion =
              (snapshot['schemaVersion'] as num?)?.toInt() ?? 1;
          if (schemaVersion < 1 ||
              schemaVersion > kParallelManifestSchemaVersion) {
            continue;
          }
          final parentTaskId =
              snapshot['parentTaskId']?.toString().trim() ?? '';
          if (parentTaskId.isEmpty) continue;
          final checkpointSequence =
              (snapshot['checkpointSequence'] as num?)?.toInt() ?? 0;
          if (checkpointSequence < 0) continue;
          final rawParts = snapshot['parts'];
          if (rawParts is! List || rawParts.isEmpty) continue;

          final childTasks = <DownloadTask>[];
          var layoutValid = true;
          var nextByte = 0;
          var calculatedBytes = 0;
          var durableBytes = 0;
          for (final rawPart in rawParts) {
            if (rawPart is! Map) {
              layoutValid = false;
              break;
            }
            final part = Map<String, dynamic>.from(rawPart);
            final from = (part['from'] as num?)?.toInt();
            final to = (part['to'] as num?)?.toInt();
            final rawTask = part['task'];
            if (from == null ||
                to == null ||
                from != nextByte ||
                to < from ||
                rawTask is! Map) {
              layoutValid = false;
              break;
            }
            final restored = Task.createFromJson(
              Map<String, dynamic>.from(rawTask),
            );
            if (restored is! DownloadTask ||
                !restored.taskId.startsWith('$parentTaskId.part.')) {
              layoutValid = false;
              break;
            }
            final size = to - from + 1;
            final savedDurable = (part['durableBytes'] as num?)?.toInt();
            final complete = part['complete'] == true;
            if (savedDurable != null &&
                (savedDurable < 0 || savedDurable > size)) {
              layoutValid = false;
              break;
            }
            durableBytes += complete
                ? size
                : (savedDurable == null ? 0 : savedDurable);
            childTasks.add(restored);
            calculatedBytes += size;
            nextByte = to + 1;
          }
          if (!layoutValid || childTasks.isEmpty || calculatedBytes <= 0) {
            continue;
          }

          final declaredBytes =
              (snapshot['totalBytes'] as num?)?.toInt() ??
              (snapshot['expectedBytes'] as num?)?.toInt() ??
              -1;
          if (declaredBytes > 0 && declaredBytes != calculatedBytes) {
            continue;
          }
          final expectedBytes = declaredBytes > 0
              ? declaredBytes
              : calculatedBytes;

          ParallelDownloadTask? parentTask;
          final rawParent = snapshot['parentTask'];
          if (schemaVersion >= 6 && rawParent is Map) {
            try {
              final restored = Task.createFromJson(
                Map<String, dynamic>.from(rawParent),
              );
              if (restored is ParallelDownloadTask &&
                  restored.taskId == parentTaskId) {
                final expectedManifest = p.normalize(
                  '${await restored.filePath()}.parts/manifest.json',
                );
                if (expectedManifest == canonicalPath) {
                  parentTask = restored;
                }
              }
            } catch (_) {
              parentTask = null;
            }
          }

          final stat = await entity.stat();
          final evidence = ParallelManifestRecoveryEvidence(
            manifestFile: File(canonicalPath),
            schemaVersion: schemaVersion,
            parentTaskId: parentTaskId,
            parentTask: parentTask,
            childTasks: List<DownloadTask>.unmodifiable(childTasks),
            expectedBytes: expectedBytes,
            durableBytes: durableBytes.clamp(0, expectedBytes),
            checkpointSequence: checkpointSequence,
          );
          grouped
              .putIfAbsent(
                canonicalPath,
                () => <_DiscoveredParallelManifestCandidate>[],
              )
              .add(
                _DiscoveredParallelManifestCandidate(
                  evidence: evidence,
                  modifiedMillis: stat.modified.millisecondsSinceEpoch,
                  isTemp: isTemp,
                ),
              );
        } catch (_) {
          // Torn/corrupt checkpoints never become recovery authority.
        }
      }
    } catch (_) {
      // One inaccessible trusted root must not block other roots.
    }
  }

  final result = <ParallelManifestRecoveryEvidence>[];
  for (final candidates in grouped.values) {
    candidates.sort((a, b) {
      final bySequence = b.evidence.checkpointSequence.compareTo(
        a.evidence.checkpointSequence,
      );
      if (bySequence != 0) return bySequence;
      final byModified = b.modifiedMillis.compareTo(a.modifiedMillis);
      if (byModified != 0) return byModified;
      if (a.isTemp == b.isTemp) return 0;
      return a.isTemp ? -1 : 1;
    });
    result.add(candidates.first.evidence);
  }
  result.sort((a, b) {
    final byId = a.parentTaskId.compareTo(b.parentTaskId);
    if (byId != 0) return byId;
    return a.manifestFile.path.compareTo(b.manifestFile.path);
  });
  return result;
}

/// Validate response metadata from a native multipart child. A full HTTP
/// 200 is safe only when this child already represents the entire resource;
/// multi-part ignored-Range responses are handled by the full-body fallback.
/// For HTTP 206 the final byte and total resource size must match the
/// immutable manifest Range. The response start may be inside the Range
/// because URLSession resumeData can restart from an already durable prefix.
bool downloadPartResponseMatchesRequestedRange({
  required int from,
  required int to,
  required int resourceSize,
  required int? statusCode,
  required Map<String, String>? responseHeaders,
}) {
  // Older platform/plugin updates did not always expose final response
  // metadata. Preserve compatibility there; current background_downloader
  // supplies response headers/status for successful final states.
  if (statusCode == null && responseHeaders == null) return true;
  if (statusCode == 200) return from == 0 && to == resourceSize - 1;
  if (statusCode != 206 || responseHeaders == null) return false;

  String? contentRange;
  for (final entry in responseHeaders.entries) {
    if (entry.key.toLowerCase() == 'content-range') {
      contentRange = entry.value.trim().toLowerCase();
      break;
    }
  }
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
      .firstMatch(contentRange ?? '');
  if (match == null) return false;
  final responseStart = int.parse(match[1]!);
  final responseEnd = int.parse(match[2]!);
  final responseSize = int.parse(match[3]!);
  return responseStart >= from &&
      responseStart <= to &&
      responseEnd == to &&
      responseSize == resourceSize;
}

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

/// Deadline for an accepted multipart enqueue to prove native ownership.
/// Expiry never guesses that ownership ended: the coordinator first queries
/// runtime liveness and visible durable bytes, and keeps the lease while
/// ownership is unknown.
const Duration kParallelPendingStartLeaseDelay = Duration(seconds: 5);

class NativeParallelBackgroundPlan {
  const NativeParallelBackgroundPlan({
    required this.parentTaskId,
    required this.maxConcurrent,
    required this.tasks,
  });

  final String parentTaskId;
  final int maxConcurrent;
  final List<DownloadTask> tasks;
}

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
    this.shouldRecoverFailedStart,
    this.onSourceRefreshNeeded,
    this.verifyPartSource,
    this.shouldDrainPartOnPause,
    this.onPausedDrainSettled,
    this.recoveryDelay = const Duration(seconds: 1),
    this.tailStallDelay = kParallelTailStallDelay,
    this.diskProgressPollInterval = kParallelDiskProgressPollInterval,
    this.pendingStartLeaseDelay = kParallelPendingStartLeaseDelay,
    this.maxActiveConnections = kDownloadGlobalConnectionBudget,
    this.onHostPressure,
    this.onHostSample,
    this.availableStorageBytes,
    this.onAssemblyFailure,
    this.assemblyStorageReserveBytes = kParallelAssemblyStorageReserveBytes,
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
  final bool Function(String childTaskId)? shouldRecoverFailedStart;
  final void Function(String parentTaskId)? onSourceRefreshNeeded;
  final Future<({bool matches, String? validator})> Function(
    DownloadTask task,
    File file,
    int bytes,
  )?
  verifyPartSource;

  /// Whether this launched child must avoid transport pause and finish its
  /// current immutable Range into a durable file instead. Used on iOS where
  /// URLSession cancelByProducingResumeData can cancel a task and still return
  /// no resume data. The policy is consulted only when pause() explicitly asks
  /// to preserve live parts.
  final bool Function(DownloadTask task)? shouldDrainPartOnPause;
  final void Function(String parentTaskId)? onPausedDrainSettled;
  final Duration recoveryDelay;
  final Duration tailStallDelay;
  final Duration diskProgressPollInterval;
  final Duration pendingStartLeaseDelay;
  final void Function(String url, int fallbackCeiling)? onHostPressure;
  final void Function(String url, int activeConnections, double bytesPerSecond)?
  onHostSample;

  /// Returns free bytes on the volume containing [path]. Null means the host
  /// could not answer, in which case allocation errors remain the safety net.
  final Future<int?> Function(String path)? availableStorageBytes;
  final void Function(ParallelAssemblyFailure failure)? onAssemblyFailure;
  final int assemblyStorageReserveBytes;

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

  /// Exact recoverable bytes proven by the current multipart manifest/disk.
  int? durableBytesFor(String id) => _sessions[id]?.creditedBytes;

  /// Fresh, generation-fenced Range children that iOS may start directly on
  /// the already-running background URLSession while Dart is suspended. The
  /// native cap is the session's *currently proven* active width, never the
  /// configured ceiling, so moving to background cannot bypass slow-start or
  /// the host governor. Only zero-byte children are exported: URLSession resume
  /// blobs and source-refresh validation remain owned by Dart.
  List<NativeParallelBackgroundPlan> nativeBackgroundPlans() {
    if (_disposed) return const <NativeParallelBackgroundPlan>[];
    final plans = <NativeParallelBackgroundPlan>[];
    for (final session in _sessions.values) {
      if (!session.active || session.pauseRequested || session.deleted)
        continue;
      final provenWidth = _activeConnectionsForSession(session);
      if (provenWidth <= 0) continue;
      final tasks = session.parts
          .where(
            (part) =>
                !part.complete &&
                !part.launched &&
                part.recoveryTimer == null &&
                part.attemptGeneration > 0 &&
                !part.sourceValidationRequired &&
                part.progress <= 0 &&
                part.credibleProgress <= 0,
          )
          .map((part) => part.task)
          .toList(growable: false);
      if (tasks.isEmpty) continue;
      plans.add(
        NativeParallelBackgroundPlan(
          parentTaskId: session.task.taskId,
          maxConcurrent: provenWidth.clamp(1, kDownloadGlobalConnectionBudget),
          tasks: tasks,
        ),
      );
    }
    return plans;
  }

  /// Repair a child whose native resume checkpoint claimed progress but no
  /// resumable/native/on-disk bytes survived. The immutable Range itself is
  /// retained; only the unprovable prefix is discarded so recovery can fetch
  /// that one Range again instead of retrying a phantom checkpoint forever.
  ///
  /// This is intentionally synchronous because it is called by [startPart]
  /// while the owning session is already serialized in [_pumpSession].
  bool resetUndurablePartProgress(String childTaskId, {int durableBytes = 0}) {
    if (_disposed) return false;
    final session = _children[childTaskId];
    if (session == null || session.deleted) return false;
    _DownloadPart? part;
    for (final candidate in session.parts) {
      if (candidate.task.taskId == childTaskId) {
        part = candidate;
        break;
      }
    }
    if (part == null || part.complete) return false;
    if (durableBytes < 0 || durableBytes > part.size) return false;

    final repaired = part.size > 0
        ? (durableBytes / part.size).clamp(0.0, 1.0).toDouble()
        : 0.0;
    _cancelTailStallWatch(part);
    part.progress = repaired;
    part.credibleProgress = repaired;
    part.durableBytes = durableBytes;
    part.speed = 0;
    part.recoveryAttempts = 0;
    part.tailRecoveryAttempted = false;
    part.tailWatchProgress = -1;
    part.lastNativeBridgeBytes = durableBytes;
    part.lastNativeBridgeAt = null;
    onPartProgress(session.task.taskId, childTaskId, repaired);
    if (session.active) _scheduleAggregateProgress(session);
    return true;
  }

  /// Clear the one-shot source-refresh fence after the child has either
  /// opened a prefix-validated Range on the refreshed URL or restarted that
  /// immutable Range from byte zero.
  Future<bool> markPartSourceValidated(String childTaskId) async {
    if (_disposed) return false;
    final session = _children[childTaskId];
    if (session == null || session.deleted) return false;
    return session.serialize(() async {
      _DownloadPart? match;
      for (final part in session.parts) {
        if (part.task.taskId == childTaskId) {
          match = part;
          break;
        }
      }
      if (match == null) return false;
      if (!match.sourceValidationRequired) return true;
      match.sourceValidationRequired = false;
      _refreshPartAttemptMetadata(session, match);
      await _persist(session);
      return true;
    });
  }

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

      // Before retaining any visible byte from the previous signed source,
      // prove that the refreshed URL serves the same resource. Validators are
      // checked when available; otherwise every visible part prefix is compared
      // byte-for-byte. Hidden native resumeData cannot be proven here and is
      // therefore fenced so _startPart will re-fetch that Range from byte zero.
      var refreshedValidator = session.resourceValidator;
      final verifier = verifyPartSource;
      for (final part in session.parts) {
        File? localFile;
        var localBytes = 0;
        try {
          final saved = await canonicalizePartialDownloadFile(
            destinationPath: await part.task.filePath(),
          );
          if (saved != null) {
            localFile = saved.file;
            localBytes = saved.bytes;
          } else {
            final candidate = File(await part.task.filePath());
            if (await candidate.exists()) {
              localFile = candidate;
              localBytes = await candidate.length();
            }
          }
        } catch (_) {}

        if (part.complete && localBytes != part.size) return null;
        if (localFile == null || localBytes <= 0) continue;
        if (verifier == null) return null;

        final probeHeaders = Map<String, String>.from(headers)
          ..removeWhere(
            (key, _) =>
                key.toLowerCase() == 'range' || key.toLowerCase() == 'if-range',
          );
        probeHeaders['Range'] = 'bytes=${part.from}-${part.to}';
        probeHeaders['Accept-Encoding'] = 'identity';
        final probeTask = part.task.copyWith(url: url, headers: probeHeaders);
        final probe = await verifier(probeTask, localFile, localBytes);
        if (!probe.matches) return null;
        final observed = probe.validator;
        if (observed != null) {
          if (refreshedValidator != null && refreshedValidator != observed) {
            return null;
          }
          refreshedValidator = observed;
        }
      }

      final updated = task.copyWith(
        url: url,
        headers: Map<String, String>.from(headers),
      );
      session.task = updated;
      session.resourceValidator = refreshedValidator;
      for (final part in session.parts) {
        final childHeaders = Map<String, String>.from(headers)
          ..removeWhere(
            (key, _) =>
                key.toLowerCase() == 'range' || key.toLowerCase() == 'if-range',
          );
        childHeaders['Range'] = 'bytes=${part.from}-${part.to}';
        childHeaders['Accept-Encoding'] = 'identity';
        final validator = session.resourceValidator;
        if (validator != null) childHeaders['If-Range'] = validator;

        // Native resumeData can embed the old signed URL. Any unfinished child
        // with a saved prefix must switch through the validated Dart Range path
        // once before native resume is allowed again.
        part.sourceValidationRequired =
            !part.complete && (part.progress > 0 || part.credibleProgress > 0);
        part.task = part.task.copyWith(
          url: url,
          headers: childHeaders,
          retries: kDownloadPartRetries,
        );
        _refreshPartAttemptMetadata(session, part);
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

  Future<List<File>> _orderedManifestCandidates(
    File manifest,
    File temp,
    String taskId,
  ) async {
    final ranked = <_ManifestRestoreCandidate>[];
    for (final file in <File>[manifest, temp]) {
      try {
        if (!await file.exists()) continue;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map) continue;
        final snapshot = Map<String, dynamic>.from(decoded);
        final parentTaskId = snapshot['parentTaskId']?.toString().trim();
        if (parentTaskId != null &&
            parentTaskId.isNotEmpty &&
            parentTaskId != taskId) {
          continue;
        }
        final sequence = (snapshot['checkpointSequence'] as num?)?.toInt() ?? 0;
        if (sequence < 0) continue;
        final stat = await file.stat();
        ranked.add(
          _ManifestRestoreCandidate(
            file: file,
            sequence: sequence,
            modifiedMillis: stat.modified.millisecondsSinceEpoch,
            isTemp: file.path == temp.path,
          ),
        );
      } catch (_) {
        // A torn candidate is ignored; the other durable snapshot can win.
      }
    }
    ranked.sort((a, b) {
      final bySequence = b.sequence.compareTo(a.sequence);
      if (bySequence != 0) return bySequence;
      final byModified = b.modifiedMillis.compareTo(a.modifiedMillis);
      if (byModified != 0) return byModified;
      if (a.isTemp == b.isTemp) return 0;
      return a.isTemp ? -1 : 1;
    });
    return ranked.map((candidate) => candidate.file).toList(growable: false);
  }

  bool _validRestoredLayout(List<_DownloadPart> parts, int declaredTotalBytes) {
    if (parts.isEmpty) return false;
    var nextByte = 0;
    var total = 0;
    for (final part in parts) {
      if (part.from != nextByte || part.to < part.from) return false;
      total += part.size;
      nextByte = part.to + 1;
    }
    if (total <= 0) return false;
    return declaredTotalBytes <= 0 || declaredTotalBytes == total;
  }

  int? _taskAttemptGeneration(Task task) {
    try {
      final raw = task.metaData.trim();
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return (decoded['attemptGeneration'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  String _partAttemptMetadata(_ParallelSession session, _DownloadPart part) {
    final metadata = <String, dynamic>{};
    try {
      final raw = part.task.metaData.trim();
      if (raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          metadata.addAll(Map<String, dynamic>.from(decoded));
        }
      }
    } catch (_) {}
    metadata['parentTaskId'] = session.task.taskId;
    metadata['attemptGeneration'] = part.attemptGeneration;
    metadata['sourceValidationRequired'] = part.sourceValidationRequired;
    return jsonEncode(metadata);
  }

  void _refreshPartAttemptMetadata(
    _ParallelSession session,
    _DownloadPart part,
  ) {
    part.task = part.task.copyWith(
      metaData: _partAttemptMetadata(session, part),
    );
  }

  void _preparePartAttempt(_ParallelSession session, _DownloadPart part) {
    if (part.attemptGeneration <= 0) part.attemptGeneration = 1;
    _refreshPartAttemptMetadata(session, part);
  }

  void _invalidatePartAttempt(_ParallelSession session, _DownloadPart part) {
    part.attemptGeneration = part.attemptGeneration <= 0
        ? 1
        : part.attemptGeneration + 1;
    _refreshPartAttemptMetadata(session, part);
  }

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
      session.cancelProgressPersist();
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
    final candidates = await _orderedManifestCandidates(
      manifest,
      temp,
      task.taskId,
    );

    for (final candidate in candidates) {
      try {
        if (!await candidate.exists()) continue;
        final raw = await candidate.readAsString();
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final schemaVersion = (json['schemaVersion'] as num?)?.toInt() ?? 1;
        if (schemaVersion < 1 ||
            schemaVersion > kParallelManifestSchemaVersion) {
          continue;
        }
        final parentTaskId = json['parentTaskId']?.toString().trim();
        if (parentTaskId != null &&
            parentTaskId.isNotEmpty &&
            parentTaskId != task.taskId) {
          continue;
        }
        final savedGeneration = (json['generation'] as num?)?.toInt() ?? 0;
        final checkpointSequence =
            (json['checkpointSequence'] as num?)?.toInt() ?? 0;
        final declaredTotalBytes =
            (json['totalBytes'] as num?)?.toInt() ??
            (json['expectedBytes'] as num?)?.toInt() ??
            -1;
        if (savedGeneration < 0 || checkpointSequence < 0) continue;
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
            parts.any((part) => part.from < 0 || part.to < part.from) ||
            !_validRestoredLayout(parts, declaredTotalBytes)) {
          continue;
        }
        var contiguous = parts.first.from == 0;
        for (var index = 1; index < parts.length && contiguous; index++) {
          contiguous = parts[index].from == parts[index - 1].to + 1;
        }
        if (!contiguous) continue;
        final calculatedBytes = parts.fold<int>(
          0,
          (sum, part) => sum + part.size,
        );
        final savedExpectedBytes =
            (json['expectedBytes'] as num?)?.toInt() ?? -1;
        if (savedExpectedBytes > 0 && savedExpectedBytes != calculatedBytes) {
          continue;
        }
        final savedValidator = json['resourceValidator'] is String
            ? (json['resourceValidator'] as String).trim()
            : '';
        final session = _ParallelSession(
          task,
          manifest,
          parts,
          generation: savedGeneration,
          resourceValidator: savedValidator.isEmpty ? null : savedValidator,
        )..checkpointSequence = checkpointSequence;
        _applyPinnedValidatorToPendingParts(session);
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
                part.durableBytes = part.size;
              } else if (bytes > 0 && bytes < part.size) {
                part.credibleProgress = bytes / part.size;
                part.durableBytes = bytes;
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
      session.pauseRequested = false;
      session.active = true;
      session.resetRamp();
      try {
        // Future native background refills must carry the same attempt token as
        // the Dart-owned session. Preparing metadata does not launch anything
        // and does not increase the slow-start width.
        for (final part in session.parts) {
          if (!part.complete) _preparePartAttempt(session, part);
        }
        // Persist the logical generation before any child is handed to native IO.
        await _persist(session);
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
            part.durableBytes = part.size;
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
              part.durableBytes = saved.bytes;
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

  void _cancelPendingStartLease(_DownloadPart part) {
    part.pendingStartLeaseTimer?.cancel();
    part.pendingStartLeaseTimer = null;
  }

  void _rollbackPendingStartReservation(
    _ParallelSession session,
    _DownloadPart part,
  ) {
    _cancelPendingStartLease(part);
    if (session.currentBatchPendingIds.remove(part.task.taskId)) {
      session.currentBatchRemaining++;
    }
    _activeConnectionIds.remove(part.task.taskId);
    part.launched = false;
    part.speed = 0;
  }

  Future<int> _durablePartBytes(_DownloadPart part) async {
    try {
      final saved = await canonicalizePartialDownloadFile(
        destinationPath: await part.task.filePath(),
      );
      if (saved != null) return saved.bytes;
      final file = File(await part.task.filePath());
      if (await file.exists()) return await file.length();
    } catch (_) {}
    return 0;
  }

  void _armPendingStartLease(_ParallelSession session, _DownloadPart part) {
    if (_disposed ||
        !session.active ||
        session.pauseRequested ||
        session.deleted ||
        part.complete ||
        !part.launched ||
        !session.currentBatchPendingIds.contains(part.task.taskId)) {
      _cancelPendingStartLease(part);
      return;
    }

    _cancelPendingStartLease(part);
    final parentGeneration = session.generation;
    final attemptGeneration = part.attemptGeneration;
    part.pendingStartLeaseTimer = Timer(pendingStartLeaseDelay, () {
      part.pendingStartLeaseTimer = null;
      unawaited(
        session.serialize(() async {
          if (_disposed ||
              !session.active ||
              session.pauseRequested ||
              session.deleted ||
              session.generation != parentGeneration ||
              part.complete ||
              !part.launched ||
              part.attemptGeneration != attemptGeneration ||
              !session.currentBatchPendingIds.contains(part.task.taskId)) {
            return;
          }

          final lookup = livePartIds;
          if (lookup == null) {
            _armPendingStartLease(session, part);
            return;
          }

          Set<String> live;
          try {
            live = await lookup();
          } catch (_) {
            // Failed liveness means ownership is unknown, never absent.
            _armPendingStartLease(session, part);
            return;
          }
          if (live.contains(part.task.taskId)) {
            _markConnectionReady(session, part);
            _armTailStallWatch(session, part);
            await _persist(session);
            return;
          }

          final durableBytes = await _durablePartBytes(part);
          if (durableBytes == part.size &&
              part.size > 0 &&
              await _adoptExactSizePart(
                session,
                part,
                settleNativeOwner: false,
              )) {
            await _afterAdoptedPart(session);
            return;
          }

          // Close the liveness-vs-disk-read race before releasing the slot.
          try {
            live = await lookup();
          } catch (_) {
            _armPendingStartLease(session, part);
            return;
          }
          if (live.contains(part.task.taskId)) {
            _markConnectionReady(session, part);
            _armTailStallWatch(session, part);
            await _persist(session);
            return;
          }

          diagnosticLog?.record('parallel.pendingStartLeaseExpired', {
            'taskId': session.task.taskId,
            'childTaskId': part.task.taskId,
            'attemptGeneration': attemptGeneration,
            'durableBytes': durableBytes,
          });
          _rollbackPendingStartReservation(session, part);
          _schedulePartRecovery(session, part);
          await _persist(session);
          if (session.active) await _status(session, TaskStatus.running);
          _schedulePumpAll();
        }),
      );
    });
  }

  Future<bool> _pumpSession(_ParallelSession session) async {
    if (_disposed ||
        !session.active ||
        session.pauseRequested ||
        session.deleted) {
      return true;
    }

    while (!_disposed &&
        session.active &&
        !session.pauseRequested &&
        !session.deleted) {
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
        if (_disposed || session.pauseRequested || !session.active) return true;
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

        // Give every native enqueue a durable attempt token. Retried/resumed
        // workers keep the same taskId/Range but never the same generation.
        _preparePartAttempt(session, part);
        await _persist(session);

        // Parallel session pumps can consume capacity while this pump awaits
        // record/manifest IO. Revalidate immediately before the synchronous
        // reservation so stale availability can never overbook the global or
        // per-session connection budget.
        if (_activeConnectionIds.length >= _connectionBudget ||
            _activeConnectionsForSession(session) >=
                session.connectionCeiling) {
          return true;
        }

        // Reserve before enqueueing to close the enqueue->running race. This
        // also keeps 5 episodes x 16 parts from becoming 80 native requests.
        part.launched = true;
        _activeConnectionIds.add(part.task.taskId);
        session.currentBatchPendingIds.add(part.task.taskId);
        session.currentBatchRemaining--;

        void rollbackUnownedReservation() =>
            _rollbackPendingStartReservation(session, part);

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
          await _persist(session);
          try {
            await _status(session, TaskStatus.running);
          } catch (_) {}
          return true;
        }
        if (!started) {
          // A false enqueue result has no native owner. Retry it only when the
          // transport did not already classify the attempt as terminal. Range
          // refresh/reconcile/disk failures belong to the logical parent; an
          // unconditional child retry here used to relaunch the same expired
          // signed URL forever.
          rollbackUnownedReservation();
          final shouldRecover =
              shouldRecoverFailedStart?.call(part.task.taskId) ?? true;
          if (!shouldRecover) {
            diagnosticLog?.record('parallel.childStartParked', {
              'taskId': part.task.taskId,
              'parentTaskId': session.task.taskId,
            });
            await _pause(session);
            return true;
          }
          _schedulePartRecovery(session, part);
          await _persist(session);
          await _status(session, TaskStatus.running);
          return true;
        }

        _armTailStallWatch(session, part);

        // On process recovery a child may already be owned by native IO, so a
        // fresh running callback is not guaranteed.
        if (record != null &&
            (record.status == TaskStatus.running ||
                record.status == TaskStatus.waitingToRetry)) {
          _markConnectionReady(session, part);
        } else {
          _armPendingStartLease(session, part);
        }
      }

      if (session.currentBatchRemaining > 0) return true;
      if (session.currentBatchPendingIds.isNotEmpty) return true;
    }
    return true;
  }

  void _markConnectionReady(_ParallelSession session, _DownloadPart part) {
    _cancelPendingStartLease(part);
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
    _cancelPendingStartLease(part);
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

  void _notifyPausedDrainSettled(_ParallelSession session) {
    if (session.active || _activeConnectionsForSession(session) > 0) return;
    diagnosticLog?.record('parallel.pauseDrainSettled', {
      'taskId': session.task.taskId,
    });
    onPausedDrainSettled?.call(session.task.taskId);
  }

  Future<void> _afterAdoptedPart(_ParallelSession session) async {
    await _persist(session);
    if (session.parts.every((child) => child.complete)) {
      await _assemble(session);
    } else {
      _scheduleAggregateProgress(session);
      _schedulePumpAll();
      _notifyPausedDrainSettled(session);
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
        // Do not free/reuse the Range while the previous native writer may
        // still own it. Keep the same child live and retry settlement later.
        part.tailRecoveryAttempted = false;
        _armTailStallWatch(session, part);
        return;
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

    try {
      await cancelParts(<String>[part.task.taskId]);
    } catch (_) {
      // Unknown cancellation outcome means ownership is still unsettled.
      // Preserve the active lease and never expose this Range to a new writer.
      if (backup != null) {
        try {
          if (await backup.exists()) await backup.delete();
        } catch (_) {}
      }
      _armTailStallWatch(session, part);
      return;
    }

    _cancelTailStallWatch(part);
    _activeConnectionIds.remove(part.task.taskId);
    part.launched = false;
    part.speed = 0;
    session.currentBatchPendingIds.remove(part.task.taskId);

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
      part.durableBytes = part.size;
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
    part.durableBytes = savedBytes;
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
        // Exact bytes prove content, not that the prior writer relinquished
        // ownership. Fail closed until native ownership is acknowledged settled.
        return false;
      }
    }

    if (!await file.exists() || await file.length() != part.size) return false;

    _markConnectionReady(session, part);
    _releaseConnection(part);
    part.complete = true;
    part.progress = 1;
    part.credibleProgress = 1;
    part.durableBytes = part.size;
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
        part.durableBytes = bytes;
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

    if (!changed) return;
    _scheduleProgressPersist(session);
    if (session.parts.every((part) => part.complete)) {
      await _assemble(session);
      return;
    }
    if (!session.parentRunningReported) {
      await _status(session, TaskStatus.running);
    }
    _scheduleAggregateProgress(session);
    _schedulePumpAll();
  }

  void _scheduleProgressPersist(_ParallelSession session) {
    if (_disposed || !session.active || session.deleted) return;
    session.progressPersistDirty = true;
    if (session.progressPersistTimer != null) return;

    session.progressPersistTimer = Timer(kParallelProgressPersistInterval, () {
      session.progressPersistTimer = null;
      if (_disposed) return;
      unawaited(
        session.serialize(() async {
          if (_disposed ||
              !session.active ||
              session.deleted ||
              !session.progressPersistDirty) {
            return;
          }
          session.progressPersistDirty = false;
          await _persist(session);
        }),
      );
    });
  }

  Future<void> _writeParentRecord(_ParallelSession session, TaskRecord record) {
    late final Future<void> operation;
    operation = session.parentRecordWrite.then((_) => saveRecord(record));
    session.parentRecordWrite = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        diagnosticLog?.record('parallel.parentRecordPersistFailed', {
          'taskId': session.task.taskId,
          'errorType': error.runtimeType.toString(),
        });
      },
    );
    return operation;
  }

  void _scheduleAggregateProgress(_ParallelSession session) {
    if (_disposed || !session.active || session.deleted) return;
    session.aggregateProgressDirty = true;
    if (session.aggregateProgressTimer != null) return;

    // Presentation must not wait behind manifest fsync/recovery bookkeeping.
    // Snapshot on the one-second clock and publish immediately; parent DB
    // writes use their own ordered chain so a stale running write can never
    // overwrite a later pause/complete record.
    session.aggregateProgressTimer = Timer(kParallelProgressCoalesceDelay, () {
      session.aggregateProgressTimer = null;
      if (_disposed ||
          !session.active ||
          session.deleted ||
          !session.aggregateProgressDirty) {
        return;
      }
      session.aggregateProgressDirty = false;
      _emitAggregateProgress(session);
    });
  }

  void _emitAggregateProgress(_ParallelSession session) {
    if (_disposed || !session.active || session.deleted) return;
    final task = session.task;
    final progress = session.progress;
    final creditedBytes = session.creditedBytes;
    final expectedBytes = session.size;
    final telemetry = _speedTelemetry.observe(
      taskId: task.taskId,
      transferredBytes: creditedBytes,
      expectedBytes: expectedBytes,
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
          task.url,
          _activeConnectionsForSession(session).clamp(1, 1 << 30),
          speed * 1000 * 1000,
        );
      }
    }

    onUpdate(
      TaskProgressUpdate(task, progress, expectedBytes, speed, timeRemaining),
    );
    unawaited(
      _writeParentRecord(
        session,
        TaskRecord(task, TaskStatus.running, progress, expectedBytes),
      ).catchError((Object _, StackTrace __) {}),
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
              await Future.wait<void>(
                sessions
                    .where((session) => session.active && !session.deleted)
                    .map(
                      (session) => session.serialize(() async {
                        if (_disposed || !session.active || session.deleted) {
                          return;
                        }
                        try {
                          if (!await _pumpSession(session)) {
                            _scheduleCoordinatorRecovery(session);
                          } else {
                            await _persist(session);
                          }
                        } catch (_) {
                          // One slow/failing session must not head-of-line block
                          // unrelated sessions. Per-session serialization still
                          // preserves ordering inside each logical download.
                          _scheduleCoordinatorRecovery(session);
                        }
                      }),
                    ),
              );
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
    int? attemptGeneration,
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
      // Native background refill tasks are created from a pre-fenced child
      // definition while Dart can be asleep. Adopt that ownership only when
      // Swift echoed the exact current attempt token. A late callback from an
      // older URLSession task can therefore never resurrect the Range.
      if (!part.launched) {
        final canAdoptNativeOwner =
            session.active &&
            !session.pauseRequested &&
            !part.sourceValidationRequired &&
            attemptGeneration != null &&
            attemptGeneration == part.attemptGeneration;
        if (!canAdoptNativeOwner) return;
        part.launched = true;
        _activeConnectionIds.add(part.task.taskId);
        _markConnectionReady(session, part);
      } else if (attemptGeneration != null &&
          part.attemptGeneration > 0 &&
          attemptGeneration != part.attemptGeneration) {
        return;
      }

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

      if (credible > previousCredible || completed) {
        onPartProgress(
          session.task.taskId,
          part.task.taskId,
          part.credibleProgress,
        );
        _scheduleProgressPersist(session);
      }

      if (!session.active) return;
      if (!session.parentRunningReported) {
        await _status(session, TaskStatus.running);
      }
      _scheduleAggregateProgress(session);
      _schedulePumpAll();
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
          final callbackAttempt = _taskAttemptGeneration(update.task);
          if (callbackAttempt != null &&
              part.attemptGeneration > 0 &&
              callbackAttempt != part.attemptGeneration) {
            diagnosticLog?.record('parallel.staleChildCallback', {
              'taskId': session.task.taskId,
              'childTaskId': part.task.taskId,
              'callbackAttempt': callbackAttempt,
              'currentAttempt': part.attemptGeneration,
            });
            return;
          }
          // Completion is durable; a late running/progress/retry callback must
          // never reserve its connection again or park the remaining parts.
          if (part.complete) return;
          if (!part.launched &&
              !(update is TaskStatusUpdate &&
                  update.status == TaskStatus.complete)) {
            final canAdoptNativeOwner =
                session.active &&
                !session.pauseRequested &&
                !part.sourceValidationRequired &&
                callbackAttempt != null &&
                callbackAttempt == part.attemptGeneration;
            if (!canAdoptNativeOwner) return;
            part.launched = true;
            _activeConnectionIds.add(part.task.taskId);
            _markConnectionReady(session, part);
          }
          if (generation != session.generation &&
              !(update is TaskStatusUpdate &&
                  update.status == TaskStatus.complete))
            return;

          if (update is TaskProgressUpdate &&
              update.progress >= 0 &&
              update.progress <= 1) {
            // On iOS the URLSession bridge carries exact byte counts from the
            // temp file. background_downloader emits a second progress callback
            // for the same child. Ignore that duplicate while the byte bridge
            // is healthy; if the bridge goes quiet, plugin progress becomes the
            // fallback automatically.
            final nativeBridgeFresh =
                part.lastNativeBridgeAt != null &&
                DateTime.now().difference(part.lastNativeBridgeAt!) <
                    const Duration(seconds: 2);
            if (nativeBridgeFresh) return;

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
            _scheduleProgressPersist(session);
            if (session.active) {
              _scheduleAggregateProgress(session);
            }
            _schedulePumpAll();
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
            if (!await _validateCompletedNativeRange(session, part, update)) {
              return;
            }
            _markConnectionReady(session, part);
            _releaseConnection(part);
            part.complete = true;
            part.progress = 1;
            part.credibleProgress = 1;
            part.durableBytes = part.size;
            await saveRecord(
              TaskRecord(part.task, TaskStatus.complete, 1, part.size),
            );
            onPartProgress(session.task.taskId, part.task.taskId, 1);
            try {
              await _persist(session);
            } on FileSystemException catch (error) {
              if (!_isInsufficientStorageError(error)) rethrow;
              final target = File(await session.task.filePath());
              await _handleAssemblyStorageFailure(
                session,
                File('${target.path}.assembling'),
                error: error,
              );
              return;
            }
            _notifyPausedDrainSettled(session);
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

          if (!session.active &&
              (update.status == TaskStatus.failed ||
                  update.status == TaskStatus.notFound ||
                  update.status == TaskStatus.canceled ||
                  update.status == TaskStatus.paused)) {
            _markConnectionReady(session, part);
            _releaseConnection(part);
            _invalidatePartAttempt(session, part);
            await _persist(session);
            _notifyPausedDrainSettled(session);
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
              await _persist(session);
              await _status(session, TaskStatus.running);
              return;
            }

            // Permanent client-side HTTP errors are not helped by hammering
            // the same signed URL forever. 401/403 specifically mean the logical
            // owner may be able to mint a fresh signed source; schedule that
            // outside this session serialization, then park all current workers.
            final exception = update.exception;
            final statusCode =
                update.responseStatusCode ??
                (exception is TaskHttpException
                    ? exception.httpResponseCode
                    : null);
            if (isDownloadUrlRefreshStatus(statusCode, include404: false)) {
              onSourceRefreshNeeded?.call(session.task.taskId);
            }
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

  Future<bool> pause(
    ParallelDownloadTask task, {
    bool preserveLiveParts = false,
  }) async {
    if (_disposed) return false;
    if (!await restore(task)) return false;
    final session = _sessions[task.taskId]!;
    // This flag is deliberately set before waiting for session.serialize(). A
    // slow-start pump may already be queued ahead of _pause; it must observe
    // the user's pause intent synchronously and stop before another enqueue.
    session.pauseRequested = true;
    return session.serialize(
      () => _pause(session, preserveLiveParts: preserveLiveParts),
    );
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
    _cancelPendingStartLease(part);
    _cancelTailStallWatch(part);
    part.recoveryAttempts++;
    part.speed = 0;
    _invalidatePartAttempt(session, part);

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
            _markConnectionReady(session, part);
            _armTailStallWatch(session, part);
            continue;
          }

          if (session.currentBatchPendingIds.contains(part.task.taskId)) {
            _rollbackPendingStartReservation(session, part);
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

  Future<bool> _pause(
    _ParallelSession session, {
    bool preserveLiveParts = false,
  }) async {
    session.active = false;
    session.generation++;
    _speedTelemetry.resetSpeed(session.task.taskId);
    session.cancelAggregateProgress();
    session.cancelProgressPersist();
    session.cancelDiskProgressPoll();
    session.cancelCoordinatorRecovery();
    session.resetRamp();

    final unfinished = session.parts
        .where((part) => !part.complete)
        .toList(growable: false);
    final drainIds = <String>{};
    final pauseCandidates = <_DownloadPart>[];
    for (final part in unfinished) {
      if (!part.launched) continue;
      final drain =
          preserveLiveParts &&
          (shouldDrainPartOnPause?.call(part.task) ?? false);
      if (drain) {
        drainIds.add(part.task.taskId);
      } else {
        pauseCandidates.add(part);
      }
    }

    if (drainIds.isNotEmpty) {
      diagnosticLog?.record('parallel.pauseDrain', {
        'taskId': session.task.taskId,
        'count': drainIds.length,
      });
    }

    var pauseFailed = false;
    await Future.wait(
      pauseCandidates.map((part) async {
        try {
          await pausePart(part.task);
        } catch (_) {
          pauseFailed = true;
        }
      }),
    );

    Set<String> live = <String>{};
    var liveLookupSucceeded = livePartIds == null;
    final lookupLive = livePartIds;
    if (lookupLive != null) {
      try {
        live = await lookupLive();
        liveLookupSucceeded = true;
      } catch (_) {
        pauseFailed = true;
      }
    }

    // Retry only transport-pause candidates that are still demonstrably live.
    // Never retry the drain set: on iOS the retry itself is the destructive
    // cancelByProducingResumeData operation we are avoiding.
    var stillUnexpected = pauseCandidates
        .where((part) => live.contains(part.task.taskId))
        .toList(growable: false);
    if (stillUnexpected.isNotEmpty) {
      await Future.wait(
        stillUnexpected.map((part) async {
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
          liveLookupSucceeded = true;
        } catch (_) {
          pauseFailed = true;
          liveLookupSucceeded = false;
        }
      }
      stillUnexpected = pauseCandidates
          .where((part) => live.contains(part.task.taskId))
          .toList(growable: false);
    }

    if (stillUnexpected.isNotEmpty ||
        (lookupLive == null && pauseFailed && drainIds.isEmpty)) {
      final stillIds = stillUnexpected.map((part) => part.task.taskId).toSet()
        ..addAll(drainIds);
      session.pauseRequested = false;
      session.active = true;
      for (final part in unfinished) {
        final owns = stillIds.contains(part.task.taskId);
        part.launched = owns;
        part.speed = 0;
        if (owns) {
          _activeConnectionIds.add(part.task.taskId);
        } else {
          _invalidatePartAttempt(session, part);
          _activeConnectionIds.remove(part.task.taskId);
        }
      }
      _scheduleDiskProgressPoll(session);
      await _persist(session);
      await _status(session, TaskStatus.running);
      return false;
    }

    var retainedDrainCount = 0;
    for (final part in unfinished) {
      final requestedDrain = drainIds.contains(part.task.taskId);
      // If native liveness could not be queried, retaining a launched drain is
      // safer than invoking a destructive pause or freeing its slot early. A
      // later native completion/failure or explicit resume reconciles it.
      final ownsDrain =
          requestedDrain &&
          (!liveLookupSucceeded ||
              lookupLive == null ||
              live.contains(part.task.taskId));
      if (ownsDrain) {
        retainedDrainCount++;
        part.launched = true;
        part.speed = 0;
        _activeConnectionIds.add(part.task.taskId);
        continue;
      }

      // A drain candidate that disappeared between enqueue and the liveness
      // snapshot may already have moved its complete file. Adopt exact bytes
      // before fencing the old attempt.
      if (requestedDrain &&
          await _adoptExactSizePart(session, part, settleNativeOwner: false)) {
        continue;
      }

      _invalidatePartAttempt(session, part);
      part.launched = false;
      part.speed = 0;
      _activeConnectionIds.remove(part.task.taskId);
    }

    await _persist(session);
    await _status(session, TaskStatus.paused);
    diagnosticLog?.record('parallel.pauseCommitted', {
      'taskId': session.task.taskId,
      'draining': retainedDrainCount,
    });
    _schedulePumpAll();
    if (retainedDrainCount == 0) _notifyPausedDrainSettled(session);
    return true;
  }

  Future<void> cancel(ParallelDownloadTask task) async {
    if (_disposed) return;
    if (!await restore(task)) return;
    final session = _sessions[task.taskId]!;
    session.deleted = true;
    session.active = false;
    session.cancelAggregateProgress();
    session.cancelProgressPersist();
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
    await _writeParentRecord(
      session,
      TaskRecord(session.task, status, session.progress, session.size),
    );
    onUpdate(TaskStatusUpdate(session.task, status));
  }

  Future<void> _persist(_ParallelSession session) async {
    if (session.deleted) return;
    await session.manifest.parent.create(recursive: true);
    session.checkpointSequence++;
    final payload = jsonEncode({
      'schemaVersion': kParallelManifestSchemaVersion,
      'parentTaskId': session.task.taskId,
      'parentTask': session.task.toJson(),
      'generation': session.generation,
      'checkpointSequence': session.checkpointSequence,
      'expectedBytes': session.size,
      'totalBytes': session.size,
      'resourceValidator': session.resourceValidator,
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
    if (await target.exists()) {
      if (await target.length() != session.size) return false;
      await _finishCompleteSession(session);
      return true;
    }

    // A crash can happen after the complete staging file was flushed and
    // closed but before its atomic rename. Reuse it only when every source
    // Range is still exact, which proves this staging file belongs to this
    // recoverable multipart generation. Otherwise normal assembly rewrites it.
    final staging = File('${target.path}.assembling');
    if (!await staging.exists() || await staging.length() != session.size) {
      return false;
    }
    for (final part in session.parts) {
      final file = File(await part.task.filePath());
      if (!await file.exists() || await file.length() != part.size) {
        return false;
      }
    }
    await staging.rename(target.path);
    await _finishCompleteSession(session);
    return true;
  }

  bool _requestedByteRange(_DownloadPart part) => part.task.headers.entries.any(
    (entry) =>
        entry.key.toLowerCase() == 'range' &&
        entry.value.toLowerCase().startsWith('bytes='),
  );

  String? _responseIfRangeValidator(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return null;
    String? etag;
    String? lastModified;
    for (final entry in headers.entries) {
      switch (entry.key.toLowerCase()) {
        case 'etag':
          etag = entry.value.trim();
        case 'last-modified':
          lastModified = entry.value.trim();
      }
    }
    if (etag != null &&
        etag!.isNotEmpty &&
        !etag!.toLowerCase().startsWith('w/')) {
      return etag;
    }
    if (lastModified != null && lastModified!.isNotEmpty) {
      return lastModified;
    }
    return null;
  }

  void _applyPinnedValidatorToPendingParts(_ParallelSession session) {
    final validator = session.resourceValidator;
    if (validator == null || validator.isEmpty) return;
    for (final part in session.parts) {
      if (part.complete) continue;
      final headers = Map<String, String>.from(part.task.headers)
        ..removeWhere((key, _) => key.toLowerCase() == 'if-range');
      headers['If-Range'] = validator;
      part.task = part.task.copyWith(headers: headers);
    }
  }

  Future<void> _invalidateCompletedRange(
    _ParallelSession session,
    _DownloadPart part, {
    required String reason,
  }) async {
    diagnosticLog?.record('parallel.rangeRejected', {
      'taskId': session.task.taskId,
      'childTaskId': part.task.taskId,
      'reason': reason,
    });
    _cancelTailStallWatch(part);
    part.recoveryTimer?.cancel();
    part.recoveryTimer = null;
    session.currentBatchPendingIds.remove(part.task.taskId);
    _activeConnectionIds.remove(part.task.taskId);
    part.launched = false;
    part.complete = false;
    part.progress = 0;
    part.credibleProgress = 0;
    part.durableBytes = 0;
    part.speed = 0;
    part.recoveryAttempts = 0;
    part.tailRecoveryAttempted = false;
    part.tailWatchProgress = -1;
    part.lastNativeBridgeBytes = 0;
    part.lastNativeBridgeAt = null;
    part.sourceValidationRequired = false;
    final file = File(await part.task.filePath());
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    await saveRecord(TaskRecord(part.task, TaskStatus.paused, 0, part.size));
    onPartProgress(session.task.taskId, part.task.taskId, 0);
    await _persist(session);
  }

  Future<bool> _validateCompletedNativeRange(
    _ParallelSession session,
    _DownloadPart part,
    TaskStatusUpdate update,
  ) async {
    if (!downloadPartResponseMatchesRequestedRange(
      from: part.from,
      to: part.to,
      resourceSize: session.size,
      statusCode: update.responseStatusCode,
      responseHeaders: update.responseHeaders,
    )) {
      await _invalidateCompletedRange(
        session,
        part,
        reason: 'contentRangeMismatch',
      );
      await _pause(session);
      return false;
    }

    final observedValidator = _responseIfRangeValidator(update.responseHeaders);
    if (observedValidator == null) return true;
    final pinned = session.resourceValidator;
    if (pinned == null) {
      session.resourceValidator = observedValidator;
      _applyPinnedValidatorToPendingParts(session);
      return true;
    }
    if (pinned == observedValidator) return true;

    await _invalidateCompletedRange(
      session,
      part,
      reason: 'resourceValidatorChanged',
    );
    await _pause(session);
    return false;
  }

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
    session.cancelProgressPersist();
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

  bool _isInsufficientStorageError(FileSystemException error) {
    final code = error.osError?.errorCode;
    if (code == 28 || code == 69 || code == 112 || code == 122) return true;
    final message = '${error.message} ${error.osError?.message ?? ''}'
        .toLowerCase();
    return message.contains('no space left') ||
        message.contains('disk full') ||
        message.contains('not enough space') ||
        message.contains('quota exceeded');
  }

  Future<bool> _hasAssemblyHeadroom(
    _ParallelSession session,
    File target, {
    required int remainingBytes,
  }) async {
    final probe = availableStorageBytes;
    if (probe == null) return true;
    try {
      final free = await probe(target.parent.path);
      if (free == null || free < 0) return true;
      final reserve = assemblyStorageReserveBytes < 0
          ? 0
          : assemblyStorageReserveBytes;
      return free >= remainingBytes + reserve;
    } catch (_) {
      return true;
    }
  }

  Future<void> _parkForStorageFailure(_ParallelSession session) async {
    session.active = false;
    session.generation++;
    session.pauseRequested = false;
    _speedTelemetry.resetSpeed(session.task.taskId);
    session.cancelAggregateProgress();
    session.cancelProgressPersist();
    session.cancelDiskProgressPoll();
    session.cancelCoordinatorRecovery();
    session.resetRamp();
    for (final part in session.parts) {
      _cancelPendingStartLease(part);
      _cancelTailStallWatch(part);
      part.recoveryTimer?.cancel();
      part.recoveryTimer = null;
      part.launched = false;
      part.speed = 0;
      _activeConnectionIds.remove(part.task.taskId);
    }
    try {
      await _status(session, TaskStatus.paused);
    } catch (_) {}
    _schedulePumpAll();
  }

  Future<void> _handleAssemblyStorageFailure(
    _ParallelSession session,
    File staging, {
    FileSystemException? error,
  }) async {
    diagnosticLog?.record('assembly.insufficientStorage', {
      'taskId': session.task.taskId,
      'total': session.size,
      if (error?.osError?.errorCode != null)
        'osError': error!.osError!.errorCode,
    });
    try {
      if (await staging.exists()) await staging.delete();
    } catch (_) {}
    onAssemblyFailure?.call(
      ParallelAssemblyFailure(
        parentTaskId: session.task.taskId,
        reason: ParallelAssemblyFailureReason.insufficientStorage,
      ),
    );
    await _parkForStorageFailure(session);
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
      await _pause(session);
      return;
    }

    final staging = File('${target.path}.assembling');
    if (!await _hasAssemblyHeadroom(
      session,
      target,
      remainingBytes: session.size,
    )) {
      await _handleAssemblyStorageFailure(session, staging);
      return;
    }

    RandomAccessFile? output;
    try {
      output = await staging.open(mode: FileMode.write);
      await output.truncate(session.size);
      await output.setPosition(0);
      var assembledBytes = 0;
      for (final part in session.parts) {
        final file = File(await part.task.filePath());
        if (!await file.exists() || await file.length() != part.size) {
          await _pause(session);
          return;
        }
        if (!await _hasAssemblyHeadroom(session, target, remainingBytes: 0)) {
          await output!.close();
          output = null;
          await _handleAssemblyStorageFailure(session, staging);
          return;
        }
        await for (final bytes in file.openRead()) {
          if (session.deleted) return;
          if (assembledBytes + bytes.length > session.size) {
            await _pause(session);
            return;
          }
          await output!.writeFrom(bytes);
          assembledBytes += bytes.length;
        }
      }
      if (assembledBytes != session.size) {
        await _pause(session);
        return;
      }
      await output!.flush();
    } on FileSystemException catch (error) {
      if (!_isInsufficientStorageError(error)) rethrow;
      try {
        await output?.close();
      } catch (_) {}
      output = null;
      await _handleAssemblyStorageFailure(session, staging, error: error);
      return;
    } finally {
      try {
        await output?.close();
      } catch (_) {}
    }
    if (session.deleted) return;
    if (!await staging.exists() || await staging.length() != session.size) {
      await _pause(session);
      return;
    }
    try {
      await staging.rename(target.path);
    } on FileSystemException catch (error) {
      if (!_isInsufficientStorageError(error)) rethrow;
      await _handleAssemblyStorageFailure(session, staging, error: error);
      return;
    }
    await _finishCompleteSession(session);
  }
}

class _ParallelSession {
  _ParallelSession(
    this.task,
    this.manifest,
    this.parts, {
    this.generation = 0,
    this.resourceValidator,
  });

  ParallelDownloadTask task;
  final File manifest;
  final List<_DownloadPart> parts;
  bool active = false;
  // Synchronous intent fence: true from the instant pause() is requested until
  // an explicit start/resume begins a new generation.
  bool pauseRequested = false;
  bool deleted = false;
  int generation;
  int checkpointSequence = 0;
  String? resourceValidator;
  int connectionCeiling = kDownloadPartsMin;
  int lastHealthyConnections = 0;
  bool slowStartComplete = false;
  List<int> rampBatches = const <int>[];
  int rampBatchIndex = 0;
  int currentBatchRemaining = 0;
  final Set<String> currentBatchPendingIds = {};
  Timer? aggregateProgressTimer;
  bool aggregateProgressDirty = false;
  Timer? progressPersistTimer;
  bool progressPersistDirty = false;
  Timer? diskProgressTimer;
  Timer? coordinatorRecoveryTimer;
  int lastDiskObservedBytes = -1;
  DateTime? lastDiskObservedAt;
  double diskObservedSpeed = 0;
  bool parentRunningReported = false;
  DateTime? lastHostProfileSampleAt;
  Future<void> _pending = Future<void>.value();
  Future<void> parentRecordWrite = Future<void>.value();

  int get size => parts.fold(0, (sum, part) => sum + part.size);
  int get creditedBytes =>
      parts.fold<int>(0, (sum, part) => sum + part.durableBytes);
  double get progress =>
      parts.fold<double>(
        0,
        (sum, part) => sum + part.size * part.credibleProgress,
      ) /
      size;
  Future<void> get idle async {
    await _pending;
    await parentRecordWrite;
  }

  void cancelAggregateProgress() {
    aggregateProgressTimer?.cancel();
    aggregateProgressTimer = null;
    aggregateProgressDirty = false;
  }

  void cancelProgressPersist() {
    progressPersistTimer?.cancel();
    progressPersistTimer = null;
    progressPersistDirty = false;
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
      part.pendingStartLeaseTimer?.cancel();
      part.pendingStartLeaseTimer = null;
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

DownloadTask _canonicalMultipartPartTask(DownloadTask task, int from, int to) {
  final headers = Map<String, String>.from(task.headers)
    ..removeWhere((key, _) {
      final normalized = key.toLowerCase();
      return normalized == 'range' || normalized == 'accept-encoding';
    });
  headers['Range'] = 'bytes=$from-$to';
  headers['Accept-Encoding'] = 'identity';
  return task.copyWith(headers: headers);
}

class _DownloadPart {
  _DownloadPart(
    DownloadTask task,
    this.from,
    this.to, {
    this.progress = 0,
    this.complete = false,
    this.attemptGeneration = 0,
    this.sourceValidationRequired = false,
    double? credibleProgress,
    int? durableBytes,
    this.needsCredibleProgressRepair = false,
  }) : task = _canonicalMultipartPartTask(task, from, to),
       durableBytes = complete
           ? to - from + 1
           : (durableBytes ?? 0).clamp(0, to - from + 1).toInt(),
       credibleProgress = complete
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

  /// Presentation/history progress. It can be informed by native callbacks but
  /// is never persisted as byte authority.
  double credibleProgress;

  /// Exact recoverable bytes proven by a visible part file or completion.
  int durableBytes;

  bool complete;
  int attemptGeneration;
  bool sourceValidationRequired;
  bool launched = false;
  double speed = 0;
  int recoveryAttempts = 0;
  Timer? recoveryTimer;
  Timer? pendingStartLeaseTimer;
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
    final savedDurableBytes = json['durableBytes'];
    final hasSavedDurableBytes = savedDurableBytes is num;
    final legacyTailSentinel =
        !complete &&
        (!hasSavedCredible || !hasSavedDurableBytes) &&
        rawProgress >= kParallelNativeCompletionSentinel;
    return _DownloadPart(
      restored.copyWith(retries: kDownloadPartRetries),
      json['from'] as int,
      json['to'] as int,
      progress: complete ? 1 : rawProgress,
      complete: complete,
      attemptGeneration: (json['attemptGeneration'] as num?)?.toInt() ?? 0,
      sourceValidationRequired: json['sourceValidationRequired'] == true,
      credibleProgress: complete
          ? 1
          : (hasSavedCredible ? savedCredible.toDouble() : null),
      durableBytes: complete
          ? (json['to'] as int) - (json['from'] as int) + 1
          : (hasSavedDurableBytes ? savedDurableBytes.toInt() : 0),
      needsCredibleProgressRepair:
          legacyTailSentinel || (!complete && !hasSavedDurableBytes),
    );
  }

  Map<String, dynamic> toJson() => {
    'task': task.toJson(),
    'from': from,
    'to': to,
    'progress': progress,
    'credibleProgress': credibleProgress,
    'durableBytes': durableBytes,
    'complete': complete,
    'attemptGeneration': attemptGeneration,
    'sourceValidationRequired': sourceValidationRequired,
  };
}

class _ManifestRestoreCandidate {
  const _ManifestRestoreCandidate({
    required this.file,
    required this.sequence,
    required this.modifiedMillis,
    required this.isTemp,
  });

  final File file;
  final int sequence;
  final int modifiedMillis;
  final bool isTemp;
}
