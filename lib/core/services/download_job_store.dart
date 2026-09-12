import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'download_job_state.dart';

const int kDownloadJobSchemaVersion = 7;

/// User-delete tombstones stay durable long enough to fence late native
/// callbacks across relaunches. Cleanup may happen immediately after
/// ownership settlement; only the tombstone itself is age-gated for GC.
const Duration kDownloadCanceledTombstoneRetention = Duration(days: 30);

bool downloadCanceledTombstoneEligibleForGc(
  DownloadJobRecord job, {
  required int nowMillis,
  required bool ownershipReleased,
  required bool pluginRecordAbsent,
  required bool metadataAbsent,
}) {
  if (job.state != DownloadJobState.canceled || job.generation <= 0) {
    return false;
  }
  if (!ownershipReleased || !pluginRecordAbsent || !metadataAbsent) {
    return false;
  }
  final ageMillis = nowMillis - job.updatedAtMillis;
  return ageMillis >= kDownloadCanceledTombstoneRetention.inMilliseconds;
}

/// Provenance for [DownloadJobRecord.durableBytes].
///
/// Percentage/progress estimates are intentionally absent. `legacyUnknown` is
/// the migration/fail-safe bucket for positive byte counts that predate this
/// schema or arrive without a durability contract.
enum DownloadDurableByteProvenance {
  none,
  legacyUnknown,
  verifiedFinalFile,
  exactDisk,
  rangeFlushed,
  multipartManifest,
  nativeRecoverable,
}

/// Why authoritative recovery evidence deliberately lowered durable bytes.
enum DownloadByteReconciliationReason {
  exactDiskLoss,
  noSurvivingBytes,
  multipartManifestRollback,
  nativeRecoverabilityLoss,
}

enum DownloadReplicaOperation {
  start,
  pause,
  resume,
  cancel,
  complete,
  sourceRefresh,
  nativeHandoff,
}

enum DownloadReplicaTransactionPhase {
  intent,
  executorAcknowledged,
  projecting,
}

class DownloadReplicaTransaction {
  const DownloadReplicaTransaction({
    required this.operation,
    required this.phase,
    required this.generation,
    this.intentData = const <String, Object?>{},
  });

  final DownloadReplicaOperation operation;
  final DownloadReplicaTransactionPhase phase;
  final int generation;
  final Map<String, Object?> intentData;

  DownloadReplicaTransaction copyWith({
    DownloadReplicaTransactionPhase? phase,
    Map<String, Object?>? intentData,
  }) => DownloadReplicaTransaction(
    operation: operation,
    phase: phase ?? this.phase,
    generation: generation,
    intentData: intentData ?? this.intentData,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'operation': operation.name,
    'phase': phase.name,
    'generation': generation,
    if (intentData.isNotEmpty) 'intentData': intentData,
  };

  static DownloadReplicaTransaction? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final operationName = _nonEmptyString(map['operation']);
    final phaseName = _nonEmptyString(map['phase']);
    final generation = _intValue(map['generation'], fallback: -1);
    if (operationName == null || phaseName == null || generation < 0) {
      return null;
    }

    DownloadReplicaOperation? operation;
    for (final value in DownloadReplicaOperation.values) {
      if (value.name == operationName) {
        operation = value;
        break;
      }
    }
    DownloadReplicaTransactionPhase? phase;
    for (final value in DownloadReplicaTransactionPhase.values) {
      if (value.name == phaseName) {
        phase = value;
        break;
      }
    }
    if (operation == null || phase == null) return null;
    final rawIntentData = map['intentData'];
    final intentData = rawIntentData is Map
        ? Map<String, Object?>.from(rawIntentData)
        : const <String, Object?>{};
    return DownloadReplicaTransaction(
      operation: operation,
      phase: phase,
      generation: generation,
      intentData: intentData,
    );
  }
}

extension DownloadDurableByteProvenanceRules on DownloadDurableByteProvenance {
  bool get isAuthoritative =>
      this != DownloadDurableByteProvenance.legacyUnknown;
}

int authoritativeDownloadJobBytes(DownloadJobRecord? record) {
  if (record == null || !record.durableByteProvenance.isAuthoritative)
    return -1;
  return record.durableBytes < 0 ? -1 : record.durableBytes;
}

const String kDownloadJobStoreBox = 'download_job_store_v1';

/// Durable identity of the remote object whose bytes are stored locally.
///
/// A strong ETag is preferred, Last-Modified is a fallback, and expected size
/// provide stable evidence. Final URL is delivery metadata only because a
/// signed CDN URL may rotate without changing the resource. The store never silently replaces an incompatible
/// fingerprint because doing so could attach old bytes to a different object.
class DownloadResourceFingerprint {
  const DownloadResourceFingerprint({
    this.strongEtag,
    this.lastModified,
    this.expectedBytes = -1,
    this.finalUrl,
  });

  final String? strongEtag;
  final String? lastModified;
  final int expectedBytes;
  final String? finalUrl;

  bool get hasIdentityEvidence =>
      (strongEtag?.trim().isNotEmpty ?? false) ||
      (lastModified?.trim().isNotEmpty ?? false) ||
      expectedBytes > 0;

  Map<String, Object?> toJson() => <String, Object?>{
    if (strongEtag?.trim().isNotEmpty ?? false) 'strongEtag': strongEtag,
    if (lastModified?.trim().isNotEmpty ?? false) 'lastModified': lastModified,
    if (expectedBytes > 0) 'expectedBytes': expectedBytes,
    if (finalUrl?.trim().isNotEmpty ?? false) 'finalUrl': finalUrl,
  };

  static DownloadResourceFingerprint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final fingerprint = DownloadResourceFingerprint(
      strongEtag: _nonEmptyString(map['strongEtag']),
      lastModified: _nonEmptyString(map['lastModified']),
      expectedBytes: _intValue(map['expectedBytes'], fallback: -1),
      finalUrl: _nonEmptyString(map['finalUrl']),
    );
    return fingerprint.hasIdentityEvidence ? fingerprint : null;
  }

  /// Returns false only when both sides contain comparable evidence that
  /// conflicts. Missing evidence is treated as unknown rather than mismatch.
  bool compatibleWith(DownloadResourceFingerprint other) {
    final aEtag = _nonEmptyString(strongEtag);
    final bEtag = _nonEmptyString(other.strongEtag);
    if (aEtag != null && bEtag != null && aEtag != bEtag) return false;

    final aModified = _nonEmptyString(lastModified);
    final bModified = _nonEmptyString(other.lastModified);
    if ((aEtag == null || bEtag == null) &&
        aModified != null &&
        bModified != null &&
        aModified != bModified) {
      return false;
    }

    if (expectedBytes > 0 &&
        other.expectedBytes > 0 &&
        expectedBytes != other.expectedBytes) {
      return false;
    }
    return true;
  }
}

/// One durable logical episode download.
///
/// The plugin database, URLSession/WorkManager tasks, multipart manifests and
/// UI providers are executors/views. This record is the target source of truth
/// while the downloader is migrated incrementally.
class DownloadJobRecord {
  const DownloadJobRecord({
    required this.taskId,
    this.logicalId,
    required this.trackingUrl,
    required this.state,
    required this.generation,
    required this.durableBytes,
    this.durableByteProvenance = DownloadDurableByteProvenance.none,
    required this.expectedBytes,
    required this.userPaused,
    required this.queueWaiting,
    required this.updatedAtMillis,
    this.taskSnapshot,
    this.fingerprint,
    this.lastByteReconciliationReason,
    this.lastByteReconciliationProvenance,
    this.lastByteReconciliationAtMillis,
    this.replicaTransaction,
  });

  final String taskId;

  /// Stable logical episode identity. Multiple execution task IDs may point to
  /// the same value across retry/adoption generations. Legacy rows can be null
  /// until presentation metadata is available to migrate them safely.
  final String? logicalId;

  final String trackingUrl;
  final DownloadJobState state;
  final int generation;
  final int durableBytes;
  final DownloadDurableByteProvenance durableByteProvenance;
  final int expectedBytes;
  final bool userPaused;
  final bool queueWaiting;
  final int updatedAtMillis;
  final Map<String, dynamic>? taskSnapshot;
  final DownloadResourceFingerprint? fingerprint;
  final DownloadByteReconciliationReason? lastByteReconciliationReason;
  final DownloadDurableByteProvenance? lastByteReconciliationProvenance;
  final int? lastByteReconciliationAtMillis;
  final DownloadReplicaTransaction? replicaTransaction;

  DownloadAttemptToken get attemptToken =>
      DownloadAttemptToken(taskId: taskId, generation: generation);

  DownloadTask? restoreTaskSnapshot() {
    final raw = taskSnapshot;
    if (raw == null) return null;
    try {
      final restored = Task.createFromJson(Map<String, dynamic>.from(raw));
      return restored is DownloadTask ? restored : null;
    } catch (_) {
      return null;
    }
  }

  DownloadJobRecord copyWith({
    String? logicalId,
    String? trackingUrl,
    DownloadJobState? state,
    int? generation,
    int? durableBytes,
    DownloadDurableByteProvenance? durableByteProvenance,
    int? expectedBytes,
    bool? userPaused,
    bool? queueWaiting,
    int? updatedAtMillis,
    Map<String, dynamic>? taskSnapshot,
    bool clearTaskSnapshot = false,
    DownloadResourceFingerprint? fingerprint,
    bool clearFingerprint = false,
    DownloadByteReconciliationReason? lastByteReconciliationReason,
    DownloadDurableByteProvenance? lastByteReconciliationProvenance,
    int? lastByteReconciliationAtMillis,
    DownloadReplicaTransaction? replicaTransaction,
    bool clearReplicaTransaction = false,
  }) => DownloadJobRecord(
    taskId: taskId,
    logicalId: logicalId ?? this.logicalId,
    trackingUrl: trackingUrl ?? this.trackingUrl,
    state: state ?? this.state,
    generation: generation ?? this.generation,
    durableBytes: durableBytes ?? this.durableBytes,
    durableByteProvenance: durableByteProvenance ?? this.durableByteProvenance,
    expectedBytes: expectedBytes ?? this.expectedBytes,
    userPaused: userPaused ?? this.userPaused,
    queueWaiting: queueWaiting ?? this.queueWaiting,
    updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
    taskSnapshot: clearTaskSnapshot
        ? null
        : (taskSnapshot ?? this.taskSnapshot),
    fingerprint: clearFingerprint ? null : (fingerprint ?? this.fingerprint),
    lastByteReconciliationReason:
        lastByteReconciliationReason ?? this.lastByteReconciliationReason,
    lastByteReconciliationProvenance:
        lastByteReconciliationProvenance ??
        this.lastByteReconciliationProvenance,
    lastByteReconciliationAtMillis:
        lastByteReconciliationAtMillis ?? this.lastByteReconciliationAtMillis,
    replicaTransaction: clearReplicaTransaction
        ? null
        : (replicaTransaction ?? this.replicaTransaction),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': kDownloadJobSchemaVersion,
    'taskId': taskId,
    if (_nonEmptyString(logicalId) != null) 'logicalId': logicalId,
    'trackingUrl': trackingUrl,
    'state': state.name,
    'generation': generation,
    'durableBytes': durableBytes,
    'durableByteProvenance': _normalizedDurableByteProvenance(
      durableBytes,
      durableByteProvenance,
    ).name,
    'expectedBytes': expectedBytes,
    'userPaused': downloadJobHasUserPauseIntent(state),
    'queueWaiting': downloadJobQueueWaiting(state),
    'updatedAtMillis': updatedAtMillis,
    if (taskSnapshot != null)
      'taskSnapshot': Map<String, dynamic>.from(taskSnapshot!),
    if (fingerprint != null) 'fingerprint': fingerprint!.toJson(),
    if (lastByteReconciliationReason != null)
      'lastByteReconciliationReason': lastByteReconciliationReason!.name,
    if (lastByteReconciliationProvenance != null)
      'lastByteReconciliationProvenance':
          lastByteReconciliationProvenance!.name,
    if (lastByteReconciliationAtMillis != null)
      'lastByteReconciliationAtMillis': lastByteReconciliationAtMillis,
    if (replicaTransaction != null)
      'replicaTransaction': replicaTransaction!.toJson(),
  };

  static DownloadJobRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final taskId = _nonEmptyString(map['taskId']);
    final trackingUrl = _nonEmptyString(map['trackingUrl']);
    if (taskId == null || trackingUrl == null) return null;

    final generation = _intValue(map['generation']);
    final durableBytes = _intValue(map['durableBytes']);
    if (generation < 0 || durableBytes < 0) return null;
    final schemaVersion = _intValue(map['schemaVersion'], fallback: 1);
    var state = _jobStateValue(map['state']);
    if (schemaVersion < 6) {
      state = migrateLegacyDownloadJobState(
        state: state,
        userPaused: map['userPaused'] == true,
        queueWaiting: map['queueWaiting'] == true,
      );
    }
    final durableByteProvenance = _durableByteProvenanceValue(
      map['durableByteProvenance'],
      durableBytes: durableBytes,
      schemaVersion: schemaVersion,
    );

    return DownloadJobRecord(
      taskId: taskId,
      logicalId: _nonEmptyString(map['logicalId']),
      trackingUrl: trackingUrl,
      state: state,
      generation: generation,
      durableBytes: durableBytes,
      durableByteProvenance: durableByteProvenance,
      expectedBytes: _intValue(map['expectedBytes'], fallback: -1),
      userPaused: downloadJobHasUserPauseIntent(state),
      queueWaiting: downloadJobQueueWaiting(state),
      updatedAtMillis: _intValue(map['updatedAtMillis']),
      taskSnapshot: map['taskSnapshot'] is Map
          ? Map<String, dynamic>.from(map['taskSnapshot'] as Map)
          : null,
      fingerprint: DownloadResourceFingerprint.fromJson(map['fingerprint']),
      lastByteReconciliationReason: _byteReconciliationReasonValue(
        map['lastByteReconciliationReason'],
      ),
      lastByteReconciliationProvenance: _optionalDurableByteProvenanceValue(
        map['lastByteReconciliationProvenance'],
      ),
      lastByteReconciliationAtMillis: _nullableIntValue(
        map['lastByteReconciliationAtMillis'],
      ),
      replicaTransaction: DownloadReplicaTransaction.fromJson(
        map['replicaTransaction'],
      ),
    );
  }
}

abstract interface class DownloadJobBackend {
  Future<Map<String, dynamic>?> read(String taskId);
  Future<List<Map<String, dynamic>>> readAll();
  Future<void> write(String taskId, Map<String, Object?> value);
  Future<void> delete(String taskId);
}

/// Deterministic durable-backend double used by transaction tests.
/// Reusing one backend simulates relaunch with a new store instance.
class InMemoryDownloadJobStoreBackend implements DownloadJobBackend {
  final Map<String, Map<String, Object?>> _rows =
      <String, Map<String, Object?>>{};

  @override
  Future<Map<String, dynamic>?> read(String taskId) async {
    final row = _rows[taskId];
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  @override
  Future<List<Map<String, dynamic>>> readAll() async => _rows.values
      .map((row) => Map<String, dynamic>.from(row))
      .toList(growable: false);

  @override
  Future<void> write(String taskId, Map<String, Object?> value) async {
    _rows[taskId] = Map<String, Object?>.from(value);
  }

  @override
  Future<void> delete(String taskId) async {
    _rows.remove(taskId);
  }
}

/// Hive backend kept separate from [DownloadJobStore] so state-machine tests do
/// not need a Flutter filesystem and future migrations can use another backend
/// without changing store invariants.
class HiveDownloadJobBackend implements DownloadJobBackend {
  const HiveDownloadJobBackend({this.boxName = kDownloadJobStoreBox});

  final String boxName;

  Future<Box<dynamic>> _box() => Hive.openBox<dynamic>(boxName);

  @override
  Future<Map<String, dynamic>?> read(String taskId) async {
    final raw = (await _box()).get(taskId);
    if (raw is! Map) return null;
    return Map<String, dynamic>.from(raw);
  }

  @override
  Future<List<Map<String, dynamic>>> readAll() async {
    final box = await _box();
    final result = <Map<String, dynamic>>[];
    for (final value in box.values) {
      if (value is Map) result.add(Map<String, dynamic>.from(value));
    }
    return result;
  }

  @override
  Future<void> write(String taskId, Map<String, Object?> value) async {
    await (await _box()).put(taskId, value);
  }

  @override
  Future<void> delete(String taskId) async {
    await (await _box()).delete(taskId);
  }
}

class DownloadJobStore {
  DownloadJobStore(this.backend);

  final DownloadJobBackend backend;
  Future<void> _writeChain = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() action) {
    final done = Completer<void>();
    final previous = _writeChain;
    _writeChain = previous.catchError((_) {}).whenComplete(() => done.future);
    return previous.catchError((_) {}).then((_) async {
      try {
        return await action();
      } finally {
        if (!done.isCompleted) done.complete();
      }
    });
  }

  Future<DownloadJobRecord?> get(String taskId) async {
    final id = taskId.trim();
    if (id.isEmpty) return null;
    return DownloadJobRecord.fromJson(await backend.read(id));
  }

  Future<DownloadAttemptToken?> beginReplicaTransaction(
    String taskId, {
    required DownloadReplicaOperation operation,
    required DownloadJobState state,
    Map<String, Object?> intentData = const <String, Object?>{},
    int? updatedAtMillis,
  }) => _serialize(() async {
    final current = await get(taskId);
    if (current == null || downloadJobIsTerminal(current.state)) return null;
    final generation = current.generation + 1;
    final next = current.copyWith(
      state: state,
      generation: generation,
      updatedAtMillis: updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch,
      replicaTransaction: DownloadReplicaTransaction(
        operation: operation,
        phase: DownloadReplicaTransactionPhase.intent,
        generation: generation,
        intentData: Map<String, Object?>.from(intentData),
      ),
    );
    if (!await _putUnlocked(next)) return null;
    return next.attemptToken;
  });

  /// Atomically creates the first durable job row together with its write-ahead
  /// replica intent. This closes the fresh-start crash window where a job row
  /// could exist without enough information to rebuild a required replica.
  Future<DownloadAttemptToken?> beginReplicaTransactionFromSeed(
    DownloadJobRecord seed, {
    required DownloadReplicaOperation operation,
    required DownloadJobState state,
    Map<String, Object?> intentData = const <String, Object?>{},
    int? updatedAtMillis,
  }) => _serialize(() async {
    final taskId = seed.taskId.trim();
    final trackingUrl = seed.trackingUrl.trim();
    if (taskId.isEmpty || trackingUrl.isEmpty) return null;
    if (seed.generation < 0 || seed.durableBytes < 0) return null;
    if (await get(taskId) != null) return null;

    final generation = seed.generation + 1;
    final next = seed.copyWith(
      state: state,
      generation: generation,
      updatedAtMillis: updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch,
      replicaTransaction: DownloadReplicaTransaction(
        operation: operation,
        phase: DownloadReplicaTransactionPhase.intent,
        generation: generation,
        intentData: Map<String, Object?>.from(intentData),
      ),
    );
    if (!await _putUnlocked(next)) return null;
    return next.attemptToken;
  });

  Future<bool> advanceReplicaTransaction(
    DownloadAttemptToken token,
    DownloadReplicaTransactionPhase phase, {
    int? updatedAtMillis,
  }) => _serialize(() async {
    final current = await get(token.taskId);
    final transaction = current?.replicaTransaction;
    if (current == null ||
        current.generation != token.generation ||
        transaction == null ||
        transaction.generation != token.generation) {
      return false;
    }
    if (phase.index < transaction.phase.index) return false;
    return _putUnlocked(
      current.copyWith(
        updatedAtMillis:
            updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch,
        replicaTransaction: transaction.copyWith(phase: phase),
      ),
    );
  });

  Future<bool> commitReplicaTransaction(
    DownloadAttemptToken token, {
    int? updatedAtMillis,
  }) => _serialize(() async {
    final current = await get(token.taskId);
    final transaction = current?.replicaTransaction;
    if (current == null ||
        current.generation != token.generation ||
        transaction == null ||
        transaction.generation != token.generation ||
        transaction.phase != DownloadReplicaTransactionPhase.projecting) {
      return false;
    }
    return _putUnlocked(
      current.copyWith(
        updatedAtMillis:
            updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch,
        clearReplicaTransaction: true,
      ),
    );
  });

  Future<List<DownloadJobRecord>> all() async {
    final jobs = <DownloadJobRecord>[];
    for (final raw in await backend.readAll()) {
      final job = DownloadJobRecord.fromJson(raw);
      if (job != null) jobs.add(job);
    }
    jobs.sort((a, b) => a.updatedAtMillis.compareTo(b.updatedAtMillis));
    return jobs;
  }

  /// Returns every execution row currently associated with one logical episode.
  /// The store intentionally does not collapse them here: DownloadService must
  /// settle/adopt executor ownership before removing an obsolete task ID.
  Future<List<DownloadJobRecord>> allForLogicalId(String logicalId) async {
    final id = logicalId.trim();
    if (id.isEmpty) return const <DownloadJobRecord>[];
    final jobs = await all();
    return jobs
        .where((job) => _nonEmptyString(job.logicalId) == id)
        .toList(growable: false);
  }

  /// Persist a newer view of a logical job.
  ///
  /// Returns false for stale or unsafe writes instead of allowing a late
  /// callback to regress durable state. The only supported way to intentionally
  /// restart from byte zero is to [remove] the job first (the user-delete path).
  Future<bool> put(DownloadJobRecord next) =>
      _serialize(() => _putUnlocked(next));

  Future<bool> _putUnlocked(DownloadJobRecord next) async {
    final taskId = next.taskId.trim();
    final trackingUrl = next.trackingUrl.trim();
    if (taskId.isEmpty || trackingUrl.isEmpty) return false;
    if (next.generation < 0 || next.durableBytes < 0) return false;

    final current = await get(taskId);
    final incomingLogicalId = _nonEmptyString(next.logicalId);
    final currentLogicalId = _nonEmptyString(current?.logicalId);
    if (currentLogicalId != null &&
        incomingLogicalId != null &&
        currentLogicalId != incomingLogicalId) {
      return false;
    }
    if (current != null) {
      // Every terminal logical state is generation-fenced. A newer
      // executor callback may never reopen a canceled/orphaned/completed job;
      // only the explicit tombstone/file cleanup transaction may remove it.
      if (downloadJobIsTerminal(current.state) && next.state != current.state) {
        return false;
      }
      if (next.generation < current.generation) return false;
      if (next.durableBytes < current.durableBytes) return false;
      if (current.expectedBytes > 0 &&
          next.expectedBytes > 0 &&
          current.expectedBytes != next.expectedBytes) {
        return false;
      }
      if (current.trackingUrl != trackingUrl) return false;
      final oldFingerprint = current.fingerprint;
      final newFingerprint = next.fingerprint;
      if (oldFingerprint != null &&
          newFingerprint != null &&
          !oldFingerprint.compatibleWith(newFingerprint)) {
        return false;
      }
    }

    // Unknown fields in a status-only checkpoint must not discard identity
    // evidence and let a later incompatible URL/size pass validation.
    final oldFingerprint = current?.fingerprint;
    final newFingerprint = next.fingerprint;
    final fingerprint = oldFingerprint == null
        ? newFingerprint
        : DownloadResourceFingerprint(
            strongEtag:
                _nonEmptyString(newFingerprint?.strongEtag) ??
                oldFingerprint.strongEtag,
            lastModified:
                _nonEmptyString(newFingerprint?.lastModified) ??
                oldFingerprint.lastModified,
            expectedBytes: (newFingerprint?.expectedBytes ?? -1) > 0
                ? newFingerprint!.expectedBytes
                : oldFingerprint.expectedBytes,
            finalUrl:
                _nonEmptyString(newFingerprint?.finalUrl) ??
                oldFingerprint.finalUrl,
          );
    final durable = next.copyWith(
      logicalId: incomingLogicalId ?? currentLogicalId,
      userPaused: downloadJobHasUserPauseIntent(next.state),
      queueWaiting: downloadJobQueueWaiting(next.state),
      durableByteProvenance: _normalizedDurableByteProvenance(
        next.durableBytes,
        next.durableByteProvenance,
      ),
      expectedBytes: next.expectedBytes > 0
          ? next.expectedBytes
          : current?.expectedBytes,
      taskSnapshot: next.taskSnapshot ?? current?.taskSnapshot,
      fingerprint: fingerprint,
    );
    await backend.write(taskId, durable.toJson());
    return true;
  }

  /// Persist one logical lifecycle checkpoint while preserving the store's
  /// monotonic byte, generation and resource-identity invariants.
  ///
  /// DownloadService supplies orchestration evidence; this store owns how that
  /// evidence is merged with the durable logical record. This keeps lifecycle
  /// writes out of UI/plugin code and prevents a status-only checkpoint from
  /// discarding stronger identity or byte evidence.
  Future<bool> checkpoint({
    required String taskId,
    String? logicalId,
    required String trackingUrl,
    required DownloadJobState state,
    int? durableBytes,
    DownloadDurableByteProvenance? durableByteProvenance,
    int? expectedBytes,
    bool? userPaused,
    bool? queueWaiting,
    Map<String, dynamic>? taskSnapshot,
    DownloadResourceFingerprint? fingerprint,
    int? updatedAtMillis,
  }) => _serialize(() async {
    final id = taskId.trim();
    final tracking = trackingUrl.trim();
    if (id.isEmpty || tracking.isEmpty) return false;

    final current = await get(id);
    final incomingBytes = durableBytes ?? current?.durableBytes ?? 0;
    if (incomingBytes < 0) return false;
    final keptBytes = current != null && current.durableBytes > incomingBytes
        ? current.durableBytes
        : incomingBytes;
    final keptProvenance = _checkpointProvenance(
      current: current,
      suppliedBytes: durableBytes,
      keptBytes: keptBytes,
      suppliedProvenance: durableByteProvenance,
    );
    final incomingExpected = expectedBytes ?? -1;
    final keptExpected = incomingExpected > 0
        ? incomingExpected
        : (current?.expectedBytes ?? -1);
    final now = updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch;

    final next = current == null
        ? DownloadJobRecord(
            taskId: id,
            logicalId: _nonEmptyString(logicalId),
            trackingUrl: tracking,
            state: state,
            generation: 0,
            durableBytes: keptBytes,
            durableByteProvenance: keptProvenance,
            expectedBytes: keptExpected,
            userPaused: userPaused ?? false,
            queueWaiting: queueWaiting ?? false,
            updatedAtMillis: now,
            taskSnapshot: taskSnapshot,
            fingerprint: fingerprint,
          )
        : current.copyWith(
            logicalId: _nonEmptyString(logicalId),
            state: state,
            durableBytes: keptBytes,
            durableByteProvenance: keptProvenance,
            expectedBytes: keptExpected,
            userPaused: userPaused ?? current.userPaused,
            queueWaiting: queueWaiting ?? current.queueWaiting,
            updatedAtMillis: now,
            taskSnapshot: taskSnapshot,
            fingerprint: fingerprint,
          );
    return _putUnlocked(next);
  });

  /// Persist the explicit user-delete terminal fact before touching any
  /// runtime owner. This is the only transition allowed to convert another
  /// terminal state (for example completed) into canceled. Ordinary writes
  /// remain protected by [_putUnlocked]'s terminal fence.
  Future<DownloadAttemptToken?> tombstoneForDeletion(
    DownloadJobRecord seed, {
    int? updatedAtMillis,
  }) => _serialize(() async {
    final taskId = seed.taskId.trim();
    final trackingUrl = seed.trackingUrl.trim();
    if (taskId.isEmpty || trackingUrl.isEmpty) return null;
    if (seed.generation < 0 || seed.durableBytes < 0) return null;

    final current = await get(taskId);
    final seedLogicalId = _nonEmptyString(seed.logicalId);
    final currentLogicalId = _nonEmptyString(current?.logicalId);
    if (current != null) {
      if (current.trackingUrl != trackingUrl) return null;
      if (currentLogicalId != null &&
          seedLogicalId != null &&
          currentLogicalId != seedLogicalId) {
        return null;
      }
      if (current.state == DownloadJobState.canceled) {
        return current.attemptToken;
      }
    }

    final base = current ?? seed;
    final next = base.copyWith(
      logicalId: currentLogicalId ?? seedLogicalId,
      state: DownloadJobState.canceled,
      generation: base.generation + 1,
      userPaused: false,
      queueWaiting: false,
      updatedAtMillis: updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch,
    );
    // Intentionally bypass the generic terminal-transition rejection.
    // Every other identity/byte field is inherited from the current row.
    await backend.write(taskId, next.toJson());
    return next.attemptToken;
  });

  /// Start a new execution generation atomically. The durable bytes and
  /// fingerprint are inherited; beginning an attempt can never reset progress.
  Future<DownloadAttemptToken?> beginAttempt(
    String taskId, {
    DownloadJobState state = DownloadJobState.starting,
    int? updatedAtMillis,
  }) => _serialize(
    () => _beginGenerationUnlocked(
      taskId,
      state: state,
      updatedAtMillis: updatedAtMillis,
    ),
  );

  /// Advance the same durable generation fence for an ownership-changing
  /// control operation (pause/resume/cancel/restack/source replacement).
  ///
  /// Native callbacks do not all carry an operation id, so service-side
  /// state/ownership acknowledgement still gates their projection. Advancing
  /// this generation additionally makes every token-aware Range/multipart
  /// callback from the previous operation stale before the executor effect.
  Future<DownloadAttemptToken?> beginOperation(
    String taskId, {
    required DownloadJobState state,
    int? updatedAtMillis,
  }) => _serialize(
    () => _beginGenerationUnlocked(
      taskId,
      state: state,
      updatedAtMillis: updatedAtMillis,
    ),
  );

  Future<DownloadAttemptToken?> _beginGenerationUnlocked(
    String taskId, {
    required DownloadJobState state,
    int? updatedAtMillis,
  }) async {
    final current = await get(taskId);
    if (current == null || downloadJobIsTerminal(current.state)) return null;
    final next = current.copyWith(
      state: state,
      generation: current.generation + 1,
      updatedAtMillis: updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch,
    );
    if (!await _putUnlocked(next)) return null;
    return next.attemptToken;
  }

  /// Apply one callback/result only when it belongs to the active generation.
  /// This is the durable counterpart of [DownloadAttemptFence].
  Future<bool> updateForAttempt(
    DownloadAttemptToken token, {
    DownloadJobState? state,
    int? durableBytes,
    DownloadDurableByteProvenance? durableByteProvenance,
    int? expectedBytes,
    bool? userPaused,
    bool? queueWaiting,
    DownloadResourceFingerprint? fingerprint,
    int? updatedAtMillis,
  }) => _serialize(() async {
    final current = await get(token.taskId);
    if (current == null || current.generation != token.generation) return false;
    final nextBytes = durableBytes ?? current.durableBytes;
    final nextProvenance = durableBytes == null
        ? (durableByteProvenance ?? current.durableByteProvenance)
        : _normalizedDurableByteProvenance(
            nextBytes,
            durableByteProvenance ??
                (nextBytes == current.durableBytes
                    ? current.durableByteProvenance
                    : DownloadDurableByteProvenance.legacyUnknown),
          );
    return _putUnlocked(
      current.copyWith(
        state: state,
        durableBytes: durableBytes,
        durableByteProvenance: nextProvenance,
        expectedBytes: expectedBytes,
        userPaused: userPaused,
        queueWaiting: queueWaiting,
        fingerprint: fingerprint,
        updatedAtMillis:
            updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );
  });

  /// Apply stronger recovery evidence that proves fewer bytes survived.
  ///
  /// This is intentionally separate from [put], [checkpoint], and
  /// [updateForAttempt], which remain monotonic. A successful downward
  /// correction advances the generation so callbacks from the pre-correction
  /// writer can no longer resurrect the discarded high-water mark.
  Future<DownloadAttemptToken?> reconcileDurableBytes(
    DownloadAttemptToken token, {
    required int durableBytes,
    required DownloadDurableByteProvenance evidenceProvenance,
    required DownloadByteReconciliationReason reason,
    DownloadResourceFingerprint? fingerprint,
    int? updatedAtMillis,
  }) => _serialize(() async {
    if (durableBytes < 0) return null;
    if (evidenceProvenance == DownloadDurableByteProvenance.none ||
        evidenceProvenance == DownloadDurableByteProvenance.legacyUnknown) {
      return null;
    }
    final current = await get(token.taskId);
    if (current == null || current.generation != token.generation) return null;
    if (current.state == DownloadJobState.completed) return null;
    if (durableBytes >= current.durableBytes) return null;

    final oldFingerprint = current.fingerprint;
    if (oldFingerprint != null &&
        fingerprint != null &&
        !oldFingerprint.compatibleWith(fingerprint)) {
      return null;
    }

    final now = updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch;
    final next = current.copyWith(
      generation: current.generation + 1,
      durableBytes: durableBytes,
      durableByteProvenance: _normalizedDurableByteProvenance(
        durableBytes,
        evidenceProvenance,
      ),
      fingerprint: fingerprint,
      updatedAtMillis: now,
      lastByteReconciliationReason: reason,
      lastByteReconciliationProvenance: evidenceProvenance,
      lastByteReconciliationAtMillis: now,
    );

    // Deliberately bypass only the normal byte-monotonicity check. All
    // identity/generation checks were performed above while serialized.
    await backend.write(token.taskId, next.toJson());
    return next.attemptToken;
  });

  Future<void> remove(String taskId) =>
      _serialize(() => backend.delete(taskId.trim()));

  /// Durable generation check for async callbacks after relaunch.
  Future<bool> accepts(DownloadAttemptToken token) async {
    if (token.generation <= 0) return false;
    final job = await get(token.taskId);
    return job != null && job.generation == token.generation;
  }
}

DownloadDurableByteProvenance _normalizedDurableByteProvenance(
  int durableBytes,
  DownloadDurableByteProvenance provenance,
) {
  if (durableBytes <= 0) return DownloadDurableByteProvenance.none;
  return provenance == DownloadDurableByteProvenance.none
      ? DownloadDurableByteProvenance.legacyUnknown
      : provenance;
}

DownloadByteReconciliationReason? _byteReconciliationReasonValue(
  Object? value,
) {
  final name = value?.toString();
  if (name == null || name.isEmpty) return null;
  for (final reason in DownloadByteReconciliationReason.values) {
    if (reason.name == name) return reason;
  }
  return null;
}

DownloadDurableByteProvenance? _optionalDurableByteProvenanceValue(
  Object? value,
) {
  final name = value?.toString();
  if (name == null || name.isEmpty) return null;
  for (final provenance in DownloadDurableByteProvenance.values) {
    if (provenance.name == name) return provenance;
  }
  return null;
}

int? _nullableIntValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

DownloadDurableByteProvenance _durableByteProvenanceValue(
  Object? value, {
  required int durableBytes,
  required int schemaVersion,
}) {
  if (durableBytes <= 0) return DownloadDurableByteProvenance.none;
  final raw = value?.toString().trim();
  if (raw != null && raw.isNotEmpty) {
    for (final candidate in DownloadDurableByteProvenance.values) {
      if (candidate.name == raw) return candidate;
    }
  }
  // Schema-v1 rows had no provenance. Unknown/future values are also treated
  // conservatively so they can never gain authority accidentally.
  return DownloadDurableByteProvenance.legacyUnknown;
}

DownloadDurableByteProvenance _checkpointProvenance({
  required DownloadJobRecord? current,
  required int? suppliedBytes,
  required int keptBytes,
  required DownloadDurableByteProvenance? suppliedProvenance,
}) {
  if (keptBytes <= 0) return DownloadDurableByteProvenance.none;
  if (suppliedProvenance != null) {
    return _normalizedDurableByteProvenance(keptBytes, suppliedProvenance);
  }
  if (current != null &&
      (suppliedBytes == null || keptBytes == current.durableBytes)) {
    return _normalizedDurableByteProvenance(
      keptBytes,
      current.durableByteProvenance,
    );
  }
  return DownloadDurableByteProvenance.legacyUnknown;
}

String? _nonEmptyString(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

int _intValue(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

DownloadJobState _jobStateValue(Object? raw) {
  final name = raw?.toString();
  for (final state in DownloadJobState.values) {
    if (state.name == name) return state;
  }
  // Unknown future/legacy state must never be interpreted as completed or a
  // fresh start. Interrupted is the conservative recoverable representation.
  return DownloadJobState.interrupted;
}
