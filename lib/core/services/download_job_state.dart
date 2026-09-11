import 'package:background_downloader/background_downloader.dart';

import 'download_parallel.dart';

/// Logical state of one episode download.
///
/// This deliberately does not mirror [TaskStatus]. Native downloader status,
/// persisted queue metadata and on-disk bytes are evidence about a logical
/// download; none of them should be the state machine by itself.
enum DownloadJobState {
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

/// What startup reconciliation should do after deriving the logical state.
enum DownloadRecoveryAction {
  /// The OS/native downloader still owns the transfer. Attach to it and never
  /// enqueue another copy.
  keepNative,

  /// Rebuild the logical FIFO entry and let the queue scheduler promote it.
  requeue,

  /// An explicit user pause is durable across process death.
  keepPaused,

  /// The row is terminal or there is not enough durable evidence to revive it.
  ignore,
}

class DownloadRecoveryPlan {
  const DownloadRecoveryPlan({required this.state, required this.action});

  final DownloadJobState state;
  final DownloadRecoveryAction action;

  bool get shouldRequeue => action == DownloadRecoveryAction.requeue;
  bool get isNativeOwned => action == DownloadRecoveryAction.keepNative;
}

class DownloadRecoveryInventory {
  const DownloadRecoveryInventory({
    required this.records,
    required this.nativeOnlyTaskIds,
    required this.durableOnlyTaskIds,
  });

  final List<TaskRecord> records;
  final Set<String> nativeOnlyTaskIds;
  final Set<String> durableOnlyTaskIds;
}

enum DownloadDurableOnlyRecoveryDisposition { recover, orphan }

/// A durable JobStore row is safe to revive only when both execution and
/// presentation identities survived. A task snapshot alone can restart bytes,
/// but without AnimeWitcher metadata the episode cannot be projected back into
/// the user-visible downloads inventory.
DownloadDurableOnlyRecoveryDisposition planDurableOnlyRecoveryDisposition({
  required bool hasPresentationMetadata,
  required bool hasRecoverableTaskDescriptor,
}) {
  return hasPresentationMetadata && hasRecoverableTaskDescriptor
      ? DownloadDurableOnlyRecoveryDisposition.recover
      : DownloadDurableOnlyRecoveryDisposition.orphan;
}

/// Build one deterministic startup inventory from every source that can carry
/// a complete logical task descriptor. Source precedence is deliberate:
/// persisted executor projection > live runtime ownership > durable snapshot.
/// A lower-priority replica can fill a missing row but can never replace a
/// stronger source for the same execution identity. Multipart children remain
/// implementation details and never become logical episode rows.
DownloadRecoveryInventory buildDownloadRecoveryInventory({
  required Iterable<TaskRecord> persistedRecords,
  required Iterable<Task> runtimeTasks,
  Iterable<TaskRecord> durableRecords = const <TaskRecord>[],
  Map<String, int> orderByTaskId = const <String, int>{},
}) {
  final records = <TaskRecord>[];
  final knownIds = <String>{};

  for (final record in persistedRecords) {
    if (!isLogicalEpisodeDownloadTask(record.task)) continue;
    if (!knownIds.add(record.task.taskId)) continue;
    records.add(record);
  }

  final missingRuntimeTasks = <DownloadTask>[];
  for (final task in runtimeTasks) {
    if (!isLogicalEpisodeDownloadTask(task)) continue;
    if (!knownIds.add(task.taskId)) continue;
    missingRuntimeTasks.add(task as DownloadTask);
  }
  missingRuntimeTasks.sort((a, b) => a.taskId.compareTo(b.taskId));

  final nativeOnlyTaskIds = <String>{};
  for (final task in missingRuntimeTasks) {
    nativeOnlyTaskIds.add(task.taskId);
    records.add(TaskRecord(task, TaskStatus.running, 0, -1));
  }

  final durableOnlyTaskIds = <String>{};
  final missingDurableRecords = <TaskRecord>[];
  for (final record in durableRecords) {
    if (!isLogicalEpisodeDownloadTask(record.task)) continue;
    if (!knownIds.add(record.task.taskId)) continue;
    durableOnlyTaskIds.add(record.task.taskId);
    missingDurableRecords.add(record);
  }
  missingDurableRecords.sort((a, b) => a.task.taskId.compareTo(b.task.taskId));
  records.addAll(missingDurableRecords);

  // Preserve executor order when no durable FIFO evidence exists. Once at
  // least one timestamp is available, order all logical rows deterministically
  // and put unknown-age legacy rows after known FIFO entries.
  if (orderByTaskId.isNotEmpty) {
    records.sort((a, b) {
      final aOrder = orderByTaskId[a.task.taskId];
      final bOrder = orderByTaskId[b.task.taskId];
      if (aOrder != null || bOrder != null) {
        if (aOrder == null) return 1;
        if (bOrder == null) return -1;
        final byOrder = aOrder.compareTo(bOrder);
        if (byOrder != 0) return byOrder;
      }
      return a.task.taskId.compareTo(b.task.taskId);
    });
  }

  return DownloadRecoveryInventory(
    records: List<TaskRecord>.unmodifiable(records),
    nativeOnlyTaskIds: Set<String>.unmodifiable(nativeOnlyTaskIds),
    durableOnlyTaskIds: Set<String>.unmodifiable(durableOnlyTaskIds),
  );
}

/// Derive one deterministic startup decision from all durable/native evidence.
///
/// Precedence is intentional:
/// 1. a completed record is terminal;
/// 2. explicit user pause always wins;
/// 3. live native ownership wins over stale persisted status;
/// 4. a durable logical waiter is requeued;
/// 5. interrupted/error states are only revived when AnimeWitcher metadata
///    proves the row belongs to an existing logical download.
DownloadRecoveryPlan planDownloadRecovery({
  required TaskStatus persisted,
  required bool queueWaiting,
  required bool userPaused,
  required bool stillInNativeQueue,
  required bool hasMetadata,
}) {
  if (persisted == TaskStatus.complete) {
    return const DownloadRecoveryPlan(
      state: DownloadJobState.completed,
      action: DownloadRecoveryAction.ignore,
    );
  }

  if (userPaused) {
    return const DownloadRecoveryPlan(
      state: DownloadJobState.pausedByUser,
      action: DownloadRecoveryAction.keepPaused,
    );
  }

  if (stillInNativeQueue) {
    final state = switch (persisted) {
      TaskStatus.enqueued => DownloadJobState.starting,
      TaskStatus.waitingToRetry => DownloadJobState.retryWaiting,
      _ => DownloadJobState.running,
    };
    return DownloadRecoveryPlan(
      state: state,
      action: DownloadRecoveryAction.keepNative,
    );
  }

  if (queueWaiting) {
    return const DownloadRecoveryPlan(
      state: DownloadJobState.queued,
      action: DownloadRecoveryAction.requeue,
    );
  }

  switch (persisted) {
    case TaskStatus.enqueued:
    case TaskStatus.running:
    case TaskStatus.waitingToRetry:
      return const DownloadRecoveryPlan(
        state: DownloadJobState.interrupted,
        action: DownloadRecoveryAction.requeue,
      );

    case TaskStatus.paused:
    case TaskStatus.failed:
    case TaskStatus.notFound:
      return DownloadRecoveryPlan(
        state: hasMetadata
            ? DownloadJobState.interrupted
            : DownloadJobState.orphaned,
        action: hasMetadata
            ? DownloadRecoveryAction.requeue
            : DownloadRecoveryAction.ignore,
      );

    case TaskStatus.canceled:
      // Explicit delete removes AnimeWitcher metadata before recovery. A
      // canceled row with metadata is therefore treated as a system/native
      // interruption; without metadata it must never be resurrected.
      return DownloadRecoveryPlan(
        state: hasMetadata
            ? DownloadJobState.interrupted
            : DownloadJobState.canceled,
        action: hasMetadata
            ? DownloadRecoveryAction.requeue
            : DownloadRecoveryAction.ignore,
      );

    case TaskStatus.complete:
      // Handled before the precedence checks above.
      return const DownloadRecoveryPlan(
        state: DownloadJobState.completed,
        action: DownloadRecoveryAction.ignore,
      );
  }
}

/// Reconcile executor evidence against an existing durable logical job.
///
/// Once a DownloadJobStore record exists it is the authority for user intent
/// and logical queue ownership. Plugin/URLSession status is still authoritative
/// for *live execution ownership*, but stale executor rows may not erase a
/// durable user pause, waiter, terminal state, or interrupted job.
DownloadRecoveryPlan planDownloadRecoveryWithJobAuthority({
  required TaskStatus persisted,
  required bool queueWaiting,
  required bool userPaused,
  required bool stillInNativeQueue,
  required bool hasMetadata,
  DownloadJobState? authoritativeState,
  bool authoritativeUserPaused = false,
  bool authoritativeQueueWaiting = false,
}) {
  if (authoritativeState == null) {
    return planDownloadRecovery(
      persisted: persisted,
      queueWaiting: queueWaiting,
      userPaused: userPaused,
      stillInNativeQueue: stillInNativeQueue,
      hasMetadata: hasMetadata,
    );
  }

  switch (authoritativeState) {
    case DownloadJobState.completed:
    case DownloadJobState.canceled:
    case DownloadJobState.orphaned:
      return DownloadRecoveryPlan(
        state: authoritativeState,
        action: DownloadRecoveryAction.ignore,
      );
    default:
      break;
  }

  // Keep legacy userPaused=true as migration evidence too. A pause is safer to
  // preserve than to accidentally turn into network activity after relaunch.
  if (authoritativeUserPaused ||
      userPaused ||
      authoritativeState == DownloadJobState.pausedByUser ||
      authoritativeState == DownloadJobState.pausing) {
    return const DownloadRecoveryPlan(
      state: DownloadJobState.pausedByUser,
      action: DownloadRecoveryAction.keepPaused,
    );
  }

  if (stillInNativeQueue) {
    final state = switch (authoritativeState) {
      DownloadJobState.queued => DownloadJobState.queued,
      DownloadJobState.starting => DownloadJobState.starting,
      DownloadJobState.retryWaiting => DownloadJobState.retryWaiting,
      DownloadJobState.assembling => DownloadJobState.assembling,
      DownloadJobState.verifying => DownloadJobState.verifying,
      _ => DownloadJobState.running,
    };
    return DownloadRecoveryPlan(
      state: state,
      action: DownloadRecoveryAction.keepNative,
    );
  }

  if (authoritativeQueueWaiting ||
      authoritativeState == DownloadJobState.queued) {
    return const DownloadRecoveryPlan(
      state: DownloadJobState.queued,
      action: DownloadRecoveryAction.requeue,
    );
  }

  return const DownloadRecoveryPlan(
    state: DownloadJobState.interrupted,
    action: DownloadRecoveryAction.requeue,
  );
}

/// Source of the byte count selected during startup/resume reconciliation.
/// Percentages from plugin/UI metadata are deliberately absent: they can inform
/// presentation, but they are never durable byte evidence.
enum DownloadRecoveryByteSource {
  verifiedFinalFile,
  exactDisk,
  jobStore,
  multipartManifest,
  none,
}

class DownloadRecoveryByteSelection {
  const DownloadRecoveryByteSelection({
    required this.bytes,
    required this.source,
  });

  final int bytes;
  final DownloadRecoveryByteSource source;
}

/// Apply the recovery truth ordering used by the download manager.
///
/// A verified final file wins. Otherwise exact visible bytes win over logical
/// checkpoints. JobStore and the current multipart manifest are the final
/// durable fallbacks. Decimal progress is intentionally not accepted here.
DownloadRecoveryByteSelection selectDownloadRecoveryBytes({
  int verifiedFinalFileBytes = -1,
  int exactDiskBytes = -1,
  int currentGenerationJobBytes = -1,
  int multipartManifestBytes = -1,
}) {
  if (verifiedFinalFileBytes >= 0) {
    return DownloadRecoveryByteSelection(
      bytes: verifiedFinalFileBytes,
      source: DownloadRecoveryByteSource.verifiedFinalFile,
    );
  }
  if (exactDiskBytes >= 0) {
    return DownloadRecoveryByteSelection(
      bytes: exactDiskBytes,
      source: DownloadRecoveryByteSource.exactDisk,
    );
  }
  if (currentGenerationJobBytes >= 0) {
    return DownloadRecoveryByteSelection(
      bytes: currentGenerationJobBytes,
      source: DownloadRecoveryByteSource.jobStore,
    );
  }
  if (multipartManifestBytes >= 0) {
    return DownloadRecoveryByteSelection(
      bytes: multipartManifestBytes,
      source: DownloadRecoveryByteSource.multipartManifest,
    );
  }
  return const DownloadRecoveryByteSelection(
    bytes: 0,
    source: DownloadRecoveryByteSource.none,
  );
}

/// Identifies one concrete execution attempt of a logical episode.
///
/// Future native/plugin callbacks can carry this token (directly or through a
/// side table). A callback is accepted only while its token is current, which
/// prevents late events from an old pause/retry/restart attempt from mutating a
/// newer download state.
class DownloadAttemptToken {
  const DownloadAttemptToken({required this.taskId, required this.generation});

  final String taskId;
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is DownloadAttemptToken &&
      other.taskId == taskId &&
      other.generation == generation;

  @override
  int get hashCode => Object.hash(taskId, generation);
}

/// In-memory attempt fence with monotonic generations per logical task.
///
/// The API accepts an optional persisted seed so this can later be backed by
/// DownloadJobStore without changing callback filtering semantics.
class DownloadAttemptFence {
  DownloadAttemptFence([Map<String, int>? persistedGenerations]) {
    if (persistedGenerations == null) return;
    for (final entry in persistedGenerations.entries) {
      final taskId = entry.key.trim();
      final generation = entry.value;
      if (taskId.isEmpty || generation < 0) continue;
      _generations[taskId] = generation;
    }
  }

  final Map<String, int> _generations = <String, int>{};

  DownloadAttemptToken begin(String taskId) {
    final id = taskId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(taskId, 'taskId', 'must not be empty');
    }
    final next = (_generations[id] ?? 0) + 1;
    _generations[id] = next;
    return DownloadAttemptToken(taskId: id, generation: next);
  }

  /// Invalidates every callback issued before this call without starting work.
  DownloadAttemptToken invalidate(String taskId) => begin(taskId);

  bool accepts(DownloadAttemptToken token) {
    if (token.generation <= 0) return false;
    return _generations[token.taskId] == token.generation;
  }

  int generationFor(String taskId) => _generations[taskId.trim()] ?? 0;

  Map<String, int> snapshot() => Map<String, int>.unmodifiable(_generations);
}
