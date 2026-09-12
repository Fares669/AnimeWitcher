from pathlib import Path

identity_path = Path('lib/core/services/download_logical_identity.dart')
source = identity_path.read_text()

old_factory = '''  factory DownloadLogicalIdentity.fromMedia({\n    required MultimediaItem item,\n    required Episode episode,\n  }) {\n    final contentKey = _contentIdentity(item);\n    final dubStatus = episode.dubStatus != DubStatus.none\n        ? episode.dubStatus\n        : (item.isDubbed ? DubStatus.dubbed : DubStatus.none);\n    final key = <String>[\n      'download:v1',\n      contentKey,\n      's${episode.season}',\n      'e${episode.episode}',\n      'dub:${dubStatus.name}',\n    ].join('|');\n\n    return DownloadLogicalIdentity._(\n      key: key,\n      contentKey: contentKey,\n      season: episode.season,\n      episode: episode.episode,\n      dubStatus: dubStatus,\n    );\n  }\n'''
new_factory = '''  factory DownloadLogicalIdentity.fromMedia({\n    required MultimediaItem item,\n    Episode? episode,\n  }) {\n    final contentKey = _contentIdentity(item);\n    final episodeDub = episode?.dubStatus ?? DubStatus.none;\n    final dubStatus = episodeDub != DubStatus.none\n        ? episodeDub\n        : (item.isDubbed ? DubStatus.dubbed : DubStatus.none);\n    final season = episode?.season ?? 0;\n    final episodeNumber = episode?.episode ?? 0;\n    final key = <String>[\n      'download:v1',\n      contentKey,\n      's$season',\n      'e$episodeNumber',\n      'dub:${dubStatus.name}',\n    ].join('|');\n\n    return DownloadLogicalIdentity._(\n      key: key,\n      contentKey: contentKey,\n      season: season,\n      episode: episodeNumber,\n      dubStatus: dubStatus,\n    );\n  }\n'''
if source.count(old_factory) != 1:
    raise SystemExit(f'identity factory anchor mismatch: {source.count(old_factory)}')
source = source.replace(old_factory, new_factory, 1)

append_anchor = '''}\n'''
helper = '''\n\n/// Restores the stable logical identity from presentation metadata.\n///\n/// New metadata carries the key explicitly. Legacy rows may be migrated only\n/// from the original media/episode snapshots; executor URLs, filenames and\n/// task IDs are never accepted as substitutes because they are mutable attempt\n/// details and can collide across episodes.\nString? logicalDownloadIdFromMetadata(Map<String, dynamic>? metadata) {\n  if (metadata == null) return null;\n  final explicit = metadata['logicalId']?.toString().trim();\n  if (explicit != null && explicit.isNotEmpty) return explicit;\n\n  final rawItem = metadata['item'];\n  if (rawItem is! Map) return null;\n  try {\n    final item = MultimediaItem.fromJson(Map<String, dynamic>.from(rawItem));\n    Episode? episode;\n    final rawEpisode = metadata['episode'];\n    if (rawEpisode is Map) {\n      episode = Episode.fromJson(Map<String, dynamic>.from(rawEpisode));\n    }\n    return DownloadLogicalIdentity.fromMedia(item: item, episode: episode).key;\n  } catch (_) {\n    return null;\n  }\n}\n'''
# Append after the class definition; this file has only the identity class.
if 'String? logicalDownloadIdFromMetadata(' not in source:
    source = source.rstrip() + helper
identity_path.write_text(source)

storage_path = Path('lib/core/storage/storage_service.dart')
storage = storage_path.read_text()

old_save_sig = '''    String? trackingUrl,\n    String? filePath,\n    Map<String, dynamic>? taskSnapshot,'''
new_save_sig = '''    String? trackingUrl,\n    String? filePath,\n    String? logicalId,\n    Map<String, dynamic>? taskSnapshot,'''
if storage.count(old_save_sig) < 2:
    raise SystemExit(f'storage signature anchors missing: {storage.count(old_save_sig)}')
# saveDownloadMetadata and patchDownloadMetadata have the same parameter segment.
storage = storage.replace(old_save_sig, new_save_sig, 2)

old_save_map = '''      if (filePath != null && filePath.isNotEmpty) 'filePath': filePath,\n      if (taskSnapshot != null)'''
new_save_map = '''      if (filePath != null && filePath.isNotEmpty) 'filePath': filePath,\n      if (logicalId != null && logicalId.trim().isNotEmpty)\n        'logicalId': logicalId.trim(),\n      if (taskSnapshot != null)'''
if storage.count(old_save_map) != 1:
    raise SystemExit(f'save metadata map anchor mismatch: {storage.count(old_save_map)}')
storage = storage.replace(old_save_map, new_save_map, 1)

old_patch_map = '''    if (filePath != null && filePath.isNotEmpty) {\n      map['filePath'] = filePath;\n    }\n    if (taskSnapshot != null) {'''
new_patch_map = '''    if (filePath != null && filePath.isNotEmpty) {\n      map['filePath'] = filePath;\n    }\n    if (logicalId != null && logicalId.trim().isNotEmpty) {\n      map['logicalId'] = logicalId.trim();\n    }\n    if (taskSnapshot != null) {'''
if storage.count(old_patch_map) != 1:
    raise SystemExit(f'patch metadata map anchor mismatch: {storage.count(old_patch_map)}')
storage = storage.replace(old_patch_map, new_patch_map, 1)
storage_path.write_text(storage)
