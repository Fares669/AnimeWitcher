from pathlib import Path

# Delivery URLs rotate and must never make a fingerprint durable by themselves.
store_path = Path('lib/core/services/download_job_store.dart')
store = store_path.read_text()
old = '''  bool get hasIdentityEvidence =>
      (strongEtag?.trim().isNotEmpty ?? false) ||
      (lastModified?.trim().isNotEmpty ?? false) ||
      expectedBytes > 0 ||
      (finalUrl?.trim().isNotEmpty ?? false);
'''
new = '''  bool get hasIdentityEvidence =>
      (strongEtag?.trim().isNotEmpty ?? false) ||
      (lastModified?.trim().isNotEmpty ?? false) ||
      expectedBytes > 0;
'''
if old in store:
    store = store.replace(old, new, 1)
elif new not in store:
    raise SystemExit('fingerprint identity getter anchor missing')
store = store.replace(
    '/// plus final URL give us additional evidence when a provider refreshes a\n/// signed CDN URL.',
    '/// provide stable evidence. Final URL is delivery metadata only because a\n/// signed CDN URL may rotate without changing the resource.',
    1,
)
store_path.write_text(store)

# Replace the real completion method as a bounded unit. The older patch used a
# global text replacement and could hit a look-alike block elsewhere.
service_path = Path('lib/core/services/download_service.dart')
source = service_path.read_text()
start_marker = '  Future<void> _persistCompletedFilePath(Task task) async {'
end_marker = '\n  Future<String> getDownloadPath('
start = source.find(start_marker)
if start < 0:
    raise SystemExit('completion method start missing')
end = source.find(end_marker, start)
if end < 0:
    raise SystemExit('completion method end missing')

method = r'''  Future<void> _persistCompletedFilePath(Task task) async {
    try {
      final path = await task.filePath();
      var fileBytes = -1;
      File? completedFile;
      if (path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) {
          completedFile = file;
          fileBytes = await file.length();
        }
      }

      final record = await FileDownloader().database.recordForId(task.taskId);
      final storage = _ref.read(storageServiceProvider);
      final metadata = await storage.getDownloadMetadata(task.taskId);
      final job = await _jobStore.get(task.taskId);
      final currentFingerprint = task is DownloadTask
          ? await _probeResourceFingerprint(task.url, headers: task.headers)
          : null;

      // Never promote the observed file into its own expectation. Every value
      // here must pre-exist the final local length or come from remote evidence.
      final expectedBytes = knownDownloadSize(<int?>[
        job?.expectedBytes,
        record?.expectedFileSize,
        downloadMetadataExpectedBytes(metadata),
        _telemetry.expectedBytesFor(task.taskId),
        currentFingerprint?.expectedBytes,
      ]);

      if (task is DownloadTask) {
        var prefixMatches = false;
        if (completedFile != null && fileBytes > 0 && expectedBytes > 0) {
          final proof = await _rangeTransfers.verifyExistingPrefix(
            id: '${task.taskId}.final-proof',
            url: task.url,
            headers: task.headers,
            file: completedFile,
            written: fileBytes,
          );
          prefixMatches = proof.matches;
        }

        final verified = downloadCompletionEvidenceMatches(
          observedFileBytes: fileBytes,
          expectedResourceBytes: expectedBytes,
          prefixMatches: prefixMatches,
          persistedFingerprint: job?.fingerprint,
          currentFingerprint: currentFingerprint,
        );
        if (!verified) {
          diagnosticLog.record('completion.resourceIdentityRejected', {
            'taskId': task.taskId,
            'fileBytes': fileBytes,
            'expectedBytes': expectedBytes,
            'prefixMatches': prefixMatches,
          });
          await _checkpointLogicalJob(
            task,
            state: DownloadJobState.interrupted,
            expectedBytes: expectedBytes,
            userPaused: false,
            queueWaiting: false,
            fingerprint: currentFingerprint,
          );
          return;
        }

        final completedFingerprint = fingerprintWithExpectedBytes(
          remote: currentFingerprint ?? job?.fingerprint,
          expectedBytes: expectedBytes,
          fallbackFinalUrl: task.url,
        );
        final completedPersisted = await _checkpointLogicalJob(
          task,
          state: DownloadJobState.completed,
          durableBytes: fileBytes,
          durableByteProvenance:
              DownloadDurableByteProvenance.verifiedFinalFile,
          expectedBytes: expectedBytes,
          userPaused: false,
          queueWaiting: false,
          fingerprint: completedFingerprint,
        );
        if (!completedPersisted) {
          diagnosticLog.record('completion.persistenceBlocked', {
            'taskId': task.taskId,
          });
          return;
        }
      }

      await storage.patchDownloadMetadata(
        task.taskId,
        trackingUrl: downloadTrackingUrl(task),
        filePath: path,
        lastProgress: 1,
        lastExpectedBytes: expectedBytes,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[DownloadService] persist filePath failed: $e');
      }
    }
  }
'''
source = source[:start] + method + source[end:]
service_path.write_text(source)

# Invariants expected by DM-06 guards.
updated = service_path.read_text()
start = updated.find(start_marker)
end = updated.find(end_marker, start)
body = updated[start:end]
required = [
    'final expectedBytes = knownDownloadSize',
    'job?.expectedBytes',
    'currentFingerprint?.expectedBytes',
    'downloadCompletionEvidenceMatches(',
    'verifyExistingPrefix(',
    'expectedResourceBytes: expectedBytes',
]
for needle in required:
    if needle not in body:
        raise SystemExit(f'missing completion invariant: {needle}')
known = body.find('final expectedBytes = knownDownloadSize')
if_task = body.find('if (task is DownloadTask)', known)
if known < 0 or if_task <= known:
    raise SystemExit('completion expected-size block is not scoped before DownloadTask verification')
if 'fileBytes,' in body[known:if_task]:
    raise SystemExit('observed file length still participates in expected size')
