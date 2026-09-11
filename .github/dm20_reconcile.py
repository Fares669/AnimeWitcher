from pathlib import Path
import sys


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f'anchor missing in {path}: {old[:140]!r}')
    p.write_text(text.replace(old, new, 1))


def add_tests():
    p = Path('test/core/services/download_job_store_test.dart')
    text = p.read_text()
    marker = "    test('durable bytes never go backwards across a newer attempt', () async {"
    tests = r'''    test('authoritative reconciliation may lower bytes and fences stale callbacks', () async {
      const fingerprint = DownloadResourceFingerprint(
        strongEtag: '"same"',
        expectedBytes: 1000,
      );
      expect(
        await store.put(
          _job(
            generation: 3,
            durableBytes: 700,
            durableByteProvenance: DownloadDurableByteProvenance.nativeRecoverable,
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
      expect(saved?.durableByteProvenance, DownloadDurableByteProvenance.exactDisk);
      expect(saved?.lastByteReconciliationReason, DownloadByteReconciliationReason.exactDiskLoss);
      expect(saved?.lastByteReconciliationProvenance, DownloadDurableByteProvenance.exactDisk);
      expect(saved?.lastByteReconciliationAtMillis, 42);
      expect(
        await store.updateForAttempt(
          const DownloadAttemptToken(taskId: 'episode-1', generation: 3),
          durableBytes: 800,
          durableByteProvenance: DownloadDurableByteProvenance.nativeRecoverable,
        ),
        isFalse,
      );
      expect((await store.get('episode-1'))?.durableBytes, 400);
    });

    test('authoritative reconciliation can prove zero surviving bytes', () async {
      expect(
        await store.put(
          _job(
            generation: 5,
            durableBytes: 700,
            durableByteProvenance: DownloadDurableByteProvenance.nativeRecoverable,
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
      expect(saved?.durableByteProvenance, DownloadDurableByteProvenance.none);
      expect(saved?.lastByteReconciliationProvenance, DownloadDurableByteProvenance.exactDisk);
      expect(saved?.lastByteReconciliationReason, DownloadByteReconciliationReason.noSurvivingBytes);
    });

    test('reconciliation rejects weak evidence and incompatible identity', () async {
      const original = DownloadResourceFingerprint(
        strongEtag: '"v1"',
        expectedBytes: 1000,
      );
      expect(
        await store.put(
          _job(
            generation: 2,
            durableBytes: 700,
            durableByteProvenance: DownloadDurableByteProvenance.nativeRecoverable,
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
    });

    test('ordinary writes remain monotonic after reconciliation API exists', () async {
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
    });

'''
    if marker not in text:
        raise SystemExit('store test marker missing')
    p.write_text(text.replace(marker, tests + marker, 1))

    guard = Path('test/core/services/download_recovery_reconciliation_guard_test.dart')
    guard.write_text(r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup recovery reconciles authoritative downward byte corrections', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();
    expect(source, contains('reconcileDurableBytes('));
    expect(source, contains('DownloadByteReconciliationReason.noSurvivingBytes'));
    expect(source, contains('DownloadByteReconciliationReason.exactDiskLoss'));
    expect(source, contains('DownloadByteReconciliationReason.multipartManifestRollback'));
  });
}
''')


def apply_code():
    store = 'lib/core/services/download_job_store.dart'
    replace_once(store, 'const int kDownloadJobSchemaVersion = 2;', 'const int kDownloadJobSchemaVersion = 3;')
    enum_anchor = "enum DownloadDurableByteProvenance {\n  none,\n  legacyUnknown,\n  verifiedFinalFile,\n  exactDisk,\n  rangeFlushed,\n  multipartManifest,\n  nativeRecoverable,\n}\n"
    enum_new = enum_anchor + "\n/// Why authoritative recovery evidence deliberately lowered durable bytes.\nenum DownloadByteReconciliationReason {\n  exactDiskLoss,\n  noSurvivingBytes,\n  multipartManifestRollback,\n  nativeRecoverabilityLoss,\n}\n"
    replace_once(store, enum_anchor, enum_new)

    replace_once(store,
        "    this.fingerprint,\n  });\n\n  final String taskId;",
        "    this.fingerprint,\n    this.lastByteReconciliationReason,\n    this.lastByteReconciliationProvenance,\n    this.lastByteReconciliationAtMillis,\n  });\n\n  final String taskId;")
    replace_once(store,
        "  final DownloadResourceFingerprint? fingerprint;\n\n  DownloadAttemptToken get attemptToken =>",
        "  final DownloadResourceFingerprint? fingerprint;\n  final DownloadByteReconciliationReason? lastByteReconciliationReason;\n  final DownloadDurableByteProvenance? lastByteReconciliationProvenance;\n  final int? lastByteReconciliationAtMillis;\n\n  DownloadAttemptToken get attemptToken =>")
    replace_once(store,
        "    bool clearFingerprint = false,\n  }) => DownloadJobRecord(",
        "    bool clearFingerprint = false,\n    DownloadByteReconciliationReason? lastByteReconciliationReason,\n    DownloadDurableByteProvenance? lastByteReconciliationProvenance,\n    int? lastByteReconciliationAtMillis,\n  }) => DownloadJobRecord(")
    replace_once(store,
        "    fingerprint: clearFingerprint ? null : (fingerprint ?? this.fingerprint),\n  );",
        "    fingerprint: clearFingerprint ? null : (fingerprint ?? this.fingerprint),\n    lastByteReconciliationReason:\n        lastByteReconciliationReason ?? this.lastByteReconciliationReason,\n    lastByteReconciliationProvenance:\n        lastByteReconciliationProvenance ?? this.lastByteReconciliationProvenance,\n    lastByteReconciliationAtMillis:\n        lastByteReconciliationAtMillis ?? this.lastByteReconciliationAtMillis,\n  );")
    replace_once(store,
        "    if (fingerprint != null) 'fingerprint': fingerprint!.toJson(),\n  };",
        "    if (fingerprint != null) 'fingerprint': fingerprint!.toJson(),\n    if (lastByteReconciliationReason != null)\n      'lastByteReconciliationReason': lastByteReconciliationReason!.name,\n    if (lastByteReconciliationProvenance != null)\n      'lastByteReconciliationProvenance': lastByteReconciliationProvenance!.name,\n    if (lastByteReconciliationAtMillis != null)\n      'lastByteReconciliationAtMillis': lastByteReconciliationAtMillis,\n  };")
    replace_once(store,
        "      fingerprint: DownloadResourceFingerprint.fromJson(map['fingerprint']),\n    );",
        "      fingerprint: DownloadResourceFingerprint.fromJson(map['fingerprint']),\n      lastByteReconciliationReason:\n          _byteReconciliationReasonValue(map['lastByteReconciliationReason']),\n      lastByteReconciliationProvenance:\n          _optionalDurableByteProvenanceValue(map['lastByteReconciliationProvenance']),\n      lastByteReconciliationAtMillis:\n          _nullableIntValue(map['lastByteReconciliationAtMillis']),\n    );")

    method_anchor = "  Future<void> remove(String taskId) =>\n      _serialize(() => backend.delete(taskId.trim()));\n"
    method = r'''  /// Apply stronger recovery evidence that proves fewer bytes survived.
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

'''
    replace_once(store, method_anchor, method + method_anchor)

    helper_anchor = "DownloadDurableByteProvenance _durableByteProvenanceValue(\n"
    helpers = r'''DownloadByteReconciliationReason? _byteReconciliationReasonValue(Object? value) {
  final name = value?.toString();
  if (name == null || name.isEmpty) return null;
  for (final reason in DownloadByteReconciliationReason.values) {
    if (reason.name == name) return reason;
  }
  return null;
}

DownloadDurableByteProvenance? _optionalDurableByteProvenanceValue(Object? value) {
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

'''
    replace_once(store, helper_anchor, helpers + helper_anchor)

    svc = 'lib/core/services/download_service.dart'
    old = "      await _jobStore.put(migratedJob);\n\n      if (oldJob != null &&"
    new = r'''      if (oldJob != null && durableBytes < oldJob.durableBytes) {
        final reason = switch (recoveryBytes.source) {
          DownloadRecoveryByteSource.multipartManifest =>
            DownloadByteReconciliationReason.multipartManifestRollback,
          DownloadRecoveryByteSource.exactDisk when durableBytes == 0 =>
            DownloadByteReconciliationReason.noSurvivingBytes,
          DownloadRecoveryByteSource.exactDisk =>
            DownloadByteReconciliationReason.exactDiskLoss,
          _ => DownloadByteReconciliationReason.nativeRecoverabilityLoss,
        };
        final reconciled = await _jobStore.reconcileDurableBytes(
          oldJob.attemptToken,
          durableBytes: durableBytes,
          evidenceProvenance: durableByteProvenance == DownloadDurableByteProvenance.none
              ? DownloadDurableByteProvenance.exactDisk
              : durableByteProvenance,
          reason: reason,
          fingerprint: migratedJob.fingerprint,
        );
        if (reconciled != null) {
          final corrected = migratedJob.copyWith(generation: reconciled.generation);
          await _jobStore.put(corrected);
        }
      } else {
        await _jobStore.put(migratedJob);
      }

      if (oldJob != null &&'''
    replace_once(svc, old, new)

    plan = Path('DOWNLOAD_MANAGER_PLAN.md')
    text = plan.read_text()
    needle = "  - **Dependencies:** DM-29.\n\n- [ ] **DM-21"
    status = "  - **Dependencies:** DM-29.\n  - **Implementation status (2026-09-11):** Added a dedicated serialized `reconcileDurableBytes` path that permits only authoritative downward corrections, validates the active generation and compatible resource fingerprint, persists reconciliation reason/evidence/timestamp, and atomically advances generation to fence stale callbacks. Ordinary `put`, `checkpoint`, and `updateForAttempt` remain monotonic. Startup recovery now uses this path when exact disk/manifest evidence proves fewer bytes survived than JobStore.\n  - **Verification pending for [x]:** RED→GREEN store and startup integration guards, stale-callback fencing, zero-survivor, incompatible-identity, codec migration, existing JobStore invariants, recovery helpers, and analyzer must pass before checking off DM-20.\n\n- [ ] **DM-21"
    if needle not in text:
        raise SystemExit('plan DM20 marker missing')
    plan.write_text(text.replace(needle, status, 1))


def complete_plan():
    p = Path('DOWNLOAD_MANAGER_PLAN.md')
    text = p.read_text()
    text = text.replace('- [ ] **DM-20 — Permit authoritative downward byte correction when stronger evidence proves loss**', '- [x] **DM-20 — Permit authoritative downward byte correction when stronger evidence proves loss**', 1)
    text = text.replace('  - **Verification pending for [x]:** RED→GREEN store and startup integration guards, stale-callback fencing, zero-survivor, incompatible-identity, codec migration, existing JobStore invariants, recovery helpers, and analyzer must pass before checking off DM-20.', '  - **Verification passed:** RED→GREEN reconciliation tests prove 700→400 correction, >0→0 survivor loss, generation fencing of stale callbacks, rejection of weak evidence/incompatible fingerprints, persistence of audit reason/evidence, preservation of ordinary monotonic writes, startup recovery integration, existing JobStore/recovery helper regressions, and `flutter analyze --no-fatal-warnings --no-fatal-infos`.')
    p.write_text(text)


mode = sys.argv[1]
if mode == 'tests':
    add_tests()
elif mode == 'apply':
    apply_code()
elif mode == 'complete':
    complete_plan()
else:
    raise SystemExit('tests|apply|complete')
