from pathlib import Path


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one source match, found {count}")
    return source.replace(old, new, 1)


service_path = Path("lib/core/services/download_service.dart")
text = service_path.read_text()

text = replace_once(
    text,
    "  final service = DownloadService(ref);",
    """  final service = DownloadService(
    ref,
    pluginParallelAccepted: pluginParallelAcceptedForPlatform(
      defaultTargetPlatform,
    ),
  );""",
    "provider platform gate",
)

text = replace_once(
    text,
    "  final bool _pluginParallelAccepted;\n  final Set<String> _userPausedIds = {};",
    "  final bool _pluginParallelAccepted;\n"
    "  final Set<String> _startupLegacyParentFence = <String>{};\n"
    "  final Set<String> _userPausedIds = {};",
    "startup fence field",
)

listener_old = """    _updatesSubscription = _sharedEvents.stream.listen((update) {
      final legacyParallelUpdate = _legacyParallelUpdateOrigin[update] == true;"""
listener_new = """    _updatesSubscription = _sharedEvents.stream.listen((update) {
      final startupParentId = downloadInternalParentTaskId(update.task);
      if (_startupLegacyParentFence.contains(update.task.taskId) ||
          (startupParentId != null &&
              _startupLegacyParentFence.contains(startupParentId))) {
        diagnosticLog.record('startup.legacyPluginUpdateIgnored', {
          'taskId': update.task.taskId,
          if (startupParentId != null) 'parentTaskId': startupParentId,
        });
        return;
      }
      final legacyParallelUpdate = _legacyParallelUpdateOrigin[update] == true;"""
text = replace_once(text, listener_old, listener_new, "startup update fence")

text = replace_once(
    text,
    "    await _serializeQueue(_recoverPersistedDownloads);\n\n    _isInitialized = true;",
    "    await _serializeQueue(_recoverPersistedDownloads);\n\n"
    "    _startupLegacyParentFence.clear();\n"
    "    _isInitialized = true;",
    "startup fence release",
)

start = text.find("  Future<void> _startPluginExecutor() async {")
if start < 0:
    raise SystemExit("plugin start helper: start not found")
end = text.find("\n  /// Test hook that replaces [FileDownloader.configure]", start)
if end < 0:
    raise SystemExit("plugin start helper: end not found")

replacement = """  Future<List<ParallelManifestRecoveryEvidence>>
  _discoverLegacyParallelManifestEvidence() async {
    return discoverParallelManifestRecoveryEvidence([
      Directory(
        p.join(
          await _getPublicDownloadsPath(),
          'AnimeWitcher',
          'Downloads',
        ),
      ),
    ]);
  }

  Future<({
    Set<String> parentIds,
    List<TaskRecord> parentRecords,
    Set<String> rogueChunkIds,
  })>
  _quarantineLegacyParallelParentsBeforePluginStart() async {
    final evidence = await _discoverLegacyParallelManifestEvidence();
    final parentIds = <String>{
      for (final manifest in evidence)
        if (manifest.parentTaskId.isNotEmpty) manifest.parentTaskId,
    };
    _startupLegacyParentFence.addAll(parentIds);
    if (parentIds.isEmpty) {
      return (
        parentIds: parentIds,
        parentRecords: <TaskRecord>[],
        rogueChunkIds: <String>{},
      );
    }

    final parentRecords = <TaskRecord>[];
    final rogueChunkIds = <String>{};
    for (final record in await FileDownloader().database.allRecords()) {
      final task = record.task;
      if (task is ParallelDownloadTask &&
          parentIds.contains(task.taskId) &&
          record.status != TaskStatus.complete) {
        parentRecords.add(record);
        await FileDownloader().database.updateRecord(
          TaskRecord(
            task,
            TaskStatus.paused,
            record.progress,
            record.expectedFileSize,
          ),
        );
      }

      final parentId = downloadInternalParentTaskId(task);
      if (task.group == FileDownloader.chunkGroup &&
          parentId != null &&
          parentIds.contains(parentId)) {
        rogueChunkIds.add(task.taskId);
        if (record.status != TaskStatus.complete &&
            record.status != TaskStatus.canceled) {
          await FileDownloader().database.updateRecord(
            TaskRecord(
              task,
              TaskStatus.paused,
              record.progress,
              record.expectedFileSize,
            ),
          );
        }
      }
    }

    diagnosticLog.record('startup.legacyPluginQuarantine', {
      'parents': parentIds.length,
      'parentRecords': parentRecords.length,
      'rogueChunks': rogueChunkIds.length,
    });
    return (
      parentIds: parentIds,
      parentRecords: parentRecords,
      rogueChunkIds: rogueChunkIds,
    );
  }

  Future<void> _restoreLegacyParallelParentsAfterPluginStart(
    List<TaskRecord> records,
  ) async {
    for (final record in records) {
      await FileDownloader().database.updateRecord(record);
    }
  }

  Future<void> _startPluginExecutor() async {
    // PR #231 stored legacy parents in background_downloader's database as
    // ParallelDownloadTask rows. Quarantine those rows before the plugin
    // reconciles killed tasks or it can create a second random chunk set
    // beside PersistentParallelDownload's deterministic .part.N writers.
    final quarantine =
        await _quarantineLegacyParallelParentsBeforePluginStart();
    try {
      await FileDownloader().start(
        doRescheduleKilledTasks: false,
        markDownloadedComplete: false,
      );

      // Broken builds may already have created background_downloader-owned
      // chunk rows for a legacy parent. Settle only the plugin chunk group;
      // PR #231 animewitcher_parts children are the valid legacy executor and
      // must remain available for manifest recovery.
      final rogueChunkIds = <String>{...quarantine.rogueChunkIds};
      for (final task in await FileDownloader().allTasks(allGroups: true)) {
        final parentId = downloadInternalParentTaskId(task);
        if (task.group == FileDownloader.chunkGroup &&
            parentId != null &&
            quarantine.parentIds.contains(parentId)) {
          rogueChunkIds.add(task.taskId);
        }
      }
      if (rogueChunkIds.isNotEmpty) {
        await FileDownloader().cancelTasksWithIds(rogueChunkIds.toList());
        diagnosticLog.record('startup.legacyPluginChunksCanceled', {
          'count': rogueChunkIds.length,
        });
      }

      // FileDownloader.start normally does this on a delayed 5-second Timer.
      // Run it synchronously while legacy rows are quarantined.
      await FileDownloader().rescheduleKilledTasks();
      await _nativeTransport.rehydrate(group: kLogicalDownloadGroup);
      for (final parentId in quarantine.parentIds) {
        _nativeTransport.forget(parentId);
      }
    } finally {
      await _restoreLegacyParallelParentsAfterPluginStart(
        quarantine.parentRecords,
      );
    }
  }
"""
text = text[:start] + replacement + text[end:]
service_path.write_text(text)

swift_path = Path("ios/Runner/DownloadNativeWaitingQueue.swift")
swift = swift_path.read_text()
swift = replace_once(
    swift,
    "  private static var hookInstalled = false\n",
    "  private static var pluginObserversInstalled = false\n"
    "  private static var hookInstalled = false\n",
    "plugin callback install state",
)

hook_start = swift.find("  static func installUrlSessionHook() {")
if hook_start < 0:
    raise SystemExit("iOS hook installer: start not found")
hook_end = swift.find("\n  /// Dart persist is source of truth", hook_start)
if hook_end < 0:
    raise SystemExit("iOS hook installer: end not found")
hook = """  static func installUrlSessionHook() {
    lock.lock()
    defer { lock.unlock() }
    #if canImport(background_downloader)
    if !pluginObserversInstalled {
      BDPlugin.onNativeTaskStatusChange = { task, statusUpdate in
        DownloadNativeWaitingQueue.handleSupportedPluginStatus(
          task: task,
          statusUpdate: statusUpdate
        )
      }
      BDPlugin.onNativeTaskProgressChange = { task, progress in
        DownloadNativeWaitingQueue.handleSupportedPluginProgress(
          task: task,
          progress: progress
        )
      }
      pluginObserversInstalled = true
    }
    #endif
    guard !hookInstalled else { return }
    hookInstalled = DownloadUrlSessionHook.install()
  }
"""
swift = swift[:hook_start] + hook + swift[hook_end:]
swift = replace_once(
    swift,
    "    guard nativePromotionAvailable, progress.isFinite, progress >= 0 else { return }",
    "    guard progress.isFinite, progress >= 0 else { return }",
    "supported plugin progress independence",
)
swift_path.write_text(swift)
