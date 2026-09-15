from pathlib import Path

policy = Path('lib/core/services/download_transport_policy.dart')
text = policy.read_text()
anchor = '''enum DownloadExecutionBackend {\n  pluginSingle,\n  pluginParallel,\n  legacyParallel,\n}\n'''
addition = anchor + '''\n/// Executor that owns control operations for an already-created logical task.\n///\n/// [ParallelDownloadTask] is only a task shape: both background_downloader and\n/// AnimeWitcher's legacy multipart executor use it. A positive legacy manifest\n/// query is therefore the only reason to route pause/cancel/source mutation to\n/// the legacy coordinator. Query failure stays unknown and fails closed.\nenum DownloadExecutorControlTarget { plugin, legacy, unknown }\n\nDownloadExecutorControlTarget selectDownloadExecutorControlTarget({\n  required bool isParallelTask,\n  required bool legacyQuerySucceeded,\n  required bool legacySessionExists,\n}) {\n  if (!isParallelTask) return DownloadExecutorControlTarget.plugin;\n  if (!legacyQuerySucceeded) return DownloadExecutorControlTarget.unknown;\n  return legacySessionExists\n      ? DownloadExecutorControlTarget.legacy\n      : DownloadExecutorControlTarget.plugin;\n}\n'''
if text.count(anchor) != 1:
    raise SystemExit(f'backend enum anchor count={text.count(anchor)}')
text = text.replace(anchor, addition, 1)
policy.write_text(text)

service = Path('lib/core/services/download_service.dart')
text = service.read_text()

pause_anchor = '''  Future<bool> _pauseTransfer(DownloadTask task) async {\n    if (_rangeTransfers.isActive(task.taskId)) {\n      await _rangeTransfers.stop(task.taskId);\n      return true;\n    }\n    if (task is ParallelDownloadTask && await _parallel.restore(task)) {\n      return _parallel.pause(\n        task,\n        preserveLiveParts:\n            Platform.isIOS && _userPausedIds.contains(task.taskId),\n      );\n    }\n\n    final settled = Completer<void>();\n'''
pause_replacement = '''  Future<DownloadExecutorControlTarget> _controlTargetFor(\n    DownloadTask task,\n  ) async {\n    if (task is! ParallelDownloadTask) {\n      return selectDownloadExecutorControlTarget(\n        isParallelTask: false,\n        legacyQuerySucceeded: false,\n        legacySessionExists: false,\n      );\n    }\n    try {\n      final legacySessionExists = await _parallel.restore(task);\n      return selectDownloadExecutorControlTarget(\n        isParallelTask: true,\n        legacyQuerySucceeded: true,\n        legacySessionExists: legacySessionExists,\n      );\n    } catch (error) {\n      diagnosticLog.record('executor.controlEvidenceUnavailable', {\n        'taskId': task.taskId,\n        'error': error.toString(),\n      });\n      return selectDownloadExecutorControlTarget(\n        isParallelTask: true,\n        legacyQuerySucceeded: false,\n        legacySessionExists: false,\n      );\n    }\n  }\n\n  Future<bool> _pauseTransfer(DownloadTask task) async {\n    if (_rangeTransfers.isActive(task.taskId)) {\n      await _rangeTransfers.stop(task.taskId);\n      return true;\n    }\n    final controlTarget = await _controlTargetFor(task);\n    if (controlTarget == DownloadExecutorControlTarget.unknown) return false;\n    if (controlTarget == DownloadExecutorControlTarget.legacy) {\n      if (task is! ParallelDownloadTask) return false;\n      return _parallel.pause(\n        task,\n        preserveLiveParts:\n            Platform.isIOS && _userPausedIds.contains(task.taskId),\n      );\n    }\n\n    final settled = Completer<void>();\n'''
if text.count(pause_anchor) != 1:
    raise SystemExit(f'pause anchor count={text.count(pause_anchor)}')
text = text.replace(pause_anchor, pause_replacement, 1)

system_old = '''    final didPause = downloadTask is ParallelDownloadTask\n        ? await _parallel.pause(downloadTask, preserveLiveParts: Platform.isIOS)\n        : await _nativeTransport.pause(downloadTask);\n'''
system_new = '''    final didPause = await _pauseTransfer(downloadTask);\n'''
if text.count(system_old) != 1:
    raise SystemExit(f'system cancel pause anchor count={text.count(system_old)}')
text = text.replace(system_old, system_new, 1)

cancel_start = text.index('      final ids = <String>{taskId};', text.index('Future<void> cancelDownload('))
cancel_end = text.index('      final cancelOwnership = await _waitForCancelOwnershipRelease(taskId);', cancel_start)
new_cancel = '''      if (cancelTask == null) {\n        diagnosticLog.record('cancel.executorUnknown', {\n          'taskId': taskId,\n          'reason': 'missingTaskDescriptor',\n        });\n        await _persistNativeWaitingSnapshot();\n        if (notifyContinuedProcessing) {\n          await _syncSessionOverlay(completedSuccess: false);\n        }\n        return;\n      }\n\n      final controlTarget = await _controlTargetFor(cancelTask);\n      switch (controlTarget) {\n        case DownloadExecutorControlTarget.legacy:\n          if (cancelTask is! ParallelDownloadTask) {\n            diagnosticLog.record('cancel.executorUnknown', {\n              'taskId': taskId,\n              'reason': 'legacyTargetWithoutParallelTask',\n            });\n            await _persistNativeWaitingSnapshot();\n            if (notifyContinuedProcessing) {\n              await _syncSessionOverlay(completedSuccess: false);\n            }\n            return;\n          }\n          await _parallel.cancel(cancelTask);\n          break;\n        case DownloadExecutorControlTarget.plugin:\n          final settlement = await _nativeTransport.cancel(cancelTask);\n          diagnosticLog.record('cancel.commandSettlement', {\n            'taskId': taskId,\n            'settlement': settlement.name,\n            'executor': 'plugin',\n          });\n          break;\n        case DownloadExecutorControlTarget.unknown:\n          diagnosticLog.record('cancel.executorUnknown', {\n            'taskId': taskId,\n            'reason': 'legacyEvidenceUnavailable',\n          });\n          await _persistNativeWaitingSnapshot();\n          if (notifyContinuedProcessing) {\n            await _syncSessionOverlay(completedSuccess: false);\n          }\n          return;\n      }\n\n      // The selected owner is responsible for its implementation-detail\n      // chunks. Only cancel any additional *logical* duplicate rows here;\n      // manually canceling FileDownloader.chunkGroup children can race the\n      // plugin parent's own settlement/resume-data handling.\n      final duplicateLogicalIds = <String>[];\n      for (final task in await FileDownloader().allTasks(allGroups: true)) {\n        if (task.taskId == taskId ||\n            isInternalDownloaderChunk(task) ||\n            downloadTrackingUrl(task) != trackingUrl) {\n          continue;\n        }\n        if (isLogicalEpisodeDownloadTask(task)) {\n          duplicateLogicalIds.add(task.taskId);\n        }\n      }\n      if (duplicateLogicalIds.isNotEmpty) {\n        await FileDownloader().cancelTasksWithIds(duplicateLogicalIds);\n      }\n\n'''
text = text[:cancel_start] + new_cancel + text[cancel_end:]
service.write_text(text)

test = Path('test/core/services/download_plugin_parallel_cancel_routing_test.dart')
text = test.read_text().replace('\n// Task 22 RED trigger\n', '\n')
test.write_text(text)

# trigger one-shot workflow after its definition exists
