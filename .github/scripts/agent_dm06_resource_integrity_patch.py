from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global source
    if new in source:
        return
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'{label} anchor mismatch: {count}')
    source = source.replace(old, new, 1)

if "import 'download_resource_identity.dart';" not in source:
    replace_once(
        "import 'download_job_store.dart';\n",
        "import 'download_job_store.dart';\nimport 'download_resource_identity.dart';\n",
        'resource identity import',
    )

# Allow lifecycle checkpoints to carry a remote validator-bearing fingerprint.
replace_once(
    '''    int? expectedBytes,\n    bool? userPaused,\n    bool? queueWaiting,\n  }) async {\n''',
    '''    int? expectedBytes,\n    bool? userPaused,\n    bool? queueWaiting,\n    DownloadResourceFingerprint? fingerprint,\n  }) async {\n''',
    'checkpoint fingerprint parameter',
)
replace_once(
    '''        fingerprint: DownloadResourceFingerprint(\n          expectedBytes: expectedBytes ?? -1,\n          finalUrl: task.url,\n        ),\n''',
    '''        fingerprint: fingerprint ??\n            fingerprintWithExpectedBytes(\n              remote: null,\n              expectedBytes: expectedBytes ?? -1,\n              fallbackFinalUrl: task.url,\n            ),\n''',
    'checkpoint fingerprint persistence',
)

# Persist remote validators and independently observed resource size on fresh start.
replace_once(
    '''        final startNow = occupied < maxConcurrent;\n        final expectedBytes = totalBytes > 0 ? totalBytes : -1;\n        // Freeze the chosen transfer shape before queueing. This preserves a\n''',
    '''        final startNow = occupied < maxConcurrent;\n        final remoteFingerprint = await _probeResourceFingerprint(\n          url,\n          headers: headers,\n        );\n        final expectedBytes = knownDownloadSize(<int?>[\n          totalBytes,\n          remoteFingerprint?.expectedBytes,\n        ]);\n        final resourceFingerprint = fingerprintWithExpectedBytes(\n          remote: remoteFingerprint,\n          expectedBytes: expectedBytes,\n          fallbackFinalUrl: url,\n        );\n        // Freeze the chosen transfer shape before queueing. This preserves a\n''',
    'fresh remote fingerprint',
)
replace_once(
    '''            fingerprint: DownloadResourceFingerprint(\n              expectedBytes: expectedBytes,\n              finalUrl: url,\n            ),\n''',
    '''            fingerprint: resourceFingerprint,\n''',
    'fresh JobStore fingerprint',
)

# Seed Range attempts with validator-bearing identity instead of URL+size only.
replace_once(
    '''    if (job == null) {\n      final seeded = DownloadJobRecord(\n''',
    '''    if (job == null) {\n      final remoteFingerprint = await _probeResourceFingerprint(\n        task.url,\n        headers: task.headers,\n      );\n      final seeded = DownloadJobRecord(\n''',
    'range seed remote fingerprint',
)
replace_once(
    '''        fingerprint: DownloadResourceFingerprint(\n          expectedBytes: expectedBytes,\n          finalUrl: task.url,\n        ),\n      );\n      if (!await _jobStore.put(seeded)) return null;\n''',
    '''        fingerprint: fingerprintWithExpectedBytes(\n          remote: remoteFingerprint,\n          expectedBytes: expectedBytes,\n          fallbackFinalUrl: task.url,\n        ),\n      );\n      if (!await _jobStore.put(seeded)) return null;\n''',
    'range seed fingerprint persistence',
)

# Exact-size local artifacts must prove both resource identity and a byte prefix.
replace_once(
    '''    if (expectedBytes > 0 && existingBytes == expectedBytes) {\n      final checkpointed = await _checkpointLogicalJob(\n        task,\n        state: DownloadJobState.completed,\n        durableBytes: expectedBytes,\n        durableByteProvenance: DownloadDurableByteProvenance.verifiedFinalFile,\n        expectedBytes: expectedBytes,\n        userPaused: false,\n        queueWaiting: false,\n      );\n''',
    '''    if (expectedBytes > 0 && existingBytes == expectedBytes) {\n      final persistedFingerprint =\n          (await _jobStore.get(task.taskId))?.fingerprint;\n      final currentFingerprint = await _probeResourceFingerprint(\n        task.url,\n        headers: task.headers,\n      );\n      final prefixProof = await _rangeTransfers.verifyExistingPrefix(\n        id: '${task.taskId}.completion-proof',\n        url: task.url,\n        headers: task.headers,\n        file: partial.file,\n        written: existingBytes,\n      );\n      if (!downloadCompletionEvidenceMatches(\n        observedFileBytes: existingBytes,\n        expectedResourceBytes: expectedBytes,\n        prefixMatches: prefixProof.matches,\n        persistedFingerprint: persistedFingerprint,\n        currentFingerprint: currentFingerprint,\n      )) {\n        diagnosticLog.record('completion.identityRejected', {\n          'taskId': task.taskId,\n          'bytes': existingBytes,\n          'expected': expectedBytes,\n        });\n        return false;\n      }\n      final checkpointed = await _checkpointLogicalJob(\n        task,\n        state: DownloadJobState.completed,\n        durableBytes: expectedBytes,\n        durableByteProvenance: DownloadDurableByteProvenance.verifiedFinalFile,\n        expectedBytes: expectedBytes,\n        userPaused: false,\n        queueWaiting: false,\n        fingerprint: fingerprintWithExpectedBytes(\n          remote: currentFingerprint,\n          expectedBytes: expectedBytes,\n          fallbackFinalUrl: task.url,\n        ),\n      );\n''',
    'exact local completion proof',
)

# A 416/reconcile-range completion is only accepted after the Range layer's
# prefix guard and a compatible current fingerprint.
old_416 = '''        } else if (failure.action == DownloadFailureAction.reconcileRange &&\n            failure.resourceSize > 0 &&\n            await dest.exists() &&\n            await dest.length() == failure.resourceSize &&\n            (expectedBytes <= 0 || expectedBytes == failure.resourceSize)) {\n          await _jobStore.updateForAttempt(\n            activeToken,\n            state: DownloadJobState.completed,\n            durableBytes: failure.resourceSize,\n            durableByteProvenance: DownloadDurableByteProvenance.rangeFlushed,\n            expectedBytes: failure.resourceSize,\n          );\n          await FileDownloader().database.updateRecord(\n            TaskRecord(task, TaskStatus.complete, 1, failure.resourceSize),\n          );\n          _sharedEvents.add(TaskProgressUpdate(task, 1, failure.resourceSize));\n          _sharedEvents.add(TaskStatusUpdate(task, TaskStatus.complete));\n        }\n'''
new_416 = '''        } else if (failure.action == DownloadFailureAction.reconcileRange &&\n            failure.resourceSize > 0 &&\n            await dest.exists() &&\n            await dest.length() == failure.resourceSize &&\n            (expectedBytes <= 0 || expectedBytes == failure.resourceSize)) {\n          final currentFingerprint = await _probeResourceFingerprint(\n            task.url,\n            headers: task.headers,\n          );\n          final persistedFingerprint =\n              (await _jobStore.get(task.taskId))?.fingerprint;\n          final completionExpected = knownDownloadSize(<int?>[\n            expectedBytes,\n            persistedFingerprint?.expectedBytes,\n            currentFingerprint?.expectedBytes,\n            failure.resourceSize,\n          ]);\n          if (!downloadCompletionEvidenceMatches(\n            observedFileBytes: failure.resourceSize,\n            expectedResourceBytes: completionExpected,\n            // DownloadRangeTransfer only reaches reconcileRange after its\n            // existing-prefix guard has succeeded.\n            prefixMatches: true,\n            persistedFingerprint: persistedFingerprint,\n            currentFingerprint: currentFingerprint,\n          )) {\n            return;\n          }\n          await _jobStore.updateForAttempt(\n            activeToken,\n            state: DownloadJobState.completed,\n            durableBytes: failure.resourceSize,\n            durableByteProvenance: DownloadDurableByteProvenance.rangeFlushed,\n            expectedBytes: completionExpected,\n            fingerprint: fingerprintWithExpectedBytes(\n              remote: currentFingerprint,\n              expectedBytes: completionExpected,\n              fallbackFinalUrl: task.url,\n            ),\n          );\n          await FileDownloader().database.updateRecord(\n            TaskRecord(task, TaskStatus.complete, 1, completionExpected),\n          );\n          _sharedEvents.add(TaskProgressUpdate(task, 1, completionExpected));\n          _sharedEvents.add(TaskStatusUpdate(task, TaskStatus.complete));\n        }\n'''
replace_once(old_416, new_416, '416 completion proof')

# Source refresh must respect the stable validator fingerprint. Delivery URLs
# may rotate; validator/expected-size conflicts may not.
replace_once(
    '''    final trackingUrl = downloadTrackingUrl(task);\n    final store = _ref.read(downloadUrlRefreshStoreProvider);\n''',
    '''    final trackingUrl = downloadTrackingUrl(task);\n    final authoritativeFingerprint =\n        (await _jobStore.get(task.taskId))?.fingerprint;\n    final store = _ref.read(downloadUrlRefreshStoreProvider);\n''',
    'refresh authoritative fingerprint',
)
replace_once(
    '''    final current = await getMetadata(task.url, headers: task.headers);\n    final currentSizeMatches =\n''',
    '''    final current = await getMetadata(task.url, headers: task.headers);\n    final currentFingerprint = await _probeResourceFingerprint(\n      task.url,\n      headers: task.headers,\n    );\n    final currentIdentityMatches =\n        authoritativeFingerprint == null ||\n        currentFingerprint == null ||\n        authoritativeFingerprint.compatibleWith(currentFingerprint);\n    final currentSizeMatches =\n''',
    'current refresh fingerprint',
)
replace_once(
    '''        current.size != null &&\n        currentSizeMatches &&\n        currentRangeOk) {\n''',
    '''        current.size != null &&\n        currentSizeMatches &&\n        currentRangeOk &&\n        currentIdentityMatches) {\n''',
    'current refresh identity check',
)
replace_once(
    '''    final metadata = await getMetadata(\n      refreshed.url,\n      headers: refreshed.headers,\n    );\n    if (metadata?.size == null ||\n''',
    '''    final metadata = await getMetadata(\n      refreshed.url,\n      headers: refreshed.headers,\n    );\n    final refreshedFingerprint = await _probeResourceFingerprint(\n      refreshed.url,\n      headers: refreshed.headers,\n    );\n    final refreshedIdentityMatches =\n        authoritativeFingerprint == null ||\n        refreshedFingerprint == null ||\n        authoritativeFingerprint.compatibleWith(refreshedFingerprint);\n    if (metadata?.size == null ||\n''',
    'refreshed fingerprint probe',
)
replace_once(
    '''        ((task is ParallelDownloadTask || partialBytes > 0) &&\n            metadata?.supportsRanges != true)) {\n''',
    '''        ((task is ParallelDownloadTask || partialBytes > 0) &&\n            metadata?.supportsRanges != true) ||\n        !refreshedIdentityMatches) {\n''',
    'refreshed identity rejection',
)
replace_once(
    '''      userPaused: false,\n      queueWaiting: false,\n    );\n    if (!refreshCheckpointed) {\n''',
    '''      userPaused: false,\n      queueWaiting: false,\n      fingerprint: fingerprintWithExpectedBytes(\n        remote: refreshedFingerprint,\n        expectedBytes: expectedBytes,\n        fallbackFinalUrl: refreshed.url,\n      ),\n    );\n    if (!refreshCheckpointed) {\n''',
    'refresh fingerprint checkpoint',
)

# Native completion must not derive expected resource size from the file it is
# trying to verify. Require an independent expected size plus current source
# prefix/fingerprint proof before publishing completed state.
old_completed = '''      final record = await FileDownloader().database.recordForId(task.taskId);\n      final expectedBytes = knownDownloadSize(<int?>[\n        fileBytes,\n        record?.expectedFileSize,\n        _telemetry.expectedBytesFor(task.taskId),\n      ]);\n      if (task is DownloadTask) {\n        final completedPersisted = await _checkpointLogicalJob(\n          task,\n          state: DownloadJobState.completed,\n          durableBytes: fileBytes > 0 ? fileBytes : null,\n          durableByteProvenance: fileBytes > 0\n              ? DownloadDurableByteProvenance.verifiedFinalFile\n              : null,\n          expectedBytes: expectedBytes,\n          userPaused: false,\n          queueWaiting: false,\n        );\n'''
new_completed = '''      final record = await FileDownloader().database.recordForId(task.taskId);\n      final metadata = await _ref\n          .read(storageServiceProvider)\n          .getDownloadMetadata(task.taskId);\n      final job = await _jobStore.get(task.taskId);\n      final currentFingerprint = task is DownloadTask\n          ? await _probeResourceFingerprint(task.url, headers: task.headers)\n          : null;\n      final expectedBytes = knownDownloadSize(<int?>[\n        job?.expectedBytes,\n        record?.expectedFileSize,\n        downloadMetadataExpectedBytes(metadata),\n        _telemetry.expectedBytesFor(task.taskId),\n        currentFingerprint?.expectedBytes,\n      ]);\n      if (task is DownloadTask) {\n        var prefixMatches = false;\n        if (fileBytes > 0 && expectedBytes > 0 && path != null && path.isNotEmpty) {\n          final proof = await _rangeTransfers.verifyExistingPrefix(\n            id: '${task.taskId}.final-proof',\n            url: task.url,\n            headers: task.headers,\n            file: File(path),\n            written: fileBytes,\n          );\n          prefixMatches = proof.matches;\n        }\n        if (!downloadCompletionEvidenceMatches(\n          observedFileBytes: fileBytes,\n          expectedResourceBytes: expectedBytes,\n          prefixMatches: prefixMatches,\n          persistedFingerprint: job?.fingerprint,\n          currentFingerprint: currentFingerprint,\n        )) {\n          diagnosticLog.record('completion.verificationRejected', {\n            'taskId': task.taskId,\n            'bytes': fileBytes,\n            'expected': expectedBytes,\n          });\n          await _checkpointLogicalJob(\n            task,\n            state: DownloadJobState.interrupted,\n            expectedBytes: expectedBytes,\n            userPaused: false,\n            queueWaiting: false,\n            fingerprint: currentFingerprint,\n          );\n          return;\n        }\n        final completedPersisted = await _checkpointLogicalJob(\n          task,\n          state: DownloadJobState.completed,\n          durableBytes: fileBytes,\n          durableByteProvenance: DownloadDurableByteProvenance.verifiedFinalFile,\n          expectedBytes: expectedBytes,\n          userPaused: false,\n          queueWaiting: false,\n          fingerprint: fingerprintWithExpectedBytes(\n            remote: currentFingerprint,\n            expectedBytes: expectedBytes,\n            fallbackFinalUrl: task.url,\n          ),\n        );\n'''
replace_once(old_completed, new_completed, 'native final completion verification')

# Add a remote fingerprint probe next to getMetadata so both source refresh and
# completion verification use one validator extraction policy.
probe_method = r'''  Future<DownloadResourceFingerprint?> _probeResourceFingerprint(
    String url, {
    Map<String, String>? headers,
  }) async {
    String? strongEtag;
    String? lastModified;
    var expectedBytes = -1;
    String? finalUrl;

    void absorb(Response<dynamic> response) {
      strongEtag ??= strongDownloadEtag(response.headers.value('etag'));
      final modified = response.headers.value('last-modified')?.trim();
      if (lastModified == null && modified != null && modified.isNotEmpty) {
        lastModified = modified;
      }
      final range = RegExp(r'^bytes\s+\d+-\d+/(\d+)$')
          .firstMatch(response.headers.value('content-range') ?? '');
      final rangeBytes = range == null ? null : int.tryParse(range[1]!);
      final contentBytes = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      if (rangeBytes != null && rangeBytes > 0) {
        expectedBytes = rangeBytes;
      } else if (response.statusCode != 206 &&
          contentBytes != null &&
          contentBytes > 0) {
        expectedBytes = contentBytes;
      }
      final resolved = response.realUri.toString().trim();
      if (resolved.isNotEmpty) finalUrl = resolved;
    }

    try {
      final response = await _dio
          .head<dynamic>(
            url,
            options: Options(
              headers: {...?headers, 'Accept-Encoding': 'identity'},
              followRedirects: true,
            ),
          )
          .timeout(const Duration(seconds: 10));
      absorb(response);
    } catch (_) {}

    if (expectedBytes <= 0 || (strongEtag == null && lastModified == null)) {
      try {
        final response = await _dio
            .get<dynamic>(
              url,
              options: Options(
                headers: {
                  ...?headers,
                  'Range': 'bytes=0-0',
                  'Accept-Encoding': 'identity',
                },
                followRedirects: true,
                responseType: ResponseType.stream,
                validateStatus: (status) =>
                    status != null && (status == 200 || status == 206),
              ),
            )
            .timeout(const Duration(seconds: 10));
        absorb(response);
        final body = response.data;
        if (body is ResponseBody) {
          final subscription = body.stream.listen(null);
          await subscription.cancel();
        }
      } catch (_) {}
    }

    final fingerprint = DownloadResourceFingerprint(
      strongEtag: strongEtag,
      lastModified: lastModified,
      expectedBytes: expectedBytes,
      finalUrl: finalUrl ?? url,
    );
    return fingerprint.hasIdentityEvidence ? fingerprint : null;
  }

'''
if '_probeResourceFingerprint(' not in source:
    marker = '  Future<DownloadMetadata?> getMetadata(\n'
    if marker not in source:
        raise SystemExit('metadata probe insertion anchor missing')
    source = source.replace(marker, probe_method + marker, 1)

path.write_text(source)
