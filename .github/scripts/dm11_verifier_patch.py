from pathlib import Path
import runpy

runpy.run_path('.github/scripts/dm11_foundation_patch.py', run_name='__main__')

path = Path('lib/core/services/download_job_store.dart')
source = path.read_text()
if 'class InMemoryDownloadJobStoreBackend' not in source:
    anchor = '''abstract interface class DownloadJobBackend {
  Future<Map<String, dynamic>?> read(String taskId);
  Future<List<Map<String, dynamic>>> readAll();
  Future<void> write(String taskId, Map<String, Object?> value);
  Future<void> delete(String taskId);
}
'''
    implementation = r'''

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
'''
    if anchor not in source:
        raise SystemExit('DM-11 in-memory backend anchor drift')
    source = source.replace(anchor, anchor + implementation, 1)

# DM-11/DM-31 cycle bootstrap: a fresh start must be able to persist its first
# durable row and enough generic intent payload to reconstruct missing replicas
# after a crash. Keep the JobStore payload generic so it does not depend on the
# refresh-descriptor implementation.
if 'final Map<String, Object?> intentData;' not in source:
    old = '''class DownloadReplicaTransaction {
  const DownloadReplicaTransaction({
    required this.operation,
    required this.phase,
    required this.generation,
  });

  final DownloadReplicaOperation operation;
  final DownloadReplicaTransactionPhase phase;
  final int generation;

  DownloadReplicaTransaction copyWith({
    DownloadReplicaTransactionPhase? phase,
  }) => DownloadReplicaTransaction(
    operation: operation,
    phase: phase ?? this.phase,
    generation: generation,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'operation': operation.name,
    'phase': phase.name,
    'generation': generation,
  };
'''
    new = '''class DownloadReplicaTransaction {
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
'''
    if old not in source:
        raise SystemExit('DM-11 intent payload model anchor drift')
    source = source.replace(old, new, 1)

    old = '''    if (operation == null || phase == null) return null;
    return DownloadReplicaTransaction(
      operation: operation,
      phase: phase,
      generation: generation,
    );
'''
    new = '''    if (operation == null || phase == null) return null;
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
'''
    if old not in source:
        raise SystemExit('DM-11 intent payload deserialize anchor drift')
    source = source.replace(old, new, 1)

if 'Future<DownloadAttemptToken?> beginReplicaTransactionFromSeed(' not in source:
    old = '''  Future<DownloadAttemptToken?> beginReplicaTransaction(
    String taskId, {
    required DownloadReplicaOperation operation,
    required DownloadJobState state,
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
      ),
    );
    if (!await _putUnlocked(next)) return null;
    return next.attemptToken;
  });

'''
    new = '''  Future<DownloadAttemptToken?> beginReplicaTransaction(
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

'''
    if old not in source:
        raise SystemExit('DM-11 fresh-start transaction anchor drift')
    source = source.replace(old, new, 1)

path.write_text(source)
