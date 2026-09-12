import 'dart:io';

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
  DownloadJobState state = DownloadJobState.running,
  int generation = 3,
  int updatedAtMillis = 1,
}) => DownloadJobRecord(
  taskId: 'episode-delete',
  logicalId: 'provider|anime|episode-7',
  trackingUrl: 'https://example.test/watch/7',
  state: state,
  generation: generation,
  durableBytes: 512,
  durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
  expectedBytes: 1024,
  userPaused: false,
  queueWaiting: false,
  updatedAtMillis: updatedAtMillis,
  fingerprint: const DownloadResourceFingerprint(
    strongEtag: '"episode-7"',
    expectedBytes: 1024,
  ),
);

String _methodBody(String source, String startSignature, String endSignature) {
  final start = source.indexOf(startSignature);
  final end = source.indexOf(endSignature, start + startSignature.length);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSignature');
  expect(end, greaterThan(start), reason: 'missing boundary $endSignature');
  return source.substring(start, end);
}

void main() {
  group('DM-07 durable delete tombstone', () {
    test(
      'explicit deletion can tombstone completed and fences late reopen',
      () async {
        final store = DownloadJobStore(_MemoryBackend());
        expect(
          await store.put(
            _job(state: DownloadJobState.completed, generation: 7),
          ),
          isTrue,
        );

        final token = await store.tombstoneForDeletion(
          _job(state: DownloadJobState.completed, generation: 7),
          updatedAtMillis: 20,
        );

        expect(token, isNotNull);
        expect(token!.generation, 8);
        final saved = await store.get('episode-delete');
        expect(saved?.state, DownloadJobState.canceled);
        expect(saved?.generation, 8);
        expect(saved?.durableBytes, 512);
        expect(saved?.fingerprint?.strongEtag, '"episode-7"');
        expect(
          await store.put(_job(state: DownloadJobState.running, generation: 9)),
          isFalse,
          reason: 'late callbacks may not resurrect a deletion tombstone',
        );
      },
    );

    test(
      'repeated deletion is idempotent and keeps the same generation',
      () async {
        final store = DownloadJobStore(_MemoryBackend());
        await store.put(_job(generation: 2));
        final first = await store.tombstoneForDeletion(
          _job(generation: 2),
          updatedAtMillis: 10,
        );
        final second = await store.tombstoneForDeletion(
          _job(generation: 2),
          updatedAtMillis: 11,
        );

        expect(first, isNotNull);
        expect(second, isNotNull);
        expect(second!.generation, first!.generation);
        expect(
          (await store.get('episode-delete'))?.state,
          DownloadJobState.canceled,
        );
      },
    );

    test(
      'a missing execution row can still receive a durable delete tombstone',
      () async {
        final store = DownloadJobStore(_MemoryBackend());
        final token = await store.tombstoneForDeletion(
          _job(generation: 0),
          updatedAtMillis: 30,
        );

        expect(token?.generation, 1);
        final saved = await store.get('episode-delete');
        expect(saved?.state, DownloadJobState.canceled);
        expect(saved?.logicalId, 'provider|anime|episode-7');
      },
    );

    test('tombstone GC requires age plus independently settled ownership and projections', () {
      const retention = kDownloadCanceledTombstoneRetention;
      final now = retention.inMilliseconds + 1000;
      final oldCanceled = _job(
        state: DownloadJobState.canceled,
        updatedAtMillis: 1,
      );

      expect(
        downloadCanceledTombstoneEligibleForGc(
          oldCanceled,
          nowMillis: now,
          ownershipReleased: true,
          pluginRecordAbsent: true,
          metadataAbsent: true,
        ),
        isTrue,
      );
      expect(
        downloadCanceledTombstoneEligibleForGc(
          oldCanceled,
          nowMillis: now,
          ownershipReleased: false,
          pluginRecordAbsent: true,
          metadataAbsent: true,
        ),
        isFalse,
      );
      expect(
        downloadCanceledTombstoneEligibleForGc(
          _job(state: DownloadJobState.running, updatedAtMillis: 1),
          nowMillis: now,
          ownershipReleased: true,
          pluginRecordAbsent: true,
          metadataAbsent: true,
        ),
        isFalse,
      );
    });
  });

  group('DM-07 service/UI ownership', () {
    final service = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final provider = File(
      'lib/features/library/presentation/downloads_provider.dart',
    ).readAsStringSync();

    test(
      'cancel persists tombstone and never removes it during ordinary cleanup',
      () {
        final body = _methodBody(
          service,
          'Future<void> cancelDownload(',
          'Future<DownloadCommandOutcome> cancelDownloadOutcome(',
        );
        expect(body, contains('tombstoneForDeletion('));
        expect(body, isNot(contains('_jobStore.remove(taskId)')));
        final settled = body.indexOf('_waitForCancelOwnershipRelease(taskId)');
        final pluginDelete = body.indexOf(
          'FileDownloader().database.deleteRecordWithId(taskId)',
        );
        expect(settled, greaterThanOrEqualTo(0));
        expect(pluginDelete, greaterThan(settled));
        expect(
          body.substring(settled, pluginDelete),
          contains('DownloadRuntimeOwnership.notOwned'),
        );
      },
    );

    test(
      'delete transaction is service-owned and UI has no lifecycle destruction',
      () {
        expect(
          service,
          contains('Future<DownloadCommandOutcome> deleteDownloadOutcome('),
        );
        final removeBody = _methodBody(
          provider,
          'Future<void> removeDownloads(List<DownloadItem> items) async {',
          'void _setOptimisticStatus(',
        );
        expect(removeBody, contains('.deleteDownloadOutcome('));
        expect(
          removeBody,
          isNot(contains('FileDownloader().database.deleteRecordWithId')),
        );
        expect(removeBody, isNot(contains('removeDownloadMetadata(')));
        expect(removeBody, isNot(contains('.deleteDownloadedFile(')));
        expect(removeBody, isNot(contains('file.delete(recursive: true)')));
      },
    );
  });
}
