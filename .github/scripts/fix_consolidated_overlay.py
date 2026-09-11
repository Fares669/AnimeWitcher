from pathlib import Path

path = Path('lib/core/services/download_service.dart')
s = path.read_text()

old = """      final job = await _jobStore.get(record.task.taskId);
      final trackingUrl = downloadTrackingUrl(record.task);
"""
new = """      final job = await _jobStore.get(record.task.taskId);
      final metadata = await storage.getDownloadMetadata(record.task.taskId);
      final logicalId =
          job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);
      final trackingUrl = downloadTrackingUrl(record.task);
"""
if s.count(old) != 1:
    raise SystemExit(f'record overlay anchor mismatch: {s.count(old)}')
s = s.replace(old, new, 1)

old = """    for (final payload in _waitingPayloads.entries) {
      if (seen.contains(payload.key)) continue;
      _rememberSessionTask(payload.key);
      final job = await _jobStore.get(payload.key);
      final payloadLogicalId = (payload.value['logicalId'] as String?)?.trim();
"""
new = """    for (final payload in _waitingPayloads.entries) {
      if (seen.contains(payload.key)) continue;
      final job = await _jobStore.get(payload.key);
      if (job != null && !downloadJobQueueWaiting(job.state)) continue;
      _rememberSessionTask(payload.key);
      final payloadLogicalId = (payload.value['logicalId'] as String?)?.trim();
"""
if s.count(old) != 1:
    raise SystemExit(f'payload overlay anchor mismatch: {s.count(old)}')
s = s.replace(old, new, 1)

path.write_text(s)
