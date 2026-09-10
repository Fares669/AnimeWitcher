from pathlib import Path

transport_path = Path('lib/core/services/download_transport.dart')
service_path = Path('lib/core/services/download_service.dart')
test_path = Path('test/core/services/download_runtime_ownership_test.dart')
plan_path = Path('DOWNLOAD_MANAGER_PLAN.md')

transport = transport_path.read_text()
service = service_path.read_text()
plan = plan_path.read_text()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, found {count}')
    return text.replace(old, new, 1)

transport = replace_once(
    transport,
    "const int kDownloadLargeFileHintThresholdBytes = 50 * 1024 * 1024;\n\n",
    """const int kDownloadLargeFileHintThresholdBytes = 50 * 1024 * 1024;\n\n/// Runtime ownership is intentionally separate from persisted task status.\n/// Only [notOwned] permits a new writer for the same execution identity.\nenum DownloadRuntimeOwnership { owned, notOwned, settling, unknown }\n\nextension DownloadRuntimeOwnershipSafety on DownloadRuntimeOwnership {\n  bool get blocksNewWriter => this != DownloadRuntimeOwnership.notOwned;\n}\n\n/// Resolve ownership from executor/runtime evidence only. A persisted database\n/// status is deliberately not an input: it may describe an older projection.\nDownloadRuntimeOwnership resolveDownloadRuntimeOwnership({\n  required bool runtimeQuerySucceeded,\n  required bool runtimeTaskPresent,\n  bool localRangeWriterActive = false,\n  bool operationSettling = false,\n  bool transferHandlePresent = false,\n}) {\n  if (localRangeWriterActive || runtimeTaskPresent) {\n    return DownloadRuntimeOwnership.owned;\n  }\n  if (operationSettling) return DownloadRuntimeOwnership.settling;\n  if (!runtimeQuerySucceeded) {\n    // A Transfer handle can be rehydrated from persistence, so presence alone\n    // cannot prove ownership; query failure therefore remains unknown.\n    return DownloadRuntimeOwnership.unknown;\n  }\n  // A successful executor query that does not contain the task is the\n  // independent negative acknowledgement needed before another writer starts.\n  return DownloadRuntimeOwnership.notOwned;\n}\n\n""",
    'ownership model',
)

old_live = """  Future<List<Task>> _liveTransferTasks() async {
    // allTasks/taskForId include persisted paused tasks. They are not proof
    // that URLSession or a worker currently owns a transfer. Use the public
    // tracked-task database to exclude durable paused records instead of the
    // plugin's testing-only downloader API.
    final paused = (await FileDownloader().database.allRecordsWithStatus(
      TaskStatus.paused,
    )).map((record) => record.taskId).toSet();
    return (await FileDownloader().allTasks(allGroups: true))
        .where((task) => !paused.contains(task.taskId))
        .toList();
  }
"""
new_live = """  Future<List<Task>> _liveTransferTasks() =>
      FileDownloader().allTasks(allGroups: true);

  Future<DownloadRuntimeOwnership> _runtimeOwnershipFor(String taskId) async {
    if (_rangeTransfers.isActive(taskId)) {
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
service = replace_once(service, old_live, new_live, 'runtime liveness')

old_pause_reject = """        return rangeAlreadyStopped &&
            !(await _liveTransferTasks()).any(
              (live) => live.taskId == task.taskId,
            );
"""
new_pause_reject = """        return rangeAlreadyStopped &&
            await _runtimeOwnershipFor(task.taskId) ==
                DownloadRuntimeOwnership.notOwned;
"""
service = replace_once(service, old_pause_reject, new_pause_reject, 'pause rejection ownership')

old_pause_child = """        var stillLive = (await _liveTransferTasks()).any(
          (live) => live.taskId == task.taskId,
        );
        if (stillLive) {
          if (!await FileDownloader().pause(task)) return false;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          stillLive = (await _liveTransferTasks()).any(
            (live) => live.taskId == task.taskId,
          );
        }
        if (stillLive) return false;
"""
new_pause_child = """        var ownership = await _runtimeOwnershipFor(task.taskId);
        if (ownership == DownloadRuntimeOwnership.owned) {
          if (!await FileDownloader().pause(task)) return false;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          ownership = await _runtimeOwnershipFor(task.taskId);
        }
        if (ownership != DownloadRuntimeOwnership.notOwned) return false;
"""
service = replace_once(service, old_pause_child, new_pause_child, 'pause child ownership')

old_start_part = """    if (_rangeTransfers.isActive(task.taskId)) return true;
    if ((await _liveTransferTasks()).any(
      (live) => live.taskId == task.taskId,
    )) {
      return true;
    }
"""
new_start_part = """    final ownership = await _runtimeOwnershipFor(task.taskId);
    if (ownership == DownloadRuntimeOwnership.owned) return true;
    if (ownership.blocksNewWriter) {
      diagnosticLog.record('part.startOwnershipBlocked', {
        'taskId': task.taskId,
        'ownership': ownership.name,
      });
      return false;
    }
"""
service = replace_once(service, old_start_part, new_start_part, 'part start ownership')

if test_path.exists():
    raise SystemExit('DM-19 test file already exists')
test_path.write_text("""import 'package:animewitcher/core/services/download_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('runtime download ownership', () {
    test('persisted paused status cannot negate a runtime-active task', () {
      final ownership = resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: true,
        runtimeTaskPresent: true,
      );
      expect(ownership, DownloadRuntimeOwnership.owned);
      expect(ownership.blocksNewWriter, isTrue);
    });

    test('stale persisted running status cannot create runtime ownership', () {
      final ownership = resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: true,
        runtimeTaskPresent: false,
      );
      expect(ownership, DownloadRuntimeOwnership.notOwned);
      expect(ownership.blocksNewWriter, isFalse);
    });

    test('rehydrated Transfer handle plus failed executor query stays unknown', () {
      final ownership = resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: false,
        runtimeTaskPresent: false,
        transferHandlePresent: true,
      );
      expect(ownership, DownloadRuntimeOwnership.unknown);
      expect(ownership.blocksNewWriter, isTrue);
    });

    test('liveness query failure without a handle also stays unknown', () {
      final ownership = resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: false,
        runtimeTaskPresent: false,
      );
      expect(ownership, DownloadRuntimeOwnership.unknown);
      expect(ownership.blocksNewWriter, isTrue);
    });

    test('settling ownership blocks a second writer', () {
      final ownership = resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: true,
        runtimeTaskPresent: false,
        operationSettling: true,
      );
      expect(ownership, DownloadRuntimeOwnership.settling);
      expect(ownership.blocksNewWriter, isTrue);
    });

    test('local Range ownership is independently authoritative', () {
      final ownership = resolveDownloadRuntimeOwnership(
        runtimeQuerySucceeded: false,
        runtimeTaskPresent: false,
        localRangeWriterActive: true,
      );
      expect(ownership, DownloadRuntimeOwnership.owned);
    });
  });
}
""")

old_plan = """- [ ] **DM-19 — Replace DB-filtered liveness with an independent runtime ownership oracle**
  - **Problem:** `_liveTransferTasks()` can exclude a real worker because the plugin DB row says `paused`.
  - **Root cause:** durable/persisted transport status is incorrectly used as proof that runtime ownership does not exist.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** `download_service.dart`, `download_transport.dart`, platform/native liveness APIs, ownership tests.
  - **Proposed fix:** define `owned / notOwned / settling / unknown` from actual Transfer/native/range/multipart ownership plus acknowledgement. DB status may support a conclusion but can never independently negate a live owner.
  - **Verification/testing:** DB paused + native running; stale DB running + owner gone; Transfer handle exists but executor state unknown; liveness query failure; relaunch; no duplicate resume while unknown.
  - **Dependencies:** None.
"""
new_plan = old_plan + """  - **Implementation status (2026-09-11):** Runtime ownership model and fail-closed writer guard are being implemented. The plugin's public `allTasks(allGroups: true)` active-executor query is now the native ownership source instead of filtering that result with persisted DB `paused` rows; Range ownership remains an independent positive signal. Query failure maps to `unknown`, which blocks a new writer, and accepted-but-unsettled ownership has an explicit `settling` state for subsequent control-ack work.
  - **Confirmed root cause:** `_liveTransferTasks()` took an executor-active result and then removed IDs solely because the persistent database projected them as `paused`, allowing stale DB state to overrule stronger runtime evidence.
"""
plan = replace_once(plan, old_plan, new_plan, 'DM-19 plan progress')

transport_path.write_text(transport)
service_path.write_text(service)
plan_path.write_text(plan)
