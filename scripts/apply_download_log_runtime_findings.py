from pathlib import Path


path = Path('lib/core/services/persistent_parallel_download.dart')
s = path.read_text()

s = s.replace(
    'const Duration kParallelProgressCoalesceDelay = Duration(milliseconds: 350);',
    'const Duration kParallelProgressCoalesceDelay = Duration(seconds: 1);',
)

old = '''    if (!changed) return;
    await _persist(session);
    if (session.parts.every((part) => part.complete)) {
      await _assemble(session);
      return;
    }
    if (!session.parentRunningReported) {
      await _status(session, TaskStatus.running);
    }
    await _emitAggregateProgress(session);
    _schedulePumpAll();
  }

  void _scheduleAggregateProgress(_ParallelSession session) {
    if (_disposed || !session.active || session.deleted) return;
    session.aggregateProgressDirty = true;
    if (session.aggregateProgressTimer != null) return;

    session.aggregateProgressTimer = Timer(kParallelProgressCoalesceDelay, () {
      session.aggregateProgressTimer = null;
      if (_disposed) return;
      unawaited(
        session.serialize(() async {
          if (_disposed ||
              !session.active ||
              session.deleted ||
              !session.aggregateProgressDirty) {
            return;
          }
          session.aggregateProgressDirty = false;
          await _emitAggregateProgress(session);
        }),
      );
    });
  }
'''
new = '''    // Keep a one-second parent heartbeat even when the byte count did not
    // move. That lets the shared telemetry estimator expire a stale speed and
    // pushes 0 B/s to both Flutter and the iOS continued-processing task.
    if (!changed) {
      _scheduleAggregateProgress(session);
      return;
    }
    if (session.parts.every((part) => part.complete)) {
      // Completion is a durability boundary; never defer its manifest write.
      await _persist(session);
      await _assemble(session);
      return;
    }
    if (!session.parentRunningReported) {
      await _status(session, TaskStatus.running);
    }
    _scheduleAggregateProgress(session, persist: true);
  }

  void _scheduleAggregateProgress(
    _ParallelSession session, {
    bool persist = false,
  }) {
    if (_disposed || !session.active || session.deleted) return;
    session.aggregateProgressDirty = true;
    if (persist) session.aggregatePersistDirty = true;
    if (session.aggregateProgressTimer != null) return;

    session.aggregateProgressTimer = Timer(kParallelProgressCoalesceDelay, () {
      session.aggregateProgressTimer = null;
      if (_disposed) return;
      unawaited(
        session.serialize(() async {
          if (_disposed ||
              !session.active ||
              session.deleted ||
              !session.aggregateProgressDirty) {
            return;
          }
          final persistCheckpoint = session.aggregatePersistDirty;
          session.aggregateProgressDirty = false;
          session.aggregatePersistDirty = false;
          // Native child callbacks can arrive from every active Range. Writing
          // and fsyncing the whole manifest for each callback used to backlog
          // the session serializer and delay pause/resume/pump work by tens of
          // seconds. Checkpoint active progress once per parent sample instead.
          if (persistCheckpoint) await _persist(session);
          await _emitAggregateProgress(session);
        }),
      );
    });
  }
'''
if old not in s:
    raise SystemExit('aggregate progress block not found')
s = s.replace(old, new)

old = '''      if (credible > previousCredible || completed) {
        onPartProgress(
          session.task.taskId,
          part.task.taskId,
          part.credibleProgress,
        );
        await _persist(session);
      }

      if (!session.active) return;
      if (!session.parentRunningReported) {
        await _status(session, TaskStatus.running);
      }
      await _emitAggregateProgress(session);
      _schedulePumpAll();
'''
new = '''      final progressChanged = credible > previousCredible || completed;
      if (progressChanged) {
        onPartProgress(
          session.task.taskId,
          part.task.taskId,
          part.credibleProgress,
        );
      }

      if (!session.active) {
        // A late native callback after pause still carries credible bytes. It
        // must be durable immediately because no active checkpoint timer runs.
        if (progressChanged) await _persist(session);
        return;
      }
      if (!session.parentRunningReported) {
        await _status(session, TaskStatus.running);
      }
      _scheduleAggregateProgress(session, persist: progressChanged);
'''
if old not in s:
    raise SystemExit('native chunk update block not found')
s = s.replace(old, new)

old = '''            onPartProgress(
              session.task.taskId,
              part.task.taskId,
              part.credibleProgress,
            );
            await _persist(session);
            if (session.active) {
              _scheduleAggregateProgress(session);
            }
            _schedulePumpAll();
            return;
'''
new = '''            onPartProgress(
              session.task.taskId,
              part.task.taskId,
              part.credibleProgress,
            );
            if (session.active) {
              _scheduleAggregateProgress(
                session,
                persist: part.credibleProgress > previousCredibleProgress,
              );
            } else if (part.credibleProgress > previousCredibleProgress) {
              // Preserve late bytes immediately while the parent is inactive.
              await _persist(session);
            }
            return;
'''
if old not in s:
    raise SystemExit('plugin progress update block not found')
s = s.replace(old, new)

old = '''  Timer? aggregateProgressTimer;
  bool aggregateProgressDirty = false;
  Timer? diskProgressTimer;
'''
new = '''  Timer? aggregateProgressTimer;
  bool aggregateProgressDirty = false;
  bool aggregatePersistDirty = false;
  Timer? diskProgressTimer;
'''
if old not in s:
    raise SystemExit('session aggregate fields not found')
s = s.replace(old, new)

old = '''    aggregateProgressTimer = null;
    aggregateProgressDirty = false;
  }
'''
new = '''    aggregateProgressTimer = null;
    aggregateProgressDirty = false;
    aggregatePersistDirty = false;
  }
'''
if old not in s:
    raise SystemExit('cancel aggregate block not found')
s = s.replace(old, new)
path.write_text(s)


path = Path('ios/Runner/DownloadNativeWaitingQueue.swift')
s = path.read_text()
s = s.replace('now - previous < 0.25', 'now - previous < 1.0')
s = s.replace(
    'private static let chunkBridgeInterval: CFTimeInterval = 0.25',
    'private static let chunkBridgeInterval: CFTimeInterval = 1.0',
)
s = s.replace(
    'private static let taskBridgeInterval: CFTimeInterval = 0.25',
    'private static let taskBridgeInterval: CFTimeInterval = 1.0',
)
path.write_text(s)


path = Path('ios/Runner/DownloadContinuedProcessingManager.swift')
s = path.read_text()
old = '''  private var didRegisterIdentifier = false
  private var currentEpisodeTaskId = ""

  private init() {}
'''
new = '''  private var didRegisterIdentifier = false
  private var currentEpisodeTaskId = ""
  private var lastAppliedUpdateAt: TimeInterval = 0
  private let minimumUpdateInterval: TimeInterval = 1.0

  private init() {}
'''
if old not in s:
    raise SystemExit('continued manager fields not found')
s = s.replace(old, new)

old = '''    if let active = activeTask {
      apply(snapshot, to: active)
      return identifier
    }
'''
new = '''    if let active = activeTask {
      applyIfDue(snapshot, to: active)
      return identifier
    }
'''
if old not in s:
    raise SystemExit('continued active start block not found')
s = s.replace(old, new)

old = '''    if let task = activeTask {
      apply(snapshot, to: task)
    }
  }
'''
new = '''    if let task = activeTask {
      applyIfDue(snapshot, to: task)
    }
  }
'''
if old not in s:
    raise SystemExit('continued update block not found')
s = s.replace(old, new)

old = '''    snapshot = nil
    identifier = nil
    currentEpisodeTaskId = ""
  }
'''
new = '''    snapshot = nil
    identifier = nil
    currentEpisodeTaskId = ""
    lastAppliedUpdateAt = 0
  }
'''
if old not in s:
    raise SystemExit('continued complete reset block not found')
s = s.replace(old, new)

old = '''        self.snapshot = nil
        self.identifier = nil
        self.currentEpisodeTaskId = ""
'''
new = '''        self.snapshot = nil
        self.identifier = nil
        self.currentEpisodeTaskId = ""
        self.lastAppliedUpdateAt = 0
'''
if old not in s:
    raise SystemExit('continued expiration reset block not found')
s = s.replace(old, new)

old = '''    if let snapshot {
      apply(snapshot, to: task)
    } else {
'''
new = '''    if let snapshot {
      applyIfDue(snapshot, to: task, force: true)
    } else {
'''
if old not in s:
    raise SystemExit('continued attach block not found')
s = s.replace(old, new)

marker = '''  private func apply(
    _ snapshot: Snapshot,
    to task: BGContinuedProcessingTask
  ) {
'''
replacement = '''  /// System continued-processing UI is expensive and user-visible. Keep its
  /// cadence at most once per second even if native/Dart producers burst.
  /// The latest snapshot is still retained on every call, so the next eligible
  /// callback uses current bytes and speed rather than an arbitrary old sample.
  private func applyIfDue(
    _ snapshot: Snapshot,
    to task: BGContinuedProcessingTask,
    force: Bool = false
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    if !force,
       lastAppliedUpdateAt > 0,
       now - lastAppliedUpdateAt < minimumUpdateInterval {
      return
    }
    apply(snapshot, to: task)
    lastAppliedUpdateAt = now
  }

  private func apply(
    _ snapshot: Snapshot,
    to task: BGContinuedProcessingTask
  ) {
'''
if marker not in s:
    raise SystemExit('continued manager apply marker not found')
s = s.replace(marker, replacement)
path.write_text(s)
