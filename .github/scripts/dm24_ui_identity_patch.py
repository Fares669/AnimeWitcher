from pathlib import Path

path = Path('lib/features/library/presentation/downloads_provider.dart')
source = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'{label} anchor mismatch: {count}')
    source = source.replace(old, new, 1)

import_anchor = "import '../../../core/services/download_job_state.dart';\nimport '../../../core/services/download_service.dart';\n"
if import_anchor in source and "download_logical_identity.dart" not in source:
    source = source.replace(
        import_anchor,
        "import '../../../core/services/download_job_state.dart';\nimport '../../../core/services/download_logical_identity.dart';\nimport '../../../core/services/download_service.dart';\n",
        1,
    )

replace_once(
    '''  final Episode? episode;\n  final int timestamp;\n''',
    '''  final Episode? episode;\n  final String? logicalId;\n  final int timestamp;\n''',
    'DownloadItem logical field',
)
replace_once(
    '''    this.episode,\n    required this.timestamp,\n''',
    '''    this.episode,\n    this.logicalId,\n    required this.timestamp,\n''',
    'DownloadItem constructor',
)

old_same = '''bool downloadsPointAtSameTarget(DownloadItem a, DownloadItem b) {\n  if (identical(a, b) || a.id == b.id) return true;\n  final trackA = downloadTrackingUrl(a.task);\n'''
new_same = '''bool downloadsPointAtSameTarget(DownloadItem a, DownloadItem b) {\n  if (identical(a, b) || a.id == b.id) return true;\n  final logicalA = a.logicalId?.trim();\n  final logicalB = b.logicalId?.trim();\n  if (logicalA != null &&\n      logicalA.isNotEmpty &&\n      logicalB != null &&\n      logicalB.isNotEmpty) {\n    return a.logicalId == b.logicalId;\n  }\n  // Pre-logical-identity migration fallback: only incomplete legacy evidence\n  // may fall through to mutable URL/file heuristics.\n  final trackA = downloadTrackingUrl(a.task);\n'''
replace_once(old_same, new_same, 'same target identity guard')

replace_once(
    '''  final byTracking = <String, int>{};\n  final byFile = <String, int>{};\n''',
    '''  final byLogicalId = <String, int>{};\n  final byTracking = <String, int>{};\n  final byFile = <String, int>{};\n''',
    'group logical map',
)
replace_once(
    '''  for (var i = 0; i < items.length; i++) {\n    unionKey(byTracking, downloadTrackingUrl(items[i].task), i);\n    unionKey(byTracking, items[i].episode?.url.trim() ?? '', i);\n    unionKey(byFile, downloadTaskFileKey(items[i].task), i);\n  }\n''',
    '''  for (var i = 0; i < items.length; i++) {\n    final logicalId = items[i].logicalId?.trim();\n    if (logicalId != null && logicalId.isNotEmpty) {\n      unionKey(byLogicalId, logicalId, i);\n      continue;\n    }\n    // Pre-logical-identity migration fallback.\n    unionKey(byTracking, downloadTrackingUrl(items[i].task), i);\n    unionKey(byTracking, items[i].episode?.url.trim() ?? '', i);\n    unionKey(byFile, downloadTaskFileKey(items[i].task), i);\n  }\n''',
    'group logical priority',
)

replace_once(
    '''    episode: metadata['episode'] != null\n        ? Episode.fromJson(\n            Map<String, dynamic>.from(metadata['episode'] as Map),\n          )\n        : null,\n    timestamp: (metadata['timestamp'] as int?) ?? 0,\n''',
    '''    episode: metadata['episode'] != null\n        ? Episode.fromJson(\n            Map<String, dynamic>.from(metadata['episode'] as Map),\n          )\n        : null,\n    logicalId: logicalDownloadIdFromMetadata(metadata),\n    timestamp: (metadata['timestamp'] as int?) ?? 0,\n''',
    'metadata logical projection',
)

replace_once(
    '''          episode: existing.episode,\n          timestamp: existing.timestamp,\n''',
    '''          episode: existing.episode,\n          logicalId: existing.logicalId,\n          timestamp: existing.timestamp,\n''',
    'update logical preservation',
)

path.write_text(source)
