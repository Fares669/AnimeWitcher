import 'dart:io';

import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_job_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryBackend implements DownloadJobBackend {
  final Map<String, Map<String, dynamic>> values = {};

  @override
  Future<Map<String, dynamic>?> read(String taskId) async {
    final value = values[taskId];
    return value == null ? null : Map<String, dynamic>.from(value);
  }

  @override
  Future<List<Map<String, dynamic>>> readAll() async =>
      values.values.map(Map<String, dynamic>.from).toList();

  @override
  Future<void> write(String taskId, Map<String, Object?> value) async {
    values[taskId] = Map<String, dynamic>.from(value);
  }

  @override
  Future<void> delete(String taskId) async => values.remove(taskId);
}

Map<String, Object?> _rawJob({
  required int schemaVersion,
  required String state,
  bool userPaused = false,
  bool queueWaiting = false,
}) => <String, Object?>{
  'schemaVersion': schemaVersion,
  'taskId': 'task-1',
  'trackingUrl': 'episode://1',
  'state': state,
  'generation': 1,
  'durableBytes': 0,
  'expectedBytes': 100,
  'userPaused': userPaused,
  'queueWaiting': queueWaiting,
  'updatedAtMillis': 1,
};

void main() {
  group('DM-05 sole logical lifecycle authority', () {
    test(
      'store normalizes compatibility flags from DownloadJobState',
      () async {
        final store = DownloadJobStore(_MemoryBackend());
        expect(
          await store.put(
            const DownloadJobRecord(
              taskId: 'task-1',
              trackingUrl: 'episode://1',
              state: DownloadJobState.running,
              generation: 1,
              durableBytes: 0,
              expectedBytes: 100,
              userPaused: true,
              queueWaiting: true,
              updatedAtMillis: 1,
            ),
          ),
          isTrue,
        );

        final stored = await store.get('task-1');
        expect(stored, isNotNull);
        expect(stored!.state, DownloadJobState.running);
        expect(stored.userPaused, isFalse);
        expect(stored.queueWaiting, isFalse);
      },
    );

    test('legacy pause flag migrates once into explicit logical state', () {
      final record = DownloadJobRecord.fromJson(
        _rawJob(schemaVersion: 5, state: 'running', userPaused: true),
      );
      expect(record, isNotNull);
      expect(record!.state, DownloadJobState.pausedByUser);
      expect(record.userPaused, isTrue);
      expect(record.queueWaiting, isFalse);
    });

    test('current schema ignores stale side flags for a running job', () {
      final record = DownloadJobRecord.fromJson(
        _rawJob(
          schemaVersion: 6,
          state: 'running',
          userPaused: true,
          queueWaiting: true,
        ),
      );
      expect(record, isNotNull);
      expect(record!.state, DownloadJobState.running);
      expect(record.userPaused, isFalse);
      expect(record.queueWaiting, isFalse);
    });

    test(
      'startup recovery does not let legacy pause metadata override JobStore',
      () {
        final source = File('lib/core/services/download_service.dart')
            .readAsStringSync();
        expect(
          source,
          contains(
            'final userPaused = oldJob != null\n'
            '          ? downloadJobHasUserPauseIntent(oldJob.state)\n'
            '          : isUserPausedMetadata(metadata) ||',
          ),
        );
        expect(source, isNot(contains('oldJob?.userPaused == true')));
        expect(
          source,
          contains(
            'final projectedState = projectedJob?.state ?? recoveryPlan.state;',
          ),
        );
      },
    );
  });
}
