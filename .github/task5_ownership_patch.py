from pathlib import Path

path = Path('lib/core/services/download_service.dart')
source = path.read_text()

old = """  Future<DownloadRuntimeOwnership> _runtimeOwnershipFor(String taskId) async {
    if (_rangeTransfers.isActive(taskId) ||
        _parallel.isActive(taskId) ||
        _parallel.hasLiveConnections(taskId)) {
      return DownloadRuntimeOwnership.owned;
    }
    try {
      final activeTasks = await _liveTransferTasks();
      return resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: true,
        runtimeTaskPresent: activeTasks.any((task) => task.taskId == taskId),
        transferHandlePresent: _nativeTransport.handleFor(taskId) != null,
      );
    } catch (_) {
      return resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: false,
        runtimeTaskPresent: false,
        transferHandlePresent: _nativeTransport.handleFor(taskId) != null,
      );
    }
  }
"""

new = """  Future<DownloadRuntimeOwnership> _runtimeOwnershipFor(String taskId) async {
    if (_rangeTransfers.isActive(taskId) ||
        _parallel.isActive(taskId) ||
        _parallel.hasLiveConnections(taskId)) {
      return DownloadRuntimeOwnership.owned;
    }
    return _nativeTransport.ownershipFor(taskId);
  }
"""

count = source.count(old)
if count != 1:
    raise SystemExit(f'Task 5 ownership patch expected one match, found {count}')

updated = source.replace(old, new, 1)
if '_nativeTransport.ownershipFor(taskId)' not in updated:
    raise SystemExit('Task 5 ownership delegation missing after patch')
path.write_text(updated)
