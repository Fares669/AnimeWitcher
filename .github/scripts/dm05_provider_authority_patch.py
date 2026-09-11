from pathlib import Path

state_path = Path('lib/core/services/download_job_state.dart')
state = state_path.read_text()

status_anchor = '''TaskStatus downloadJobTaskStatus(DownloadJobState state) {
  return switch (state) {
    DownloadJobState.queued => TaskStatus.paused,
    DownloadJobState.starting => TaskStatus.enqueued,
    DownloadJobState.running ||
    DownloadJobState.pausing ||
    DownloadJobState.assembling ||
    DownloadJobState.verifying => TaskStatus.running,
    DownloadJobState.retryWaiting => TaskStatus.waitingToRetry,
    DownloadJobState.pausedByUser ||
    DownloadJobState.interrupted ||
    DownloadJobState.orphaned => TaskStatus.paused,
    DownloadJobState.completed => TaskStatus.complete,
    DownloadJobState.canceled => TaskStatus.canceled,
  };
}
'''
display_helper = status_anchor + '''
/// User-visible projection of durable logical state. This intentionally differs
/// from [downloadJobTaskStatus] for queued work: executor compatibility may
/// persist it as paused, while the UI must show it as waiting/enqueued.
TaskStatus downloadJobDisplayStatus(DownloadJobState state) {
  return switch (state) {
    DownloadJobState.queued || DownloadJobState.starting => TaskStatus.enqueued,
    DownloadJobState.running ||
    DownloadJobState.pausing ||
    DownloadJobState.assembling ||
    DownloadJobState.verifying => TaskStatus.running,
    DownloadJobState.retryWaiting => TaskStatus.waitingToRetry,
    DownloadJobState.pausedByUser ||
    DownloadJobState.interrupted ||
    DownloadJobState.orphaned => TaskStatus.paused,
    DownloadJobState.completed => TaskStatus.complete,
    DownloadJobState.canceled => TaskStatus.canceled,
  };
}
'''
if 'TaskStatus downloadJobDisplayStatus(' not in state:
    if state.count(status_anchor) != 1:
        raise SystemExit(f'display helper anchor mismatch: {state.count(status_anchor)}')
    state = state.replace(status_anchor, display_helper, 1)
state_path.write_text(state)

service_path = Path('lib/core/services/download_service.dart')
service = service_path.read_text()
service_anchor = '''  Stream<TaskUpdate> get updates => _updatesController.stream;
'''
service_replacement = service_anchor + '''
  /// Read-only logical lifecycle projection for UI surfaces. Executor/plugin
  /// status remains evidence and must not overwrite a durable JobStore state.
  Future<DownloadJobState?> logicalJobStateForTask(String taskId) async {
    final id = taskId.trim();
    if (id.isEmpty) return null;
    return (await _jobStore.get(id))?.state;
  }
'''
if 'Future<DownloadJobState?> logicalJobStateForTask(' not in service:
    if service.count(service_anchor) != 1:
        raise SystemExit(f'service API anchor mismatch: {service.count(service_anchor)}')
    service = service.replace(service_anchor, service_replacement, 1)
service_path.write_text(service)

provider_path = Path('lib/features/library/presentation/downloads_provider.dart')
source = provider_path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'{label} anchor mismatch: {count}')
    source = source.replace(old, new, 1)

replace_once(
    "import '../../../core/services/download_concurrency.dart';\nimport '../../../core/services/download_service.dart';\n",
    "import '../../../core/services/download_concurrency.dart';\nimport '../../../core/services/download_job_state.dart';\nimport '../../../core/services/download_service.dart';\n",
    'provider import',
)

replace_once(
    '''DownloadItem? downloadItemFromTaskMetadata({
  required Task task,
  required TaskStatus status,
  required Map<String, dynamic> metadata,
  double progress = 0,
}) {''',
    '''DownloadItem? downloadItemFromTaskMetadata({
  required Task task,
  required TaskStatus status,
  required Map<String, dynamic> metadata,
  DownloadJobState? logicalState,
  double progress = 0,
}) {''',
    'metadata builder signature',
)
replace_once(
    '''    status: displayDownloadStatus(
      persisted: status,
      queueWaiting: isQueueWaitingMetadata(metadata),
    ),''',
    '''    status: logicalState != null
        ? downloadJobDisplayStatus(logicalState)
        : displayDownloadStatus(
            persisted: status,
            queueWaiting: isQueueWaitingMetadata(metadata),
          ),''',
    'metadata builder status',
)

replace_once(
    '''    final records = await FileDownloader().database.allRecords();
    final storage = ref.read(storageServiceProvider);

    final List<DownloadItem> items = [];''',
    '''    final records = await FileDownloader().database.allRecords();
    final storage = ref.read(storageServiceProvider);
    final downloadService = ref.read(downloadServiceProvider);

    final List<DownloadItem> items = [];''',
    'refresh dependencies',
)

old_refresh = '''      // Skip non-download tasks and cancelled ones. Failed downloads are kept
      // and shown as paused so the user can resume instead of starting over.
      if (record.task is! DownloadTask) continue;
      if (record.status == TaskStatus.canceled) {
        continue;
      }

      var status = record.status;
      var progress = record.progress;
      if (status == TaskStatus.failed || status == TaskStatus.notFound) {
        status = TaskStatus.paused;
        if (progress < 0 || progress > 1) progress = 0.0;
        unawaited(
          FileDownloader().database.updateRecord(
            TaskRecord(
              record.task,
              TaskStatus.paused,
              progress,
              record.expectedFileSize,
            ),
          ),
        );
      } else if (progress < 0 || progress > 1) {
        // Sentinel progress values from the downloader (failed/paused markers)
        progress = status == TaskStatus.complete ? 1.0 : 0.0;
      }

      final metadata = await storage.getDownloadMetadata(record.task.taskId);'''
new_refresh = '''      if (record.task is! DownloadTask) continue;
      final logicalState = await downloadService.logicalJobStateForTask(
        record.task.taskId,
      );

      var status = record.status;
      var progress = record.progress;
      if (logicalState != null) {
        // JobStore is the lifecycle authority. Stale plugin paused/failed/
        // canceled rows are executor evidence only and cannot redefine intent.
        if (logicalState == DownloadJobState.canceled ||
            logicalState == DownloadJobState.orphaned) {
          continue;
        }
        status = downloadJobDisplayStatus(logicalState);
        if (progress < 0 || progress > 1) {
          progress = logicalState == DownloadJobState.completed ? 1.0 : 0.0;
        }
      } else {
        // Pre-JobStore migration fallback: legacy rows without a durable job
        // retain the old plugin-status normalization until they are migrated.
        if (status == TaskStatus.canceled) continue;
        if (status == TaskStatus.failed || status == TaskStatus.notFound) {
          status = TaskStatus.paused;
          if (progress < 0 || progress > 1) progress = 0.0;
          unawaited(
            FileDownloader().database.updateRecord(
              TaskRecord(
                record.task,
                TaskStatus.paused,
                progress,
                record.expectedFileSize,
              ),
            ),
          );
        } else if (progress < 0 || progress > 1) {
          progress = status == TaskStatus.complete ? 1.0 : 0.0;
        }
      }

      final metadata = await storage.getDownloadMetadata(record.task.taskId);'''
replace_once(old_refresh, new_refresh, 'refresh authority')

replace_once(
    '''        status: status,
        metadata: metadata,
        progress: progress,''',
    '''        status: status,
        metadata: metadata,
        logicalState: logicalState,
        progress: progress,''',
    'refresh builder logical state',
)

handle_anchor = '''  Future<void> _handleUpdate(TaskUpdate update) async {
    if (state.value == null || _deletingIds.contains(update.task.taskId))
      return;

    // DownloadService already exposes sampled live metrics.'''
handle_replacement = '''  Future<void> _handleUpdate(TaskUpdate update) async {
    if (state.value == null || _deletingIds.contains(update.task.taskId))
      return;

    final logicalState = await ref
        .read(downloadServiceProvider)
        .logicalJobStateForTask(update.task.taskId);

    // DownloadService already exposes sampled live metrics.'''
replace_once(handle_anchor, handle_replacement, 'handle state lookup')

old_status_update = '''      if (update is TaskProgressUpdate) {
        if (update.progress >= 0 && update.progress <= 1) {
          newProgress = update.progress;
        }
      } else if (update is TaskStatusUpdate) {
        newStatus = update.status;
        if (update.status == TaskStatus.complete) newProgress = 1.0;
      }
'''
new_status_update = '''      if (update is TaskProgressUpdate) {
        if (update.progress >= 0 && update.progress <= 1) {
          newProgress = update.progress;
        }
        if (logicalState != null) {
          newStatus = downloadJobDisplayStatus(logicalState);
        }
      } else if (update is TaskStatusUpdate) {
        if (logicalState != null) {
          newStatus = downloadJobDisplayStatus(logicalState);
          if (logicalState == DownloadJobState.completed) newProgress = 1.0;
        } else {
          // Pre-JobStore migration fallback: raw executor status remains the
          // projection only until a durable logical job exists.
          newStatus = update.status;
          if (update.status == TaskStatus.complete) newProgress = 1.0;
        }
      }
'''
replace_once(old_status_update, new_status_update, 'callback authority')

old_new_row = '''      if (update is TaskStatusUpdate &&
          update.task is DownloadTask &&
          isActiveDownloadStatus(update.status)) {
        final metadata = await ref
            .read(storageServiceProvider)
            .getDownloadMetadata(update.task.taskId);
        final incoming = metadata == null
            ? null
            : downloadItemFromTaskMetadata(
                task: update.task,
                status: update.status,
                metadata: metadata,
              );'''
new_new_row = '''      final projectedStatus = logicalState != null
          ? downloadJobDisplayStatus(logicalState)
          : (update is TaskStatusUpdate ? update.status : null);
      if (update is TaskStatusUpdate &&
          update.task is DownloadTask &&
          projectedStatus != null &&
          isActiveDownloadStatus(projectedStatus)) {
        final metadata = await ref
            .read(storageServiceProvider)
            .getDownloadMetadata(update.task.taskId);
        final incoming = metadata == null
            ? null
            : downloadItemFromTaskMetadata(
                task: update.task,
                status: projectedStatus,
                metadata: metadata,
                logicalState: logicalState,
              );'''
replace_once(old_new_row, new_new_row, 'new row authority')

provider_path.write_text(source)
