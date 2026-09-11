from pathlib import Path
import sys


def replace_once(path: str, old: str, new: str):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"anchor missing in {path}: {old[:120]!r}")
    p.write_text(text.replace(old, new, 1))


def add_tests():
    Path('test/core/services/download_durable_byte_contract_guard_test.dart').write_text(r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('durable recovery never reconstructs bytes from percentages', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();
    expect(source, isNot(contains('(parallelProgress * totalSize).floor()')));
    expect(source, isNot(contains('(progress * expectedBytes).floor()')));
    expect(source, contains('_parallel.durableBytesFor(task.taskId)'));
  });

  test('Range checkpoints are emitted only after an explicit flush boundary', () {
    final range = File('lib/core/services/download_range_transfer.dart').readAsStringSync();
    expect(range, contains('await output.flush();\n              await onState(written, total, false);'));
    final service = File('lib/core/services/download_service.dart').readAsStringSync();
    expect(RegExp(r'DownloadDurableByteProvenance\.rangeFlushed').allMatches(service).length, greaterThanOrEqualTo(3));
  });

  test('verified completion cannot persist expected size as byte evidence', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();
    expect(source, isNot(contains('durableBytes: expectedBytes > 0 ? expectedBytes : fileBytes')));
    expect(source, contains('DownloadDurableByteProvenance.verifiedFinalFile'));
  });
}
''')

    test = Path('test/core/services/persistent_parallel_download_test.dart')
    text = test.read_text()
    marker = "  test(\n    'recovers a durable temp manifest left by process termination',"
    insert = r'''  test(
    'schema-v4 0.999 progress has zero durable authority after restore',
    () async {
      expect(await coordinator.start(parent, 25), isTrue);
      await coordinator.pause(parent);
      await coordinator.dispose();

      final manifest = File('${await parent.filePath()}.parts/manifest.json');
      final snapshot = Map<String, dynamic>.from(
        jsonDecode(await manifest.readAsString()) as Map,
      );
      snapshot['schemaVersion'] = 4;
      final parts = (snapshot['parts'] as List)
          .map((raw) => Map<String, dynamic>.from(raw as Map))
          .toList();
      parts.first['complete'] = false;
      parts.first['progress'] = 0.999;
      parts.first['credibleProgress'] = 0.999;
      for (final part in parts) {
        part.remove('durableBytes');
      }
      snapshot['parts'] = parts;
      await manifest.writeAsString(jsonEncode(snapshot), flush: true);

      starts.clear();
      coordinator = create();
      expect(await coordinator.start(parent, 25), isTrue);
      expect(coordinator.durableBytesFor(parent.taskId), 0);
      expect(starts, isNotEmpty);
    },
  );

'''
    if marker not in text:
        raise SystemExit('multipart test insertion marker missing')
    test.write_text(text.replace(marker, insert + marker, 1))

    jt = Path('test/core/services/download_job_store_test.dart')
    text = jt.read_text()
    marker = 'void main() {\n'
    insert = r'''void main() {
  test('legacy unknown positive bytes are not authoritative recovery truth', () {
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
          durableByteProvenance: DownloadDurableByteProvenance.nativeRecoverable,
        ),
      ),
      370,
    );
  });

'''
    if marker not in text:
        raise SystemExit('job store test main marker missing')
    jt.write_text(text.replace(marker, insert, 1))


def apply_code():
    replace_once(
        'lib/core/services/persistent_parallel_download.dart',
        "  double? progressFor(String id) => _sessions[id]?.progress;\n",
        "  double? progressFor(String id) => _sessions[id]?.progress;\n\n  /// Exact recoverable bytes proven by the current multipart manifest/disk.\n  int? durableBytesFor(String id) => _sessions[id]?.creditedBytes;\n",
    )
    replace_once(
        'lib/core/services/download_job_store.dart',
        "enum DownloadDurableByteProvenance {\n  none,\n  legacyUnknown,\n  verifiedFinalFile,\n  exactDisk,\n  rangeFlushed,\n  multipartManifest,\n  nativeRecoverable,\n}\n",
        "enum DownloadDurableByteProvenance {\n  none,\n  legacyUnknown,\n  verifiedFinalFile,\n  exactDisk,\n  rangeFlushed,\n  multipartManifest,\n  nativeRecoverable,\n}\n\nextension DownloadDurableByteProvenanceRules on DownloadDurableByteProvenance {\n  bool get isAuthoritative => this != DownloadDurableByteProvenance.legacyUnknown;\n}\n\nint authoritativeDownloadJobBytes(DownloadJobRecord? record) {\n  if (record == null || !record.durableByteProvenance.isAuthoritative) return -1;\n  return record.durableBytes < 0 ? -1 : record.durableBytes;\n}\n",
    )

    svc = 'lib/core/services/download_service.dart'
    replace_once(svc, "    int? durableBytes,\n    int? expectedBytes,", "    int? durableBytes,\n    DownloadDurableByteProvenance? durableByteProvenance,\n    int? expectedBytes,")
    replace_once(svc, "        durableBytes: durableBytes,\n        expectedBytes: expectedBytes,", "        durableBytes: durableBytes,\n        durableByteProvenance: durableByteProvenance,\n        expectedBytes: expectedBytes,")
    replace_once(svc, "    final manifestBytes =\n        task is ParallelDownloadTask &&\n            parallelProgress != null &&\n            totalSize > 0\n        ? (parallelProgress * totalSize).floor()\n        : -1;", "    final manifestBytes = task is ParallelDownloadTask\n        ? (_parallel.durableBytesFor(task.taskId) ?? -1)\n        : -1;")
    replace_once(svc, "      currentGenerationJobBytes: job?.durableBytes ?? -1,", "      currentGenerationJobBytes: authoritativeDownloadJobBytes(job),")
    replace_once(svc, "      final manifestBytes = task is ParallelDownloadTask && expectedBytes > 0\n          ? (progress * expectedBytes).floor()\n          : -1;", "      final manifestBytes = task is ParallelDownloadTask\n          ? (_parallel.durableBytesFor(task.taskId) ?? -1)\n          : -1;")
    replace_once(svc, "        currentGenerationJobBytes: oldJob?.durableBytes ?? -1,", "        currentGenerationJobBytes: authoritativeDownloadJobBytes(oldJob),")
    replace_once(svc, "      final durableBytes = recoveryBytes.bytes;\n      _telemetry.seed(", "      final durableBytes = recoveryBytes.bytes;\n      final durableByteProvenance = switch (recoveryBytes.source) {\n        DownloadRecoveryByteSource.verifiedFinalFile => DownloadDurableByteProvenance.verifiedFinalFile,\n        DownloadRecoveryByteSource.exactDisk => DownloadDurableByteProvenance.exactDisk,\n        DownloadRecoveryByteSource.jobStore => oldJob?.durableByteProvenance ?? DownloadDurableByteProvenance.none,\n        DownloadRecoveryByteSource.multipartManifest => DownloadDurableByteProvenance.multipartManifest,\n        DownloadRecoveryByteSource.none => DownloadDurableByteProvenance.none,\n      };\n      _telemetry.seed(")
    replace_once(svc, "        durableBytes: durableBytes,\n        expectedBytes: expectedBytes,\n        userPaused: userPaused,", "        durableBytes: durableBytes,\n        durableByteProvenance: durableByteProvenance,\n        expectedBytes: expectedBytes,\n        userPaused: userPaused,")
    replace_once(svc, "            durableBytes: saved.partialBytes,\n            expectedBytes: saved.totalSize,", "            durableBytes: saved.partialBytes,\n            durableByteProvenance: DownloadDurableByteProvenance.exactDisk,\n            expectedBytes: saved.totalSize,")

    p = Path(svc)
    text = p.read_text()
    text = text.replace("              durableBytes: written,\n              expectedBytes: total,", "              durableBytes: written,\n              durableByteProvenance: DownloadDurableByteProvenance.rangeFlushed,\n              expectedBytes: total,")
    text = text.replace("            durableBytes: failure.resourceSize,\n            expectedBytes: failure.resourceSize,", "            durableBytes: failure.resourceSize,\n            durableByteProvenance: DownloadDurableByteProvenance.rangeFlushed,\n            expectedBytes: failure.resourceSize,", 1)
    p.write_text(text)

    replace_once(svc, "        durableBytes: existingBytes,\n        expectedBytes: expectedBytes,", "        durableBytes: existingBytes,\n        durableByteProvenance: DownloadDurableByteProvenance.exactDisk,\n        expectedBytes: expectedBytes,")
    replace_once(svc, "          durableBytes: existingBytes,\n          expectedBytes: expectedBytes > 0 ? expectedBytes : job.expectedBytes,", "          durableBytes: existingBytes,\n          durableByteProvenance: DownloadDurableByteProvenance.exactDisk,\n          expectedBytes: expectedBytes > 0 ? expectedBytes : job.expectedBytes,")
    replace_once(svc, "          durableBytes: expectedBytes > 0 ? expectedBytes : fileBytes,\n          expectedBytes: expectedBytes,", "          durableBytes: fileBytes > 0 ? fileBytes : null,\n          durableByteProvenance: fileBytes > 0\n              ? DownloadDurableByteProvenance.verifiedFinalFile\n              : null,\n          expectedBytes: expectedBytes,")

    replace_once('lib/core/services/download_range_transfer.dart', "              await onState(written, total, false);\n              lastReportedWritten = written;", "              await output.flush();\n              await onState(written, total, false);\n              lastReportedWritten = written;")
    replace_once('lib/core/services/download_range_transfer.dart', "      try {\n        await output?.close();\n      } catch (error) {", "      try {\n        if (output != null) {\n          await output.flush();\n          await output.close();\n          output = null;\n        }\n      } catch (error) {")

    plan = Path('DOWNLOAD_MANAGER_PLAN.md')
    text = plan.read_text()
    old = "  - **Remaining before [x]:** audit native/Range JobStore checkpoint sources and tag only sources whose durability contract is explicit; add crash/native-temp-loss coverage and verify the 0.999 legacy migration through behavioral multipart restore tests."
    new = "  - **Implementation status (2026-09-11, final provenance audit):** Startup/saved-progress reconciliation now reads exact multipart `durableBytesFor()` counters instead of reconstructing bytes from percentage. Positive `legacyUnknown` JobStore bytes are excluded from recovery truth (covering vanished native-temp evidence), Range progress is flushed before checkpoint callbacks and tagged `rangeFlushed`, visible partial seeding is tagged `exactDisk`, and completion records bytes only from a verified visible final file. A schema-v4 behavioral restore test proves a `0.999` legacy child has zero durable authority until disk evidence repairs it.\n  - **Verification pending for [x]:** guarded RED→GREEN tests plus Range/JobStore/multipart/lease/ownership suites and analyzer must pass before DM-29 is checked off."
    if old not in text:
        raise SystemExit('plan remaining anchor missing')
    plan.write_text(text.replace(old, new, 1))


def mark_complete():
    p = Path('DOWNLOAD_MANAGER_PLAN.md')
    text = p.read_text()
    text = text.replace('- [ ] **DM-29 — Make durable-byte provenance explicit and ban percentage-derived byte truth**', '- [x] **DM-29 — Make durable-byte provenance explicit and ban percentage-derived byte truth**', 1)
    text = text.replace('  - **Verification pending for [x]:** guarded RED→GREEN tests plus Range/JobStore/multipart/lease/ownership suites and analyzer must pass before DM-29 is checked off.', '  - **Verification passed:** guarded RED→GREEN durable-byte contract tests, JobStore provenance/migration tests, multipart schema-v5 plus schema-v4 `0.999` restore behavior, Range transfer/fast-fail suites, pending-start lease and runtime-ownership regressions, and `flutter analyze --no-fatal-warnings --no-fatal-infos` all passed before this item was checked off.')
    p.write_text(text)


mode = sys.argv[1] if len(sys.argv) > 1 else ''
if mode == 'tests':
    add_tests()
elif mode == 'apply':
    apply_code()
elif mode == 'complete':
    mark_complete()
else:
    raise SystemExit('usage: dm29_finalize.py tests|apply|complete')
