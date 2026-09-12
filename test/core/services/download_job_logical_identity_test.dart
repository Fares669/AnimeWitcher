import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_job_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryBackend implements DownloadJobBackend {
  final Map<String, Map<String, dynamic>> values = {};

  @override
  Future<void> delete(String taskId) async => values.remove(taskId);

  @override
  Future<Map<String, dynamic>?> read(String taskId) async {
    final value = values[taskId];
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  @override
  Future<List<Map<String, dynamic>>> readAll() async => values.values
      .map((value) => Map<String, dynamic>.from(value))
      .toList(growable: false);

  @override
  Future<void> write(String taskId, Map<String, Object?> value) async {
    values[taskId] = Map<String, dynamic>.from(value);
  }
}

DownloadJobRecord _job({
  required String taskId,
  String? logicalId,
  int generation = 1,
  int updatedAtMillis = 1,
}) => DownloadJobRecord(
  taskId: taskId,
  logicalId: logicalId,
  trackingUrl: 'https://example.test/watch/12',
  state: DownloadJobState.running,
  generation: generation,
  durableBytes: 0,
  expectedBytes: 1000,
  userPaused: false,
  queueWaiting: false,
  updatedAtMillis: updatedAtMillis,
);

void main() {
  group('DM-24 JobStore logical identity', () {
    test('logical id round trips independently from execution task id', () {
      final source = _job(
        taskId: 'attempt-a',
        logicalId: 'download:v1|sync:malid:999|s1|e12|dub:subbed',
      );

      final json = source.toJson();
      final decoded = DownloadJobRecord.fromJson(json);

      expect(json['schemaVersion'], kDownloadJobSchemaVersion);
      expect(decoded?.taskId, 'attempt-a');
      expect(decoded?.logicalId, source.logicalId);
    });

    test('legacy rows remain readable without inventing a logical id', () {
      final legacy = _job(taskId: 'legacy', logicalId: 'logical-a').toJson()
        ..['schemaVersion'] = 4
        ..remove('logicalId');

      final decoded = DownloadJobRecord.fromJson(legacy);

      expect(decoded, isNotNull);
      expect(decoded!.logicalId, isNull);
    });

    test('status-only checkpoint preserves existing logical identity', () async {
      final backend = _MemoryBackend();
      final store = DownloadJobStore(backend);
      expect(
        await store.put(_job(taskId: 'attempt-a', logicalId: 'logical-a')),
        isTrue,
      );

      expect(
        await store.put(
          _job(taskId: 'attempt-a', generation: 2, updatedAtMillis: 2),
        ),
        isTrue,
      );

      expect((await store.get('attempt-a'))?.logicalId, 'logical-a');
    });

    test('one execution task cannot silently change logical episode', () async {
      final backend = _MemoryBackend();
      final store = DownloadJobStore(backend);
      expect(
        await store.put(_job(taskId: 'attempt-a', logicalId: 'logical-a')),
        isTrue,
      );

      expect(
        await store.put(
          _job(
            taskId: 'attempt-a',
            logicalId: 'logical-b',
            generation: 2,
            updatedAtMillis: 2,
          ),
        ),
        isFalse,
      );
      expect((await store.get('attempt-a'))?.logicalId, 'logical-a');
    });

    test('store can enumerate multiple execution ids for one logical job', () async {
      final backend = _MemoryBackend();
      final store = DownloadJobStore(backend);
      await store.put(
        _job(taskId: 'attempt-b', logicalId: 'logical-a', updatedAtMillis: 2),
      );
      await store.put(
        _job(taskId: 'attempt-a', logicalId: 'logical-a', updatedAtMillis: 1),
      );
      await store.put(
        _job(taskId: 'other', logicalId: 'logical-b', updatedAtMillis: 3),
      );

      final matches = await store.allForLogicalId('logical-a');

      expect(matches.map((job) => job.taskId), ['attempt-a', 'attempt-b']);
    });
  });
}
