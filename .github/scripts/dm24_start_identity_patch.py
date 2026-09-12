from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'{label} anchor mismatch: {count}')
    source = source.replace(old, new, 1)

replace_once(
    "import 'download_job_store.dart';\n",
    "import 'download_job_store.dart';\nimport 'download_logical_identity.dart';\n",
    'logical identity import',
)

replace_once(
    "    diagnosticLog.record('command.start', {'total': totalBytes});\n",
    """    final logicalId = DownloadLogicalIdentity.fromMedia(\n      item: item,\n      episode: episode,\n    ).key;\n    diagnosticLog.record('command.start', {\n      'total': totalBytes,\n      'logicalId': logicalId,\n    });\n""",
    'start logical id',
)

old_existing = '''      // Prevention: Check if task is ALREADY running (using database for robustness)\n      final records = await FileDownloader().database.allRecords();\n      final existingRecord = records.firstWhereOrNull(\n        (r) =>\n            (isLogicalEpisodeDownloadTask(r.task)) &&\n            (r.status == TaskStatus.failed ||\n                r.status == TaskStatus.notFound ||\n                r.status == TaskStatus.enqueued ||\n                r.status == TaskStatus.running ||\n                r.status == TaskStatus.paused ||\n                r.status == TaskStatus.waitingToRetry) &&\n            (r.task.metaData.isNotEmpty ? r.task.metaData : r.task.url) ==\n                (trackingUrl ?? url),\n      );\n'''
new_existing = '''      // Canonical logical identity is the primary duplicate/adoption key. A\n      // signed URL, filename or execution taskId may rotate between attempts.\n      final records = await FileDownloader().database.allRecords();\n      final recordsById = <String, TaskRecord>{\n        for (final record in records) record.task.taskId: record,\n      };\n      final logicalJobs = await _jobStore.allForLogicalId(logicalId);\n      DownloadJobRecord? existingLogicalJob;\n      TaskRecord? existingRecord;\n      for (final job in logicalJobs.reversed) {\n        if (job.state == DownloadJobState.completed ||\n            job.state == DownloadJobState.canceled ||\n            job.state == DownloadJobState.orphaned) {\n          continue;\n        }\n        final projected = recordsById[job.taskId];\n        if (projected != null && isLogicalEpisodeDownloadTask(projected.task)) {\n          existingLogicalJob = job;\n          existingRecord = projected;\n          break;\n        }\n        final restored = job.restoreTaskSnapshot();\n        if (restored == null || !isLogicalEpisodeDownloadTask(restored)) continue;\n        final progress = job.expectedBytes > 0\n            ? (job.durableBytes / job.expectedBytes).clamp(0.0, 1.0)\n            : 0.0;\n        existingLogicalJob = job;\n        existingRecord = TaskRecord(\n          restored,\n          downloadJobTaskStatus(job.state),\n          progress,\n          job.expectedBytes,\n        );\n        // Repair a lost executor projection; this does not start a writer.\n        await FileDownloader().database.updateRecord(existingRecord);\n        break;\n      }\n\n      // Pre-logical-identity migration fallback: old rows may not yet have a\n      // canonical key. Keep the historical tracking-URL lookup only for them.\n      existingRecord ??= records.firstWhereOrNull(\n        (r) =>\n            (isLogicalEpisodeDownloadTask(r.task)) &&\n            (r.status == TaskStatus.failed ||\n                r.status == TaskStatus.notFound ||\n                r.status == TaskStatus.enqueued ||\n                r.status == TaskStatus.running ||\n                r.status == TaskStatus.paused ||\n                r.status == TaskStatus.waitingToRetry) &&\n            (r.task.metaData.isNotEmpty ? r.task.metaData : r.task.url) ==\n                (trackingUrl ?? url),\n      );\n'''
replace_once(old_existing, new_existing, 'existing task lookup')

replace_once(
    '''        final occupying = occupiesDownloadSlot(\n          status: existingRecord.status,\n          queueWaiting: _queueWaitingIds.contains(existingRecord.task.taskId),\n        );\n''',
    '''        final authoritativeJob =\n            existingLogicalJob ?? await _jobStore.get(existingRecord.task.taskId);\n        final occupying = authoritativeJob != null\n            ? downloadJobOccupiesSlot(authoritativeJob.state)\n            : occupiesDownloadSlot(\n                status: existingRecord.status,\n                queueWaiting: _queueWaitingIds.contains(existingRecord.task.taskId),\n              );\n''',
    'existing occupancy authority',
)

replace_once(
    '''      final completeRecords = await _completeRecordsForEpisode(\n        records,\n        trackingUrl: tracking,\n        item: item,\n''',
    '''      final completeRecords = await _completeRecordsForEpisode(\n        records,\n        logicalId: logicalId,\n        trackingUrl: tracking,\n        item: item,\n''',
    'complete lookup call',
)

replace_once(
    '''          DownloadJobRecord(\n            taskId: transferTask.taskId,\n            trackingUrl: trackingUrl ?? url,\n''',
    '''          DownloadJobRecord(\n            taskId: transferTask.taskId,\n            logicalId: logicalId,\n            trackingUrl: trackingUrl ?? url,\n''',
    'fresh JobStore logical id',
)

replace_once(
    '''          trackingUrl: trackingUrl ?? url,\n          filePath: path,\n          taskSnapshot: transferTask.toJson(),\n''',
    '''          trackingUrl: trackingUrl ?? url,\n          filePath: path,\n          logicalId: logicalId,\n          taskSnapshot: transferTask.toJson(),\n''',
    'fresh metadata logical id',
)

old_complete = '''  Future<List<TaskRecord>> _completeRecordsForEpisode(\n    List<TaskRecord> records, {\n    required String trackingUrl,\n    required MultimediaItem item,\n    Episode? episode,\n    required String filename,\n    required String directory,\n  }) async {\n    final storage = _ref.read(storageServiceProvider);\n    final matches = <TaskRecord>[];\n    for (final record in records) {\n      if (record.status != TaskStatus.complete) continue;\n      final recordUrl = downloadTrackingUrl(record.task);\n      var matched =\n          recordUrl == trackingUrl ||\n          (episode?.url.trim().isNotEmpty == true &&\n              recordUrl == episode!.url.trim()) ||\n          taskMatchesDownloadFile(\n            task: record.task,\n            filename: filename,\n            directory: directory,\n          );\n      if (!matched) {\n        final metadata = await storage.getDownloadMetadata(record.task.taskId);\n        if (metadata != null) {\n          final storedTracking = (metadata['trackingUrl'] as String?)?.trim();\n          matched =\n              (storedTracking != null && storedTracking == trackingUrl) ||\n              metadataMatchesDownload(\n                item: item,\n                episode: episode,\n                candidateItem: MultimediaItem.fromJson(\n                  Map<String, dynamic>.from(metadata['item'] as Map),\n                ),\n                candidateEpisode: metadata['episode'] != null\n                    ? Episode.fromJson(\n                        Map<String, dynamic>.from(metadata['episode'] as Map),\n                      )\n                    : null,\n              );\n        }\n      }\n      if (matched) matches.add(record);\n    }\n    return matches;\n  }\n'''
new_complete = '''  Future<List<TaskRecord>> _completeRecordsForEpisode(\n    List<TaskRecord> records, {\n    required String logicalId,\n    required String trackingUrl,\n    required MultimediaItem item,\n    Episode? episode,\n    required String filename,\n    required String directory,\n  }) async {\n    final storage = _ref.read(storageServiceProvider);\n    final matches = <TaskRecord>[];\n    for (final record in records) {\n      if (record.status != TaskStatus.complete) continue;\n      final metadata = await storage.getDownloadMetadata(record.task.taskId);\n      final candidateLogicalId = logicalDownloadIdFromMetadata(metadata);\n      if (candidateLogicalId != null) {\n        if (candidateLogicalId == logicalId) matches.add(record);\n        continue;\n      }\n\n      // Pre-logical-identity migration fallback. Only rows that genuinely lack\n      // reconstructable presentation identity may use URL/path heuristics.\n      final recordUrl = downloadTrackingUrl(record.task);\n      var matched =\n          recordUrl == trackingUrl ||\n          (episode?.url.trim().isNotEmpty == true &&\n              recordUrl == episode!.url.trim()) ||\n          taskMatchesDownloadFile(\n            task: record.task,\n            filename: filename,\n            directory: directory,\n          );\n      if (!matched && metadata != null && metadata['item'] is Map) {\n        final storedTracking = (metadata['trackingUrl'] as String?)?.trim();\n        matched =\n            (storedTracking != null && storedTracking == trackingUrl) ||\n            metadataMatchesDownload(\n              item: item,\n              episode: episode,\n              candidateItem: MultimediaItem.fromJson(\n                Map<String, dynamic>.from(metadata['item'] as Map),\n              ),\n              candidateEpisode: metadata['episode'] is Map\n                  ? Episode.fromJson(\n                      Map<String, dynamic>.from(metadata['episode'] as Map),\n                    )\n                  : null,\n            );\n      }\n      if (matched) matches.add(record);\n    }\n    return matches;\n  }\n'''
replace_once(old_complete, new_complete, 'complete record identity matching')

path.write_text(source)
