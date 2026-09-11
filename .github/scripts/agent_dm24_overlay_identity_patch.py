from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'{label} anchor mismatch: {count}')
    source = source.replace(old, new, 1)

replace_once(
    '''  String _overlayEpisodeKeyFromParts({\n''',
    '''  // Pre-logical-identity migration fallback: mutable executor keys are\n  // consulted only when no canonical logical identity survives.\n  String _overlayEpisodeKeyFromParts({\n''',
    'legacy overlay marker',
)

replace_once(
    '''    final records = await FileDownloader().database.allRecords();\n    final liveProgress = _ref.read(downloadProgressProvider);\n    final entries = <DownloadOverlayEntry>[];\n''',
    '''    final records = await FileDownloader().database.allRecords();\n    final storage = _ref.read(storageServiceProvider);\n    final liveProgress = _ref.read(downloadProgressProvider);\n    final entries = <DownloadOverlayEntry>[];\n''',
    'overlay storage handle',
)

replace_once(
    '''      final job = await _jobStore.get(record.task.taskId);\n      final trackingUrl = downloadTrackingUrl(record.task);\n''',
    '''      final job = await _jobStore.get(record.task.taskId);\n      final metadata = await storage.getDownloadMetadata(record.task.taskId);\n      final logicalId =\n          job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);\n      final trackingUrl = downloadTrackingUrl(record.task);\n''',
    'overlay persisted logical id',
)

replace_once(
    '''          episodeKey: _overlayEpisodeKeyForTask(record.task),\n''',
    '''          episodeKey: logicalId ?? _overlayEpisodeKeyForTask(record.task),\n''',
    'overlay logical key',
)

replace_once(
    '''    for (final payload in _waitingPayloads.entries) {\n      if (seen.contains(payload.key)) continue;\n      _rememberSessionTask(payload.key);\n      entries.add(\n        DownloadOverlayEntry(\n          taskId: payload.key,\n          status: TaskStatus.enqueued,\n          displayName: payload.value['displayName'] as String? ?? '',\n          queueWaiting: true,\n          episodeKey: _overlayEpisodeKeyFromParts(\n''',
    '''    for (final payload in _waitingPayloads.entries) {\n      if (seen.contains(payload.key)) continue;\n      _rememberSessionTask(payload.key);\n      final job = await _jobStore.get(payload.key);\n      final payloadLogicalId =\n          (payload.value['logicalId'] as String?)?.trim();\n      entries.add(\n        DownloadOverlayEntry(\n          taskId: payload.key,\n          status: job != null\n              ? downloadJobDisplayStatus(job.state)\n              : TaskStatus.enqueued,\n          displayName: payload.value['displayName'] as String? ?? '',\n          queueWaiting: job != null\n              ? downloadJobQueueWaiting(job.state)\n              : true,\n          episodeKey: payloadLogicalId != null && payloadLogicalId.isNotEmpty\n              ? payloadLogicalId\n              : _overlayEpisodeKeyFromParts(\n''',
    'waiting overlay logical id',
)

replace_once(
    '''            filename: payload.value['filename'] as String? ?? '',\n          ),\n        ),\n      );\n''',
    '''            filename: payload.value['filename'] as String? ?? '',\n          ),\n        ),\n      );\n''',
    'waiting overlay formatting guard',
)

replace_once(
    '''    final payload = Map<String, Object>.from(_waitingPayloadFor(task));\n    if (task is! ParallelDownloadTask) {\n''',
    '''    final payload = Map<String, Object>.from(_waitingPayloadFor(task));\n    final job = await _jobStore.get(task.taskId);\n    final metadata = await _ref\n        .read(storageServiceProvider)\n        .getDownloadMetadata(task.taskId);\n    final logicalId =\n        job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);\n    if (logicalId != null && logicalId.isNotEmpty) {\n      payload['logicalId'] = logicalId;\n    }\n    if (task is! ParallelDownloadTask) {\n''',
    'waiter payload logical id',
)

path.write_text(source)
