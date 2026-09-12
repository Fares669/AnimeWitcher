from pathlib import Path


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    source = path.read_text()
    if new in source:
        return
    if old not in source:
        raise SystemExit(f'DM-31 {label} anchor drift in {path}')
    path.write_text(source.replace(old, new, 1))

refresh = Path('lib/core/services/download_url_refresh.dart')
source = refresh.read_text()
if 'required this.generation' not in source:
    source = source.replace(
        '''    required this.updatedAtMillis,\n    this.quality,\n''',
        '''    required this.updatedAtMillis,\n    required this.generation,\n    this.quality,\n''',
        1,
    )
    source = source.replace(
        '''  final int updatedAtMillis;\n\n  Map<String, Object?> toJson() => <String, Object?>{\n''',
        '''  final int updatedAtMillis;\n  final int generation;\n\n  Map<String, Object?> toJson() => <String, Object?>{\n''',
        1,
    )
    source = source.replace(
        '''    'updatedAtMillis': updatedAtMillis,\n  };\n''',
        '''    'updatedAtMillis': updatedAtMillis,\n    'generation': generation,\n  };\n''',
        1,
    )
    source = source.replace(
        '''      updatedAtMillis: _int(map['updatedAtMillis']),\n    );\n''',
        '''      updatedAtMillis: _int(map['updatedAtMillis']),\n      // Legacy descriptors predate generation fencing. Generation zero keeps\n      // them readable until the owning DownloadService rewrites the record.\n      generation: _int(map['generation']),\n    );\n''',
        1,
    )

old_store = '''  Future<void> save(DownloadUrlRefreshDescriptor descriptor) async {\n    if (descriptor.trackingUrl.trim().isEmpty ||\n        descriptor.providerId.trim().isEmpty ||\n        descriptor.source.trim().isEmpty) {\n      return;\n    }\n    await backend.write(keyFor(descriptor.trackingUrl), descriptor.toJson());\n  }\n'''
new_store = '''  Future<void> _tail = Future<void>.value();\n\n  Future<T> _serialize<T>(Future<T> Function() action) {\n    final completer = Completer<T>();\n    _tail = _tail.then<void>((_) async {\n      try {\n        completer.complete(await action());\n      } catch (error, stack) {\n        completer.completeError(error, stack);\n      }\n    });\n    return completer.future;\n  }\n\n  Future<bool> save(DownloadUrlRefreshDescriptor descriptor) =>\n      _serialize(() async {\n        if (descriptor.trackingUrl.trim().isEmpty ||\n            descriptor.providerId.trim().isEmpty ||\n            descriptor.source.trim().isEmpty) {\n          return false;\n        }\n        final key = keyFor(descriptor.trackingUrl);\n        final existing = DownloadUrlRefreshDescriptor.fromJson(\n          await backend.read(key),\n        );\n        if (existing != null && existing.generation > descriptor.generation) {\n          return false;\n        }\n        await backend.write(key, descriptor.toJson());\n        return true;\n      });\n'''
if old_store in source:
    source = source.replace(old_store, new_store, 1)

old_remove = '''  Future<void> remove(String trackingUrl) =>\n      backend.delete(keyFor(trackingUrl));\n'''
new_remove = '''  Future<bool> removeForGeneration(\n    String trackingUrl,\n    int generation,\n  ) => _serialize(() async {\n    final key = keyFor(trackingUrl);\n    final descriptor = DownloadUrlRefreshDescriptor.fromJson(\n      await backend.read(key),\n    );\n    if (descriptor == null) return true;\n    if (descriptor.generation != generation) return false;\n    await backend.delete(key);\n    return true;\n  });\n\n  Future<void> remove(String trackingUrl) =>\n      backend.delete(keyFor(trackingUrl));\n'''
if old_remove in source:
    source = source.replace(old_remove, new_remove, 1)
refresh.write_text(source)

launcher = Path('lib/features/details/presentation/download_launcher.dart')
source = launcher.read_text()
old_block = '''                  final refreshStore = _ref.read(\n                    downloadUrlRefreshStoreProvider,\n                  );\n                  await refreshStore.save(\n                    DownloadUrlRefreshDescriptor(\n                      trackingUrl: resolveUrl,\n                      providerId: providerId,\n                      source: stream.source,\n                      quality: stream.quality,\n                      refreshUrl: stream.refreshUrl,\n                      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,\n                    ),\n                  );\n\n                  final outcome = await downloadService.startDownloadOutcome(\n'''
new_block = '''                  final outcome = await downloadService.startDownloadOutcome(\n'''
if old_block in source:
    source = source.replace(old_block, new_block, 1)
call_anchor = '''                    totalBytes: metadata.size ?? -1,\n                  );\n'''
call_new = '''                    totalBytes: metadata.size ?? -1,\n                    refreshDescriptor: DownloadUrlRefreshDescriptor(\n                      trackingUrl: resolveUrl,\n                      providerId: providerId,\n                      source: stream.source,\n                      quality: stream.quality,\n                      refreshUrl: stream.refreshUrl,\n                      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,\n                      generation: 0,\n                    ),\n                  );\n'''
if call_new not in source:
    if call_anchor not in source:
        raise SystemExit('DM-31 launcher outcome call anchor drift')
    source = source.replace(call_anchor, call_new, 1)
cleanup = '''\n                  if (!accepted) {\n                    await refreshStore.remove(resolveUrl);\n                  }\n'''
source = source.replace(cleanup, '\n', 1)
launcher.write_text(source)

service = Path('lib/core/services/download_service.dart')
source = service.read_text()
wrapper_sig = '''    Map<String, String>? headers,\n    int totalBytes = -1,\n  }) async {\n    final outcome = await startDownloadOutcome(\n'''
wrapper_new = '''    Map<String, String>? headers,\n    int totalBytes = -1,\n    DownloadUrlRefreshDescriptor? refreshDescriptor,\n  }) async {\n    final outcome = await startDownloadOutcome(\n'''
if 'Future<bool> startDownload({' in source and 'DownloadUrlRefreshDescriptor? refreshDescriptor,' not in source:
    if wrapper_sig not in source:
        raise SystemExit('DM-31 startDownload signature anchor drift')
    source = source.replace(wrapper_sig, wrapper_new, 1)

wrapper_forward = '''      headers: headers,\n      totalBytes: totalBytes,\n    );\n'''
wrapper_forward_new = '''      headers: headers,\n      totalBytes: totalBytes,\n      refreshDescriptor: refreshDescriptor,\n    );\n'''
# Only the wrapper call occurs before startDownloadOutcome declaration.
wrapper_pos = source.find('Future<bool> startDownload({')
outcome_pos = source.find('Future<DownloadCommandOutcome> startDownloadOutcome({')
segment = source[wrapper_pos:outcome_pos]
if 'refreshDescriptor: refreshDescriptor,' not in segment:
    if wrapper_forward not in segment:
        raise SystemExit('DM-31 wrapper forwarding anchor drift')
    segment = segment.replace(wrapper_forward, wrapper_forward_new, 1)
    source = source[:wrapper_pos] + segment + source[outcome_pos:]

outcome_start = source.find('Future<DownloadCommandOutcome> startDownloadOutcome({')
outcome_header_end = source.find('  }) async {', outcome_start)
header = source[outcome_start:outcome_header_end]
if 'DownloadUrlRefreshDescriptor? refreshDescriptor,' not in header:
    old = '''    Map<String, String>? headers,\n    int totalBytes = -1,\n'''
    new = '''    Map<String, String>? headers,\n    int totalBytes = -1,\n    DownloadUrlRefreshDescriptor? refreshDescriptor,\n'''
    header = header.replace(old, new, 1)
    source = source[:outcome_start] + header + source[outcome_header_end:]

helper_anchor = '''  Future<bool> startDownload({\n'''
helper = '''  Future<bool> _commitRefreshDescriptorForGeneration(\n    DownloadUrlRefreshDescriptor descriptor, {\n    required String trackingUrl,\n    required int generation,\n  }) {\n    return _ref.read(downloadUrlRefreshStoreProvider).save(\n      DownloadUrlRefreshDescriptor(\n        trackingUrl: trackingUrl,\n        providerId: descriptor.providerId,\n        source: descriptor.source,\n        quality: descriptor.quality,\n        refreshUrl: descriptor.refreshUrl,\n        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,\n        generation: generation,\n      ),\n    );\n  }\n\n'''
if '_commitRefreshDescriptorForGeneration(' not in source:
    if helper_anchor not in source:
        raise SystemExit('DM-31 helper insertion anchor drift')
    source = source.replace(helper_anchor, helper + helper_anchor, 1)

job_anchor = '''        if (!jobPersisted) {\n          throw StateError('Failed to persist fresh download intent');\n        }\n\n        _waitingPayloads[transferTask.taskId] = _waitingPayloadFor(\n'''
job_new = '''        if (!jobPersisted) {\n          throw StateError('Failed to persist fresh download intent');\n        }\n\n        int? refreshDescriptorGeneration;\n        if (!startNow && refreshDescriptor != null) {\n          final committed = await _commitRefreshDescriptorForGeneration(\n            refreshDescriptor,\n            trackingUrl: trackingUrl ?? url,\n            generation: 0,\n          );\n          if (!committed) {\n            throw StateError('A newer refresh descriptor owns this download');\n          }\n          refreshDescriptorGeneration = 0;\n        }\n\n        _waitingPayloads[transferTask.taskId] = _waitingPayloadFor(\n'''
if 'int? refreshDescriptorGeneration;' not in source:
    if job_anchor not in source:
        raise SystemExit('DM-31 persisted-job anchor drift')
    source = source.replace(job_anchor, job_new, 1)

op_anchor = '''        if (startOperation == null) {\n          throw StateError(\n            'Failed to fence start operation for ${transferTask.taskId}',\n          );\n        }\n        final success = await _enqueueTransfer(transferTask, expectedBytes);\n'''
op_new = '''        if (startOperation == null) {\n          throw StateError(\n            'Failed to fence start operation for ${transferTask.taskId}',\n          );\n        }\n        if (refreshDescriptor != null) {\n          final committed = await _commitRefreshDescriptorForGeneration(\n            refreshDescriptor,\n            trackingUrl: trackingUrl ?? url,\n            generation: startOperation.generation,\n          );\n          if (!committed) {\n            throw StateError('A newer refresh descriptor owns this download');\n          }\n          refreshDescriptorGeneration = startOperation.generation;\n        }\n        final success = await _enqueueTransfer(transferTask, expectedBytes);\n'''
if 'generation: startOperation.generation,' not in source:
    if op_anchor not in source:
        raise SystemExit('DM-31 start-operation anchor drift')
    source = source.replace(op_anchor, op_new, 1)

catch_anchor = '''        await storage.removeDownloadMetadata(task.taskId);\n        // A start that never established recoverable ownership must not leave\n'''
catch_new = '''        await storage.removeDownloadMetadata(task.taskId);\n        if (refreshDescriptorGeneration != null) {\n          await _ref.read(downloadUrlRefreshStoreProvider).removeForGeneration(\n            trackingUrl ?? url,\n            refreshDescriptorGeneration,\n          );\n        }\n        // A start that never established recoverable ownership must not leave\n'''
if 'removeForGeneration(\n            trackingUrl ?? url,' not in source:
    if catch_anchor not in source:
        raise SystemExit('DM-31 rollback anchor drift')
    source = source.replace(catch_anchor, catch_new, 1)
service.write_text(source)
