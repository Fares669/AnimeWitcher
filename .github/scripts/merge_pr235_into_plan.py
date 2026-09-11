from pathlib import Path


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'{label} anchor mismatch: {count}')
    return source.replace(old, new, 1)


# Consolidate the completed DM-05/DM-24 production work from PR #235 on top
# of the newer long-lived plan branch. Intentionally do not copy the agent's
# temporary workflows/scripts or its DM-06 RED-only probe.
service_path = Path('lib/core/services/download_service.dart')
service = service_path.read_text()

if "import 'download_logical_identity.dart';" not in service:
    service = replace_once(
        service,
        "import 'download_job_store.dart';\n",
        "import 'download_job_store.dart';\nimport 'download_logical_identity.dart';\n",
        'service logical identity import',
    )

if 'Pre-logical-identity migration fallback: mutable executor keys' not in service:
    service = replace_once(
        service,
        "  String _overlayEpisodeKeyFromParts({\n",
        "  // Pre-logical-identity migration fallback: mutable executor keys are\n"
        "  // consulted only when no canonical logical identity survives.\n"
        "  String _overlayEpisodeKeyFromParts({\n",
        'overlay migration marker',
    )

service = replace_once(
    service,
    "    final records = await FileDownloader().database.allRecords();\n"
    "    final liveProgress = _ref.read(downloadProgressProvider);\n"
    "    final entries = <DownloadOverlayEntry>[];\n",
    "    final records = await FileDownloader().database.allRecords();\n"
    "    final storage = _ref.read(storageServiceProvider);\n"
    "    final liveProgress = _ref.read(downloadProgressProvider);\n"
    "    final entries = <DownloadOverlayEntry>[];\n",
    'overlay storage handle',
)
service = replace_once(
    service,
    "      final job = await _jobStore.get(record.task.taskId);\n"
    "      final trackingUrl = downloadTrackingUrl(record.task);\n",
    "      final job = await _jobStore.get(record.task.taskId);\n"
    "      final metadata = await storage.getDownloadMetadata(record.task.taskId);\n"
    "      final logicalId =\n"
    "          job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);\n"
    "      final trackingUrl = downloadTrackingUrl(record.task);\n",
    'overlay record logical id',
)
service = replace_once(
    service,
    "          episodeKey: _overlayEpisodeKeyForTask(record.task),\n",
    "          episodeKey: logicalId ?? _overlayEpisodeKeyForTask(record.task),\n",
    'overlay episode key',
)
service = replace_once(
    service,
    "    for (final payload in _waitingPayloads.entries) {\n"
    "      if (seen.contains(payload.key)) continue;\n"
    "      _rememberSessionTask(payload.key);\n"
    "      entries.add(\n",
    "    for (final payload in _waitingPayloads.entries) {\n"
    "      if (seen.contains(payload.key)) continue;\n"
    "      _rememberSessionTask(payload.key);\n"
    "      final job = await _jobStore.get(payload.key);\n"
    "      final payloadLogicalId = (payload.value['logicalId'] as String?)?.trim();\n"
    "      entries.add(\n",
    'waiting overlay authority',
)
service = replace_once(
    service,
    "          status: TaskStatus.enqueued,\n"
    "          displayName: payload.value['displayName'] as String? ?? '',\n"
    "          queueWaiting: true,\n"
    "          episodeKey: _overlayEpisodeKeyFromParts(\n"
    "            taskId: payload.key,\n"
    "            trackingUrl: payload.value['metaData'] as String? ?? '',\n"
    "            url: payload.value['url'] as String? ?? '',\n"
    "            directory: payload.value['directory'] as String? ?? '',\n"
    "            filename: payload.value['filename'] as String? ?? '',\n"
    "          ),\n",
    "          status: job != null\n"
    "              ? downloadJobDisplayStatus(job.state)\n"
    "              : TaskStatus.enqueued,\n"
    "          displayName: payload.value['displayName'] as String? ?? '',\n"
    "          queueWaiting: job != null ? downloadJobQueueWaiting(job.state) : true,\n"
    "          episodeKey: payloadLogicalId != null && payloadLogicalId.isNotEmpty\n"
    "              ? payloadLogicalId\n"
    "              : _overlayEpisodeKeyFromParts(\n"
    "                  taskId: payload.key,\n"
    "                  trackingUrl: payload.value['metaData'] as String? ?? '',\n"
    "                  url: payload.value['url'] as String? ?? '',\n"
    "                  directory: payload.value['directory'] as String? ?? '',\n"
    "                  filename: payload.value['filename'] as String? ?? '',\n"
    "                ),\n",
    'waiting overlay projection',
)
service = replace_once(
    service,
    "    final payload = Map<String, Object>.from(_waitingPayloadFor(task));\n"
    "    if (task is! ParallelDownloadTask) {\n",
    "    final payload = Map<String, Object>.from(_waitingPayloadFor(task));\n"
    "    final job = await _jobStore.get(task.taskId);\n"
    "    final metadata = await _ref\n"
    "        .read(storageServiceProvider)\n"
    "        .getDownloadMetadata(task.taskId);\n"
    "    final logicalId = job?.logicalId ?? logicalDownloadIdFromMetadata(metadata);\n"
    "    if (logicalId != null && logicalId.isNotEmpty) {\n"
    "      payload['logicalId'] = logicalId;\n"
    "    }\n"
    "    if (task is! ParallelDownloadTask) {\n",
    'native waiter logical id',
)

service = replace_once(
    service,
    "    diagnosticLog.record('command.start', {'total': totalBytes});\n",
    "    final logicalId = DownloadLogicalIdentity.fromMedia(\n"
    "      item: item,\n"
    "      episode: episode,\n"
    "    ).key;\n"
    "    diagnosticLog.record('command.start', {\n"
    "      'total': totalBytes,\n"
    "      'logicalId': logicalId,\n"
    "    });\n",
    'start logical id',
)

old_start = """      // Prevention: Check if task is ALREADY running (using database for robustness)
      final records = await FileDownloader().database.allRecords();
      final existingRecord = records.firstWhereOrNull(
        (r) =>
            (isLogicalEpisodeDownloadTask(r.task)) &&
            (r.status == TaskStatus.failed ||
                r.status == TaskStatus.notFound ||
                r.status == TaskStatus.enqueued ||
                r.status == TaskStatus.running ||
                r.status == TaskStatus.paused ||
                r.status == TaskStatus.waitingToRetry) &&
            (r.task.metaData.isNotEmpty ? r.task.metaData : r.task.url) ==
                (trackingUrl ?? url),
      );

"""
new_start = """      // Canonical logical identity is the primary duplicate/adoption key. A
      // signed URL, filename or execution taskId may rotate between attempts.
      final records = await FileDownloader().database.allRecords();
      final recordsById = <String, TaskRecord>{
        for (final record in records) record.task.taskId: record,
      };
      final logicalJobs = await _jobStore.allForLogicalId(logicalId);
      DownloadJobRecord? existingLogicalJob;
      TaskRecord? existingRecord;
      for (final job in logicalJobs.reversed) {
        if (job.state == DownloadJobState.completed ||
            job.state == DownloadJobState.canceled ||
            job.state == DownloadJobState.orphaned) {
          continue;
        }
        final projected = recordsById[job.taskId];
        if (projected != null && isLogicalEpisodeDownloadTask(projected.task)) {
          existingLogicalJob = job;
          existingRecord = projected;
          break;
        }
        final restored = job.restoreTaskSnapshot();
        if (restored == null || !isLogicalEpisodeDownloadTask(restored)) {
          continue;
        }
        final progress = job.expectedBytes > 0
            ? (job.durableBytes / job.expectedBytes).clamp(0.0, 1.0)
            : 0.0;
        existingLogicalJob = job;
        existingRecord = TaskRecord(
          restored,
          downloadJobTaskStatus(job.state),
          progress,
          job.expectedBytes,
        );
        // Repair a lost executor projection; this does not start a writer.
        await FileDownloader().database.updateRecord(existingRecord);
        break;
      }

      // Pre-logical-identity migration fallback: old rows may not yet have a
      // canonical key. Keep the historical tracking-URL lookup only for them.
      existingRecord ??= records.firstWhereOrNull(
        (r) =>
            (isLogicalEpisodeDownloadTask(r.task)) &&
            (r.status == TaskStatus.failed ||
                r.status == TaskStatus.notFound ||
                r.status == TaskStatus.enqueued ||
                r.status == TaskStatus.running ||
                r.status == TaskStatus.paused ||
                r.status == TaskStatus.waitingToRetry) &&
            (r.task.metaData.isNotEmpty ? r.task.metaData : r.task.url) ==
                (trackingUrl ?? url),
      );

"""
service = replace_once(service, old_start, new_start, 'logical duplicate/adoption')
service = replace_once(
    service,
    "        final occupying = occupiesDownloadSlot(\n"
    "          status: existingRecord.status,\n"
    "          queueWaiting: _queueWaitingIds.contains(existingRecord.task.taskId),\n"
    "        );\n",
    "        final authoritativeJob =\n"
    "            existingLogicalJob ?? await _jobStore.get(existingRecord.task.taskId);\n"
    "        final occupying = authoritativeJob != null\n"
    "            ? downloadJobOccupiesSlot(authoritativeJob.state)\n"
    "            : occupiesDownloadSlot(\n"
    "                status: existingRecord.status,\n"
    "                queueWaiting: _queueWaitingIds.contains(\n"
    "                  existingRecord.task.taskId,\n"
    "                ),\n"
    "              );\n",
    'existing logical job slot authority',
)
service = replace_once(
    service,
    "      final completeRecords = await _completeRecordsForEpisode(\n"
    "        records,\n"
    "        trackingUrl: tracking,\n",
    "      final completeRecords = await _completeRecordsForEpisode(\n"
    "        records,\n"
    "        logicalId: logicalId,\n"
    "        trackingUrl: tracking,\n",
    'complete logical id call',
)
service = replace_once(
    service,
    "          DownloadJobRecord(\n"
    "            taskId: transferTask.taskId,\n"
    "            trackingUrl: trackingUrl ?? url,\n",
    "          DownloadJobRecord(\n"
    "            taskId: transferTask.taskId,\n"
    "            logicalId: logicalId,\n"
    "            trackingUrl: trackingUrl ?? url,\n",
    'fresh job logical id',
)
service = replace_once(
    service,
    "          trackingUrl: trackingUrl ?? url,\n"
    "          filePath: path,\n"
    "          taskSnapshot: transferTask.toJson(),\n",
    "          trackingUrl: trackingUrl ?? url,\n"
    "          filePath: path,\n"
    "          logicalId: logicalId,\n"
    "          taskSnapshot: transferTask.toJson(),\n",
    'fresh metadata logical id',
)
service = replace_once(
    service,
    "  Future<List<TaskRecord>> _completeRecordsForEpisode(\n"
    "    List<TaskRecord> records, {\n"
    "    required String trackingUrl,\n",
    "  Future<List<TaskRecord>> _completeRecordsForEpisode(\n"
    "    List<TaskRecord> records, {\n"
    "    required String logicalId,\n"
    "    required String trackingUrl,\n",
    'complete logical id signature',
)
old_complete_loop = """    for (final record in records) {
      if (record.status != TaskStatus.complete) continue;
      final recordUrl = downloadTrackingUrl(record.task);
      var matched =
          recordUrl == trackingUrl ||
          (episode?.url.trim().isNotEmpty == true &&
              recordUrl == episode!.url.trim()) ||
          taskMatchesDownloadFile(
            task: record.task,
            filename: filename,
            directory: directory,
          );
      if (!matched) {
        final metadata = await storage.getDownloadMetadata(record.task.taskId);
        if (metadata != null) {
          final storedTracking = (metadata['trackingUrl'] as String?)?.trim();
          matched =
              (storedTracking != null && storedTracking == trackingUrl) ||
              metadataMatchesDownload(
                item: item,
                episode: episode,
                candidateItem: MultimediaItem.fromJson(
                  Map<String, dynamic>.from(metadata['item'] as Map),
                ),
                candidateEpisode: metadata['episode'] != null
                    ? Episode.fromJson(
                        Map<String, dynamic>.from(metadata['episode'] as Map),
                      )
                    : null,
              );
        }
      }
      if (matched) matches.add(record);
    }
"""
new_complete_loop = """    for (final record in records) {
      if (record.status != TaskStatus.complete) continue;
      final metadata = await storage.getDownloadMetadata(record.task.taskId);
      final candidateLogicalId = logicalDownloadIdFromMetadata(metadata);
      if (candidateLogicalId != null) {
        if (candidateLogicalId == logicalId) matches.add(record);
        continue;
      }

      // Pre-logical-identity migration fallback. Only rows that genuinely lack
      // reconstructable presentation identity may use URL/path heuristics.
      final recordUrl = downloadTrackingUrl(record.task);
      var matched =
          recordUrl == trackingUrl ||
          (episode?.url.trim().isNotEmpty == true &&
              recordUrl == episode!.url.trim()) ||
          taskMatchesDownloadFile(
            task: record.task,
            filename: filename,
            directory: directory,
          );
      if (!matched && metadata != null && metadata['item'] is Map) {
        final storedTracking = (metadata['trackingUrl'] as String?)?.trim();
        matched =
            (storedTracking != null && storedTracking == trackingUrl) ||
            metadataMatchesDownload(
              item: item,
              episode: episode,
              candidateItem: MultimediaItem.fromJson(
                Map<String, dynamic>.from(metadata['item'] as Map),
              ),
              candidateEpisode: metadata['episode'] is Map
                  ? Episode.fromJson(
                      Map<String, dynamic>.from(metadata['episode'] as Map),
                    )
                  : null,
            );
      }
      if (matched) matches.add(record);
    }
"""
service = replace_once(service, old_complete_loop, new_complete_loop, 'complete logical matching')
service_path.write_text(service)


provider_path = Path('lib/features/library/presentation/downloads_provider.dart')
provider = provider_path.read_text()
if "download_logical_identity.dart" not in provider:
    provider = replace_once(
        provider,
        "import '../../../core/services/download_job_state.dart';\n",
        "import '../../../core/services/download_job_state.dart';\n"
        "import '../../../core/services/download_logical_identity.dart';\n",
        'provider logical identity import',
    )
provider = replace_once(
    provider,
    "  final Episode? episode;\n  final int timestamp;\n",
    "  final Episode? episode;\n  final String? logicalId;\n  final int timestamp;\n",
    'DownloadItem logical field',
)
provider = replace_once(
    provider,
    "    required this.item,\n    this.episode,\n    required this.timestamp,\n",
    "    required this.item,\n    this.episode,\n    this.logicalId,\n    required this.timestamp,\n",
    'DownloadItem logical ctor',
)
provider = replace_once(
    provider,
    "bool downloadsPointAtSameTarget(DownloadItem a, DownloadItem b) {\n"
    "  if (identical(a, b) || a.id == b.id) return true;\n",
    "bool downloadsPointAtSameTarget(DownloadItem a, DownloadItem b) {\n"
    "  if (identical(a, b) || a.id == b.id) return true;\n"
    "  final logicalA = a.logicalId?.trim();\n"
    "  final logicalB = b.logicalId?.trim();\n"
    "  if (logicalA != null &&\n"
    "      logicalA.isNotEmpty &&\n"
    "      logicalB != null &&\n"
    "      logicalB.isNotEmpty) {\n"
    "    return logicalA == logicalB;\n"
    "  }\n"
    "  // Pre-logical-identity migration fallback: only incomplete legacy evidence\n"
    "  // may fall through to mutable URL/file heuristics.\n",
    'provider target logical identity',
)
provider = replace_once(
    provider,
    "  final byTracking = <String, int>{};\n  final byFile = <String, int>{};\n",
    "  final byLogicalId = <String, int>{};\n  final byTracking = <String, int>{};\n  final byFile = <String, int>{};\n",
    'provider logical grouping map',
)
provider = replace_once(
    provider,
    "  for (var i = 0; i < items.length; i++) {\n"
    "    unionKey(byTracking, downloadTrackingUrl(items[i].task), i);\n"
    "    unionKey(byTracking, items[i].episode?.url.trim() ?? '', i);\n"
    "    unionKey(byFile, downloadTaskFileKey(items[i].task), i);\n"
    "  }\n",
    "  for (var i = 0; i < items.length; i++) {\n"
    "    final logicalId = items[i].logicalId?.trim();\n"
    "    if (logicalId != null && logicalId.isNotEmpty) {\n"
    "      unionKey(byLogicalId, logicalId, i);\n"
    "      continue;\n"
    "    }\n"
    "    // Pre-logical-identity migration fallback.\n"
    "    unionKey(byTracking, downloadTrackingUrl(items[i].task), i);\n"
    "    unionKey(byTracking, items[i].episode?.url.trim() ?? '', i);\n"
    "    unionKey(byFile, downloadTaskFileKey(items[i].task), i);\n"
    "  }\n",
    'provider logical grouping',
)
provider = replace_once(
    provider,
    "        : null,\n    timestamp: (metadata['timestamp'] as int?) ?? 0,\n",
    "        : null,\n    logicalId: logicalDownloadIdFromMetadata(metadata),\n    timestamp: (metadata['timestamp'] as int?) ?? 0,\n",
    'metadata logical identity projection',
)
provider = replace_once(
    provider,
    "          item: existing.item,\n          episode: existing.episode,\n          timestamp: existing.timestamp,\n",
    "          item: existing.item,\n          episode: existing.episode,\n          logicalId: existing.logicalId,\n          timestamp: existing.timestamp,\n",
    'updated DownloadItem logical identity',
)
provider_path.write_text(provider)
