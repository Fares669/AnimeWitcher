from pathlib import Path
import re


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise SystemExit(f'missing invariant: {label}')


state_path = Path('lib/core/services/download_job_state.dart')
state = state_path.read_text()
if 'downloadJobHasUserPauseIntent' not in state:
    pattern = re.compile(
        r"bool downloadJobUserPaused\(DownloadJobState state\) =>\n\s+state == DownloadJobState\.pausedByUser;\n"
    )
    match = pattern.search(state)
    if match is None:
        raise SystemExit('downloadJobUserPaused anchor missing')
    replacement = match.group(0) + '''\n/// Durable user-pause intent is encoded in logical state only.\nbool downloadJobHasUserPauseIntent(DownloadJobState state) =>\n    state == DownloadJobState.pausing ||\n    state == DownloadJobState.pausedByUser;\n\nbool downloadJobIsTerminal(DownloadJobState state) =>\n    state == DownloadJobState.completed ||\n    state == DownloadJobState.canceled ||\n    state == DownloadJobState.orphaned;\n\n/// One-time migration for pre-v6 side flags. Pause wins over queue.\nDownloadJobState migrateLegacyDownloadJobState({\n  required DownloadJobState state,\n  required bool userPaused,\n  required bool queueWaiting,\n}) {\n  if (downloadJobIsTerminal(state)) return state;\n  if (userPaused) {\n    return state == DownloadJobState.pausing\n        ? DownloadJobState.pausing\n        : DownloadJobState.pausedByUser;\n  }\n  if (queueWaiting) return DownloadJobState.queued;\n  return state;\n}\n'''
    state = state[:match.start()] + replacement + state[match.end():]
state_path.write_text(state)

store_path = Path('lib/core/services/download_job_store.dart')
store = store_path.read_text()
store = store.replace(
    'const int kDownloadJobSchemaVersion = 5;',
    'const int kDownloadJobSchemaVersion = 6;',
    1,
)
if 'var state = _jobStateValue' not in store:
    marker = "    final schemaVersion = _intValue(map['schemaVersion'], fallback: 1);\n"
    if marker not in store:
        raise SystemExit('schemaVersion marker missing')
    store = store.replace(
        marker,
        marker
        + "    var state = _jobStateValue(map['state']);\n"
        + "    if (schemaVersion < 6) {\n"
        + "      state = migrateLegacyDownloadJobState(\n"
        + "        state: state,\n"
        + "        userPaused: map['userPaused'] == true,\n"
        + "        queueWaiting: map['queueWaiting'] == true,\n"
        + "      );\n"
        + "    }\n",
        1,
    )
store = store.replace(
    "      state: _jobStateValue(map['state']),",
    "      state: state,",
    1,
)
store = store.replace(
    "      userPaused: map['userPaused'] == true,\n      queueWaiting: map['queueWaiting'] == true,",
    "      userPaused: downloadJobHasUserPauseIntent(state),\n      queueWaiting: downloadJobQueueWaiting(state),",
    1,
)
store = store.replace(
    "    'userPaused': userPaused,\n    'queueWaiting': queueWaiting,",
    "    'userPaused': downloadJobHasUserPauseIntent(state),\n    'queueWaiting': downloadJobQueueWaiting(state),",
    1,
)
if 'userPaused: downloadJobHasUserPauseIntent(next.state)' not in store:
    marker = '    final durable = next.copyWith(\n      logicalId: incomingLogicalId ?? currentLogicalId,\n'
    if marker not in store:
        raise SystemExit('durable copy marker missing')
    store = store.replace(
        marker,
        marker
        + '      userPaused: downloadJobHasUserPauseIntent(next.state),\n'
        + '      queueWaiting: downloadJobQueueWaiting(next.state),\n',
        1,
    )
store_path.write_text(store)

service_path = Path('lib/core/services/download_service.dart')
service = service_path.read_text()

# Replace the whole startup intent hydration method; this is intentionally tiny
# and bounded by the next method's documentation comment.
method_pattern = re.compile(
    r"  Future<void> _restoreAuthoritativeJobIntent\(\) async \{.*?\n  \}\n\n  /// Persist lifecycle boundaries",
    re.S,
)
match = method_pattern.search(service)
if match is None:
    raise SystemExit('restoreAuthoritativeJobIntent method missing')
method = '''  Future<void> _restoreAuthoritativeJobIntent() async {\n    for (final job in await _jobStore.all()) {\n      if (downloadJobHasUserPauseIntent(job.state)) {\n        _userPausedIds.add(job.taskId);\n      }\n      if (downloadJobQueueWaiting(job.state)) {\n        _queueWaitingIds.add(job.taskId);\n      }\n      if (downloadJobIsTerminal(job.state)) {\n        _terminalJobIds.add(job.taskId);\n      }\n    }\n  }\n\n  /// Persist lifecycle boundaries'''
service = service[:match.start()] + method + service[match.end():]

service = re.sub(
    r"      final queueWaiting = oldJob == null\n\s+\? legacyQueueWaiting\n\s+: oldJob\.queueWaiting \|\| oldJob\.state == DownloadJobState\.queued;",
    '''      final queueWaiting = oldJob == null\n          ? legacyQueueWaiting\n          : downloadJobQueueWaiting(oldJob.state);''',
    service,
    count=1,
)
service = re.sub(
    r"      final userPaused =\n\s+isUserPausedMetadata\(metadata\) \|\|\n\s+_userPausedIds\.contains\(task\.taskId\) \|\|\n\s+oldJob\?\.userPaused == true \|\|\n\s+oldJob\?\.state == DownloadJobState\.pausedByUser \|\|\n\s+oldJob\?\.state == DownloadJobState\.pausing;",
    '''      final userPaused = oldJob != null\n          ? downloadJobHasUserPauseIntent(oldJob.state)\n          : isUserPausedMetadata(metadata) ||\n                _userPausedIds.contains(task.taskId);''',
    service,
    count=1,
)
service = service.replace(
    '        userPaused: userPaused,\n        queueWaiting: recoveryPlan.shouldRequeue,',
    '        userPaused: downloadJobHasUserPauseIntent(recoveryPlan.state),\n        queueWaiting: downloadJobQueueWaiting(recoveryPlan.state),',
    1,
)

display_pattern = re.compile(
    r"      final showAsWaiting = _queueWaitingIds\.contains\(task\.taskId\);\n"
    r"      final showAsRunning =.*?\n"
    r"      _publishProgress\(\n"
    r"        trackingUrl: trackingUrl,\n"
    r"        taskId: task\.taskId,\n"
    r"        progress: progress,\n"
    r"        totalSize: expectedBytes,\n"
    r"        status: showAsWaiting.*?\n"
    r"      \);",
    re.S,
)
if display_pattern.search(service):
    service = display_pattern.sub(
        '''      final projectedJob = await _jobStore.get(task.taskId);\n      final projectedState = projectedJob?.state ?? recoveryPlan.state;\n      _publishProgress(\n        trackingUrl: trackingUrl,\n        taskId: task.taskId,\n        progress: progress,\n        totalSize: expectedBytes,\n        status: downloadJobDisplayStatus(projectedState),\n      );''',
        service,
        count=1,
    )

service = service.replace(
    '''          state: _userPausedIds.contains(task.taskId)\n              ? DownloadJobState.pausedByUser\n              : DownloadJobState.interrupted,''',
    '''          state: downloadJobHasUserPauseIntent(\n            (await _jobStore.get(task.taskId))?.state ??\n                DownloadJobState.interrupted,\n          )\n              ? DownloadJobState.pausedByUser\n              : DownloadJobState.interrupted,''',
    1,
)
service_path.write_text(service)

# Hard assertions: the repair is successful only if legacy replicas no longer
# override an existing durable job in the known recovery paths.
state = state_path.read_text()
store = store_path.read_text()
service = service_path.read_text()
require(state, 'downloadJobHasUserPauseIntent', 'pause intent helper')
require(state, 'migrateLegacyDownloadJobState', 'legacy state migration')
require(store, 'const int kDownloadJobSchemaVersion = 6;', 'schema v6')
require(store, "'userPaused': downloadJobHasUserPauseIntent(state)", 'serialized pause projection')
require(store, 'userPaused: downloadJobHasUserPauseIntent(state)', 'read pause projection')
require(store, 'userPaused: downloadJobHasUserPauseIntent(next.state)', 'write normalization')
if 'oldJob?.userPaused == true' in service:
    raise SystemExit('stale JobStore side flag still drives recovery pause')
require(service, 'final projectedState = projectedJob?.state ?? recoveryPlan.state;', 'recovery UI state projection')
