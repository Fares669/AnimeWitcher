from pathlib import Path

service = Path('lib/core/services/download_service.dart')
text = service.read_text()
old = '''    if (canNativeResume && !refreshResult.refreshed) {
      var resumed = false;
      try {
        resumed = await _nativeTransport.resume(task);
      } catch (_) {
        resumed = false;
      }
      if (resumed) return true;
      if (saved.partialBytes <= 0) {
        // taskCanResume proves opaque native ownership existed, but the executor
        // could not adopt it. Never convert that hidden byte ownership into an
        // implicit zero-byte restart.
        throw _DownloadRestartRequiredException(task.taskId);
      }
    }

'''
new = '''    if (!refreshResult.refreshed) {
      // For an unchanged source, background_downloader owns the normal
      // resume-vs-reenqueue decision through Transfer.resume(). The app-level
      // taskCanResume probe above exists only to protect opaque bytes during a
      // signed-source replacement; it must not become a second lifecycle
      // policy for ordinary resume.
      var resumed = false;
      try {
        resumed = await _nativeTransport.resume(task);
      } catch (_) {
        resumed = false;
      }
      if (resumed) return true;

      // A missing/rejected Transfer is not permission to start another writer.
      // Settle targeted runtime ownership before falling back to durable app
      // recovery. Unknown/settling/owned all fail closed.
      final ownership = await _runtimeOwnershipFor(task.taskId);
      diagnosticLog.record('resume.pluginDeferred', {
        'taskId': task.taskId,
        'ownership': ownership.name,
        'opaqueNativeResume': canNativeResume,
      });
      if (ownership.blocksNewWriter) return false;

      if (canNativeResume && saved.partialBytes <= 0) {
        // The plugin reported opaque native resume state but its Transfer could
        // not adopt it. Never convert hidden bytes into an implicit zero-byte
        // restart outside background_downloader.
        throw _DownloadRestartRequiredException(task.taskId);
      }
    }

'''
if text.count(old) != 1:
    raise SystemExit(f'ordinary resume anchor count={text.count(old)}')
service.write_text(text.replace(old, new, 1))
