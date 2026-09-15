from pathlib import Path

path = Path('lib/core/services/download_service.dart')
text = path.read_text()


def replace_once(old: str, new: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'expected exactly one match, found {count}: {old[:120]!r}')
    text = text.replace(old, new, 1)

replace_once(
    """        final stoppedRange = await _rangeTransfers.stop(taskId);\n        // Plugin pause produces URLSession resumeData and drops the\n        // transferring task so it no longer occupies a slot. Never cancel —\n        // cancel deletes the temp file and forces a restart from byte 0.\n        var didPause = false;\n        try {\n          didPause = await _pauseTransfer(\n            downloadTask,\n            rangeAlreadyStopped: stoppedRange,\n          );\n        } catch (_) {}\n""",
    """        await _rangeTransfers.stop(taskId);\n        // Plugin pause produces URLSession resumeData and drops the\n        // transferring task so it no longer occupies a slot. Never cancel —\n        // cancel deletes the temp file and forces a restart from byte 0.\n        var didPause = false;\n        try {\n          didPause = await _pauseTransfer(downloadTask);\n        } catch (_) {}\n""",
)

replace_once(
    """  Future<bool> _pauseTransfer(\n    DownloadTask task, {\n    bool rangeAlreadyStopped = false,\n  }) async {\n""",
    """  Future<bool> _pauseTransfer(DownloadTask task) async {\n""",
)

replace_once(
    """      if (!accepted) {\n        // pauseDownload already joined the Range writer before entering the\n        // control queue. A missing native task is expected in that case.\n        return rangeAlreadyStopped &&\n            await _runtimeOwnershipFor(task.taskId) ==\n                DownloadRuntimeOwnership.notOwned;\n      }\n""",
    """      if (!accepted) {\n        // A second pause against an already-paused plugin parent legitimately\n        // returns false. Command acknowledgement is not the authority here:\n        // if runtime ownership is already released, the requested pause is\n        // idempotently settled and must not leave the logical job in `pausing`.\n        final rejectedOwnership = await _runtimeOwnershipFor(task.taskId);\n        diagnosticLog.record('native.pauseRejectedOwnership', {\n          'taskId': task.taskId,\n          'ownership': rejectedOwnership.name,\n        });\n        return rejectedOwnership == DownloadRuntimeOwnership.notOwned;\n      }\n""",
)

replace_once(
    """    if (task is ParallelDownloadTask) {\n      if (await _parallel.restore(task))\n        return _parallel.start(task, saved.totalSize);\n      // Import completed/paused legacy chunks without using resumeChunkTasks,\n      // which cancels all siblings when one completed child cannot be resumed.\n      final data = await BackgroundDownloaderCompat.resumeDataForTaskId(\n        task.taskId,\n      );\n      if (data != null && data.data.isNotEmpty) {\n        await _parallel.importLegacy(task, data.data);\n        return _parallel.start(task, saved.totalSize);\n      }\n      // A historical percentage can survive after all multipart manifests and\n      // bytes are gone. Only actual surviving bytes may block a zero restart.\n      if (saved.partialBytes > 0) return false;\n      return _enqueueTransfer(task, saved.totalSize);\n    }\n""",
    """    if (task is ParallelDownloadTask) {\n      if (await _parallel.restore(task)) {\n        return _parallel.start(task, saved.totalSize);\n      }\n\n      // A plugin-owned ParallelDownloadTask must resume through the plugin as\n      // one logical parent. The previous code skipped this entirely and fell\n      // through to a fresh enqueue, which created a brand-new set of chunk IDs\n      // after every pause on iOS. Parent Transfer evidence or any reserved\n      // plugin chunk is enough to classify this as plugin-owned persistence.\n      final pluginParentKnown = _nativeTransport.handleFor(task.taskId) != null;\n      var pluginChunkEvidence = false;\n      try {\n        pluginChunkEvidence = (await FileDownloader().allTasks(allGroups: true))\n            .any(\n              (candidate) =>\n                  candidate.group == FileDownloader.chunkGroup &&\n                  downloadInternalParentTaskId(candidate) == task.taskId,\n            );\n      } catch (_) {\n        // An unavailable runtime inventory is ambiguous. Fail closed below\n        // instead of creating replacement writers for hidden plugin chunks.\n        pluginChunkEvidence = pluginParentKnown;\n      }\n\n      if (pluginParentKnown || pluginChunkEvidence) {\n        var pluginResumed = false;\n        try {\n          pluginResumed = await _nativeTransport.resume(task);\n        } catch (_) {\n          pluginResumed = false;\n        }\n        diagnosticLog.record('resume.pluginParallel', {\n          'taskId': task.taskId,\n          'accepted': pluginResumed,\n          'parentKnown': pluginParentKnown,\n          'chunkEvidence': pluginChunkEvidence,\n        });\n        if (pluginResumed) return true;\n\n        final ownership = await _runtimeOwnershipFor(task.taskId);\n        diagnosticLog.record('resume.pluginParallelDeferred', {\n          'taskId': task.taskId,\n          'ownership': ownership.name,\n        });\n        // Never convert a known plugin parent/chunk set into AnimeWitcher's\n        // legacy multipart executor, and never silently enqueue fresh chunks.\n        return false;\n      }\n\n      // Import only genuine pre-plugin legacy parent resume data. A current\n      // plugin parent was handled above and can never reach this migration seam.\n      final data = await BackgroundDownloaderCompat.resumeDataForTaskId(\n        task.taskId,\n      );\n      if (data != null && data.data.isNotEmpty) {\n        await _parallel.importLegacy(task, data.data);\n        return _parallel.start(task, saved.totalSize);\n      }\n      // A historical percentage can survive after all multipart manifests and\n      // bytes are gone. Only actual surviving bytes may block a zero restart.\n      if (saved.partialBytes > 0) return false;\n      return _enqueueTransfer(task, saved.totalSize);\n    }\n""",
)

path.write_text(text)
