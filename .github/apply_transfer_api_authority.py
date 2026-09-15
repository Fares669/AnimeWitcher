from pathlib import Path

path = Path('lib/core/services/background_downloader_transport.dart')
text = path.read_text()

old_start = '''  @override\n  Future<bool> start(DownloadTask task) async {\n    if (!isBackgroundDownloaderTransportTask(task)) return false;\n\n    final existing = handleFor(task.taskId);\n    if (existing != null && runtimeTaskStatusCanOwnWriter(existing.status)) {\n      _attach(existing);\n      return true;\n    }\n\n    try {\n      // Callers may reach fresh start only after logical reconciliation proved\n      // that another writer cannot own this identity and durable bytes do not\n      // require a stricter resume path.\n      final transfer = await _downloader.transfers.start(task);\n      _attach(transfer);\n      return runtimeTaskStatusCanOwnWriter(transfer.status) ||\n          transfer.status == TaskStatus.complete;\n    } catch (_) {\n      return false;\n    }\n  }\n'''
new_start = '''  @override\n  Future<bool> start(DownloadTask task) async {\n    if (!isBackgroundDownloaderTransportTask(task)) return false;\n\n    try {\n      // Let background_downloader own duplicate lookup and database\n      // reattachment. Callers reach this method only after logical\n      // reconciliation has fenced competing writers, so a persisted failed or\n      // paused transfer is returned but never re-enqueued implicitly here.\n      final transfer = await _downloader.transfers.getOrStart(\n        task,\n        matchBy: (existingTask) => existingTask.taskId == task.taskId,\n        reEnqueueIfFailed: false,\n      );\n      _attach(transfer);\n      return runtimeTaskStatusCanOwnWriter(transfer.status) ||\n          transfer.status == TaskStatus.complete;\n    } catch (_) {\n      return false;\n    }\n  }\n'''
if text.count(old_start) != 1:
    raise SystemExit(f'start anchor count={text.count(old_start)}')
text = text.replace(old_start, new_start, 1)

old_resume = '''  @override\n  Future<bool> resume(DownloadTask task) async {\n    if (!isBackgroundDownloaderTransportTask(task)) return false;\n    try {\n      // Use the low-level resume API so missing resume data returns false and\n      // AnimeWitcher can fall back to its verified on-disk Range recovery.\n      final resumed = await _downloader.resume(task);\n      if (!resumed) return false;\n      final transfer = await _downloader.transfers.getOrStart(\n        task,\n        matchBy: (existingTask) => existingTask.taskId == task.taskId,\n        reEnqueueIfFailed: false,\n      );\n      _attach(transfer);\n      return true;\n    } catch (_) {\n      return false;\n    }\n  }\n'''
new_resume = '''  @override\n  Future<bool> resume(DownloadTask task) async {\n    if (!isBackgroundDownloaderTransportTask(task)) return false;\n    try {\n      final transfer = await _downloader.transfers.getOrStart(\n        task,\n        matchBy: (existingTask) => existingTask.taskId == task.taskId,\n        reEnqueueIfFailed: false,\n      );\n      _attach(transfer);\n\n      // Transfers.getOrStart may reconnect to an already-running/completed\n      // execution. Otherwise delegate resume-data handling and the documented\n      // re-enqueue fallback to Transfer.resume() instead of duplicating it.\n      if (transfer.status == TaskStatus.complete ||\n          runtimeTaskStatusCanOwnWriter(transfer.status)) {\n        return true;\n      }\n      return await transfer.resume();\n    } catch (_) {\n      return false;\n    }\n  }\n'''
if text.count(old_resume) != 1:
    raise SystemExit(f'resume anchor count={text.count(old_resume)}')
text = text.replace(old_resume, new_resume, 1)
path.write_text(text)

test = Path('test/core/services/background_downloader_transfer_api_authority_test.dart')
content = test.read_text().replace('\n// Transfer API authority RED trigger\n', '\n')
test.write_text(content)

# trigger one-shot workflow after its definition exists
