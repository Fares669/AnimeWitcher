from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly 1 match, found {count}")
    return text.replace(old, new, 1)


# 1) Union inventory: persisted DB > live runtime > durable snapshots.
path = Path("lib/core/services/download_job_state.dart")
text = path.read_text()
old = """class DownloadRecoveryInventory {
  const DownloadRecoveryInventory({
    required this.records,
    required this.nativeOnlyTaskIds,
  });

  final List<TaskRecord> records;
  final Set<String> nativeOnlyTaskIds;
}

/// Build one deterministic startup inventory from the persisted executor
/// projection plus tasks the runtime still owns. Persisted records win when
/// both sources know the same execution identity. Native-only logical tasks are
/// synthesized as running projections so recovery can attach to the existing
/// writer instead of starting a second transfer. Multipart children remain
/// implementation details and never become logical episode rows.
DownloadRecoveryInventory buildDownloadRecoveryInventory({
  required Iterable<TaskRecord> persistedRecords,
  required Iterable<Task> runtimeTasks,
}) {
  final records = <TaskRecord>[];
  final knownIds = <String>{};

  for (final record in persistedRecords) {
    if (!isLogicalEpisodeDownloadTask(record.task)) continue;
    final taskId = record.task.taskId;
    if (!knownIds.add(taskId)) continue;
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

  return DownloadRecoveryInventory(
    records: List<TaskRecord>.unmodifiable(records),
    nativeOnlyTaskIds: Set<String>.unmodifiable(nativeOnlyTaskIds),
  );
}
"""
new = """class DownloadRecoveryInventory {
  const DownloadRecoveryInventory({
    required this.records,
    required this.nativeOnlyTaskIds,
    required this.durableOnlyTaskIds,
  });

  final List<TaskRecord> records;
  final Set<String> nativeOnlyTaskIds;
  final Set<String> durableOnlyTaskIds;
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
  missingDurableRecords.sort(
    (a, b) => a.task.taskId.compareTo(b.task.taskId),
  );
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
"""
text = replace_once(text, old, new, "recovery inventory")
path.write_text(text)

# 2) JobStore owns a backwards-compatible full task snapshot.
path = Path("lib/core/services/download_job_store.dart")
text = path.read_text()
text = replace_once(
    text,
    "import 'package:hive_flutter/hive_flutter.dart';\n",
    "import 'package:background_downloader/background_downloader.dart';\nimport 'package:hive_flutter/hive_flutter.dart';\n",
    "job store import",
)
text = replace_once(
    text,
    "const int kDownloadJobSchemaVersion = 3;",
    "const int kDownloadJobSchemaVersion = 4;",
    "schema",
)
text = replace_once(
    text,
    "    required this.updatedAtMillis,\n    this.fingerprint,\n",
    "    required this.updatedAtMillis,\n    this.taskSnapshot,\n    this.fingerprint,\n",
    "record constructor snapshot",
)
text = replace_once(
    text,
    "  final int updatedAtMillis;\n  final DownloadResourceFingerprint? fingerprint;\n",
    "  final int updatedAtMillis;\n  final Map<String, dynamic>? taskSnapshot;\n  final DownloadResourceFingerprint? fingerprint;\n",
    "record field snapshot",
)
text = replace_once(
    text,
    "  DownloadAttemptToken get attemptToken =>\n      DownloadAttemptToken(taskId: taskId, generation: generation);\n\n",
    "  DownloadAttemptToken get attemptToken =>\n      DownloadAttemptToken(taskId: taskId, generation: generation);\n\n  DownloadTask? restoreTaskSnapshot() {\n    final raw = taskSnapshot;\n    if (raw == null) return null;\n    try {\n      final restored = Task.createFromJson(Map<String, dynamic>.from(raw));\n      return restored is DownloadTask ? restored : null;\n    } catch (_) {\n      return null;\n    }\n  }\n\n",
    "restore snapshot method",
)
text = replace_once(
    text,
    "    int? updatedAtMillis,\n    DownloadResourceFingerprint? fingerprint,\n",
    "    int? updatedAtMillis,\n    Map<String, dynamic>? taskSnapshot,\n    bool clearTaskSnapshot = false,\n    DownloadResourceFingerprint? fingerprint,\n",
    "copyWith snapshot args",
)
text = replace_once(
    text,
    "    updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,\n    fingerprint: clearFingerprint ? null : (fingerprint ?? this.fingerprint),\n",
    "    updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,\n    taskSnapshot: clearTaskSnapshot\n        ? null\n        : (taskSnapshot ?? this.taskSnapshot),\n    fingerprint: clearFingerprint ? null : (fingerprint ?? this.fingerprint),\n",
    "copyWith snapshot value",
)
text = replace_once(
    text,
    "    'updatedAtMillis': updatedAtMillis,\n    if (fingerprint != null) 'fingerprint': fingerprint!.toJson(),\n",
    "    'updatedAtMillis': updatedAtMillis,\n    if (taskSnapshot != null)\n      'taskSnapshot': Map<String, dynamic>.from(taskSnapshot!),\n    if (fingerprint != null) 'fingerprint': fingerprint!.toJson(),\n",
    "toJson snapshot",
)
text = replace_once(
    text,
    "      updatedAtMillis: _intValue(map['updatedAtMillis']),\n      fingerprint: DownloadResourceFingerprint.fromJson(map['fingerprint']),\n",
    "      updatedAtMillis: _intValue(map['updatedAtMillis']),\n      taskSnapshot: map['taskSnapshot'] is Map\n          ? Map<String, dynamic>.from(map['taskSnapshot'] as Map)\n          : null,\n      fingerprint: DownloadResourceFingerprint.fromJson(map['fingerprint']),\n",
    "fromJson snapshot",
)
text = replace_once(
    text,
    "      expectedBytes: next.expectedBytes > 0\n          ? next.expectedBytes\n          : current?.expectedBytes,\n      fingerprint: fingerprint,\n",
    "      expectedBytes: next.expectedBytes > 0\n          ? next.expectedBytes\n          : current?.expectedBytes,\n      taskSnapshot: next.taskSnapshot ?? current?.taskSnapshot,\n      fingerprint: fingerprint,\n",
    "put snapshot merge",
)
text = replace_once(
    text,
    "    bool? queueWaiting,\n    DownloadResourceFingerprint? fingerprint,\n    int? updatedAtMillis,\n",
    "    bool? queueWaiting,\n    Map<String, dynamic>? taskSnapshot,\n    DownloadResourceFingerprint? fingerprint,\n    int? updatedAtMillis,\n",
    "checkpoint snapshot arg",
)
# Add snapshot to new-record and existing-record checkpoint branches.
needle = "            updatedAtMillis: now,\n            fingerprint: fingerprint,\n"
if text.count(needle) != 1:
    raise SystemExit(f"checkpoint new branch: expected 1, found {text.count(needle)}")
text = text.replace(
    needle,
    "            updatedAtMillis: now,\n            taskSnapshot: taskSnapshot,\n            fingerprint: fingerprint,\n",
    1,
)
needle = "            queueWaiting: queueWaiting ?? current.queueWaiting,\n            updatedAtMillis: now,\n            fingerprint: fingerprint,\n"
if text.count(needle) != 1:
    raise SystemExit(f"checkpoint existing branch: expected 1, found {text.count(needle)}")
text = text.replace(
    needle,
    "            queueWaiting: queueWaiting ?? current.queueWaiting,\n            updatedAtMillis: now,\n            taskSnapshot: taskSnapshot,\n            fingerprint: fingerprint,\n",
    1,
)
path.write_text(text)

# 3) Metadata keeps the same descriptor as an independent recovery replica.
path = Path("lib/core/storage/storage_service.dart")
text = path.read_text()
sig = "    String? trackingUrl,\n    String? filePath,\n    bool? queueWaiting,\n"
if text.count(sig) != 2:
    raise SystemExit(f"metadata signatures: expected 2, found {text.count(sig)}")
text = text.replace(
    sig,
    "    String? trackingUrl,\n    String? filePath,\n    Map<String, dynamic>? taskSnapshot,\n    bool? queueWaiting,\n",
    2,
)
text = replace_once(
    text,
    "      if (filePath != null && filePath.isNotEmpty) 'filePath': filePath,\n",
    "      if (filePath != null && filePath.isNotEmpty) 'filePath': filePath,\n      if (taskSnapshot != null)\n        'taskSnapshot': Map<String, dynamic>.from(taskSnapshot),\n",
    "metadata save snapshot",
)
text = replace_once(
    text,
    "    if (filePath != null && filePath.isNotEmpty) {\n      map['filePath'] = filePath;\n    }\n",
    "    if (filePath != null && filePath.isNotEmpty) {\n      map['filePath'] = filePath;\n    }\n    if (taskSnapshot != null) {\n      map['taskSnapshot'] = Map<String, dynamic>.from(taskSnapshot);\n    }\n",
    "metadata patch snapshot",
)
marker = """  Future<Map<String, dynamic>?> getDownloadMetadata(String taskId) async {
    final box = await Hive.openBox<dynamic>(kDownloadMetadataBox);
    final data = box.get(taskId);
    if (data == null) return null;
    return Map<String, dynamic>.from(data as Map);
  }

"""
replacement = marker + """  Future<Map<String, Map<String, dynamic>>> getAllDownloadMetadata() async {
    final box = await Hive.openBox<dynamic>(kDownloadMetadataBox);
    final result = <String, Map<String, dynamic>>{};
    for (final key in box.keys) {
      if (key is! String) continue;
      final raw = box.get(key);
      if (raw is! Map) continue;
      result[key] = Map<String, dynamic>.from(raw);
    }
    return result;
  }

"""
text = replace_once(text, marker, replacement, "metadata enumeration")
path.write_text(text)

# 4) DownloadService joins JobStore/metadata snapshots into startup inventory.
path = Path("lib/core/services/download_service.dart")
text = path.read_text()
text = replace_once(
    text,
    "        queueWaiting: queueWaiting,\n        fingerprint: DownloadResourceFingerprint(\n",
    "        queueWaiting: queueWaiting,\n        taskSnapshot: task.toJson(),\n        fingerprint: DownloadResourceFingerprint(\n",
    "checkpoint task snapshot",
)
old_prelude = """  Future<void> _recoverPersistedDownloads() async {
    final persistedRecords = await FileDownloader().database.allRecords();
    final runtimeTasks = await _liveTransferTasks();
    final inventory = buildDownloadRecoveryInventory(
      persistedRecords: persistedRecords,
      runtimeTasks: runtimeTasks,
    );
    final records = inventory.records;
    diagnosticLog.record('recovery.begin', {
      'count': records.length,
      'nativeOnly': inventory.nativeOnlyTaskIds.length,
    });
"""
new_prelude = """  Future<void> _recoverPersistedDownloads() async {
    final storage = _ref.read(storageServiceProvider);
    final persistedRecords = await FileDownloader().database.allRecords();
    final runtimeTasks = await _liveTransferTasks();
    final jobs = await _jobStore.all();
    final metadataById = await storage.getAllDownloadMetadata();

    final durableRecords = <TaskRecord>[];
    final orderByTaskId = <String, int>{};
    final knownExecutorIds = <String>{
      for (final record in persistedRecords) record.task.taskId,
      for (final task in runtimeTasks) task.taskId,
    };

    for (final entry in metadataById.entries) {
      final timestamp = entry.value['timestamp'];
      if (timestamp is num) orderByTaskId[entry.key] = timestamp.toInt();
    }
    final jobById = <String, DownloadJobRecord>{
      for (final job in jobs) job.taskId: job,
    };
    for (final job in jobs) {
      orderByTaskId.putIfAbsent(job.taskId, () => job.updatedAtMillis);
      if (knownExecutorIds.contains(job.taskId) ||
          job.state == DownloadJobState.completed ||
          job.state == DownloadJobState.canceled ||
          job.state == DownloadJobState.orphaned) {
        continue;
      }
      final metadata = metadataById[job.taskId];
      final task = job.restoreTaskSnapshot() ??
          _downloadTaskFromMetadataSnapshot(metadata);
      if (task == null) {
        await _jobStore.checkpoint(
          taskId: job.taskId,
          trackingUrl: job.trackingUrl,
          state: DownloadJobState.orphaned,
          durableBytes: job.durableBytes,
          durableByteProvenance: job.durableByteProvenance,
          expectedBytes: job.expectedBytes,
          userPaused: job.userPaused,
          queueWaiting: false,
          fingerprint: job.fingerprint,
        );
        diagnosticLog.record('recovery.orphanedMissingDescriptor', {
          'taskId': job.taskId,
          'source': 'jobStore',
        });
        continue;
      }
      final progress = job.expectedBytes > 0
          ? (job.durableBytes / job.expectedBytes).clamp(0.0, 1.0).toDouble()
          : downloadMetadataProgress(metadata);
      durableRecords.add(
        TaskRecord(task, TaskStatus.paused, progress, job.expectedBytes),
      );
    }

    // Metadata can survive even if both executor DB and JobStore were lost.
    // New-format rows carry a complete task snapshot and are recoverable; old
    // rows become explicit orphans instead of guessing URL/headers/path.
    for (final entry in metadataById.entries) {
      final taskId = entry.key;
      if (knownExecutorIds.contains(taskId) ||
          jobById.containsKey(taskId) ||
          durableRecords.any((record) => record.task.taskId == taskId)) {
        continue;
      }
      final metadata = entry.value;
      final task = _downloadTaskFromMetadataSnapshot(metadata);
      final trackingUrl = (metadata['trackingUrl'] as String?)?.trim() ?? '';
      if (task == null) {
        if (trackingUrl.isNotEmpty) {
          await _jobStore.checkpoint(
            taskId: taskId,
            trackingUrl: trackingUrl,
            state: DownloadJobState.orphaned,
            expectedBytes: downloadMetadataExpectedBytes(metadata),
            userPaused: isUserPausedMetadata(metadata),
            queueWaiting: false,
          );
          diagnosticLog.record('recovery.orphanedMissingDescriptor', {
            'taskId': taskId,
            'source': 'metadata',
          });
        }
        continue;
      }
      final expected = downloadMetadataExpectedBytes(metadata);
      durableRecords.add(
        TaskRecord(
          task,
          TaskStatus.paused,
          downloadMetadataProgress(metadata),
          expected,
        ),
      );
    }

    final inventory = buildDownloadRecoveryInventory(
      persistedRecords: persistedRecords,
      runtimeTasks: runtimeTasks,
      durableRecords: durableRecords,
      orderByTaskId: orderByTaskId,
    );
    final records = inventory.records;
    diagnosticLog.record('recovery.begin', {
      'count': records.length,
      'nativeOnly': inventory.nativeOnlyTaskIds.length,
      'durableOnly': inventory.durableOnlyTaskIds.length,
    });
"""
text = replace_once(text, old_prelude, new_prelude, "service recovery prelude")
text = replace_once(
    text,
    """    final nativeIds = <String>{
      for (final task in runtimeTasks)
        if (isLogicalEpisodeDownloadTask(task)) task.taskId,
    };
    final storage = _ref.read(storageServiceProvider);
""",
    """    final nativeIds = <String>{
      for (final task in runtimeTasks)
        if (isLogicalEpisodeDownloadTask(task)) task.taskId,
    };
""",
    "remove duplicate storage local",
)
text = replace_once(
    text,
    """        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
        fingerprint:
            oldJob?.fingerprint ??
""",
    """        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
        taskSnapshot: oldJob?.taskSnapshot ?? task.toJson(),
        fingerprint:
            oldJob?.fingerprint ??
""",
    "migrated snapshot",
)
anchor = """      if (inventory.nativeOnlyTaskIds.contains(task.taskId) &&
          recoveryPlan.action != DownloadRecoveryAction.ignore) {
"""
if text.count(anchor) != 1:
    raise SystemExit("native-only anchor missing")
durable_block = """      if (inventory.durableOnlyTaskIds.contains(task.taskId) &&
          recoveryPlan.action != DownloadRecoveryAction.ignore) {
        await FileDownloader().database.updateRecord(
          TaskRecord(task, TaskStatus.paused, progress, expectedBytes),
        );
        diagnosticLog.record('recovery.repairedDurableProjection', {
          'taskId': task.taskId,
          'progress': progress,
          'expectedBytes': expectedBytes,
        });
      }

"""
text = text.replace(anchor, durable_block + anchor, 1)
text = replace_once(
    text,
    """            updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
            fingerprint: DownloadResourceFingerprint(
              expectedBytes: expectedBytes,
              finalUrl: url,
""",
    """            updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
            taskSnapshot: transferTask.toJson(),
            fingerprint: DownloadResourceFingerprint(
              expectedBytes: expectedBytes,
              finalUrl: url,
""",
    "fresh job snapshot",
)
text = replace_once(
    text,
    """          trackingUrl: trackingUrl ?? url,
          filePath: path,
          queueWaiting: !startNow,
""",
    """          trackingUrl: trackingUrl ?? url,
          filePath: path,
          taskSnapshot: transferTask.toJson(),
          queueWaiting: !startNow,
""",
    "fresh metadata snapshot",
)
seed_pattern = re.compile(
    r"(final seeded = DownloadJobRecord\(\n\s+taskId: task\.taskId,.*?updatedAtMillis: DateTime\.now\(\)\.millisecondsSinceEpoch,\n)(\s+fingerprint:)",
    re.S,
)
text, count = seed_pattern.subn(
    r"\1        taskSnapshot: task.toJson(),\n\2", text, count=1
)
if count != 1:
    raise SystemExit(f"range seed snapshot: expected 1, found {count}")
helper_anchor = "  Future<void> _restoreAuthoritativeJobIntent() async {\n"
helper = """  DownloadTask? _downloadTaskFromMetadataSnapshot(
    Map<String, dynamic>? metadata,
  ) {
    final raw = metadata?['taskSnapshot'];
    if (raw is! Map) return null;
    try {
      final restored = Task.createFromJson(Map<String, dynamic>.from(raw));
      return restored is DownloadTask && isLogicalEpisodeDownloadTask(restored)
          ? restored
          : null;
    } catch (_) {
      return null;
    }
  }

"""
text = replace_once(text, helper_anchor, helper + helper_anchor, "metadata snapshot helper")
path.write_text(text)

# 5) Focused verifier exercises inventory + durable descriptor round-trip.
path = Path(".github/workflows/dm04-verifier.yml")
text = path.read_text()
text = replace_once(
    text,
    "      - name: Run DM-04 recovery inventory regression\n        run: flutter test test/core/services/download_recovery_inventory_test.dart\n",
    "      - name: Run DM-04 durable recovery regressions\n        run: flutter test test/core/services/download_recovery_inventory_test.dart test/core/services/download_recovery_snapshot_test.dart\n",
    "focused verifier tests",
)
path.write_text(text)
