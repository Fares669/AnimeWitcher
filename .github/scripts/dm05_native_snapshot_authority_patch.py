from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()

old = '''    final waiters = <Map<String, Object>>[];
    final transferring = <String>[];
    final paused = <String>[];
    final waiterIds = <String>{};
    final completedIds = <String>{};
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final task = record.task as DownloadTask;
      if (record.status == TaskStatus.complete) {
        completedIds.add(task.taskId);
        _waitingPayloads.remove(task.taskId);
        continue;
      }
      if (record.status == TaskStatus.canceled &&
          !_userPausedIds.contains(task.taskId)) {
        completedIds.add(task.taskId);
        _waitingPayloads.remove(task.taskId);
        continue;
      }
      final leftoverWaiting = _queueWaitingIds.contains(task.taskId);
      final userPaused =
          _userPausedIds.contains(task.taskId) ||
          (record.status == TaskStatus.paused && !leftoverWaiting);
      if (userPaused) {
        paused.add(task.taskId);
        continue;
      }
      // Swift's fallback waiter starts one raw URLSession task.
      // Never pass it a ParallelDownloadTask: doing so silently turns a
      // requested four-part episode into one part. Dart/PersistentParallelDownload
      // owns multipart promotion and all child checkpoint/assembly semantics.
      if (isNativeWaitingSnapshotWaiter(
            status: record.status,
            queueWaiting: leftoverWaiting,
            userPaused: false,
          ) &&
          task is! ParallelDownloadTask) {
        waiters.add(await _waitingPayloadPreservingBytes(task));
        waiterIds.add(task.taskId);
        continue;
      }
      if (occupiesDownloadSlot(status: record.status, queueWaiting: false)) {
        transferring.add(task.taskId);
        _waitingPayloads.remove(task.taskId);
      }
    }
    for (final id in _userPausedIds) {
      if (!paused.contains(id) && !completedIds.contains(id)) {
        paused.add(id);
        transferring.remove(id);
      }
    }
    for (final entry in _waitingPayloads.entries) {
      if (waiterIds.contains(entry.key) ||
          paused.contains(entry.key) ||
          transferring.contains(entry.key) ||
          completedIds.contains(entry.key)) {
        continue;
      }
      final record = records.firstWhereOrNull(
        (record) => record.task.taskId == entry.key,
      );
      if (record?.task is ParallelDownloadTask ||
          _rangeTransfers.isActive(entry.key))
        continue;
      waiters.add(
        await _waitingPayloadPreservingBytes(
          record?.task as DownloadTask? ??
              Task.createFromJsonString(entry.value['taskJson'] as String)
                  as DownloadTask,
        ),
      );
    }
'''
new = '''    final waiters = <Map<String, Object>>[];
    final transferring = <String>[];
    final paused = <String>[];
    final waiterIds = <String>{};
    final queueWaitingIds = <String>{};
    final completedIds = <String>{};
    for (final record in records) {
      if (!isLogicalEpisodeDownloadTask(record.task)) continue;
      final task = record.task as DownloadTask;
      final job = await _jobStore.get(task.taskId);
      if (job != null &&
          (job.state == DownloadJobState.completed ||
              job.state == DownloadJobState.canceled ||
              job.state == DownloadJobState.orphaned)) {
        completedIds.add(task.taskId);
        _waitingPayloads.remove(task.taskId);
        continue;
      }
      if (job == null) {
        // Pre-JobStore migration fallback: plugin status and in-memory intent
        // may classify old executor rows only until durable authority exists.
        if (record.status == TaskStatus.complete) {
          completedIds.add(task.taskId);
          _waitingPayloads.remove(task.taskId);
          continue;
        }
        if (record.status == TaskStatus.canceled &&
            !_userPausedIds.contains(task.taskId)) {
          completedIds.add(task.taskId);
          _waitingPayloads.remove(task.taskId);
          continue;
        }
      }
      final leftoverWaiting = job != null
          ? downloadJobQueueWaiting(job.state)
          : _queueWaitingIds.contains(task.taskId);
      final userPaused = job != null
          ? downloadJobUserPaused(job.state)
          : _userPausedIds.contains(task.taskId) ||
                (record.status == TaskStatus.paused && !leftoverWaiting);
      final projectedStatus = job != null
          ? downloadJobTaskStatus(job.state)
          : record.status;
      if (leftoverWaiting) queueWaitingIds.add(task.taskId);
      if (userPaused) {
        paused.add(task.taskId);
        continue;
      }
      // Swift's fallback waiter starts one raw URLSession task.
      // Never pass it a ParallelDownloadTask: doing so silently turns a
      // requested four-part episode into one part. Dart/PersistentParallelDownload
      // owns multipart promotion and all child checkpoint/assembly semantics.
      if (isNativeWaitingSnapshotWaiter(
            status: projectedStatus,
            queueWaiting: leftoverWaiting,
            userPaused: false,
          ) &&
          task is! ParallelDownloadTask) {
        waiters.add(await _waitingPayloadPreservingBytes(task));
        waiterIds.add(task.taskId);
        continue;
      }
      final occupiesSlot = job != null
          ? downloadJobOccupiesSlot(job.state)
          : occupiesDownloadSlot(status: record.status, queueWaiting: false);
      if (occupiesSlot) {
        transferring.add(task.taskId);
        _waitingPayloads.remove(task.taskId);
      }
    }
    for (final id in _userPausedIds) {
      final job = await _jobStore.get(id);
      if (job != null && !downloadJobUserPaused(job.state)) continue;
      if (!paused.contains(id) && !completedIds.contains(id)) {
        paused.add(id);
        transferring.remove(id);
        queueWaitingIds.remove(id);
      }
    }
    for (final entry in _waitingPayloads.entries) {
      if (waiterIds.contains(entry.key) ||
          paused.contains(entry.key) ||
          transferring.contains(entry.key) ||
          completedIds.contains(entry.key)) {
        continue;
      }
      final job = await _jobStore.get(entry.key);
      if (job != null) {
        if (downloadJobUserPaused(job.state)) {
          paused.add(entry.key);
          continue;
        }
        if (!downloadJobQueueWaiting(job.state)) continue;
        queueWaitingIds.add(entry.key);
      }
      final record = records.firstWhereOrNull(
        (record) => record.task.taskId == entry.key,
      );
      if (record?.task is ParallelDownloadTask ||
          _rangeTransfers.isActive(entry.key)) {
        continue;
      }
      waiters.add(
        await _waitingPayloadPreservingBytes(
          record?.task as DownloadTask? ??
              Task.createFromJsonString(entry.value['taskJson'] as String)
                  as DownloadTask,
        ),
      );
    }
'''
if source.count(old) != 1:
    raise SystemExit(f'native snapshot authority anchor mismatch: {source.count(old)}')
source = source.replace(old, new, 1)

old_queue_arg = '''      queueWaitingTaskIds: _queueWaitingIds.toList(),'''
new_queue_arg = '''      queueWaitingTaskIds: queueWaitingIds.toList(),'''
if source.count(old_queue_arg) != 1:
    raise SystemExit(f'queue waiting snapshot arg mismatch: {source.count(old_queue_arg)}')
source = source.replace(old_queue_arg, new_queue_arg, 1)

path.write_text(source)
