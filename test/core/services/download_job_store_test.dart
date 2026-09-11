import 'package:animewitcher/core/services/download_job_state.dart';
import 'package:animewitcher/core/services/download_job_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryBackend implements DownloadJobBackend {
  final Map<String, Map<String, dynamic>> values = {};

  @override
  Future<void> delete(String taskId) async {
    values.remove(taskId);
  }

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
  String taskId = 'episode-1',
  String trackingUrl = 'https://example.test/watch/1',
  DownloadJobState state = DownloadJobState.running,
  int generation = 1,
  int durableBytes = 100,
  DownloadDurableByteProvenance durableByteProvenance =
      DownloadDurableByteProvenance.none,
  int expectedBytes = 1000,
  bool userPaused = false,
  bool queueWaiting = false,
  int updatedAtMillis = 1,
  DownloadResourceFingerprint? fingerprint,
}) => DownloadJobRecord(
  taskId: taskId,
  trackingUrl: trackingUrl,
  state: state,
  generation: generation,
  durableBytes: durableBytes,
  durableByteProvenance: durableByteProvenance,
  expectedBytes: expectedBytes,
  userPaused: userPaused,
  queueWaiting: queueWaiting,
  updatedAtMillis: updatedAtMillis,
  fingerprint: fingerprint,
);

void main() {
  test(
    'legacy unknown positive bytes are not authoritative recovery truth',
    () {
      final record = DownloadJobRecord(
        taskId: 'legacy-native',
        trackingUrl: 'https://example.com/episode',
        state: DownloadJobState.interrupted,
        generation: 1,
        durableBytes: 370,
        durableByteProvenance: DownloadDurableByteProvenance.legacyUnknown,
        expectedBytes: 1000,
        userPaused: false,
        queueWaiting: false,
        updatedAtMillis: 1,
      );
      expect(authoritativeDownloadJobBytes(record), -1);
      expect(
        authoritativeDownloadJobBytes(
          record.copyWith(
            durableByteProvenance:
                DownloadDurableByteProvenance.nativeRecoverable,
          ),
        ),
        370,
      );
    },
  );

  group('durable byte provenance codec', () {
    test('v1 positive durable bytes migrate as legacy unknown evidence', () {
      final legacy = _job(durableBytes: 456).toJson()
        ..['schemaVersion'] = 1
        ..remove('durableByteProvenance');

      final decoded = DownloadJobRecord.fromJson(legacy);

      expect(decoded, isNotNull);
      expect(
        decoded!.durableByteProvenance,
        DownloadDurableByteProvenance.legacyUnknown,
      );
    });

    test('current schema exact disk provenance round trips explicitly', () {
      final source = _job(
        durableBytes: 456,
        durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
      );

      final json = source.toJson();
      final decoded = DownloadJobRecord.fromJson(json);

      expect(json['schemaVersion'], kDownloadJobSchemaVersion);
      expect(json['durableByteProvenance'], 'exactDisk');
      expect(
        decoded?.durableByteProvenance,
        DownloadDurableByteProvenance.exactDisk,
      );
    });

    test('v3 exact disk provenance remains readable after schema upgrade', () {
      final legacy =
          _job(
              durableBytes: 456,
              durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
            ).toJson()
            ..['schemaVersion'] = 3
            ..remove('taskSnapshot');

      final decoded = DownloadJobRecord.fromJson(legacy);

      expect(decoded, isNotNull);
      expect(
        decoded!.durableByteProvenance,
        DownloadDurableByteProvenance.exactDisk,
      );
    });

    test('unqualified positive bytes persist as explicit legacy unknown', () {
      final json = _job(durableBytes: 12).toJson();
      expect(json['durableByteProvenance'], 'legacyUnknown');
      expect(
        DownloadJobRecord.fromJson(json)?.durableByteProvenance,
        DownloadDurableByteProvenance.legacyUnknown,
      );
    });
  });

  group('DownloadJobRecord codec', () {
    test('round trips logical state and resource fingerprint', () {
      const fingerprint = DownloadResourceFingerprint(
        strongEtag: '"abc"',
        lastModified: 'Wed, 09 Sep 2026 08:00:00 GMT',
        expectedBytes: 1000,
        finalUrl: 'https://cdn.example.test/file.mp4?token=2',
      );
      final source = _job(
        state: DownloadJobState.pausedByUser,
        generation: 7,
        durableBytes: 456,
        userPaused: true,
        fingerprint: fingerprint,
      );

      final decoded = DownloadJobRecord.fromJson(source.toJson());

      expect(decoded, isNotNull);
      expect(decoded!.taskId, source.taskId);
      expect(decoded.trackingUrl, source.trackingUrl);
      expect(decoded.state, DownloadJobState.pausedByUser);
      expect(decoded.generation, 7);
      expect(decoded.durableBytes, 456);
      expect(decoded.userPaused, isTrue);
      expect(decoded.fingerprint?.strongEtag, '"abc"');
      expect(decoded.fingerprint?.expectedBytes, 1000);
    });

    test('unknown state is conservatively restored as interrupted', () {
      final json = _job().toJson()..['state'] = 'futureNewState';
      final decoded = DownloadJobRecord.fromJson(json);
      expect(decoded?.state, DownloadJobState.interrupted);
    });

    test('invalid identifiers or negative durable bytes are rejected', () {
      final missingId = _job().toJson()..['taskId'] = '';
      final negativeBytes = _job().toJson()..['durableBytes'] = -1;
      expect(DownloadJobRecord.fromJson(missingId), isNull);
      expect(DownloadJobRecord.fromJson(negativeBytes), isNull);
    });
  });

  group('resource fingerprint', () {
    test(
      'shared Last-Modified still rejects changes when one ETag is absent',
      () {
        const old = DownloadResourceFingerprint(
          strongEtag: '"v1"',
          lastModified: 'old',
        );
        const changed = DownloadResourceFingerprint(lastModified: 'new');
        expect(old.compatibleWith(changed), isFalse);
        expect(changed.compatibleWith(old), isFalse);
      },
    );
    test('strong ETag mismatch is incompatible', () {
      const old = DownloadResourceFingerprint(
        strongEtag: '"old"',
        expectedBytes: 100,
      );
      const fresh = DownloadResourceFingerprint(
        strongEtag: '"new"',
        expectedBytes: 100,
      );
      expect(old.compatibleWith(fresh), isFalse);
    });

    test('missing validator is unknown, not automatically incompatible', () {
      const old = DownloadResourceFingerprint(
        strongEtag: '"same"',
        expectedBytes: 100,
      );
      const fresh = DownloadResourceFingerprint(expectedBytes: 100);
      expect(old.compatibleWith(fresh), isTrue);
    });

    test('size mismatch is incompatible even without validators', () {
      const old = DownloadResourceFingerprint(expectedBytes: 100);
      const fresh = DownloadResourceFingerprint(expectedBytes: 101);
      expect(old.compatibleWith(fresh), isFalse);
    });
  });

  group('DownloadJobStore invariants', () {
    late _MemoryBackend backend;
    late DownloadJobStore store;

    setUp(() {
      backend = _MemoryBackend();
      store = DownloadJobStore(backend);
    });

    test('persists and loads one logical job', () async {
      final source = _job();
      expect(await store.put(source), isTrue);
      final loaded = await store.get(source.taskId);
      expect(loaded?.state, DownloadJobState.running);
      expect(loaded?.durableBytes, 100);
    });

    test(
      'status-only checkpoint retains size and fingerprint across recreation',
      () async {
        await store.put(
          _job(
            fingerprint: const DownloadResourceFingerprint(
              strongEtag: '"v1"',
              lastModified: 'date',
              expectedBytes: 1000,
            ),
          ),
        );
        expect(
          await store.put(
            _job(expectedBytes: -1, state: DownloadJobState.interrupted),
          ),
          isTrue,
        );
        store = DownloadJobStore(backend);
        final saved = await store.get('episode-1');
        expect(saved!.expectedBytes, 1000);
        expect(saved.fingerprint!.strongEtag, '"v1"');
        expect(await store.put(_job(expectedBytes: 1100)), isFalse);
        expect(
          await store.put(
            _job(
              fingerprint: const DownloadResourceFingerprint(
                strongEtag: '"v2"',
                expectedBytes: 1000,
              ),
            ),
          ),
          isFalse,
        );
      },
    );

    test(
      'partial fingerprint update cannot erase a stronger validator',
      () async {
        await store.put(
          _job(
            fingerprint: const DownloadResourceFingerprint(
              strongEtag: '"v1"',
              lastModified: 'date',
              expectedBytes: 1000,
            ),
          ),
        );
        final token = await store.beginAttempt('episode-1');
        expect(
          await store.updateForAttempt(
            token!,
            expectedBytes: 0,
            fingerprint: const DownloadResourceFingerprint(
              finalUrl: 'https://cdn.test/new-token',
            ),
          ),
          isTrue,
        );
        final saved = await store.get('episode-1');
        expect(saved!.expectedBytes, 1000);
        expect(saved.fingerprint!.strongEtag, '"v1"');
        expect(saved.fingerprint!.lastModified, 'date');
        expect(saved.fingerprint!.expectedBytes, 1000);
        expect(saved.fingerprint!.finalUrl, 'https://cdn.test/new-token');
      },
    );

    test('rejects a callback from an older generation', () async {
      expect(await store.put(_job(generation: 4, durableBytes: 500)), isTrue);

      final stale = await store.put(
        _job(
          state: DownloadJobState.pausedByUser,
          generation: 3,
          durableBytes: 700,
          userPaused: true,
        ),
      );

      expect(stale, isFalse);
      final loaded = await store.get('episode-1');
      expect(loaded?.generation, 4);
      expect(loaded?.state, DownloadJobState.running);
      expect(loaded?.durableBytes, 500);
    });

    test(
      'authoritative reconciliation may lower bytes and fences stale callbacks',
      () async {
        const fingerprint = DownloadResourceFingerprint(
          strongEtag: '"same"',
          expectedBytes: 1000,
        );
        expect(
          await store.put(
            _job(
              generation: 3,
              durableBytes: 700,
              durableByteProvenance:
                  DownloadDurableByteProvenance.nativeRecoverable,
              fingerprint: fingerprint,
            ),
          ),
          isTrue,
        );

        final reconciled = await store.reconcileDurableBytes(
          const DownloadAttemptToken(taskId: 'episode-1', generation: 3),
          durableBytes: 400,
          evidenceProvenance: DownloadDurableByteProvenance.exactDisk,
          reason: DownloadByteReconciliationReason.exactDiskLoss,
          fingerprint: fingerprint,
          updatedAtMillis: 42,
        );

        expect(reconciled?.generation, 4);
        final saved = await store.get('episode-1');
        expect(saved?.durableBytes, 400);
        expect(
          saved?.durableByteProvenance,
          DownloadDurableByteProvenance.exactDisk,
        );
        expect(
          saved?.lastByteReconciliationReason,
          DownloadByteReconciliationReason.exactDiskLoss,
        );
        expect(
          saved?.lastByteReconciliationProvenance,
          DownloadDurableByteProvenance.exactDisk,
        );
        expect(saved?.lastByteReconciliationAtMillis, 42);
        expect(
          await store.updateForAttempt(
            const DownloadAttemptToken(taskId: 'episode-1', generation: 3),
            durableBytes: 800,
            durableByteProvenance:
                DownloadDurableByteProvenance.nativeRecoverable,
          ),
          isFalse,
        );
        expect((await store.get('episode-1'))?.durableBytes, 400);
      },
    );

    test(
      'authoritative reconciliation can prove zero surviving bytes',
      () async {
        expect(
          await store.put(
            _job(
              generation: 5,
              durableBytes: 700,
              durableByteProvenance:
                  DownloadDurableByteProvenance.nativeRecoverable,
            ),
          ),
          isTrue,
        );
        final token = await store.reconcileDurableBytes(
          const DownloadAttemptToken(taskId: 'episode-1', generation: 5),
          durableBytes: 0,
          evidenceProvenance: DownloadDurableByteProvenance.exactDisk,
          reason: DownloadByteReconciliationReason.noSurvivingBytes,
        );
        expect(token?.generation, 6);
        final saved = await store.get('episode-1');
        expect(saved?.durableBytes, 0);
        expect(
          saved?.durableByteProvenance,
          DownloadDurableByteProvenance.none,
        );
        expect(
          saved?.lastByteReconciliationProvenance,
          DownloadDurableByteProvenance.exactDisk,
        );
        expect(
          saved?.lastByteReconciliationReason,
          DownloadByteReconciliationReason.noSurvivingBytes,
        );
      },
    );

    test(
      'reconciliation rejects weak evidence and incompatible identity',
      () async {
        const original = DownloadResourceFingerprint(
          strongEtag: '"v1"',
          expectedBytes: 1000,
        );
        expect(
          await store.put(
            _job(
              generation: 2,
              durableBytes: 700,
              durableByteProvenance:
                  DownloadDurableByteProvenance.nativeRecoverable,
              fingerprint: original,
            ),
          ),
          isTrue,
        );

        expect(
          await store.reconcileDurableBytes(
            const DownloadAttemptToken(taskId: 'episode-1', generation: 2),
            durableBytes: 400,
            evidenceProvenance: DownloadDurableByteProvenance.legacyUnknown,
            reason: DownloadByteReconciliationReason.exactDiskLoss,
            fingerprint: original,
          ),
          isNull,
        );
        expect(
          await store.reconcileDurableBytes(
            const DownloadAttemptToken(taskId: 'episode-1', generation: 2),
            durableBytes: 400,
            evidenceProvenance: DownloadDurableByteProvenance.exactDisk,
            reason: DownloadByteReconciliationReason.exactDiskLoss,
            fingerprint: const DownloadResourceFingerprint(
              strongEtag: '"v2"',
              expectedBytes: 1000,
            ),
          ),
          isNull,
        );
        final saved = await store.get('episode-1');
        expect(saved?.durableBytes, 700);
        expect(saved?.generation, 2);
      },
    );

    test(
      'ordinary writes remain monotonic after reconciliation API exists',
      () async {
        expect(
          await store.put(
            _job(
              generation: 2,
              durableBytes: 700,
              durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
            ),
          ),
          isTrue,
        );
        expect(
          await store.checkpoint(
            taskId: 'episode-1',
            trackingUrl: 'https://example.test/watch/1',
            state: DownloadJobState.running,
            durableBytes: 400,
            durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
          ),
          isTrue,
        );
        expect((await store.get('episode-1'))?.durableBytes, 700);
      },
    );

    test('durable bytes never go backwards across a newer attempt', () async {
      expect(await store.put(_job(generation: 2, durableBytes: 700)), isTrue);

      final regressed = await store.put(_job(generation: 3, durableBytes: 600));

      expect(regressed, isFalse);
      expect((await store.get('episode-1'))?.durableBytes, 700);
    });

    test('completed is terminal against late running callbacks', () async {
      expect(
        await store.put(
          _job(
            state: DownloadJobState.completed,
            generation: 5,
            durableBytes: 1000,
          ),
        ),
        isTrue,
      );

      expect(
        await store.put(
          _job(
            state: DownloadJobState.running,
            generation: 6,
            durableBytes: 1000,
          ),
        ),
        isFalse,
      );
      expect((await store.get('episode-1'))?.state, DownloadJobState.completed);
    });

    test('expected size cannot silently change under saved bytes', () async {
      expect(
        await store.put(_job(expectedBytes: 1000, durableBytes: 400)),
        isTrue,
      );

      expect(
        await store.put(
          _job(generation: 2, expectedBytes: 1100, durableBytes: 400),
        ),
        isFalse,
      );
      expect((await store.get('episode-1'))?.expectedBytes, 1000);
    });

    test('incompatible fingerprint is rejected', () async {
      expect(
        await store.put(
          _job(
            fingerprint: const DownloadResourceFingerprint(
              strongEtag: '"old"',
              expectedBytes: 1000,
            ),
          ),
        ),
        isTrue,
      );

      expect(
        await store.put(
          _job(
            generation: 2,
            durableBytes: 100,
            fingerprint: const DownloadResourceFingerprint(
              strongEtag: '"new"',
              expectedBytes: 1000,
            ),
          ),
        ),
        isFalse,
      );
    });

    test(
      'delete is the explicit boundary that permits a fresh zero-byte job',
      () async {
        expect(await store.put(_job(generation: 3, durableBytes: 900)), isTrue);
        expect(await store.put(_job(generation: 4, durableBytes: 0)), isFalse);

        await store.remove('episode-1');

        expect(await store.put(_job(generation: 1, durableBytes: 0)), isTrue);
        expect((await store.get('episode-1'))?.durableBytes, 0);
      },
    );

    test('durable attempt token accepts only the current generation', () async {
      expect(await store.put(_job(generation: 8)), isTrue);

      expect(
        await store.accepts(
          const DownloadAttemptToken(taskId: 'episode-1', generation: 8),
        ),
        isTrue,
      );
      expect(
        await store.accepts(
          const DownloadAttemptToken(taskId: 'episode-1', generation: 7),
        ),
        isFalse,
      );
    });

    test(
      'all ignores corrupt entries and sorts by durable update order',
      () async {
        await store.put(_job(taskId: 'b', updatedAtMillis: 20));
        await store.put(_job(taskId: 'a', updatedAtMillis: 10));
        backend.values['broken'] = {'taskId': '', 'trackingUrl': ''};

        final jobs = await store.all();
        expect(jobs.map((job) => job.taskId).toList(), ['a', 'b']);
      },
    );
  });
}
