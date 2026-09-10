from pathlib import Path

store_path = Path('lib/core/services/download_job_store.dart')
test_path = Path('test/core/services/download_job_store_test.dart')
plan_path = Path('DOWNLOAD_MANAGER_PLAN.md')

store = store_path.read_text()
test = test_path.read_text()
plan = plan_path.read_text()

# RED test first: require explicit persisted provenance and v1 migration behavior.
anchor = "  group('DownloadJobRecord codec', () {\n"
if anchor not in test:
    raise SystemExit('codec test anchor missing')
red_tests = r'''  group('durable byte provenance codec', () {
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

    test('v2 exact disk provenance round trips explicitly', () {
      final source = _job(
        durableBytes: 456,
        durableByteProvenance: DownloadDurableByteProvenance.exactDisk,
      );

      final json = source.toJson();
      final decoded = DownloadJobRecord.fromJson(json);

      expect(json['schemaVersion'], 2);
      expect(json['durableByteProvenance'], 'exactDisk');
      expect(
        decoded?.durableByteProvenance,
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

'''
if 'v1 positive durable bytes migrate as legacy unknown evidence' not in test:
    test = test.replace(anchor, red_tests + anchor, 1)

# Extend test helper API so tests compile once production API lands. During RED,
# the missing production type/parameter is the expected failure.
helper_old = """  int durableBytes = 100,\n  int expectedBytes = 1000,\n"""
helper_new = """  int durableBytes = 100,\n  DownloadDurableByteProvenance durableByteProvenance =\n      DownloadDurableByteProvenance.none,\n  int expectedBytes = 1000,\n"""
if helper_old not in test and helper_new not in test:
    raise SystemExit('test helper params anchor missing')
if helper_old in test:
    test = test.replace(helper_old, helper_new, 1)
ctor_old = """  durableBytes: durableBytes,\n  expectedBytes: expectedBytes,\n"""
ctor_new = """  durableBytes: durableBytes,\n  durableByteProvenance: durableByteProvenance,\n  expectedBytes: expectedBytes,\n"""
if ctor_old not in test and ctor_new not in test:
    raise SystemExit('test helper ctor anchor missing')
if ctor_old in test:
    test = test.replace(ctor_old, ctor_new, 1)

test_path.write_text(test)

# Production patch.
if 'enum DownloadDurableByteProvenance' not in store:
    store = store.replace(
        "const int kDownloadJobSchemaVersion = 1;\n",
        """const int kDownloadJobSchemaVersion = 2;\n\n/// Provenance for [DownloadJobRecord.durableBytes].\n///\n/// Percentage/progress estimates are intentionally absent. `legacyUnknown` is\n/// the migration/fail-safe bucket for positive byte counts that predate this\n/// schema or arrive without a durability contract.\nenum DownloadDurableByteProvenance {\n  none,\n  legacyUnknown,\n  verifiedFinalFile,\n  exactDisk,\n  rangeFlushed,\n  multipartManifest,\n  nativeRecoverable,\n}\n\n""",
        1,
    )

ctor_anchor = """    required this.durableBytes,\n    required this.expectedBytes,\n"""
if ctor_anchor in store:
    store = store.replace(
        ctor_anchor,
        """    required this.durableBytes,\n    this.durableByteProvenance = DownloadDurableByteProvenance.none,\n    required this.expectedBytes,\n""",
        1,
    )
field_anchor = """  final int durableBytes;\n  final int expectedBytes;\n"""
if field_anchor in store:
    store = store.replace(
        field_anchor,
        """  final int durableBytes;\n  final DownloadDurableByteProvenance durableByteProvenance;\n  final int expectedBytes;\n""",
        1,
    )
copy_param_anchor = """    int? durableBytes,\n    int? expectedBytes,\n"""
if copy_param_anchor in store:
    store = store.replace(
        copy_param_anchor,
        """    int? durableBytes,\n    DownloadDurableByteProvenance? durableByteProvenance,\n    int? expectedBytes,\n""",
        1,
    )
copy_ctor_anchor = """    durableBytes: durableBytes ?? this.durableBytes,\n    expectedBytes: expectedBytes ?? this.expectedBytes,\n"""
if copy_ctor_anchor in store:
    store = store.replace(
        copy_ctor_anchor,
        """    durableBytes: durableBytes ?? this.durableBytes,\n    durableByteProvenance:\n        durableByteProvenance ?? this.durableByteProvenance,\n    expectedBytes: expectedBytes ?? this.expectedBytes,\n""",
        1,
    )
json_anchor = """    'durableBytes': durableBytes,\n    'expectedBytes': expectedBytes,\n"""
if json_anchor in store:
    store = store.replace(
        json_anchor,
        """    'durableBytes': durableBytes,\n    'durableByteProvenance': _normalizedDurableByteProvenance(\n      durableBytes,\n      durableByteProvenance,\n    ).name,\n    'expectedBytes': expectedBytes,\n""",
        1,
    )

fromjson_anchor = """    final generation = _intValue(map['generation']);\n    final durableBytes = _intValue(map['durableBytes']);\n    if (generation < 0 || durableBytes < 0) return null;\n\n    return DownloadJobRecord(\n"""
if fromjson_anchor in store:
    store = store.replace(
        fromjson_anchor,
        """    final generation = _intValue(map['generation']);\n    final durableBytes = _intValue(map['durableBytes']);\n    if (generation < 0 || durableBytes < 0) return null;\n    final schemaVersion = _intValue(map['schemaVersion'], fallback: 1);\n    final durableByteProvenance = _durableByteProvenanceValue(\n      map['durableByteProvenance'],\n      durableBytes: durableBytes,\n      schemaVersion: schemaVersion,\n    );\n\n    return DownloadJobRecord(\n""",
        1,
    )
record_ctor_anchor = """      durableBytes: durableBytes,\n      expectedBytes: _intValue(map['expectedBytes'], fallback: -1),\n"""
if record_ctor_anchor in store:
    store = store.replace(
        record_ctor_anchor,
        """      durableBytes: durableBytes,\n      durableByteProvenance: durableByteProvenance,\n      expectedBytes: _intValue(map['expectedBytes'], fallback: -1),\n""",
        1,
    )

# Normalize every persisted record so positive unqualified bytes become an
# explicit low-confidence provenance rather than silently inheriting `none`.
durable_copy_anchor = """    final durable = next.copyWith(\n      expectedBytes: next.expectedBytes > 0\n"""
if durable_copy_anchor in store:
    store = store.replace(
        durable_copy_anchor,
        """    final durable = next.copyWith(\n      durableByteProvenance: _normalizedDurableByteProvenance(\n        next.durableBytes,\n        next.durableByteProvenance,\n      ),\n      expectedBytes: next.expectedBytes > 0\n""",
        1,
    )

# checkpoint() accepts explicit provenance. A changed byte count without one is
# downgraded to legacyUnknown instead of inheriting stronger old evidence.
checkpoint_param = """    int? durableBytes,\n    int? expectedBytes,\n    bool? userPaused,\n"""
if checkpoint_param in store:
    store = store.replace(
        checkpoint_param,
        """    int? durableBytes,\n    DownloadDurableByteProvenance? durableByteProvenance,\n    int? expectedBytes,\n    bool? userPaused,\n""",
        1,
    )
kept_anchor = """    final keptBytes = current != null && current.durableBytes > incomingBytes\n        ? current.durableBytes\n        : incomingBytes;\n    final incomingExpected = expectedBytes ?? -1;\n"""
if kept_anchor in store:
    store = store.replace(
        kept_anchor,
        """    final keptBytes = current != null && current.durableBytes > incomingBytes\n        ? current.durableBytes\n        : incomingBytes;\n    final keptProvenance = _checkpointProvenance(\n      current: current,\n      suppliedBytes: durableBytes,\n      keptBytes: keptBytes,\n      suppliedProvenance: durableByteProvenance,\n    );\n    final incomingExpected = expectedBytes ?? -1;\n""",
        1,
    )
new_record_anchor = """            durableBytes: keptBytes,\n            expectedBytes: keptExpected,\n"""
if new_record_anchor in store:
    store = store.replace(
        new_record_anchor,
        """            durableBytes: keptBytes,\n            durableByteProvenance: keptProvenance,\n            expectedBytes: keptExpected,\n""",
        1,
    )
existing_copy_anchor = """            state: state,\n            durableBytes: keptBytes,\n            expectedBytes: keptExpected,\n"""
if existing_copy_anchor in store:
    store = store.replace(
        existing_copy_anchor,
        """            state: state,\n            durableBytes: keptBytes,\n            durableByteProvenance: keptProvenance,\n            expectedBytes: keptExpected,\n""",
        1,
    )

# updateForAttempt() gets the same explicit provenance API and safety behavior.
update_sig = """    DownloadJobState? state,\n    int? durableBytes,\n    int? expectedBytes,\n"""
if update_sig in store:
    store = store.replace(
        update_sig,
        """    DownloadJobState? state,\n    int? durableBytes,\n    DownloadDurableByteProvenance? durableByteProvenance,\n    int? expectedBytes,\n""",
        1,
    )
update_body = """    if (current == null || current.generation != token.generation) return false;\n    return _putUnlocked(\n      current.copyWith(\n        state: state,\n        durableBytes: durableBytes,\n        expectedBytes: expectedBytes,\n"""
if update_body in store:
    store = store.replace(
        update_body,
        """    if (current == null || current.generation != token.generation) return false;\n    final nextBytes = durableBytes ?? current.durableBytes;\n    final nextProvenance = durableBytes == null\n        ? (durableByteProvenance ?? current.durableByteProvenance)\n        : _normalizedDurableByteProvenance(\n            nextBytes,\n            durableByteProvenance ??\n                (nextBytes == current.durableBytes\n                    ? current.durableByteProvenance\n                    : DownloadDurableByteProvenance.legacyUnknown),\n          );\n    return _putUnlocked(\n      current.copyWith(\n        state: state,\n        durableBytes: durableBytes,\n        durableByteProvenance: nextProvenance,\n        expectedBytes: expectedBytes,\n""",
        1,
    )

helpers_anchor = """String? _nonEmptyString(Object? value) {\n"""
helpers = r'''DownloadDurableByteProvenance _normalizedDurableByteProvenance(
  int durableBytes,
  DownloadDurableByteProvenance provenance,
) {
  if (durableBytes <= 0) return DownloadDurableByteProvenance.none;
  return provenance == DownloadDurableByteProvenance.none
      ? DownloadDurableByteProvenance.legacyUnknown
      : provenance;
}

DownloadDurableByteProvenance _durableByteProvenanceValue(
  Object? value, {
  required int durableBytes,
  required int schemaVersion,
}) {
  if (durableBytes <= 0) return DownloadDurableByteProvenance.none;
  final raw = value?.toString().trim();
  if (raw != null && raw.isNotEmpty) {
    for (final candidate in DownloadDurableByteProvenance.values) {
      if (candidate.name == raw) return candidate;
    }
  }
  // Schema-v1 rows had no provenance. Unknown/future values are also treated
  // conservatively so they can never gain authority accidentally.
  return DownloadDurableByteProvenance.legacyUnknown;
}

DownloadDurableByteProvenance _checkpointProvenance({
  required DownloadJobRecord? current,
  required int? suppliedBytes,
  required int keptBytes,
  required DownloadDurableByteProvenance? suppliedProvenance,
}) {
  if (keptBytes <= 0) return DownloadDurableByteProvenance.none;
  if (suppliedProvenance != null) {
    return _normalizedDurableByteProvenance(keptBytes, suppliedProvenance);
  }
  if (current != null &&
      (suppliedBytes == null || keptBytes == current.durableBytes)) {
    return _normalizedDurableByteProvenance(
      keptBytes,
      current.durableByteProvenance,
    );
  }
  return DownloadDurableByteProvenance.legacyUnknown;
}

'''
if helpers_anchor in store and '_checkpointProvenance({' not in store:
    store = store.replace(helpers_anchor, helpers + helpers_anchor, 1)

store_path.write_text(store)

# Plan progress note only; DM-29 remains unchecked until multipart/native audit.
needle = "  - **Remaining before [x]:** add persisted byte-provenance semantics to DownloadJobStore and migrate old records; convert multipart manifest to a new schema with exact per-part durable-byte fields rather than `credibleProgress` as authority; audit native/Range checkpoint sources and accept them only when their durability contract is explicit; add migration/crash/0.999/native-temp-loss tests described above.\n"
replacement = "  - **Implementation status (2026-09-11, provenance slice):** JobStore schema v2 now persists `DownloadDurableByteProvenance`. Schema-v1 positive byte counts migrate conservatively to `legacyUnknown`; zero bytes use `none`; exact callers can record `verifiedFinalFile`, `exactDisk`, `rangeFlushed`, `multipartManifest`, or `nativeRecoverable`. Status-only checkpoints preserve provenance, while a changed unqualified byte count is downgraded to `legacyUnknown` instead of inheriting stronger evidence.\n  - **Remaining before [x]:** convert multipart manifest to a new schema with exact per-part durable-byte fields rather than `credibleProgress` as authority; audit native/Range checkpoint sources and tag only sources whose durability contract is explicit; add crash/0.999/native-temp-loss tests described above.\n"
if needle in plan:
    plan = plan.replace(needle, replacement, 1)
elif 'JobStore schema v2 now persists `DownloadDurableByteProvenance`' not in plan:
    raise SystemExit('DM-29 remaining-note anchor missing')
plan_path.write_text(plan)
