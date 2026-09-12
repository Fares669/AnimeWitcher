from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()

start_sig = 'Future<DownloadCommandOutcome> startDownloadOutcome({'
start = source.find(start_sig)
if start < 0:
    raise SystemExit('startDownloadOutcome missing')
end = source.find('Future<List<TaskRecord>> _completeRecordsForEpisode(', start)
if end < 0:
    raise SystemExit('complete-record method missing')
body = source[start:end]

# If the desired invariants are already present this repair is idempotent.
if (
    'final allJobs = await _jobStore.all();' in body
    and 'if (candidateLogicalId != logicalId) continue;' in body
    and 'if (candidateLogicalId != null)' in body
    and 'if (candidateTracking == (trackingUrl ?? url))' in body
):
    raise SystemExit(0)

legacy_start = body.find(
    '      // Pre-logical-identity migration fallback: old rows may not yet have a\n'
)
if legacy_start < 0:
    raise SystemExit('legacy fallback start missing')
legacy_end = body.find('\n      if (existingRecord != null) {', legacy_start)
if legacy_end < 0:
    raise SystemExit('legacy fallback end missing')

replacement = '''      if (existingRecord == null) {
        // Reconstruct canonical identity for pre-DM24 JobStore rows before any
        // mutable URL/path fallback. This is adoption/repair only; it never
        // creates a second execution writer.
        final allJobs = await _jobStore.all();
        final storage = _ref.read(storageServiceProvider);
        for (final candidateJob in allJobs.reversed) {
          if (candidateJob.state == DownloadJobState.completed ||
              candidateJob.state == DownloadJobState.canceled ||
              candidateJob.state == DownloadJobState.orphaned) {
            continue;
          }
          final metadata = await storage.getDownloadMetadata(candidateJob.taskId);
          final candidateLogicalId = candidateJob.logicalId ??
              logicalDownloadIdFromMetadata(metadata);
          if (candidateLogicalId != logicalId) continue;

          var migratedJob = candidateJob;
          if (candidateJob.logicalId == null) {
            migratedJob = candidateJob.copyWith(
              logicalId: logicalId,
              updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
            );
            if (!await _jobStore.put(migratedJob)) continue;
          }

          final projected = recordsById[candidateJob.taskId];
          if (projected != null && isLogicalEpisodeDownloadTask(projected.task)) {
            existingLogicalJob = migratedJob;
            existingRecord = projected;
            break;
          }

          final restored = migratedJob.restoreTaskSnapshot();
          if (restored == null || !isLogicalEpisodeDownloadTask(restored)) {
            continue;
          }
          final progress = migratedJob.expectedBytes > 0
              ? (migratedJob.durableBytes / migratedJob.expectedBytes)
                    .clamp(0.0, 1.0)
              : 0.0;
          existingLogicalJob = migratedJob;
          existingRecord = TaskRecord(
            restored,
            downloadJobTaskStatus(migratedJob.state),
            progress,
            migratedJob.expectedBytes,
          );
          await FileDownloader().database.updateRecord(existingRecord);
          break;
        }
      }

      // Pre-logical-identity migration fallback: only evidence that genuinely
      // lacks canonical identity may use a historical tracking URL. Once a row
      // has a logical ID, a different episode can never collapse through URL.
      if (existingRecord == null) {
        final storage = _ref.read(storageServiceProvider);
        for (final candidate in records) {
          if (!isLogicalEpisodeDownloadTask(candidate.task) ||
              !(candidate.status == TaskStatus.failed ||
                  candidate.status == TaskStatus.notFound ||
                  candidate.status == TaskStatus.enqueued ||
                  candidate.status == TaskStatus.running ||
                  candidate.status == TaskStatus.paused ||
                  candidate.status == TaskStatus.waitingToRetry)) {
            continue;
          }
          final candidateJob = await _jobStore.get(candidate.task.taskId);
          final candidateMetadata =
              await storage.getDownloadMetadata(candidate.task.taskId);
          final candidateLogicalId = candidateJob?.logicalId ??
              logicalDownloadIdFromMetadata(candidateMetadata);
          if (candidateLogicalId != null) {
            if (candidateLogicalId != logicalId) continue;
            existingLogicalJob = candidateJob;
            existingRecord = candidate;
            break;
          }

          final candidateTracking = candidate.task.metaData.isNotEmpty
              ? candidate.task.metaData
              : candidate.task.url;
          if (candidateTracking == (trackingUrl ?? url)) {
            existingRecord = candidate;
            break;
          }
        }
      }
'''

body = body[:legacy_start] + replacement + body[legacy_end:]
source = source[:start] + body + source[end:]
path.write_text(source)

# Result-oriented assertions instead of formatting-sensitive anchors.
updated = path.read_text()
section = updated[updated.find(start_sig):updated.find('Future<List<TaskRecord>> _completeRecordsForEpisode(', updated.find(start_sig))]
required = [
    'final allJobs = await _jobStore.all();',
    'logicalDownloadIdFromMetadata(metadata)',
    'if (candidateLogicalId != logicalId) continue;',
    'logicalId: logicalId',
    'if (candidateLogicalId != null)',
    'if (candidateTracking == (trackingUrl ?? url))',
]
for invariant in required:
    if invariant not in section:
        raise SystemExit(f'missing DM-24 invariant: {invariant}')
