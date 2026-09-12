from pathlib import Path

path = Path("lib/core/services/download_service.dart")
source = path.read_text()

if "final manifestEvidenceById = <String, ParallelManifestRecoveryEvidence>{" in source:
    raise SystemExit("manifest startup reconciliation already exists")

anchor = """    final metadataById = await storage.getAllDownloadMetadata();

    final durableRecords = <TaskRecord>[];
"""
replacement = """    final metadataById = await storage.getAllDownloadMetadata();

    // DM-04: manifests are durable executor evidence even when plugin DB,
    // JobStore or metadata projections were lost. Scan only the app-owned
    // Downloads subtree; never infer task identity from arbitrary files.
    final discoveredManifests = await discoverParallelManifestRecoveryEvidence([
      Directory(
        p.join(await _getPublicDownloadsPath(), 'AnimeWitcher', 'Downloads'),
      ),
    ]);
    final manifestEvidenceById = <String, ParallelManifestRecoveryEvidence>{};
    final unresolvedManifestEvidence = <ParallelManifestRecoveryEvidence>[];
    final manifestsByParent = <String, List<ParallelManifestRecoveryEvidence>>{};
    for (final manifestEvidence in discoveredManifests) {
      manifestsByParent
          .putIfAbsent(
            manifestEvidence.parentTaskId,
            () => <ParallelManifestRecoveryEvidence>[],
          )
          .add(manifestEvidence);
    }
    for (final entry in manifestsByParent.entries) {
      final candidates = entry.value;
      if (candidates.length != 1) {
        unresolvedManifestEvidence.addAll(candidates);
        diagnosticLog.record('recovery.unresolvedManifest', {
          'taskId': entry.key,
          'reason': 'duplicateParentEvidence',
          'count': candidates.length,
        });
        continue;
      }
      final manifestEvidence = candidates.single;
      if (manifestEvidence.parentTask == null) {
        unresolvedManifestEvidence.add(manifestEvidence);
        diagnosticLog.record('recovery.unresolvedManifest', {
          'taskId': manifestEvidence.parentTaskId,
          'reason': 'missingParentDescriptor',
          'schemaVersion': manifestEvidence.schemaVersion,
        });
        continue;
      }
      manifestEvidenceById[manifestEvidence.parentTaskId] = manifestEvidence;
      try {
        // Rehydrate multipart child ownership before any orphan/user-pause
        // decision so a surviving writer cannot become invisible at parent level.
        await _parallel.restore(manifestEvidence.parentTask!);
      } catch (_) {
        diagnosticLog.record('recovery.unresolvedManifestOwnership', {
          'taskId': manifestEvidence.parentTaskId,
          'reason': 'restoreFailed',
        });
      }
    }

    // Legacy manifests are intentionally not enough to fabricate a parent.
    // If a known child writer survived, settle that exact child identity before
    // ignoring the unresolved parent evidence.
    Set<String>? liveManifestPartIds;
    try {
      liveManifestPartIds = await _livePartIds();
    } catch (_) {
      liveManifestPartIds = null;
    }
    final settledLegacyChildIds = <String>{};
    for (final manifestEvidence in unresolvedManifestEvidence) {
      if (liveManifestPartIds == null) {
        diagnosticLog.record('recovery.unresolvedManifestOwnership', {
          'taskId': manifestEvidence.parentTaskId,
          'reason': 'ownershipQueryFailed',
        });
        continue;
      }
      for (final childTask in manifestEvidence.childTasks) {
        if (!liveManifestPartIds.contains(childTask.taskId) ||
            !settledLegacyChildIds.add(childTask.taskId)) {
          continue;
        }
        var settled = false;
        try {
          settled = await _pauseTransfer(childTask);
        } catch (_) {
          settled = false;
        }
        if (!settled) {
          diagnosticLog.record('recovery.unresolvedManifestOwnership', {
            'taskId': manifestEvidence.parentTaskId,
            'childTaskId': childTask.taskId,
            'reason': 'childOwnershipNotReleased',
          });
        }
      }
    }

    final durableRecords = <TaskRecord>[];
"""
if source.count(anchor) != 1:
    raise SystemExit(f"expected one startup anchor, found {source.count(anchor)}")
source = source.replace(anchor, replacement, 1)

anchor = """      final task =
          job.restoreTaskSnapshot() ??
          _downloadTaskFromMetadataSnapshot(metadata);
"""
replacement = """      final task =
          job.restoreTaskSnapshot() ??
          _downloadTaskFromMetadataSnapshot(metadata) ??
          manifestEvidenceById[job.taskId]?.parentTask;
"""
if source.count(anchor) != 1:
    raise SystemExit(f"expected one JobStore descriptor anchor, found {source.count(anchor)}")
source = source.replace(anchor, replacement, 1)

anchor = """      final metadata = entry.value;
      final task = _downloadTaskFromMetadataSnapshot(metadata);
      final trackingUrl = (metadata['trackingUrl'] as String?)?.trim() ?? '';
"""
replacement = """      final metadata = entry.value;
      final manifestEvidence = manifestEvidenceById[taskId];
      final metadataTask = _downloadTaskFromMetadataSnapshot(metadata);
      final task =
          _downloadTaskFromMetadataSnapshot(metadata) ??
          manifestEvidenceById[taskId]?.parentTask;
      final trackingUrl = (metadata['trackingUrl'] as String?)?.trim() ?? '';
"""
if source.count(anchor) != 1:
    raise SystemExit(f"expected one metadata descriptor anchor, found {source.count(anchor)}")
source = source.replace(anchor, replacement, 1)

anchor = """      final expected = downloadMetadataExpectedBytes(metadata);
      durableRecords.add(
        TaskRecord(
          task,
          TaskStatus.paused,
          downloadMetadataProgress(metadata),
          expected,
        ),
      );
    }

    final inventory = buildDownloadRecoveryInventory(
"""
replacement = """      final expected = knownDownloadSize(<int?>[
        downloadMetadataExpectedBytes(metadata),
        manifestEvidence?.expectedBytes,
      ]);
      final progress =
          metadataTask == null &&
              manifestEvidence != null &&
              manifestEvidence.expectedBytes > 0
          ? (manifestEvidence.durableBytes / manifestEvidence.expectedBytes)
                .clamp(0.0, 1.0)
                .toDouble()
          : downloadMetadataProgress(metadata);
      durableRecords.add(
        TaskRecord(task, TaskStatus.paused, progress, expected),
      );
    }

    // A v6 manifest can be the only surviving logical descriptor. Add it once
    // as durable paused evidence; the normal missing-presentation policy below
    // either reconstructs the projection from metadata or explicitly orphans it.
    for (final manifestEvidence in manifestEvidenceById.values) {
      if (knownExecutorIds.contains(manifestEvidence.parentTaskId) ||
          jobById.containsKey(manifestEvidence.parentTaskId) ||
          metadataById.containsKey(manifestEvidence.parentTaskId) ||
          durableRecords.any(
            (record) => record.task.taskId == manifestEvidence.parentTaskId,
          )) {
        continue;
      }
      final parentTask = manifestEvidence.parentTask!;
      final progress = manifestEvidence.expectedBytes > 0
          ? (manifestEvidence.durableBytes / manifestEvidence.expectedBytes)
                .clamp(0.0, 1.0)
                .toDouble()
          : 0.0;
      durableRecords.add(
        TaskRecord(
          parentTask,
          TaskStatus.paused,
          progress,
          manifestEvidence.expectedBytes,
        ),
      );
    }

    final inventory = buildDownloadRecoveryInventory(
"""
if source.count(anchor) != 1:
    raise SystemExit(f"expected one metadata durable-record anchor, found {source.count(anchor)}")
source = source.replace(anchor, replacement, 1)

anchor = """        final expectedForOrphan = knownDownloadSize(<int?>[
          record.expectedFileSize,
          downloadMetadataExpectedBytes(metadata),
          oldJob?.expectedBytes,
        ]);
"""
replacement = """        final orphanManifest = manifestEvidenceById[task.taskId];
        final expectedForOrphan = knownDownloadSize(<int?>[
          record.expectedFileSize,
          downloadMetadataExpectedBytes(metadata),
          oldJob?.expectedBytes,
          orphanManifest?.expectedBytes,
        ]);
        final orphanBytes = selectDownloadRecoveryBytes(
          exactDiskBytes: -1,
          currentGenerationJobBytes: authoritativeDownloadJobBytes(oldJob),
          multipartManifestBytes: orphanManifest?.durableBytes ?? -1,
        );
        final orphanProvenance = switch (orphanBytes.source) {
          DownloadRecoveryByteSource.jobStore =>
            oldJob?.durableByteProvenance ?? DownloadDurableByteProvenance.none,
          DownloadRecoveryByteSource.multipartManifest =>
            DownloadDurableByteProvenance.multipartManifest,
          _ => DownloadDurableByteProvenance.none,
        };
"""
if source.count(anchor) != 1:
    raise SystemExit(f"expected one orphan evidence anchor, found {source.count(anchor)}")
source = source.replace(anchor, replacement, 1)

anchor = """        final orphanCommitted = await _checkpointLogicalJob(
          task,
          state: DownloadJobState.orphaned,
          expectedBytes: expectedForOrphan,
          userPaused: false,
          queueWaiting: false,
        );
"""
replacement = """        final orphanCommitted = await _checkpointLogicalJob(
          task,
          state: DownloadJobState.orphaned,
          durableBytes: orphanBytes.bytes,
          durableByteProvenance: orphanProvenance,
          expectedBytes: expectedForOrphan,
          userPaused: false,
          queueWaiting: false,
        );
"""
if source.count(anchor) != 1:
    raise SystemExit(f"expected one orphan checkpoint anchor, found {source.count(anchor)}")
source = source.replace(anchor, replacement, 1)

path.write_text(source)
