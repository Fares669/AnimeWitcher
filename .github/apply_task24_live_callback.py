from pathlib import Path

path = Path('lib/core/services/download_service.dart')
text = path.read_text()
old = '''      if (live != null && update.task is! ParallelDownloadTask) {
        await _attachToLiveNativeTask(update.task as DownloadTask, live: live);
        return;
      }
'''
new = '''      if (live != null) {
        await _attachToLiveNativeTask(update.task as DownloadTask, live: live);
        return;
      }
'''
count = text.count(old)
if count != 1:
    raise SystemExit(f'live callback anchor count={count}')
path.write_text(text.replace(old, new, 1))
