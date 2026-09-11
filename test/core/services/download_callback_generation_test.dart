import 'dart:io';

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

  group('DM-10 service callback fences', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();

    test('cancel and restack correctness do not depend on fixed suppression windows', () {
      expect(source, isNot(contains('_cancellingUrls')));
      expect(source, isNot(contains('_restackingWaiterIds')));
      expect(
        source,
        isNot(contains('Future.delayed(const Duration(milliseconds: 500)')),
      );
      expect(
        source,
        isNot(
          contains('Future<void>.delayed(const Duration(milliseconds: 800)'),
        ),
      );

      final restackStart = source.indexOf(
        'Future<List<String>> _cancelNativeWaitersForRestackUnlocked(',
      );
      final restackEnd = source.indexOf(
        'Future<void> _enqueueExistingTaskAsWaiterUnlocked(',
        restackStart,
      );
      expect(restackStart, greaterThanOrEqualTo(0));
      expect(restackEnd, greaterThan(restackStart));
      final restack = source.substring(restackStart, restackEnd);
      expect(restack, contains('_jobStore.beginOperation('));
      expect(restack, contains('_waitForCancelOwnershipRelease('));
      expect(restack, contains('DownloadRuntimeOwnership.notOwned'));
    });

    test('ownership-changing commands advance durable generation before executor effects', () {
      final pauseStart = source.indexOf(
        'Future<void> pauseDownload(String taskId) async {',
      );
      final pauseEnd = source.indexOf(
        'Future<void> resumeDownload(String taskId) async {',
        pauseStart,
      );
      final pause = source.substring(pauseStart, pauseEnd);
      expect(pause, contains('_jobStore.beginOperation('));
      expect(
        pause.indexOf('_jobStore.beginOperation('),
        lessThan(pause.indexOf('await _rangeTransfers.stop(taskId);')),
      );

      final cancelStart = source.indexOf('Future<void> cancelDownload(');
      final cancelEnd = source.indexOf(
        'Future<DownloadCommandOutcome> cancelDownloadOutcome(',
        cancelStart,
      );
      final cancel = source.substring(cancelStart, cancelEnd);
      expect(cancel, contains('_jobStore.tombstoneForDeletion('));
      expect(
        cancel.indexOf('_jobStore.tombstoneForDeletion('),
        lessThan(cancel.indexOf('await _rangeTransfers.stop(taskId);')),
      );

      final refreshStart = source.indexOf(
        'Future<({DownloadTask task, bool refreshed})> _refreshTaskBeforeResume(',
      );
      final refreshEnd = source.indexOf(
        'Future<List<Task>> _liveTransferTasks()',
        refreshStart,
      );
      final refresh = source.substring(refreshStart, refreshEnd);
      expect(refresh, contains('_jobStore.beginOperation('));
      expect(
        refresh.indexOf('_jobStore.beginOperation('),
        lessThan(refresh.indexOf('await _parallel.replaceSource(')),
      );
    });

    test(
      'complete callback is verified before it is published as accepted',
      () {
        final listener = source.indexOf(
          '_sharedEvents.stream.listen((update) {',
        );
        final accepted = source.indexOf(
          '_updatesController.add(update);',
          listener,
        );
        final completionFence = source.indexOf(
          '_handleVerifiedCompleteUpdate(update, trackingUrl)',
          listener,
        );
        expect(completionFence, greaterThan(listener));
        expect(completionFence, lessThan(accepted));

        final helper = source.indexOf(
          'Future<void> _handleVerifiedCompleteUpdate(',
        );
        final statusHandler = source.indexOf(
          'void _handleStatusUpdate(',
          helper,
        );
        expect(helper, greaterThanOrEqualTo(0));
        expect(statusHandler, greaterThan(helper));
        final body = source.substring(helper, statusHandler);
        expect(body, contains('await _persistCompletedFilePath(update.task);'));
        expect(body, contains('job?.state != DownloadJobState.completed'));
        expect(
          body.indexOf('await _persistCompletedFilePath(update.task);'),
          lessThan(body.indexOf('_updatesController.add(update);')),
        );
      },
    );
  });
}
