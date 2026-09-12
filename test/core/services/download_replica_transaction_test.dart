import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_job_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late InMemoryDownloadJobStoreBackend backend;
  late DownloadJobStore store;

  DownloadJobRecord record({int generation = 2}) => DownloadJobRecord(
    taskId: 'episode-1',
    trackingUrl: 'https://example.test/episode-1',
    state: DownloadJobState.running,
    generation: generation,
    durableBytes: 0,
    expectedBytes: 100,
    userPaused: false,
    queueWaiting: false,
    updatedAtMillis: 1,
  );

  setUp(() {
    backend = InMemoryDownloadJobStoreBackend();
    store = DownloadJobStore(backend);
  });

  test('intent survives relaunch before executor acknowledgement', () async {
    await store.put(record());
    final token = await store.beginReplicaTransaction(
      'episode-1',
      operation: DownloadReplicaOperation.pause,
      state: DownloadJobState.pausing,
      updatedAtMillis: 10,
    );

    expect(token, isNotNull);
    final persisted = await DownloadJobStore(backend).get('episode-1');
    expect(persisted!.generation, 3);
    expect(persisted.replicaTransaction!.operation, DownloadReplicaOperation.pause);
    expect(
      persisted.replicaTransaction!.phase,
      DownloadReplicaTransactionPhase.intent,
    );
  });

  test('executor acknowledgement survives relaunch', () async {
    await store.put(record());
    final token = (await store.beginReplicaTransaction(
      'episode-1',
      operation: DownloadReplicaOperation.resume,
      state: DownloadJobState.starting,
    ))!;

    expect(
      await store.advanceReplicaTransaction(
        token,
        DownloadReplicaTransactionPhase.executorAcknowledged,
      ),
      isTrue,
    );

    final persisted = await DownloadJobStore(backend).get('episode-1');
    expect(
      persisted!.replicaTransaction!.phase,
      DownloadReplicaTransactionPhase.executorAcknowledged,
    );
  });

  test('projection phase is durable and commit clears only journal', () async {
    await store.put(record());
    final token = (await store.beginReplicaTransaction(
      'episode-1',
      operation: DownloadReplicaOperation.cancel,
      state: DownloadJobState.interrupted,
    ))!;

    expect(
      await store.advanceReplicaTransaction(
        token,
        DownloadReplicaTransactionPhase.executorAcknowledged,
      ),
      isTrue,
    );
    expect(
      await store.advanceReplicaTransaction(
        token,
        DownloadReplicaTransactionPhase.projecting,
      ),
      isTrue,
    );
    expect(await store.commitReplicaTransaction(token), isTrue);

    final persisted = await store.get('episode-1');
    expect(persisted!.replicaTransaction, isNull);
    expect(persisted.generation, token.generation);
    expect(persisted.state, DownloadJobState.interrupted);
  });

  test('stale process cannot advance a newer generation', () async {
    await store.put(record());
    final stale = (await store.beginReplicaTransaction(
      'episode-1',
      operation: DownloadReplicaOperation.pause,
      state: DownloadJobState.pausing,
    ))!;
    final newer = (await store.beginReplicaTransaction(
      'episode-1',
      operation: DownloadReplicaOperation.resume,
      state: DownloadJobState.starting,
    ))!;

    expect(newer.generation, greaterThan(stale.generation));
    expect(
      await store.advanceReplicaTransaction(
        stale,
        DownloadReplicaTransactionPhase.executorAcknowledged,
      ),
      isFalse,
    );
    expect(
      (await store.get('episode-1'))!.replicaTransaction!.generation,
      newer.generation,
    );
  });

  test('legacy v6 row loads without a transaction journal', () {
    final json = record().toJson()
      ..['schemaVersion'] = 6
      ..remove('replicaTransaction');

    final restored = DownloadJobRecord.fromJson(json);
    expect(restored, isNotNull);
    expect(restored!.replicaTransaction, isNull);
  });

  test(
    'fresh-start intent creates first durable row with relaunch recovery payload',
    () async {
      final seed = record(generation: 0).copyWith(
        state: DownloadJobState.starting,
      );
      final token = await store.beginReplicaTransactionFromSeed(
        seed,
        operation: DownloadReplicaOperation.start,
        state: DownloadJobState.starting,
        intentData: const <String, Object?>{
          'refreshDescriptor': <String, Object?>{
            'providerId': 'provider-a',
            'source': 'server-a',
            'quality': '1080p',
            'refreshUrl': 'https://example.test/refresh',
          },
        },
        updatedAtMillis: 20,
      );

      expect(token, isNotNull);
      expect(token!.generation, 1);

      final relaunched = DownloadJobStore(backend);
      final persisted = await relaunched.get('episode-1');
      expect(persisted, isNotNull);
      expect(persisted!.generation, token.generation);
      expect(
        persisted.replicaTransaction!.operation,
        DownloadReplicaOperation.start,
      );
      expect(
        persisted.replicaTransaction!.phase,
        DownloadReplicaTransactionPhase.intent,
      );
      expect(
        persisted.replicaTransaction!.intentData['refreshDescriptor'],
        const <String, Object?>{
          'providerId': 'provider-a',
          'source': 'server-a',
          'quality': '1080p',
          'refreshUrl': 'https://example.test/refresh',
        },
      );
    },
  );
}
