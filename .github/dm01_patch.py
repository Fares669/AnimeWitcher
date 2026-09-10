from pathlib import Path

source_path = Path('lib/core/services/persistent_parallel_download.dart')
test_path = Path('test/core/services/persistent_parallel_download_pending_start_lease_test.dart')
source = source_path.read_text()
test = test_path.read_text()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one match, found {count}')
    return text.replace(old, new, 1)


source = replace_once(
    source,
    "const Duration kParallelDiskProgressPollInterval = Duration(seconds: 1);\n\nclass NativeParallelBackgroundPlan {",
    "const Duration kParallelDiskProgressPollInterval = Duration(seconds: 1);\n\n/// Deadline for an accepted multipart enqueue to prove native ownership.\n/// Expiry never guesses that ownership ended: the coordinator first queries\n/// runtime liveness and visible durable bytes, and keeps the lease while\n/// ownership is unknown.\nconst Duration kParallelPendingStartLeaseDelay = Duration(seconds: 5);\n\nclass NativeParallelBackgroundPlan {",
    'constant',
)
source = replace_once(
    source,
    "    this.diskProgressPollInterval = kParallelDiskProgressPollInterval,\n    this.maxActiveConnections = kDownloadGlobalConnectionBudget,",
    "    this.diskProgressPollInterval = kParallelDiskProgressPollInterval,\n    this.pendingStartLeaseDelay = kParallelPendingStartLeaseDelay,\n    this.maxActiveConnections = kDownloadGlobalConnectionBudget,",
    'constructor parameter',
)
source = replace_once(
    source,
    "  final Duration diskProgressPollInterval;\n  final void Function(String url, int fallbackCeiling)? onHostPressure;",
    "  final Duration diskProgressPollInterval;\n  final Duration pendingStartLeaseDelay;\n  final void Function(String url, int fallbackCeiling)? onHostPressure;",
    'field',
)

marker = "  Future<bool> _pumpSession(_ParallelSession session) async {"
helpers = r'''  void _cancelPendingStartLease(_DownloadPart part) {
    part.pendingStartLeaseTimer?.cancel();
    part.pendingStartLeaseTimer = null;
  }

  void _rollbackPendingStartReservation(
    _ParallelSession session,
    _DownloadPart part,
  ) {
    _cancelPendingStartLease(part);
    if (session.currentBatchPendingIds.remove(part.task.taskId)) {
      session.currentBatchRemaining++;
    }
    _activeConnectionIds.remove(part.task.taskId);
    part.launched = false;
    part.speed = 0;
  }

  Future<int> _durablePartBytes(_DownloadPart part) async {
    try {
      final saved = await canonicalizePartialDownloadFile(
        destinationPath: await part.task.filePath(),
      );
      if (saved != null) return saved.bytes;
      final file = File(await part.task.filePath());
      if (await file.exists()) return await file.length();
    } catch (_) {}
    return 0;
  }

  void _armPendingStartLease(_ParallelSession session, _DownloadPart part) {
    if (_disposed ||
        !session.active ||
        session.pauseRequested ||
        session.deleted ||
        part.complete ||
        !part.launched ||
        !session.currentBatchPendingIds.contains(part.task.taskId)) {
      _cancelPendingStartLease(part);
      return;
    }

    _cancelPendingStartLease(part);
    final parentGeneration = session.generation;
    final attemptGeneration = part.attemptGeneration;
    part.pendingStartLeaseTimer = Timer(pendingStartLeaseDelay, () {
      part.pendingStartLeaseTimer = null;
      unawaited(
        session.serialize(() async {
          if (_disposed ||
              !session.active ||
              session.pauseRequested ||
              session.deleted ||
              session.generation != parentGeneration ||
              part.complete ||
              !part.launched ||
              part.attemptGeneration != attemptGeneration ||
              !session.currentBatchPendingIds.contains(part.task.taskId)) {
            return;
          }

          final lookup = livePartIds;
          if (lookup == null) {
            _armPendingStartLease(session, part);
            return;
          }

          Set<String> live;
          try {
            live = await lookup();
          } catch (_) {
            // Failed liveness means ownership is unknown, never absent.
            _armPendingStartLease(session, part);
            return;
          }
          if (live.contains(part.task.taskId)) {
            _markConnectionReady(session, part);
            _armTailStallWatch(session, part);
            await _persist(session);
            return;
          }

          final durableBytes = await _durablePartBytes(part);
          if (durableBytes == part.size &&
              part.size > 0 &&
              await _adoptExactSizePart(
                session,
                part,
                settleNativeOwner: false,
              )) {
            await _afterAdoptedPart(session);
            return;
          }

          // Close the liveness-vs-disk-read race before releasing the slot.
          try {
            live = await lookup();
          } catch (_) {
            _armPendingStartLease(session, part);
            return;
          }
          if (live.contains(part.task.taskId)) {
            _markConnectionReady(session, part);
            _armTailStallWatch(session, part);
            await _persist(session);
            return;
          }

          diagnosticLog?.record('parallel.pendingStartLeaseExpired', {
            'taskId': session.task.taskId,
            'childTaskId': part.task.taskId,
            'attemptGeneration': attemptGeneration,
            'durableBytes': durableBytes,
          });
          _rollbackPendingStartReservation(session, part);
          _schedulePartRecovery(session, part);
          await _persist(session);
          if (session.active) await _status(session, TaskStatus.running);
          _schedulePumpAll();
        }),
      );
    });
  }

'''
source = replace_once(source, marker, helpers + marker, 'helpers')

old_rollback = r'''        void rollbackUnownedReservation() {
          // Reservation happens before startPart to close the enqueue/running
          // race. If native never accepts the child, put that slot back into
          // the same slow-start batch. Otherwise repeated transient enqueue
          // failures consume the batch counter and can strand the episode with
          // no launchable work even though its immutable Range still exists.
          if (session.currentBatchPendingIds.remove(part.task.taskId)) {
            session.currentBatchRemaining++;
          }
          _activeConnectionIds.remove(part.task.taskId);
          part.launched = false;
        }
'''
new_rollback = r'''        void rollbackUnownedReservation() =>
            _rollbackPendingStartReservation(session, part);
'''
source = replace_once(source, old_rollback, new_rollback, 'rollback')

old_accept = r'''        if (record != null &&
            (record.status == TaskStatus.running ||
                record.status == TaskStatus.waitingToRetry)) {
          session.currentBatchPendingIds.remove(part.task.taskId);
        }
'''
new_accept = r'''        if (record != null &&
            (record.status == TaskStatus.running ||
                record.status == TaskStatus.waitingToRetry)) {
          _markConnectionReady(session, part);
        } else {
          _armPendingStartLease(session, part);
        }
'''
source = replace_once(source, old_accept, new_accept, 'accepted start')

source = replace_once(
    source,
    "  void _markConnectionReady(_ParallelSession session, _DownloadPart part) {\n    if (!session.currentBatchPendingIds.remove(part.task.taskId)) return;",
    "  void _markConnectionReady(_ParallelSession session, _DownloadPart part) {\n    _cancelPendingStartLease(part);\n    if (!session.currentBatchPendingIds.remove(part.task.taskId)) return;",
    'ready cancellation',
)
source = replace_once(
    source,
    "    part.recoveryTimer = null;\n    _cancelTailStallWatch(part);\n    _activeConnectionIds.remove(part.task.taskId);",
    "    part.recoveryTimer = null;\n    _cancelPendingStartLease(part);\n    _cancelTailStallWatch(part);\n    _activeConnectionIds.remove(part.task.taskId);",
    'release cancellation',
)
source = replace_once(
    source,
    "    }\n    _cancelTailStallWatch(part);\n    part.recoveryAttempts++;\n    part.speed = 0;\n    _invalidatePartAttempt(session, part);",
    "    }\n    _cancelPendingStartLease(part);\n    _cancelTailStallWatch(part);\n    part.recoveryAttempts++;\n    part.speed = 0;\n    _invalidatePartAttempt(session, part);",
    'recovery cancellation',
)

old_reconcile_live = r'''          if (nativeOwnsPart) {
            _armTailStallWatch(session, part);
            continue;
          }

          // URLSession can temporarily drop a worker during hand-off without
'''
new_reconcile_live = r'''          if (nativeOwnsPart) {
            _markConnectionReady(session, part);
            _armTailStallWatch(session, part);
            continue;
          }

          if (session.currentBatchPendingIds.contains(part.task.taskId)) {
            _rollbackPendingStartReservation(session, part);
          }

          // URLSession can temporarily drop a worker during hand-off without
'''
source = replace_once(source, old_reconcile_live, new_reconcile_live, 'reconcile lease')

source = replace_once(
    source,
    "      part.recoveryTimer?.cancel();\n      part.recoveryTimer = null;\n      part.tailStallTimer?.cancel();",
    "      part.recoveryTimer?.cancel();\n      part.recoveryTimer = null;\n      part.pendingStartLeaseTimer?.cancel();\n      part.pendingStartLeaseTimer = null;\n      part.tailStallTimer?.cancel();",
    'reset cancellation',
)
source = replace_once(
    source,
    "  int recoveryAttempts = 0;\n  Timer? recoveryTimer;\n  Timer? tailStallTimer;",
    "  int recoveryAttempts = 0;\n  Timer? recoveryTimer;\n  Timer? pendingStartLeaseTimer;\n  Timer? tailStallTimer;",
    'part timer field',
)

test = replace_once(
    test,
    "        recoveryDelay: const Duration(milliseconds: 10),\n        maxActiveConnections: 2,",
    "        recoveryDelay: const Duration(milliseconds: 10),\n        pendingStartLeaseDelay: const Duration(milliseconds: 40),\n        maxActiveConnections: 2,",
    'test lease delay',
)
test = replace_once(
    test,
    "        await Future<void>.delayed(const Duration(seconds: 6));",
    "        await Future<void>.delayed(const Duration(milliseconds: 250));",
    'test wait',
)

source_path.write_text(source)
test_path.write_text(test)
