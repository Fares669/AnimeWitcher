from pathlib import Path

p = Path('lib/core/services/download_service.dart')
text = p.read_text(encoding='utf-8')
old = """      if (!isLogicalEpisodeDownloadTask(task)) continue;
      if (task.taskId == taskId) return task;
      if (track.isNotEmpty && downloadTrackingUrl(task) == track) {
        return task;
      }
"""
new = """      if (!isLogicalEpisodeDownloadTask(task)) continue;
      final downloadTask = task as DownloadTask;
      if (downloadTask.taskId == taskId) return downloadTask;
      if (track.isNotEmpty && downloadTrackingUrl(downloadTask) == track) {
        return downloadTask;
      }
"""
if old not in text:
    raise RuntimeError('live native task type marker not found')
text = text.replace(old, new, 1)

# Enqueued logical parents already handed to the native downloader reserve a
# slot during the short enqueue->running transition. Do not treat them as safe
# to cancel/restack while another episode is being resumed.
text = text.replace(
    """      return occupiesDownloadSlot(
        status: record.status,
        queueWaiting: _queueWaitingIds.contains(taskId),
      );
""",
    """      return reservesDownloadSlot(
        status: record.status,
        queueWaiting: _queueWaitingIds.contains(taskId),
      );
""",
    1,
)
text = text.replace(
    """      if (record != null &&
          occupiesDownloadSlot(
            status: record.status,
            queueWaiting: _queueWaitingIds.contains(task.taskId),
          )) {
""",
    """      if (record != null &&
          reservesDownloadSlot(
            status: record.status,
            queueWaiting: _queueWaitingIds.contains(task.taskId),
          )) {
""",
    1,
)
p.write_text(text, encoding='utf-8')

# This import is unnecessary because repository methods delegate to
# StorageService and do not reference the parallel constants directly.
p = Path('lib/core/storage/settings_repository.dart')
text = p.read_text(encoding='utf-8')
text = text.replace("import '../services/download_parallel.dart';\n", '', 1)
p.write_text(text, encoding='utf-8')

print('Applied analyzer/type-flow fixes')
