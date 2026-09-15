from pathlib import Path

service = Path('lib/core/services/download_service.dart')
text = service.read_text()

old_can_resume = '''    final canNativeResume =\n        task is! ParallelDownloadTask && await _canNativeResume(task);\n'''
new_can_resume = '''    final canNativeResume = await _canNativeResume(task);\n'''
if text.count(old_can_resume) != 1:
    raise SystemExit(f'canNativeResume anchor count={text.count(old_can_resume)}')
text = text.replace(old_can_resume, new_can_resume, 1)

old_opaque = '''    if (task is! ParallelDownloadTask &&\n        hasOpaqueNativeResume &&\n        partialBytes <= 0) {\n      // We proved the old source needs replacement and also proved that the\n      // only resumable bytes are opaque native resume data tied to that old\n      // source. The replacement itself is valid, but those bytes cannot be\n      // migrated safely, so leave durable/source state untouched and require an\n      // explicit user-visible restart decision.\n      return (task: task, refreshed: false, restartRequired: true);\n    }\n\n'''
new_opaque = '''    var legacySessionExists = false;\n    if (task is ParallelDownloadTask) {\n      try {\n        legacySessionExists = await _parallel.restore(task);\n      } catch (error) {\n        // A failed legacy-evidence query is ambiguous. Never guess that a\n        // ParallelDownloadTask belongs to either executor while changing its\n        // remote source.\n        diagnosticLog.record('source.refreshLegacyEvidenceUnavailable', {\n          'taskId': task.taskId,\n          'error': error.toString(),\n        });\n        return (task: task, refreshed: false, restartRequired: false);\n      }\n    }\n\n    if (!legacySessionExists &&\n        hasOpaqueNativeResume &&\n        partialBytes <= 0) {\n      // background_downloader 9.6.1 owns plugin resume/re-enqueue. Its\n      // ParallelDownloadTask resume payload, however, contains the original\n      // child task descriptors and there is no public API to rewrite those\n      // child URLs. Never migrate that plugin state into AnimeWitcher's legacy\n      // executor and never discard opaque bytes silently. A user-visible\n      // restart decision is safer until the plugin exposes source replacement\n      // for paused parallel chunks.\n      return (task: task, refreshed: false, restartRequired: true);\n    }\n\n'''
if text.count(old_opaque) != 1:
    raise SystemExit(f'opaque refresh anchor count={text.count(old_opaque)}')
text = text.replace(old_opaque, new_opaque, 1)

old_parallel = '''    if (task is ParallelDownloadTask) {\n      final replaced = await _parallel.replaceSource(\n        task,\n        url: refreshed.url,\n        headers: refreshed.headers,\n      );\n      return replaced == null\n          ? (task: task, refreshed: false, restartRequired: false)\n          : (task: replaced, refreshed: true, restartRequired: false);\n    }\n\n'''
new_parallel = '''    if (legacySessionExists) {\n      final replaced = await _parallel.replaceSource(\n        task as ParallelDownloadTask,\n        url: refreshed.url,\n        headers: refreshed.headers,\n      );\n      return replaced == null\n          ? (task: task, refreshed: false, restartRequired: false)\n          : (task: replaced, refreshed: true, restartRequired: false);\n    }\n\n'''
if text.count(old_parallel) != 1:
    raise SystemExit(f'parallel refresh anchor count={text.count(old_parallel)}')
text = text.replace(old_parallel, new_parallel, 1)
service.write_text(text)

test = Path('test/core/services/download_plugin_source_refresh_routing_test.dart')
content = test.read_text().replace('\n// Task 25 source refresh RED trigger\n', '\n')
test.write_text(content)
