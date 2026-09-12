from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()

# The start/adoption patch normally adds this import first. Keep this script
# independently safe for reruns/diagnostics.
if "import 'download_logical_identity.dart';" not in source:
    anchor = "import 'download_job_store.dart';\n"
    if source.count(anchor) != 1:
        raise SystemExit(f'logical identity import anchor mismatch: {source.count(anchor)}')
    source = source.replace(anchor, anchor + "import 'download_logical_identity.dart';\n", 1)

fallback_method = '''  String _overlayEpisodeKeyFromParts({\n'''
if '// Pre-logical-identity migration fallback: overlay keys below' not in source:
    if source.count(fallback_method) != 1:
        raise SystemExit(f'overlay fallback method anchor mismatch: {source.count(fallback_method)}')
    source = source.replace(
        fallback_method,
        '''  // Pre-logical-identity migration fallback: overlay keys below are\n  // only used when durable/presentation evidence cannot reconstruct a logical ID.\n''' + fallback_method,
        1,
    )

old_start = '''    final records = await FileDownloader().database.allRecords();\n    final liveProgress = _ref.read(downloadProgressProvider);\n    final entries = <DownloadOverlayEntry>[];\n    for (final record in records) {\n      if (!isLogicalEpisodeDownloadTask(record.task)) continue;\n      final trackingUrl = downloadTrackingUrl(record.task);\n      final live = liveProgress[trackingUrl];\n      final leftoverWaiting = _queueWaitingIds.contains(record.task.taskId);\n      final liveRunning = live?.status == TaskStatus.running;\n      final inSession =\n          _sessionOrder.contains(record.task.taskId) ||\n          occupiesDownloadSlot(\n            status: record.status,\n            queueWaiting: leftoverWaiting,\n          ) ||\n          leftoverWaiting ||\n          liveRunning ||\n          record.status == TaskStatus.enqueued;\n      if (!inSession) continue;\n'''
new_start = '''    final records = await FileDownloader().database.allRecords();\n    final storage = _ref.read(storageServiceProvider);\n    final liveProgress = _ref.read(downloadProgressProvider);\n    final entries = <DownloadOverlayEntry>[];\n    for (final record in records) {\n      if (!isLogicalEpisodeDownloadTask(record.task)) continue;\n      final job = await _jobStore.get(record.task.taskId);\n      final metadata = await storage.getDownloadMetadata(record.task.taskId);\n      final logicalId =\n          job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);\n      final trackingUrl = downloadTrackingUrl(record.task);\n      final live = liveProgress[trackingUrl];\n      final liveRunning = live?.status == TaskStatus.running;\n      final leftoverWaiting = job != null\n          ? downloadJobQueueWaiting(job.state)\n          : _queueWaitingIds.contains(record.task.taskId);\n      final inSession = job != null\n          ? _sessionOrder.contains(record.task.taskId) ||\n                downloadJobOccupiesSlot(job.state) ||\n                leftoverWaiting ||\n                liveRunning\n          : _sessionOrder.contains(record.task.taskId) ||\n                occupiesDownloadSlot(\n                  status: record.status,\n                  queueWaiting: leftoverWaiting,\n                ) ||\n                leftoverWaiting ||\n                liveRunning ||\n                record.status == TaskStatus.enqueued;\n      // Pre-JobStore migration fallback above is deliberately isolated to rows\n      // without durable lifecycle authority.\n      if (!inSession) continue;\n'''
if source.count(old_start) != 1:
    raise SystemExit(f'overlay start anchor mismatch: {source.count(old_start)}')
source = source.replace(old_start, new_start, 1)

old_status = '''      final displayStatus = displayDownloadStatus(\n        persisted: liveRunning ? TaskStatus.running : record.status,\n        queueWaiting: leftoverWaiting && !liveRunning,\n      );\n'''
new_status = '''      final displayStatus = job != null\n          ? downloadJobDisplayStatus(job.state)\n          : displayDownloadStatus(\n              persisted: liveRunning ? TaskStatus.running : record.status,\n              queueWaiting: leftoverWaiting && !liveRunning,\n            );\n'''
if source.count(old_status) != 1:
    raise SystemExit(f'overlay display status anchor mismatch: {source.count(old_status)}')
source = source.replace(old_status, new_status, 1)

old_episode = '''          episodeKey: _overlayEpisodeKeyForTask(record.task),\n'''
new_episode = '''          episodeKey: logicalId ?? _overlayEpisodeKeyForTask(record.task),\n'''
if source.count(old_episode) != 1:
    raise SystemExit(f'overlay episode key anchor mismatch: {source.count(old_episode)}')
source = source.replace(old_episode, new_episode, 1)

old_waiter_loop = '''    for (final payload in _waitingPayloads.entries) {\n      if (seen.contains(payload.key)) continue;\n      _rememberSessionTask(payload.key);\n      entries.add(\n        DownloadOverlayEntry(\n          taskId: payload.key,\n          status: TaskStatus.enqueued,\n          displayName: payload.value['displayName'] as String? ?? '',\n          queueWaiting: true,\n          episodeKey: _overlayEpisodeKeyFromParts(\n            taskId: payload.key,\n            trackingUrl: payload.value['metaData'] as String? ?? '',\n            url: payload.value['url'] as String? ?? '',\n            directory: payload.value['directory'] as String? ?? '',\n            filename: payload.value['filename'] as String? ?? '',\n          ),\n        ),\n      );\n    }\n'''
new_waiter_loop = '''    for (final payload in _waitingPayloads.entries) {\n      if (seen.contains(payload.key)) continue;\n      final job = await _jobStore.get(payload.key);\n      final metadata = await storage.getDownloadMetadata(payload.key);\n      final logicalId =\n          job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);\n      _rememberSessionTask(payload.key);\n      entries.add(\n        DownloadOverlayEntry(\n          taskId: payload.key,\n          status: job != null\n              ? downloadJobDisplayStatus(job.state)\n              : TaskStatus.enqueued,\n          displayName: payload.value['displayName'] as String? ?? '',\n          queueWaiting: job != null\n              ? downloadJobQueueWaiting(job.state)\n              : true,\n          episodeKey: logicalId ??\n              _overlayEpisodeKeyFromParts(\n                taskId: payload.key,\n                trackingUrl: payload.value['metaData'] as String? ?? '',\n                url: payload.value['url'] as String? ?? '',\n                directory: payload.value['directory'] as String? ?? '',\n                filename: payload.value['filename'] as String? ?? '',\n              ),\n        ),\n      );\n    }\n'''
if source.count(old_waiter_loop) != 1:
    raise SystemExit(f'overlay waiter loop anchor mismatch: {source.count(old_waiter_loop)}')
source = source.replace(old_waiter_loop, new_waiter_loop, 1)

old_payload = '''  ) async {\n    final payload = Map<String, Object>.from(_waitingPayloadFor(task));\n    if (task is! ParallelDownloadTask) {\n'''
new_payload = '''  ) async {\n    final payload = Map<String, Object>.from(_waitingPayloadFor(task));\n    final metadata = await _ref\n        .read(storageServiceProvider)\n        .getDownloadMetadata(task.taskId);\n    final job = await _jobStore.get(task.taskId);\n    final logicalId = job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);\n    if (logicalId != null && logicalId.isNotEmpty) {\n      payload['logicalId'] = logicalId;\n    }\n    if (task is! ParallelDownloadTask) {\n'''
# Restrict to the preserving-bytes function by slicing around its declaration.
method_index = source.index('Future<Map<String, Object>> _waitingPayloadPreservingBytes(')
if method_index < 0:
    raise SystemExit('waiting payload method missing')
anchor_index = source.find(old_payload, method_index)
if anchor_index < 0:
    raise SystemExit('waiting payload body anchor missing')
source = source[:anchor_index] + new_payload + source[anchor_index + len(old_payload):]

path.write_text(source)
