
import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_job_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryBackend implements DownloadJobBackend {
  final Map<String, Map<String, dynamic>> values =
      <String, Map<String, dynamic>>{};

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
  DownloadJobState state = DownloadJobState.running,
  int generation = 1,
}) => DownloadJobRecord(
  taskId: 'episode-1',
  trackingUrl: 'https://example.test/watch/1',
  state: state,
  generation: generation,
  durableBytes: 100,
  durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
  expectedBytes: 1000,
  userPaused: false,
  queueWaiting: false,
  updatedAtMillis: generation,
);

void main() {
  group('DM-10 durable generation fencing', () {
    late DownloadJobStore store;

    setUp(() {
      store = DownloadJobStore(_MemoryBackend());
    });

    test(
      'canceled tombstone cannot be reopened by a newer running generation',
      () async {
        expect(
          await store.put(
            _job(state: DownloadJobState.canceled, generation: 4),
          ),
          isTrue,
        );

        expect(
          await store.put(_job(state: DownloadJobState.running, generation: 5)),
          isFalse,
        );
        expect(await store.beginAttempt('episode-1'), isNull);
        expect(
          (await store.get('episode-1'))?.state,
          DownloadJobState.canceled,
        );
      },
    );

    test('pause callback from the previous generation cannot regress a resumed job', () async {
      expect(await store.put(_job(generation: 1)), isTrue);
      final pause = await store.beginAttempt(
        'episode-1',
        state: DownloadJobState.pausing,
      );
      expect(pause?.generation, 2);
      final resume = await store.beginAttempt(
        'episode-1',
        state: DownloadJobState.starting,
      );
      expect(resume?.generation, 3);

      expect(
        await store.updateForAttempt(
          pause!,
          state: DownloadJobState.pausedByUser,
        ),
        isFalse,
      );
      expect((await store.get('episode-1'))?.state, DownloadJobState.starting);
    });

    test(
      'old retry failure cannot park a newer execution generation',
      () async {
        expect(await store.put(_job(generation: 7)), isTrue);
        final oldAttempt = await store.beginAttempt(
          'episode-1',
          state: DownloadJobState.running,
        );
        final retry = await store.beginAttempt(
          'episode-1',
          state: DownloadJobState.retryWaiting,
        );
        expect(oldAttempt?.generation, 8);
        expect(retry?.generation, 9);

        expect(
          await store.updateForAttempt(
            oldAttempt!,
            state: DownloadJobState.interrupted,
          ),
          isFalse,
        );
        expect((await store.get('episode-1'))?.generation, 9);
        expect(
          (await store.get('episode-1'))?.state,
          DownloadJobState.retryWaiting,
        );
      },
    );
  });

  }
