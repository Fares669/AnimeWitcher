from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()

if '_jobStore.beginReplicaTransactionFromSeed(' in source:
    print('DM-11 fresh-start journal wiring already present')
    raise SystemExit(0)

old_persist = '''        final jobPersisted = await _jobStore.put(
          DownloadJobRecord(
            taskId: transferTask.taskId,
            logicalId: logicalId,
            trackingUrl: trackingUrl ?? url,
            state: startNow
                ? DownloadJobState.starting
                : DownloadJobState.queued,
            generation: 0,
            durableBytes: 0,
            expectedBytes: expectedBytes,
            userPaused: false,
            queueWaiting: !startNow,
            updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
            taskSnapshot: transferTask.toJson(),
            fingerprint: resourceFingerprint,
          ),
        );
        if (!jobPersisted) {
          throw StateError('Failed to persist fresh download intent');
        }
'''
new_persist = '''        final startIntent = await _jobStore.beginReplicaTransactionFromSeed(
          DownloadJobRecord(
            taskId: transferTask.taskId,
            logicalId: logicalId,
            trackingUrl: trackingUrl ?? url,
            state: startNow
                ? DownloadJobState.starting
                : DownloadJobState.queued,
            generation: 0,
            durableBytes: 0,
            expectedBytes: expectedBytes,
            userPaused: false,
            queueWaiting: !startNow,
            updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
            taskSnapshot: transferTask.toJson(),
            fingerprint: resourceFingerprint,
          ),
          operation: DownloadReplicaOperation.start,
          state: startNow
              ? DownloadJobState.starting
              : DownloadJobState.queued,
          intentData: <String, Object?>{
            if (refreshDescriptor != null)
              'refreshDescriptor': <String, Object?>{
                'trackingUrl': trackingUrl ?? url,
                'providerId': refreshDescriptor.providerId,
                'source': refreshDescriptor.source,
                if (refreshDescriptor.quality != null)
                  'quality': refreshDescriptor.quality,
                if (refreshDescriptor.refreshUrl != null)
                  'refreshUrl': refreshDescriptor.refreshUrl,
              },
          },
        );
        if (startIntent == null) {
          throw StateError('Failed to persist fresh download intent');
        }
'''
if old_persist not in source:
    raise SystemExit('DM-11 fresh-start persistence anchor drift')
source = source.replace(old_persist, new_persist, 1)

old_queued_generation = '''            generation: 0,
            claimOwnership: true,
'''
new_queued_generation = '''            generation: startIntent.generation,
            claimOwnership: true,
'''
if old_queued_generation not in source:
    raise SystemExit('DM-11 queued descriptor generation anchor drift')
source = source.replace(old_queued_generation, new_queued_generation, 1)

old_start_operation = '''        final startOperation = await _jobStore.beginOperation(
          transferTask.taskId,
          state: DownloadJobState.starting,
        );
        if (startOperation == null) {
          throw StateError(
            'Failed to fence start operation for ${transferTask.taskId}',
          );
        }
'''
new_start_operation = '''        // The write-ahead start intent is also the execution generation fence.
        // Do not increment generation again before the executor effect or the
        // durable journal and refresh-descriptor owner would describe different
        // attempts after a crash.
        final startOperation = startIntent;
'''
if old_start_operation not in source:
    raise SystemExit('DM-11 start generation anchor drift')
source = source.replace(old_start_operation, new_start_operation, 1)

path.write_text(source)
