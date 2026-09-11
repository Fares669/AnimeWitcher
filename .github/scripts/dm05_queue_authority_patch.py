from pathlib import Path

state_path = Path('lib/core/services/download_job_state.dart')
state = state_path.read_text()

enum_anchor = '''enum DownloadJobState {
  queued,
  starting,
  running,
  retryWaiting,
  pausing,
  pausedByUser,
  interrupted,
  assembling,
  verifying,
  completed,
  canceled,
  orphaned,
}
'''
helpers = enum_anchor + '''
/// Queue scheduling is a projection of the durable logical state. Plugin
/// TaskStatus and legacy metadata are executor/migration evidence only.
bool downloadJobQueueWaiting(DownloadJobState state) =>
    state == DownloadJobState.queued;

/// `pausing` still owns its slot until executor ownership is proven released;
/// only the settled logical pause is excluded as user-paused by the scheduler.
bool downloadJobUserPaused(DownloadJobState state) =>
    state == DownloadJobState.pausedByUser;

bool downloadJobOccupiesSlot(DownloadJobState state) {
  return switch (state) {
    DownloadJobState.starting ||
    DownloadJobState.running ||
    DownloadJobState.retryWaiting ||
    DownloadJobState.pausing ||
    DownloadJobState.assembling ||
    DownloadJobState.verifying => true,
    DownloadJobState.queued ||
    DownloadJobState.pausedByUser ||
    DownloadJobState.interrupted ||
    DownloadJobState.completed ||
    DownloadJobState.canceled ||
    DownloadJobState.orphaned => false,
  };
}

/// Compatibility projection for queue code that still consumes TaskStatus.
/// This never reads TaskStatus to derive logical state; direction is strictly
/// DownloadJobState -> plugin-shaped status.
TaskStatus downloadJobTaskStatus(DownloadJobState state) {
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
if 'bool downloadJobQueueWaiting(' not in state:
    if state.count(enum_anchor) != 1:
        raise SystemExit('DownloadJobState enum anchor mismatch')
    state = state.replace(enum_anchor, helpers, 1)
state_path.write_text(state)

service_path = Path('lib/core/services/download_service.dart')
source = service_path.read_text()

old_occupied = '''  int _occupiedSlotCount(List<TaskRecord> records) {
    final occupying = <String>{};
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final taskId = record.task.taskId;
      if (_userPausedIds.contains(taskId)) {
        if (_parallel.hasLiveConnections(taskId)) occupying.add(taskId);
        continue;
      }
      if (reservesDownloadSlot(
        status: record.status,
        queueWaiting: _queueWaitingIds.contains(taskId),
      )) {
        occupying.add(taskId);
      }
    }
    occupying.addAll(_startingTaskIds);
    occupying.removeAll(_restackingWaiterIds);
    return occupying.length;
  }
'''
new_occupied = '''  Future<int> _occupiedSlotCount(List<TaskRecord> records) async {
    final occupying = <String>{};
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final taskId = record.task.taskId;
      final job = await _jobStore.get(taskId);
      if (job != null) {
        if (downloadJobOccupiesSlot(job.state)) occupying.add(taskId);
        continue;
      }

      // Pre-JobStore migration fallback only. Once a durable job exists the
      // replicas below are never allowed to decide lifecycle.
      if (_userPausedIds.contains(taskId)) {
        if (_parallel.hasLiveConnections(taskId)) occupying.add(taskId);
        continue;
      }
      if (reservesDownloadSlot(
        status: record.status,
        queueWaiting: _queueWaitingIds.contains(taskId),
      )) {
        occupying.add(taskId);
      }
    }
    occupying.addAll(_startingTaskIds);
    occupying.removeAll(_restackingWaiterIds);
    return occupying.length;
  }
'''
if source.count(old_occupied) != 1:
    raise SystemExit(f'occupied method anchor mismatch: {source.count(old_occupied)}')
source = source.replace(old_occupied, new_occupied, 1)

old_queue = '''  Future<List<DownloadQueueEntry>> _queueEntries(
    List<TaskRecord> records,
  ) async {
    final storage = _ref.read(storageServiceProvider);
    final entries = <DownloadQueueEntry>[];
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      if (record.status == TaskStatus.complete ||
          record.status == TaskStatus.canceled) {
        continue;
      }
      final metadata = await storage.getDownloadMetadata(record.task.taskId);
      final queueWaiting =
          _queueWaitingIds.contains(record.task.taskId) ||
          isQueueWaitingMetadata(metadata);
      final userPaused =
          _userPausedIds.contains(record.task.taskId) ||
          isUserPausedMetadata(metadata);
      entries.add(
        DownloadQueueEntry(
          taskId: record.task.taskId,
          status: record.status,
          timestamp: (metadata?['timestamp'] as int?) ?? 0,
          queueWaiting: queueWaiting,
          userPaused: userPaused,
        ),
      );
    }
    return entries;
  }
'''
new_queue = '''  Future<List<DownloadQueueEntry>> _queueEntries(
    List<TaskRecord> records,
  ) async {
    final storage = _ref.read(storageServiceProvider);
    final entries = <DownloadQueueEntry>[];
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final taskId = record.task.taskId;
      final job = await _jobStore.get(taskId);
      if (job != null &&
          (job.state == DownloadJobState.completed ||
              job.state == DownloadJobState.canceled ||
              job.state == DownloadJobState.orphaned)) {
        continue;
      }
      if (job == null &&
          (record.status == TaskStatus.complete ||
              record.status == TaskStatus.canceled)) {
        continue;
      }
      final metadata = await storage.getDownloadMetadata(taskId);
      final queueWaiting = job != null
          ? downloadJobQueueWaiting(job.state)
          : _queueWaitingIds.contains(taskId) || isQueueWaitingMetadata(metadata);
      final userPaused = job != null
          ? downloadJobUserPaused(job.state)
          : _userPausedIds.contains(taskId) || isUserPausedMetadata(metadata);
      entries.add(
        DownloadQueueEntry(
          taskId: taskId,
          status: job != null ? downloadJobTaskStatus(job.state) : record.status,
          timestamp: (metadata?['timestamp'] as int?) ?? job?.updatedAt ?? 0,
          queueWaiting: queueWaiting,
          userPaused: userPaused,
        ),
      );
    }
    return entries;
  }
'''
if source.count(old_queue) != 1:
    raise SystemExit(f'queue method anchor mismatch: {source.count(old_queue)}')
source = source.replace(old_queue, new_queue, 1)

source = source.replace(
    '''if (_occupiedSlotCount(await FileDownloader().database.allRecords()) >=\n          max) {''',
    '''if ((await _occupiedSlotCount(\n              await FileDownloader().database.allRecords(),\n            )) >=\n          max) {''',
)
source = source.replace(
    'final occupiedAfterEarlier = _occupiedSlotCount(latestRecords);',
    'final occupiedAfterEarlier = await _occupiedSlotCount(latestRecords);',
)
source = source.replace(
    '''final occupied = _occupiedSlotCount(\n          await FileDownloader().database.allRecords(),\n        );''',
    '''final occupied = await _occupiedSlotCount(\n          await FileDownloader().database.allRecords(),\n        );''',
)

# No synchronous call may remain after the async conversion.
remaining = [line for line in source.splitlines() if '_occupiedSlotCount(' in line]
for line in remaining:
    stripped = line.strip()
    if stripped.startswith('Future<int> _occupiedSlotCount('):
        continue
    if 'await _occupiedSlotCount(' not in line:
        raise SystemExit(f'unconverted occupied-slot call: {line}')

service_path.write_text(source)
