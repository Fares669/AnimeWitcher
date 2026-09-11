from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()

old_start = '''    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final trackingUrl = downloadTrackingUrl(record.task);
      final live = liveProgress[trackingUrl];
      final leftoverWaiting = _queueWaitingIds.contains(record.task.taskId);
      final liveRunning = live?.status == TaskStatus.running;
      final inSession =
          _sessionOrder.contains(record.task.taskId) ||
          occupiesDownloadSlot(
            status: record.status,
            queueWaiting: leftoverWaiting,
          ) ||
          leftoverWaiting ||
          liveRunning ||
          record.status == TaskStatus.enqueued;
      if (!inSession) continue;
'''
new_start = '''    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final job = await _jobStore.get(record.task.taskId);
      final trackingUrl = downloadTrackingUrl(record.task);
      final live = liveProgress[trackingUrl];
      final liveRunning = live?.status == TaskStatus.running;
      final leftoverWaiting = job != null
          ? downloadJobQueueWaiting(job.state)
          : _queueWaitingIds.contains(record.task.taskId);
      final inSession = job != null
          ? _sessionOrder.contains(record.task.taskId) ||
                downloadJobOccupiesSlot(job.state) ||
                leftoverWaiting ||
                liveRunning
          : _sessionOrder.contains(record.task.taskId) ||
                occupiesDownloadSlot(
                  status: record.status,
                  queueWaiting: leftoverWaiting,
                ) ||
                leftoverWaiting ||
                liveRunning ||
                record.status == TaskStatus.enqueued;
      // Pre-JobStore migration fallback above is deliberately isolated to rows
      // without durable lifecycle authority.
      if (!inSession) continue;
'''
if source.count(old_start) != 1:
    raise SystemExit(f'overlay start anchor mismatch: {source.count(old_start)}')
source = source.replace(old_start, new_start, 1)

old_status = '''      final displayStatus = displayDownloadStatus(
        persisted: liveRunning ? TaskStatus.running : record.status,
        queueWaiting: leftoverWaiting && !liveRunning,
      );
'''
new_status = '''      final displayStatus = job != null
          ? downloadJobDisplayStatus(job.state)
          : displayDownloadStatus(
              persisted: liveRunning ? TaskStatus.running : record.status,
              queueWaiting: leftoverWaiting && !liveRunning,
            );
'''
if source.count(old_status) != 1:
    raise SystemExit(f'overlay status anchor mismatch: {source.count(old_status)}')
source = source.replace(old_status, new_status, 1)

path.write_text(source)
