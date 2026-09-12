from pathlib import Path

path = Path('lib/core/services/download_job_store.dart')
source = path.read_text()

if 'enum DownloadReplicaOperation' in source:
    print('DM-11 transaction foundation already present')
    raise SystemExit(0)


def replace_once(old: str, new: str, label: str) -> None:
    global source
    if old not in source:
        raise SystemExit(f'DM-11 {label} anchor drift')
    source = source.replace(old, new, 1)


replace_once(
    'const int kDownloadJobSchemaVersion = 6;',
    'const int kDownloadJobSchemaVersion = 7;',
    'schema',
)

reason_enum = '''enum DownloadByteReconciliationReason {
  exactDiskLoss,
  noSurvivingBytes,
  multipartManifestRollback,
  nativeRecoverabilityLoss,
}
'''
replace_once(
    reason_enum,
    reason_enum + r'''

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
  });

  final DownloadReplicaOperation operation;
  final DownloadReplicaTransactionPhase phase;
  final int generation;

  DownloadReplicaTransaction copyWith({DownloadReplicaTransactionPhase? phase}) =>
      DownloadReplicaTransaction(
        operation: operation,
        phase: phase ?? this.phase,
        generation: generation,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'operation': operation.name,
    'phase': phase.name,
    'generation': generation,
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
    return DownloadReplicaTransaction(
      operation: operation,
      phase: phase,
      generation: generation,
    );
  }
}
''',
    'transaction model',
)

replace_once(
    '''    this.lastByteReconciliationAtMillis,
  });''',
    '''    this.lastByteReconciliationAtMillis,
    this.replicaTransaction,
  });''',
    'constructor',
)
replace_once(
    '''  final int? lastByteReconciliationAtMillis;

  DownloadAttemptToken get attemptToken =>''',
    '''  final int? lastByteReconciliationAtMillis;
  final DownloadReplicaTransaction? replicaTransaction;

  DownloadAttemptToken get attemptToken =>''',
    'field',
)
replace_once(
    '''    int? lastByteReconciliationAtMillis,
  }) => DownloadJobRecord(''',
    '''    int? lastByteReconciliationAtMillis,
    DownloadReplicaTransaction? replicaTransaction,
    bool clearReplicaTransaction = false,
  }) => DownloadJobRecord(''',
    'copyWith signature',
)
copy_anchor = '''    lastByteReconciliationAtMillis:
        lastByteReconciliationAtMillis ?? this.lastByteReconciliationAtMillis,
'''
replace_once(
    copy_anchor,
    copy_anchor + '''    replicaTransaction: clearReplicaTransaction
        ? null
        : (replicaTransaction ?? this.replicaTransaction),
''',
    'copyWith body',
)
json_anchor = '''    if (lastByteReconciliationAtMillis != null)
      'lastByteReconciliationAtMillis': lastByteReconciliationAtMillis,
'''
replace_once(
    json_anchor,
    json_anchor + '''    if (replicaTransaction != null)
      'replicaTransaction': replicaTransaction!.toJson(),
''',
    'serialization',
)
from_json_anchor = '''      lastByteReconciliationAtMillis: _nullableIntValue(
        map['lastByteReconciliationAtMillis'],
      ),
'''
replace_once(
    from_json_anchor,
    from_json_anchor + '''      replicaTransaction: DownloadReplicaTransaction.fromJson(
        map['replicaTransaction'],
      ),
''',
    'deserialization',
)

all_anchor = '''  Future<List<DownloadJobRecord>> all() async {
'''
methods = r'''  Future<DownloadAttemptToken?> beginReplicaTransaction(
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
      updatedAtMillis:
          updatedAtMillis ?? DateTime.now().millisecondsSinceEpoch,
      replicaTransaction: DownloadReplicaTransaction(
        operation: operation,
        phase: DownloadReplicaTransactionPhase.intent,
        generation: generation,
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

'''
replace_once(all_anchor, methods + all_anchor, 'store methods')
path.write_text(source)
