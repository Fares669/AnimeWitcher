from pathlib import Path

path = Path('lib/core/services/download_service.dart')
text = path.read_text()

if 'class _DownloadRestartRequiredException' not in text:
    marker = '''enum DownloadCommandOutcome {
  running,
  attached,
  queued,
  paused,
  settlingOwnership,
  alreadyComplete,
  restartRequired,
  recoverableFailure,
  serviceUnavailable,
  missingState,
  terminal,
}
'''
    insert = marker + '''
class _DownloadRestartRequiredException implements Exception {
  final String taskId;

  const _DownloadRestartRequiredException(this.taskId);
}
'''
    if marker not in text:
        raise SystemExit('DownloadCommandOutcome marker not found')
    text = text.replace(marker, insert, 1)

old = '''  Future<DownloadCommandOutcome> resumeDownloadOutcome(String taskId) async {
    try {
      await resumeDownload(taskId);
    } on DownloadServiceUnavailableException {
      return DownloadCommandOutcome.serviceUnavailable;
    } catch (_) {
      return DownloadCommandOutcome.recoverableFailure;
    }
'''
new = '''  Future<DownloadCommandOutcome> resumeDownloadOutcome(String taskId) async {
    try {
      await resumeDownload(taskId);
    } on _DownloadRestartRequiredException {
      return DownloadCommandOutcome.restartRequired;
    } on DownloadServiceUnavailableException {
      return DownloadCommandOutcome.serviceUnavailable;
    } catch (_) {
      return DownloadCommandOutcome.recoverableFailure;
    }
'''
if old in text:
    text = text.replace(old, new, 1)
elif 'on _DownloadRestartRequiredException' not in text:
    raise SystemExit('resumeDownloadOutcome marker not found')

if 'Future<bool> _canNativeResume(DownloadTask task)' not in text:
    marker = '''  Future<bool> _resumeDownloadTask(DownloadTask task) async {
'''
    helper = '''  Future<bool> _canNativeResume(DownloadTask task) async {
    try {
      return await FileDownloader()
          .taskCanResume(task)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return false;
    }
  }

'''
    if marker not in text:
        raise SystemExit('_resumeDownloadTask marker not found')
    text = text.replace(marker, helper + marker, 1)

old = '''    final saved = await _savedProgressFor(task);
    if (saved.totalSize > 0 &&
        saved.partialBytes == saved.totalSize &&
        await _resumeUsingPartialFile(task)) {
      return true;
    }
    final refreshResult = await _refreshTaskBeforeResume(
      task,
      expectedBytes: saved.totalSize,
      partialBytes: saved.partialBytes,
    );
    task = refreshResult.task;
'''
new = '''    final saved = await _savedProgressFor(task);
    if (saved.totalSize > 0 &&
        saved.partialBytes == saved.totalSize &&
        await _resumeUsingPartialFile(task)) {
      return true;
    }
    final canNativeResume = task is! ParallelDownloadTask &&
        await _canNativeResume(task);
    final refreshResult = await _refreshTaskBeforeResume(
      task,
      expectedBytes: saved.totalSize,
      partialBytes: saved.partialBytes,
      hasOpaqueNativeResume: canNativeResume && saved.partialBytes <= 0,
    );
    if (refreshResult.restartRequired) {
      diagnosticLog.record('source.refreshRestartRequired', {
        'taskId': task.taskId,
        'opaqueNativeResume': canNativeResume,
      });
      throw _DownloadRestartRequiredException(task.taskId);
    }
    task = refreshResult.task;
'''
if old in text:
    text = text.replace(old, new, 1)
elif 'hasOpaqueNativeResume: canNativeResume && saved.partialBytes <= 0' not in text:
    raise SystemExit('_resumeDownloadTask refresh marker not found')

old = '''    return resumeOrRestartDownload(
      canResume: () async {
        try {
          return await FileDownloader()
              .taskCanResume(task)
              .timeout(const Duration(seconds: 3));
        } catch (_) {
          return false;
        }
      },
      resume: () => _nativeTransport.resume(task),
      resumeFromPartial: () => _resumeUsingPartialFile(task),
      restart: () =>
          _enqueueFreshAdaptiveTask(task, knownTotalBytes: saved.totalSize),
      savedProgress: saved.progress,
      existingPartialBytes: saved.partialBytes,
      expectedBytes: saved.totalSize,
    );
'''
new = '''    if (canNativeResume && !refreshResult.refreshed) {
      final resumed = await _nativeTransport.resume(task);
      if (resumed) return true;
      if (saved.partialBytes <= 0) {
        // taskCanResume proves opaque native ownership existed, but the executor
        // could not adopt it. Never convert that hidden byte ownership into an
        // implicit zero-byte restart.
        throw _DownloadRestartRequiredException(task.taskId);
      }
    }

    return resumeOrRestartDownload(
      canResume: () async => false,
      resume: () async => false,
      resumeFromPartial: () => _resumeUsingPartialFile(task),
      restart: () =>
          _enqueueFreshAdaptiveTask(task, knownTotalBytes: saved.totalSize),
      savedProgress: saved.progress,
      existingPartialBytes: saved.partialBytes,
      expectedBytes: saved.totalSize,
    );
'''
if old in text:
    text = text.replace(old, new, 1)
elif 'taskCanResume proves opaque native ownership existed' not in text:
    raise SystemExit('resumeOrRestartDownload marker not found')

old = '''  Future<({DownloadTask task, bool refreshed})> _refreshTaskBeforeResume(
    DownloadTask task, {
    required int expectedBytes,
    required int partialBytes,
  }) async {
'''
new = '''  Future<({DownloadTask task, bool refreshed, bool restartRequired})>
  _refreshTaskBeforeResume(
    DownloadTask task, {
    required int expectedBytes,
    required int partialBytes,
    bool hasOpaqueNativeResume = false,
  }) async {
'''
if old in text:
    text = text.replace(old, new, 1)
elif 'bool hasOpaqueNativeResume = false' not in text:
    raise SystemExit('_refreshTaskBeforeResume signature not found')

old = '''    // Native single-file resume data may be the only durable representation of
    // its bytes. Do not replace that URL unless a visible partial prefix exists.
    // Multipart manifests own their own durable child files, so they are safe.
    if (task is! ParallelDownloadTask && partialBytes <= 0) {
      return (task: task, refreshed: false);
    }

'''
if old in text:
    text = text.replace(old, '', 1)

text = text.replace(
    'return (task: task, refreshed: false);',
    'return (task: task, refreshed: false, restartRequired: false);',
)
text = text.replace(
    ': (task: replaced, refreshed: true);',
    ': (task: replaced, refreshed: true, restartRequired: false);',
)
text = text.replace(
    '? (task: task, refreshed: false)\n          : (task: replaced, refreshed: true, restartRequired: false);',
    '? (task: task, refreshed: false, restartRequired: false)\n          : (task: replaced, refreshed: true, restartRequired: false);',
)
text = text.replace(
    'return (task: updated, refreshed: true);',
    'return (task: updated, refreshed: true, restartRequired: false);',
)

validation = '''    if (metadata?.size == null ||
        (expectedBytes > 0 && metadata!.size != expectedBytes) ||
        ((task is ParallelDownloadTask || partialBytes > 0) &&
            metadata?.supportsRanges != true) ||
        !refreshedIdentityMatches) {
      return (task: task, refreshed: false, restartRequired: false);
    }

'''
insert = validation + '''    if (task is! ParallelDownloadTask &&
        hasOpaqueNativeResume &&
        partialBytes <= 0) {
      // We proved the old source needs replacement and also proved that the
      // only resumable bytes are opaque native resume data tied to that old
      // source. The replacement itself is valid, but those bytes cannot be
      // migrated safely, so leave durable/source state untouched and require an
      // explicit user-visible restart decision.
      return (task: task, refreshed: false, restartRequired: true);
    }

'''
if validation in text and 'only resumable bytes are opaque native resume data' not in text:
    text = text.replace(validation, insert, 1)

# Normalize any missed two-field tuple returns inside this method after broad
# replacements above. Fail closed if a legacy tuple remains.
method_start = text.index('_refreshTaskBeforeResume(')
method_end = text.index('\n  Future<List<Task>> _liveTransferTasks()', method_start)
method = text[method_start:method_end]
if '(task: task, refreshed: false)' in method or '(task: updated, refreshed: true)' in method:
    raise SystemExit('legacy refresh tuple remains')

path.write_text(text)
