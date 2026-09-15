from pathlib import Path

path = Path('lib/core/services/download_service.dart')
text = path.read_text()
old = '''      if (update is TaskStatusUpdate &&
          update.status == TaskStatus.paused &&
          (_rangeTransfers.isActive(update.task.taskId) ||
              _parallel.isActive(update.task.taskId) ||
              _nativeTransport.owns(update.task.taskId))) {
'''
new = '''      if (update is TaskStatusUpdate &&
          update.status == TaskStatus.paused &&
          (_rangeTransfers.isActive(update.task.taskId) ||
              _parallel.isActive(update.task.taskId) ||
              _nativeTransport.runtimeStatusCanOwnWriter(update.task.taskId))) {
'''
count = text.count(old)
if count != 1:
    raise SystemExit(f'stale-pause guard anchor count={count}')
path.write_text(text.replace(old, new, 1))
