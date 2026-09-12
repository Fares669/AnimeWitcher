from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global source
    if new in source:
        return
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'{label} anchor mismatch: {count}')
    source = source.replace(old, new, 1)

# The URL/file/task-id overlay key is migration compatibility only once a
# canonical logical episode id exists.
replace_once(
    '''  String _overlayEpisodeKeyFromParts({\n''',
    '''  // Pre-logical-identity migration fallback. New downloads project the\n  // canonical episode id into every overlay/native snapshot instead.\n  String _overlayEpisodeKeyFromParts({\n''',
    'overlay migration comment',
)

replace_once(
    '''    final records = await FileDownloader().database.allRecords();\n    final liveProgress = _ref.read(downloadProgressProvider);\n    final entries = <DownloadOverlayEntry>[];\n''',
    '''    final records = await FileDownloader().database.allRecords();\n    final storage = _ref.read(storageServiceProvider);\n    final liveProgress = _ref.read(downloadProgressProvider);\n    final entries = <DownloadOverlayEntry>[];\n''',
    'overlay storage',
)

replace_once(
    '''      final job = await _jobStore.get(record.task.taskId);\n      final trackingUrl = downloadTrackingUrl(record.task);\n''',
    '''      final job = await _jobStore.get(record.task.taskId);\n      final metadata = await storage.getDownloadMetadata(record.task.taskId);\n      final logicalId =\n          job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);\n      final trackingUrl = downloadTrackingUrl(record.task);\n''',
    'overlay logical id lookup',
)

replace_once(
    '''          episodeKey: _overlayEpisodeKeyForTask(record.task),\n''',
    '''          episodeKey: logicalId ?? _overlayEpisodeKeyForTask(record.task),\n''',
    'overlay canonical episode key',
)

# This anchor is present after the DM05 payload-only state authority patch.
replace_once(
    '''    for (final payload in _waitingPayloads.entries) {\n      if (seen.contains(payload.key)) continue;\n      final job = await _jobStore.get(payload.key);\n      if (job != null && !downloadJobQueueWaiting(job.state)) continue;\n      _rememberSessionTask(payload.key);\n''',
    '''    for (final payload in _waitingPayloads.entries) {\n      if (seen.contains(payload.key)) continue;\n      final job = await _jobStore.get(payload.key);\n      if (job != null && !downloadJobQueueWaiting(job.state)) continue;\n      final metadata = await storage.getDownloadMetadata(payload.key);\n      final persistedLogicalId =\n          job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);\n      final payloadLogicalId = payload.value['logicalId']?.toString().trim();\n      final logicalId = persistedLogicalId ??\n          ((payloadLogicalId != null && payloadLogicalId.isNotEmpty)\n              ? payloadLogicalId\n              : null);\n      _rememberSessionTask(payload.key);\n''',
    'payload logical id lookup',
)

replace_once(
    '''          episodeKey: _overlayEpisodeKeyFromParts(\n            taskId: payload.key,\n            trackingUrl: payload.value['metaData'] as String? ?? '',\n            url: payload.value['url'] as String? ?? '',\n            directory: payload.value['directory'] as String? ?? '',\n            filename: payload.value['filename'] as String? ?? '',\n          ),\n''',
    '''          episodeKey: logicalId ??\n              _overlayEpisodeKeyFromParts(\n                taskId: payload.key,\n                trackingUrl: payload.value['metaData'] as String? ?? '',\n                url: payload.value['url'] as String? ?? '',\n                directory: payload.value['directory'] as String? ?? '',\n                filename: payload.value['filename'] as String? ?? '',\n              ),\n''',
    'payload canonical episode key',
)

replace_once(
    '''  Future<Map<String, Object>> _waitingPayloadPreservingBytes(\n    DownloadTask task,\n  ) async {\n    final payload = Map<String, Object>.from(_waitingPayloadFor(task));\n''',
    '''  Future<Map<String, Object>> _waitingPayloadPreservingBytes(\n    DownloadTask task,\n  ) async {\n    final payload = Map<String, Object>.from(_waitingPayloadFor(task));\n    final job = await _jobStore.get(task.taskId);\n    final metadata = await _ref\n        .read(storageServiceProvider)\n        .getDownloadMetadata(task.taskId);\n    final logicalId = job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);\n    if (logicalId != null && logicalId.isNotEmpty) {\n      payload['logicalId'] = logicalId;\n    }\n''',
    'native waiter logical id',
)

# Harden the migration path produced by dm24_start_identity_patch.py. Legacy
# JobStore/plugin rows with reconstructable metadata are migrated by logical id
# before URL fallback. A row with a known different logical id may never match
# only because a signed URL/filename collides.
legacy_block = '''      // Pre-logical-identity migration fallback: old rows may not yet have a\n      // canonical key. Keep the historical tracking-URL lookup only for them.\n      existingRecord ??= records.firstWhereOrNull(\n        (r) =>\n            (isLogicalEpisodeDownloadTask(r.task)) &&\n            (r.status == TaskStatus.failed ||\n                r.status == TaskStatus.notFound ||\n                r.status == TaskStatus.enqueued ||\n                r.status == TaskStatus.running ||\n                r.status == TaskStatus.paused ||\n                r.status == TaskStatus.waitingToRetry) &&\n            (r.task.metaData.isNotEmpty ? r.task.metaData : r.task.url) ==\n                (trackingUrl ?? url),\n      );\n'''
hardened_block = '''      if (existingRecord == null) {\n        // Migrate legacy JobStore rows by reconstructable presentation identity\n        // before consulting any mutable URL/file execution key. This also repairs\n        // a lost plugin projection without creating a second writer.\n        final allJobs = await _jobStore.all();\n        final storage = _ref.read(storageServiceProvider);\n        for (final candidateJob in allJobs.reversed) {\n          if (candidateJob.state == DownloadJobState.completed ||\n              candidateJob.state == DownloadJobState.canceled ||\n              candidateJob.state == DownloadJobState.orphaned) {\n            continue;\n          }\n          final metadata = await storage.getDownloadMetadata(candidateJob.taskId);\n          final candidateLogicalId = candidateJob.logicalId ??\n              logicalDownloadIdFromMetadata(metadata);\n          if (candidateLogicalId != logicalId) continue;\n          var migratedJob = candidateJob;\n          if (candidateJob.logicalId == null) {\n            migratedJob = candidateJob.copyWith(\n              logicalId: logicalId,\n              updatedAtMillis: DateTime.now().millisecondsSinceEpoch,\n            );\n            if (!await _jobStore.put(migratedJob)) continue;\n          }\n          final projected = recordsById[candidateJob.taskId];\n          if (projected != null && isLogicalEpisodeDownloadTask(projected.task)) {\n            existingLogicalJob = migratedJob;\n            existingRecord = projected;\n            break;\n          }\n          final restored = migratedJob.restoreTaskSnapshot();\n          if (restored == null || !isLogicalEpisodeDownloadTask(restored)) continue;\n          final progress = migratedJob.expectedBytes > 0\n              ? (migratedJob.durableBytes / migratedJob.expectedBytes)\n                    .clamp(0.0, 1.0)\n              : 0.0;\n          existingLogicalJob = migratedJob;\n          existingRecord = TaskRecord(\n            restored,\n            downloadJobTaskStatus(migratedJob.state),\n            progress,\n            migratedJob.expectedBytes,\n          );\n          await FileDownloader().database.updateRecord(existingRecord);\n          break;\n        }\n      }\n\n      // Pre-logical-identity migration fallback: only evidence that genuinely\n      // lacks a canonical identity may use the historical tracking URL. Known\n      // different logical ids are explicitly fenced from this path.\n      if (existingRecord == null) {\n        final storage = _ref.read(storageServiceProvider);\n        for (final candidate in records) {\n          if (!isLogicalEpisodeDownloadTask(candidate.task) ||\n              !(candidate.status == TaskStatus.failed ||\n                  candidate.status == TaskStatus.notFound ||\n                  candidate.status == TaskStatus.enqueued ||\n                  candidate.status == TaskStatus.running ||\n                  candidate.status == TaskStatus.paused ||\n                  candidate.status == TaskStatus.waitingToRetry)) {\n            continue;\n          }\n          final candidateJob = await _jobStore.get(candidate.task.taskId);\n          final candidateMetadata =\n              await storage.getDownloadMetadata(candidate.task.taskId);\n          final candidateLogicalId = candidateJob?.logicalId ??\n              logicalDownloadIdFromMetadata(candidateMetadata);\n          if (candidateLogicalId != null) {\n            if (candidateLogicalId != logicalId) continue;\n            existingLogicalJob = candidateJob;\n            existingRecord = candidate;\n            break;\n          }\n          final candidateTracking = candidate.task.metaData.isNotEmpty\n              ? candidate.task.metaData\n              : candidate.task.url;\n          if (candidateTracking == (trackingUrl ?? url)) {\n            existingRecord = candidate;\n            break;\n          }\n        }\n      }\n'''
replace_once(legacy_block, hardened_block, 'legacy start adoption fencing')

path.write_text(source)
