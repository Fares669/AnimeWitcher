from pathlib import Path

source_path = Path('lib/core/services/persistent_parallel_download.dart')
test_path = Path('test/core/services/persistent_parallel_download_durable_manifest_guard_test.dart')
plan_path = Path('DOWNLOAD_MANAGER_PLAN.md')

source = source_path.read_text()
plan = plan_path.read_text()

# RED: a source-level invariant guard for the private manifest model.
if not test_path.exists():
    test_path.write_text(r'''import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('multipart manifest has exact per-part durable byte authority', () {
    final source = File(
      'lib/core/services/persistent_parallel_download.dart',
    ).readAsStringSync();

    expect(source, contains('kParallelManifestSchemaVersion = 5'));
    expect(source, contains("'durableBytes': durableBytes"));
    expect(source, contains('sum + part.durableBytes'));
    expect(source, contains('final savedDurableBytes = json[\'durableBytes\']'));
  });
}
''')

# Schema v5: explicit exact per-part durable bytes.
source = source.replace(
    '/// Version 4 also persists whether a child must bypass old native resumeData\n'
    '/// after its parent source URL was refreshed.\n'
    'const int kParallelManifestSchemaVersion = 4;',
    '/// Version 4 also persists whether a child must bypass old native resumeData\n'
    '/// after its parent source URL was refreshed. Version 5 adds exact per-part\n'
    '/// durable byte counters. Floating-point progress remains presentation/history\n'
    '/// only and is never recovery byte authority.\n'
    'const int kParallelManifestSchemaVersion = 5;',
    1,
)

# Session byte truth comes only from exact durable counters.
old = """  int get creditedBytes => parts.fold<int>(\n    0,\n    (sum, part) =>\n        sum +\n        (part.complete\n            ? part.size\n            : (part.size * part.credibleProgress).floor()),\n  );\n"""
new = """  int get creditedBytes =>\n      parts.fold<int>(0, (sum, part) => sum + part.durableBytes);\n"""
if old not in source:
    raise SystemExit('creditedBytes anchor missing')
source = source.replace(old, new, 1)

# Constructor/model field.
old = """    this.sourceValidationRequired = false,\n    double? credibleProgress,\n    this.needsCredibleProgressRepair = false,\n  }) : credibleProgress = complete\n"""
new = """    this.sourceValidationRequired = false,\n    double? credibleProgress,\n    int? durableBytes,\n    this.needsCredibleProgressRepair = false,\n  }) : durableBytes = complete\n           ? to - from + 1\n           : (durableBytes ?? 0).clamp(0, to - from + 1).toInt(),\n       credibleProgress = complete\n"""
if old not in source:
    raise SystemExit('part constructor anchor missing')
source = source.replace(old, new, 1)

old = """  /// Byte-credible progress used by the logical episode/UI. A 0.999 sentinel\n  /// never advances this field by itself.\n  double credibleProgress;\n\n  bool complete;\n"""
new = """  /// Presentation/history progress. It can be informed by native callbacks but\n  /// is never persisted as byte authority.\n  double credibleProgress;\n\n  /// Exact recoverable bytes proven by a visible part file or completion.\n  int durableBytes;\n\n  bool complete;\n"""
if old not in source:
    raise SystemExit('part field anchor missing')
source = source.replace(old, new, 1)

# Codec: old manifests deliberately migrate unfinished progress to zero byte
# authority. Restore's disk scan can then repopulate exact bytes safely.
old = """    final savedCredible = json['credibleProgress'];\n    final hasSavedCredible = savedCredible is num;\n    final legacyTailSentinel =\n        !complete &&\n        !hasSavedCredible &&\n        rawProgress >= kParallelNativeCompletionSentinel;\n    return _DownloadPart(\n"""
new = """    final savedCredible = json['credibleProgress'];\n    final hasSavedCredible = savedCredible is num;\n    final savedDurableBytes = json['durableBytes'];\n    final hasSavedDurableBytes = savedDurableBytes is num;\n    final legacyTailSentinel =\n        !complete &&\n        (!hasSavedCredible || !hasSavedDurableBytes) &&\n        rawProgress >= kParallelNativeCompletionSentinel;\n    return _DownloadPart(\n"""
if old not in source:
    raise SystemExit('part fromJson prelude missing')
source = source.replace(old, new, 1)

old = """      credibleProgress: complete\n          ? 1\n          : (hasSavedCredible ? savedCredible.toDouble() : null),\n      needsCredibleProgressRepair: legacyTailSentinel,\n"""
new = """      credibleProgress: complete\n          ? 1\n          : (hasSavedCredible ? savedCredible.toDouble() : null),\n      durableBytes: complete\n          ? (json['to'] as int) - (json['from'] as int) + 1\n          : (hasSavedDurableBytes ? savedDurableBytes.toInt() : 0),\n      needsCredibleProgressRepair:\n          legacyTailSentinel || (!complete && !hasSavedDurableBytes),\n"""
if old not in source:
    raise SystemExit('part fromJson ctor missing')
source = source.replace(old, new, 1)

old = """    'progress': progress,\n    'credibleProgress': credibleProgress,\n    'complete': complete,\n"""
new = """    'progress': progress,\n    'credibleProgress': credibleProgress,\n    'durableBytes': durableBytes,\n    'complete': complete,\n"""
if old not in source:
    raise SystemExit('part toJson anchor missing')
source = source.replace(old, new, 1)

# Exact byte observations populate durableBytes.
source = source.replace(
    '    part.progress = repaired;\n    part.credibleProgress = repaired;\n',
    '    part.progress = repaired;\n    part.credibleProgress = repaired;\n    part.durableBytes = durableBytes;\n',
    1,
)
source = source.replace(
    '                part.complete = true;\n                part.progress = 1;\n                part.credibleProgress = 1;\n',
    '                part.complete = true;\n                part.progress = 1;\n                part.credibleProgress = 1;\n                part.durableBytes = part.size;\n',
)
source = source.replace(
    '                part.credibleProgress = bytes / part.size;\n',
    '                part.credibleProgress = bytes / part.size;\n                part.durableBytes = bytes;\n',
)
source = source.replace(
    '            part.complete = true;\n            part.progress = 1;\n            part.credibleProgress = 1;\n',
    '            part.complete = true;\n            part.progress = 1;\n            part.credibleProgress = 1;\n            part.durableBytes = part.size;\n',
)
source = source.replace(
    '              part.credibleProgress = diskProgress;\n',
    '              part.credibleProgress = diskProgress;\n              part.durableBytes = saved.bytes;\n',
)
source = source.replace(
    '      part.complete = true;\n      part.progress = 1;\n      part.credibleProgress = 1;\n',
    '      part.complete = true;\n      part.progress = 1;\n      part.credibleProgress = 1;\n      part.durableBytes = part.size;\n',
)
source = source.replace(
    '    part.progress = part.size > 0 ? savedBytes / part.size : 0;\n    part.credibleProgress = part.progress;\n',
    '    part.progress = part.size > 0 ? savedBytes / part.size : 0;\n    part.credibleProgress = part.progress;\n    part.durableBytes = savedBytes;\n',
    1,
)
source = source.replace(
    '    part.complete = true;\n    part.progress = 1;\n    part.credibleProgress = 1;\n    await saveRecord(TaskRecord(part.task, TaskStatus.complete, 1, part.size));\n',
    '    part.complete = true;\n    part.progress = 1;\n    part.credibleProgress = 1;\n    part.durableBytes = part.size;\n    await saveRecord(TaskRecord(part.task, TaskStatus.complete, 1, part.size));\n',
    1,
)
source = source.replace(
    '        part.credibleProgress = diskProgress;\n        if (part.progress >= kParallelNativeCompletionSentinel ||\n',
    '        part.credibleProgress = diskProgress;\n        part.durableBytes = bytes;\n        if (part.progress >= kParallelNativeCompletionSentinel ||\n',
    1,
)
source = source.replace(
    '    part.progress = 0;\n    part.credibleProgress = 0;\n',
    '    part.progress = 0;\n    part.credibleProgress = 0;\n    part.durableBytes = 0;\n',
)

# Any exact completion assignment missed above gets the exact Range size.
source = source.replace(
    '            part.complete = true;\n            part.progress = 1;\n            part.credibleProgress = 1;\n            part.speed = 0;\n',
    '            part.complete = true;\n            part.progress = 1;\n            part.credibleProgress = 1;\n            part.durableBytes = part.size;\n            part.speed = 0;\n',
)

source_path.write_text(source)

needle = "  - **Remaining before [x]:** convert multipart manifest to a new schema with exact per-part durable-byte fields rather than `credibleProgress` as authority; audit native/Range checkpoint sources and tag only sources whose durability contract is explicit; add crash/0.999/native-temp-loss tests described above.\n"
replacement = "  - **Implementation status (2026-09-11, multipart slice):** Multipart manifest schema v5 persists an exact `durableBytes` counter per child. Parent credited bytes now sum those counters rather than `part.size * credibleProgress`; legacy unfinished manifests migrate with zero byte authority and are repaired from visible disk evidence. Native/plugin percentages remain presentation/recovery hints only, while exact disk observations and exact completion update durable byte truth.\n  - **Remaining before [x]:** audit native/Range JobStore checkpoint sources and tag only sources whose durability contract is explicit; add crash/native-temp-loss coverage and verify the 0.999 legacy migration through behavioral multipart restore tests.\n"
if needle in plan:
    plan = plan.replace(needle, replacement, 1)
elif 'Multipart manifest schema v5 persists an exact `durableBytes` counter per child' not in plan:
    raise SystemExit('plan anchor missing')
plan_path.write_text(plan)
