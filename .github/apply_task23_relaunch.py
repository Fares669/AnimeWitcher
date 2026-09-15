from pathlib import Path

transport = Path('lib/core/services/background_downloader_transport.dart')
text = transport.read_text()
old_resume = '''  @override
  Future<bool> resume(DownloadTask task) async {
    if (!isBackgroundDownloaderTransportTask(task)) return false;
    try {
      final transfer = await _downloader.transfers.getOrStart(
        task,
        matchBy: (existingTask) => existingTask.taskId == task.taskId,
        reEnqueueIfFailed: false,
      );
      _attach(transfer);

      // Transfers.getOrStart may reconnect to an already-running/completed
      // execution. Otherwise delegate resume-data handling and the documented
      // re-enqueue fallback to Transfer.resume() instead of duplicating it.
      if (transfer.status == TaskStatus.complete ||
          runtimeTaskStatusCanOwnWriter(transfer.status)) {
        return true;
      }
      return await transfer.resume();
    } catch (_) {
      return false;
    }
  }
'''
new_resume = '''  @override
  Future<bool> resume(DownloadTask task) async {
    if (!isBackgroundDownloaderTransportTask(task)) return false;
    try {
      // Resume is a reconnect operation, never a start operation. A process
      // relaunch can leave plugin-owned parallel chunks alive while the parent
      // database projection is missing. Calling Transfers.getOrStart here
      // would be allowed to enqueue a replacement parent and create a second
      // writer/chunk generation. Rehydrate only what background_downloader
      // already knows, then let that existing Transfer own resume semantics.
      var transfer = handleFor(task.taskId);
      if (transfer == null) {
        await _downloader.transfers.rehydrateFromDatabase(group: task.group);
        transfer = handleFor(task.taskId);
      }
      if (transfer == null) return false;
      _attach(transfer);

      if (transfer.status == TaskStatus.complete ||
          runtimeTaskStatusCanOwnWriter(transfer.status)) {
        return true;
      }
      return await transfer.resume();
    } catch (_) {
      return false;
    }
  }
'''
if text.count(old_resume) != 1:
    raise SystemExit(f'transport resume anchor count={text.count(old_resume)}')
transport.write_text(text.replace(old_resume, new_resume, 1))

service = Path('lib/core/services/download_service.dart')
text = service.read_text()
old_parallel = '''      if (pluginParentKnown || pluginChunkEvidence) {
        var pluginResumed = false;
        try {
          pluginResumed = await _nativeTransport.resume(task);
        } catch (_) {
          pluginResumed = false;
        }
        diagnosticLog.record('resume.pluginParallel', {
          'taskId': task.taskId,
          'accepted': pluginResumed,
          'parentKnown': pluginParentKnown,
          'chunkEvidence': pluginChunkEvidence,
        });
        if (pluginResumed) return true;

        final ownership = await _runtimeOwnershipFor(task.taskId);
        diagnosticLog.record('resume.pluginParallelDeferred', {
          'taskId': task.taskId,
          'ownership': ownership.name,
        });
        // Never convert a known plugin parent/chunk set into AnimeWitcher's
        // legacy multipart executor, and never silently enqueue fresh chunks.
        return false;
      }
'''
new_parallel = '''      if (pluginParentKnown) {
        var pluginResumed = false;
        try {
          pluginResumed = await _nativeTransport.resume(task);
        } catch (_) {
          pluginResumed = false;
        }
        diagnosticLog.record('resume.pluginParallel', {
          'taskId': task.taskId,
          'accepted': pluginResumed,
          'parentKnown': true,
          'chunkEvidence': pluginChunkEvidence,
        });
        if (pluginResumed) return true;

        final ownership = await _runtimeOwnershipFor(task.taskId);
        diagnosticLog.record('resume.pluginParallelDeferred', {
          'taskId': task.taskId,
          'ownership': ownership.name,
        });
        // The plugin parent exists but did not settle resume. Never replace it
        // with AnimeWitcher's legacy executor or a fresh parent.
        return false;
      }

      if (pluginChunkEvidence) {
        // background_downloader.start(doRescheduleKilledTasks: true) already
        // owns killed-task recovery. If only child runtime evidence survives,
        // the logical parent projection is incomplete: do not manufacture a
        // replacement parent and risk a second writer/chunk generation.
        diagnosticLog.record('resume.pluginParallelDeferred', {
          'taskId': task.taskId,
          'ownership': DownloadRuntimeOwnership.unknown.name,
          'reason': 'parentProjectionMissing',
        });
        return false;
      }
'''
if text.count(old_parallel) != 1:
    raise SystemExit(f'parallel resume anchor count={text.count(old_parallel)}')
service.write_text(text.replace(old_parallel, new_parallel, 1))

# Diagnostic trigger only; production patch content above is unchanged.
