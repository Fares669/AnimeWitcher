from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:160]!r}")
    file.write_text(text.replace(old, new, 1))


parallel = 'lib/core/services/persistent_parallel_download.dart'
continued = 'lib/core/services/download_continued_processing_service.dart'
service = 'lib/core/services/download_service.dart'
swift = 'ios/Runner/DownloadNativeWaitingQueue.swift'
app_delegate = 'ios/Runner/AppDelegate.swift'
runtime_test = 'test/core/services/download_runtime_stability_review_test.dart'

# ---------------------------------------------------------------------------
# Dart multipart coordinator: pre-fence future children and expose a native
# refill plan capped at the connection width already proven in foreground.
# ---------------------------------------------------------------------------
replace_once(
    parallel,
    '''/// Native DownloadTasks transfer the parts; this coordinator persists their\n''',
    '''class NativeParallelBackgroundPlan {\n  const NativeParallelBackgroundPlan({\n    required this.parentTaskId,\n    required this.maxConcurrent,\n    required this.tasks,\n  });\n\n  final String parentTaskId;\n  final int maxConcurrent;\n  final List<DownloadTask> tasks;\n}\n\n/// Native DownloadTasks transfer the parts; this coordinator persists their\n''',
)

replace_once(
    parallel,
    '''  double? progressFor(String id) => _sessions[id]?.progress;\n\n''',
    '''  double? progressFor(String id) => _sessions[id]?.progress;\n\n  /// Fresh, generation-fenced Range children that iOS may start directly on\n  /// the already-running background URLSession while Dart is suspended. The\n  /// native cap is the session's *currently proven* active width, never the\n  /// configured ceiling, so moving to background cannot bypass slow-start or\n  /// the host governor. Only zero-byte children are exported: URLSession resume\n  /// blobs and source-refresh validation remain owned by Dart.\n  List<NativeParallelBackgroundPlan> nativeBackgroundPlans() {\n    if (_disposed) return const <NativeParallelBackgroundPlan>[];\n    final plans = <NativeParallelBackgroundPlan>[];\n    for (final session in _sessions.values) {\n      if (!session.active || session.pauseRequested || session.deleted) continue;\n      final provenWidth = _activeConnectionsForSession(session);\n      if (provenWidth <= 0) continue;\n      final tasks = session.parts\n          .where(\n            (part) =>\n                !part.complete &&\n                !part.launched &&\n                part.recoveryTimer == null &&\n                part.attemptGeneration > 0 &&\n                !part.sourceValidationRequired &&\n                part.progress <= 0 &&\n                part.credibleProgress <= 0,\n          )\n          .map((part) => part.task)\n          .toList(growable: false);\n      if (tasks.isEmpty) continue;\n      plans.add(\n        NativeParallelBackgroundPlan(\n          parentTaskId: session.task.taskId,\n          maxConcurrent: provenWidth.clamp(1, kDownloadGlobalConnectionBudget),\n          tasks: tasks,\n        ),\n      );\n    }\n    return plans;\n  }\n\n''',
)

replace_once(
    parallel,
    '''      session.pauseRequested = false;\n      session.active = true;\n      session.resetRamp();\n      try {\n        // Persist the logical generation before any child is handed to native IO.\n        await _persist(session);\n''',
    '''      session.pauseRequested = false;\n      session.active = true;\n      session.resetRamp();\n      try {\n        // Future native background refills must carry the same attempt token as\n        // the Dart-owned session. Preparing metadata does not launch anything\n        // and does not increase the slow-start width.\n        for (final part in session.parts) {\n          if (!part.complete) _preparePartAttempt(session, part);\n        }\n        // Persist the logical generation before any child is handed to native IO.\n        await _persist(session);\n''',
)

replace_once(
    parallel,
    '''    int? expectedBytes,\n    double? speedBytesPerSecond,\n    bool completed = false,\n''',
    '''    int? expectedBytes,\n    int? attemptGeneration,\n    double? speedBytesPerSecond,\n    bool completed = false,\n''',
)

replace_once(
    parallel,
    '''      // Native bridge updates do not carry the Dart task metadata token.\n      // Accept them only while this exact child currently owns a slot.\n      if (part == null || part.complete || !part.launched) return;\n\n''',
    '''      if (part == null || part.complete) return;\n      // Native background refill tasks are created from a pre-fenced child\n      // definition while Dart can be asleep. Adopt that ownership only when\n      // Swift echoed the exact current attempt token. A late callback from an\n      // older URLSession task can therefore never resurrect the Range.\n      if (!part.launched) {\n        final canAdoptNativeOwner =\n            session.active &&\n            !session.pauseRequested &&\n            !part.sourceValidationRequired &&\n            attemptGeneration != null &&\n            attemptGeneration == part.attemptGeneration;\n        if (!canAdoptNativeOwner) return;\n        part.launched = true;\n        _activeConnectionIds.add(part.task.taskId);\n        _markConnectionReady(session, part);\n      } else if (attemptGeneration != null &&\n          part.attemptGeneration > 0 &&\n          attemptGeneration != part.attemptGeneration) {\n        return;\n      }\n\n''',
)

replace_once(
    parallel,
    '''          if (!part.launched &&\n              !(update is TaskStatusUpdate &&\n                  update.status == TaskStatus.complete)) {\n            return;\n          }\n''',
    '''          if (!part.launched &&\n              !(update is TaskStatusUpdate &&\n                  update.status == TaskStatus.complete)) {\n            final canAdoptNativeOwner =\n                session.active &&\n                !session.pauseRequested &&\n                !part.sourceValidationRequired &&\n                callbackAttempt != null &&\n                callbackAttempt == part.attemptGeneration;\n            if (!canAdoptNativeOwner) return;\n            part.launched = true;\n            _activeConnectionIds.add(part.task.taskId);\n            _markConnectionReady(session, part);\n          }\n''',
)

# ---------------------------------------------------------------------------
# Method-channel model: carry the child attempt token and the native refill
# plans to Swift.
# ---------------------------------------------------------------------------
replace_once(
    continued,
    '''  int? expectedBytes,\n  double? speedBytesPerSecond,\n  required bool completed,\n''',
    '''  int? expectedBytes,\n  int? attemptGeneration,\n  double? speedBytesPerSecond,\n  required bool completed,\n''',
)

replace_once(
    continued,
    '''    int sessionCurrentIndex = 0,\n  }) async {\n''',
    '''    int sessionCurrentIndex = 0,\n    List<Map<String, Object>> multipartPlans = const [],\n  }) async {\n''',
)

replace_once(
    continued,
    '''      'sessionCurrentIndex': sessionCurrentIndex,\n    });\n''',
    '''      'sessionCurrentIndex': sessionCurrentIndex,\n      'multipartPlans': multipartPlans,\n    });\n''',
)

replace_once(
    continued,
    '''      final rawExpected = arguments['expectedBytes'];\n      final rawSpeed = arguments['speedBytesPerSecond'];\n      onChunkUpdate?.call(\n''',
    '''      final rawExpected = arguments['expectedBytes'];\n      final rawAttempt = arguments['attemptGeneration'];\n      final rawSpeed = arguments['speedBytesPerSecond'];\n      onChunkUpdate?.call(\n''',
)

replace_once(
    continued,
    '''        expectedBytes: rawExpected is num ? rawExpected.toInt() : null,\n        speedBytesPerSecond: rawSpeed is num ? rawSpeed.toDouble() : null,\n''',
    '''        expectedBytes: rawExpected is num ? rawExpected.toInt() : null,\n        attemptGeneration: rawAttempt is num ? rawAttempt.toInt() : null,\n        speedBytesPerSecond: rawSpeed is num ? rawSpeed.toDouble() : null,\n''',
)

# ---------------------------------------------------------------------------
# DownloadService: publish native refill plans and forward the fencing token.
# ---------------------------------------------------------------------------
replace_once(
    service,
    '''    int? expectedBytes,\n    double? speedBytesPerSecond,\n    bool completed = false,\n''',
    '''    int? expectedBytes,\n    int? attemptGeneration,\n    double? speedBytesPerSecond,\n    bool completed = false,\n''',
)

replace_once(
    service,
    '''        expectedBytes: expectedBytes,\n        speedBytesPerSecond: speedBytesPerSecond,\n        completed: completed,\n''',
    '''        expectedBytes: expectedBytes,\n        attemptGeneration: attemptGeneration,\n        speedBytesPerSecond: speedBytesPerSecond,\n        completed: completed,\n''',
)

replace_once(
    service,
    '''    await _continuedProcessing.persistNativeQueue(\n      maxConcurrent: max,\n''',
    '''    final multipartPlans = <Map<String, Object>>[];\n    if (Platform.isIOS) {\n      for (final plan in _parallel.nativeBackgroundPlans()) {\n        multipartPlans.add(<String, Object>{\n          'parentTaskId': plan.parentTaskId,\n          'maxConcurrent': plan.maxConcurrent,\n          'waiters': <Map<String, Object>>[\n            for (final child in plan.tasks) nativeWaitingPayload(child),\n          ],\n        });\n      }\n    }\n    await _continuedProcessing.persistNativeQueue(\n      maxConcurrent: max,\n''',
)

replace_once(
    service,
    '''      sessionCurrentIndex: overlay?.currentIndex ?? 0,\n    );\n''',
    '''      sessionCurrentIndex: overlay?.currentIndex ?? 0,\n      multipartPlans: multipartPlans,\n    );\n''',
)

# ---------------------------------------------------------------------------
# Swift native owner: remove stale logical owners from persisted aggregation,
# keep one-episode totals singular, and refill multipart children directly on
# the plugin background URLSession while Flutter is suspended.
# ---------------------------------------------------------------------------
replace_once(
    swift,
    '''  struct RunningSample: Codable, Equatable {\n''',
    '''  struct MultipartPlan: Codable, Equatable, Sendable {\n    var parentTaskId: String\n    var maxConcurrent: Int\n    var waiters: [Waiter]\n\n    static func from(arguments: [String: Any]) -> MultipartPlan? {\n      guard let parentTaskId = string(arguments["parentTaskId"]),\n            !parentTaskId.isEmpty else { return nil }\n      let cap = min(max(intValue(arguments["maxConcurrent"]) ?? 1, 1), 16)\n      let waiters = dictionaryArray(arguments["waiters"]).compactMap(Waiter.from(arguments:))\n      return MultipartPlan(\n        parentTaskId: parentTaskId,\n        maxConcurrent: cap,\n        waiters: waiters\n      )\n    }\n  }\n\n  struct RunningSample: Codable, Equatable {\n''',
)

replace_once(
    swift,
    '''    var sessionCurrentIndex: Int\n    var runningSamples: [String: RunningSample]\n\n    init(\n''',
    '''    var sessionCurrentIndex: Int\n    var runningSamples: [String: RunningSample]\n    var multipartPlans: [MultipartPlan]\n\n    init(\n''',
)

replace_once(
    swift,
    '''      sessionCurrentIndex: Int = 0,\n      runningSamples: [String: RunningSample] = [:]\n    ) {\n''',
    '''      sessionCurrentIndex: Int = 0,\n      runningSamples: [String: RunningSample] = [:],\n      multipartPlans: [MultipartPlan] = []\n    ) {\n''',
)

replace_once(
    swift,
    '''      self.sessionCurrentIndex = sessionCurrentIndex\n      self.runningSamples = runningSamples\n    }\n''',
    '''      self.sessionCurrentIndex = sessionCurrentIndex\n      self.runningSamples = runningSamples\n      self.multipartPlans = multipartPlans\n    }\n''',
)

replace_once(
    swift,
    '''      sessionCurrentIndex = try container.decodeIfPresent(Int.self, forKey: .sessionCurrentIndex) ?? 0\n      runningSamples = try container.decodeIfPresent([String: RunningSample].self, forKey: .runningSamples) ?? [:]\n    }\n''',
    '''      sessionCurrentIndex = try container.decodeIfPresent(Int.self, forKey: .sessionCurrentIndex) ?? 0\n      runningSamples = try container.decodeIfPresent([String: RunningSample].self, forKey: .runningSamples) ?? [:]\n      multipartPlans = try container.decodeIfPresent([MultipartPlan].self, forKey: .multipartPlans) ?? []\n    }\n''',
)

replace_once(
    swift,
    '''  private static var lastMultipartOverlayTimes: [String: CFAbsoluteTime] = [:]\n  private static let chunkBridgeInterval: CFTimeInterval = 1.0\n''',
    '''  private static var lastMultipartOverlayTimes: [String: CFAbsoluteTime] = [:]\n  private static var latestDownloadSession: URLSession?\n  private static var multipartPromotionParents = Set<String>()\n  private static let chunkBridgeInterval: CFTimeInterval = 1.0\n''',
)

replace_once(
    swift,
    '''    let dartBatchTotal = intValue(arguments["sessionBatchTotal"]) ?? 0\n    let released = Set(stringArray(arguments["queueWaitingTaskIds"]))\n''',
    '''    let dartBatchTotal = intValue(arguments["sessionBatchTotal"]) ?? 0\n    let dartMultipartPlans = dictionaryArray(arguments["multipartPlans"])\n      .compactMap(MultipartPlan.from(arguments:))\n    let released = Set(stringArray(arguments["queueWaitingTaskIds"]))\n''',
)

replace_once(
    swift,
    '''    let transferring = unique(current.transferringTaskIds + dartTransferring)\n      .filter {\n''',
    '''    // Persisted liveness is not runtime ownership. Keep an old logical ID\n    // only when this process has actual URLSession evidence for it; otherwise a\n    // relaunch plus a new taskId for the same episode made the overlay sum the\n    // same 452 MB resource two or three times.\n    let multipartRuntimeParents = Set(\n      multipartChildSamples.compactMap { $0.value.isEmpty ? nil : $0.key }\n    )\n    let retainedNativeOwners = current.transferringTaskIds.filter {\n      seenTransferringIds.contains($0) || multipartRuntimeParents.contains($0)\n    }\n    let transferring = unique(retainedNativeOwners + dartTransferring)\n      .filter {\n''',
)

replace_once(
    swift,
    '''        runningSamples: current.runningSamples.filter { transferringSet.contains($0.key) }\n      )\n''',
    '''        runningSamples: current.runningSamples.filter { transferringSet.contains($0.key) },\n        multipartPlans: dartMultipartPlans\n      )\n''',
)

replace_once(
    swift,
    '''    multipartChildSamples.removeAll()\n    lastMultipartOverlayTimes.removeAll()\n  }\n''',
    '''    multipartChildSamples.removeAll()\n    lastMultipartOverlayTimes.removeAll()\n    latestDownloadSession = nil\n    multipartPromotionParents.removeAll()\n  }\n''',
)

replace_once(
    swift,
    '''    let transferringSet = Set(state.transferringTaskIds)\n    var written: Int64 = 0\n''',
    '''    let transferringSet = Set(state.transferringTaskIds)\n    // One logical episode must have one byte denominator. Even if a stale\n    // persisted ID survives briefly during foreground/background handoff, never\n    // add two samples for a `1 of 1` session. This is a presentation guard; the\n    // persisted-owner filter above fixes the underlying state.\n    if state.sessionBatchTotal <= 1 {\n      let candidateId = transferringSet.contains(state.sessionCurrentTaskId)\n        && state.runningSamples[state.sessionCurrentTaskId] != nil\n        ? state.sessionCurrentTaskId\n        : state.transferringTaskIds.first(where: { state.runningSamples[$0] != nil })\n      if let candidateId, let running = state.runningSamples[candidateId] {\n        let total = running.expected > 0 ? running.expected : state.sessionTotalBytes\n        let transferred = total > 0\n          ? min(max(running.written, 0), total)\n          : max(running.written, 0)\n        let progress = total > 0\n          ? min(max(Double(transferred) / Double(total), 0), 1)\n          : state.sessionProgress\n        let name = !running.displayName.isEmpty\n          ? running.displayName\n          : (!state.sessionDisplayName.isEmpty ? state.sessionDisplayName : fallbackName)\n        return (\n          currentTaskId: candidateId,\n          displayName: name,\n          progress: progress,\n          totalBytes: total,\n          transferredBytes: transferred,\n          speedBytesPerSecond: max(running.speed, 0)\n        )\n      }\n    }\n    var written: Int64 = 0\n''',
)

# Parse the attempt token embedded by PersistentParallelDownload into the
# native chunk bridge so Dart can safely adopt a child started while asleep.
replace_once(
    swift,
    '''  private static func parentTaskId(from task: URLSessionTask) -> String? {\n''',
    '''  private static func attemptGeneration(from task: URLSessionTask) -> Int? {\n    let description = task.taskDescription ?? ""\n    let json = description.components(separatedBy: "***<<<|>>>***").first ?? description\n    guard let data = json.data(using: .utf8),\n          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],\n          let meta = object["metaData"] as? String,\n          let metaData = meta.data(using: .utf8),\n          let metadata = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any]\n    else { return nil }\n    return (metadata["attemptGeneration"] as? NSNumber)?.intValue\n  }\n\n  private static func parentTaskId(from task: URLSessionTask) -> String? {\n''',
)

replace_once(
    swift,
    '''    if speed > 0 {\n      values["speedBytesPerSecond"] = speed\n    }\n\n    NotificationCenter.default.post(\n''',
    '''    if let attempt = attemptGeneration(from: task) {\n      values["attemptGeneration"] = attempt\n    }\n    if speed > 0 {\n      values["speedBytesPerSecond"] = speed\n    }\n\n    NotificationCenter.default.post(\n''',
)

# Session memory + direct background refill. The plan contains only fresh
# zero-byte children and therefore never consumes opaque resume data.
replace_once(
    swift,
    '''  static func handleBytesWritten(\n    _ downloadTask: URLSessionDownloadTask,\n    totalWritten: Int64,\n    totalExpected: Int64\n  ) {\n    if isDownloadPart(downloadTask) {\n''',
    '''  private static func rememberDownloadSession(_ session: URLSession) {\n    lock.lock()\n    latestDownloadSession = session\n    lock.unlock()\n  }\n\n  static func acceptsDartOverlayUpdates() -> Bool {\n    isAppInForeground()\n  }\n\n  static func promoteMultipartIfPossible(\n    on suppliedSession: URLSession? = nil,\n    parentId: String? = nil\n  ) {\n    guard !isAppInForeground() else { return }\n\n    lock.lock()\n    if let suppliedSession { latestDownloadSession = suppliedSession }\n    let session = suppliedSession ?? latestDownloadSession\n    let state = loadLocked()\n    let plans = state.multipartPlans.filter { parentId == nil || $0.parentTaskId == parentId }\n    lock.unlock()\n\n    guard let session else { return }\n    for plan in plans where !plan.waiters.isEmpty {\n      promoteMultipartPlan(plan.parentTaskId, on: session)\n    }\n  }\n\n  private static func promoteMultipartPlan(_ parentId: String, on session: URLSession) {\n    lock.lock()\n    if multipartPromotionParents.contains(parentId) {\n      lock.unlock()\n      return\n    }\n    multipartPromotionParents.insert(parentId)\n    lock.unlock()\n\n    session.getAllTasks { tasks in\n      defer {\n        lock.lock()\n        multipartPromotionParents.remove(parentId)\n        lock.unlock()\n      }\n      guard !isAppInForeground() else { return }\n\n      let liveChildIds = Set(tasks.compactMap { task -> String? in\n        guard task.state != .completed,\n              isDownloadPart(task),\n              parentTaskId(from: task) == parentId\n        else { return nil }\n        return taskId(from: task)\n      })\n\n      let selected: [Waiter]\n      lock.lock()\n      var state = loadLocked()\n      guard let index = state.multipartPlans.firstIndex(where: { $0.parentTaskId == parentId }) else {\n        lock.unlock()\n        return\n      }\n      var plan = state.multipartPlans[index]\n      plan.waiters.removeAll { liveChildIds.contains($0.taskId) }\n      let available = max(min(plan.maxConcurrent, 16) - liveChildIds.count, 0)\n      selected = Array(plan.waiters.prefix(available))\n      if !selected.isEmpty {\n        let selectedIds = Set(selected.map(\\.taskId))\n        plan.waiters.removeAll { selectedIds.contains($0.taskId) }\n      }\n      state.multipartPlans[index] = plan\n      saveLocked(state)\n      lock.unlock()\n\n      for waiter in selected {\n        startMultipartChild(waiter, on: session)\n      }\n    }\n  }\n\n  private static func startMultipartChild(_ waiter: Waiter, on session: URLSession) {\n    guard waiter.savedProgress <= 0,\n          waiter.resumeDataBase64?.isEmpty ?? true,\n          let url = URL(string: waiter.url)\n    else { return }\n    var request = URLRequest(url: url)\n    request.httpMethod = waiter.httpRequestMethod.isEmpty ? "GET" : waiter.httpRequestMethod\n    for (key, value) in waiter.headers {\n      request.setValue(value, forHTTPHeaderField: key)\n    }\n    if let post = postFromTaskJson(waiter.taskJson), !post.isEmpty {\n      request.httpBody = post.data(using: .utf8)\n    }\n    let task = session.downloadTask(with: request)\n    task.taskDescription = waiter.taskDescription\n    task.priority = URLSessionTask.highPriority\n    DownloadNativeDiagnosticLog.record("background.multipart.promote", task: task)\n    task.resume()\n  }\n\n  static func handleBytesWritten(\n    _ downloadTask: URLSessionDownloadTask,\n    session: URLSession? = nil,\n    totalWritten: Int64,\n    totalExpected: Int64\n  ) {\n    if let session { rememberDownloadSession(session) }\n    if isDownloadPart(downloadTask) {\n''',
)

replace_once(
    swift,
    '''      postMultipartChunkUpdate(\n        downloadTask,\n        totalWritten: totalWritten,\n        totalExpected: totalExpected,\n        completed: false\n      )\n      return\n''',
    '''      postMultipartChunkUpdate(\n        downloadTask,\n        totalWritten: totalWritten,\n        totalExpected: totalExpected,\n        completed: false\n      )\n      promoteMultipartIfPossible(on: session, parentId: parentTaskId(from: downloadTask))\n      return\n''',
)

replace_once(
    swift,
    '''  static func handlePluginTaskCompleted(\n    session: URLSession,\n    task: URLSessionTask,\n    error: Error?\n  ) {\n''',
    '''  static func handlePluginTaskCompleted(\n    session: URLSession,\n    task: URLSessionTask,\n    error: Error?\n  ) {\n    rememberDownloadSession(session)\n''',
)

replace_once(
    swift,
    '''      postMultipartChunkUpdate(\n        task,\n        totalWritten: task.countOfBytesReceived,\n        totalExpected: task.countOfBytesExpectedToReceive,\n        completed: error == nil\n      )\n      return\n''',
    '''      postMultipartChunkUpdate(\n        task,\n        totalWritten: task.countOfBytesReceived,\n        totalExpected: task.countOfBytesExpectedToReceive,\n        completed: error == nil\n      )\n      promoteMultipartIfPossible(on: session, parentId: parentTaskId(from: task))\n      return\n''',
)

# Hook passes its exact background URLSession into the refill owner.
replace_once(
    swift,
    '''      DownloadNativeWaitingQueue.handleBytesWritten(\n        downloadTask,\n        totalWritten: totalWritten,\n        totalExpected: totalExpected\n      )\n''',
    '''      DownloadNativeWaitingQueue.handleBytesWritten(\n        downloadTask,\n        session: session,\n        totalWritten: totalWritten,\n        totalExpected: totalExpected\n      )\n''',
)

# AppDelegate: persisted plans can refill immediately if a background session
# has already been observed. Also prevent Dart's stale transition samples from
# racing the native background presentation clock.
replace_once(
    app_delegate,
    '''        DownloadNativeWaitingQueue.persist(from: arguments)\n        result(true)\n''',
    '''        DownloadNativeWaitingQueue.persist(from: arguments)\n        DownloadNativeWaitingQueue.promoteMultipartIfPossible()\n        result(true)\n''',
)

replace_once(
    app_delegate,
    '''          case "update":\n            let progress =\n''',
    '''          case "update":\n            if !DownloadNativeWaitingQueue.acceptsDartOverlayUpdates() {\n              result(true)\n              return\n            }\n            let progress =\n''',
)

replace_once(
    app_delegate,
    '''      if let speed = values["speedBytesPerSecond"] as? NSNumber {\n        arguments["speedBytesPerSecond"] = speed.doubleValue\n      }\n      if let completed = values["completed"] as? Bool {\n''',
    '''      if let attempt = values["attemptGeneration"] as? NSNumber {\n        arguments["attemptGeneration"] = attempt.intValue\n      }\n      if let speed = values["speedBytesPerSecond"] as? NSNumber {\n        arguments["speedBytesPerSecond"] = speed.doubleValue\n      }\n      if let completed = values["completed"] as? Bool {\n''',
)

# ---------------------------------------------------------------------------
# Static regression checks pin the two user-visible invariants and the native
# background refill ownership model.
# ---------------------------------------------------------------------------
replace_once(
    runtime_test,
    '''    test(\n      'multipart native bytes keep iOS continued-processing progress alive',\n''',
    '''    test('single-episode iOS overlay cannot multiply the file total', () {\n      final swift = File('ios/Runner/DownloadNativeWaitingQueue.swift')\n          .readAsStringSync();\n      expect(swift, contains('if state.sessionBatchTotal <= 1'));\n      expect(swift, contains('retainedNativeOwners + dartTransferring'));\n      expect(\n        swift,\n        isNot(contains('current.transferringTaskIds + dartTransferring')),\n      );\n      expect(swift, contains('acceptsDartOverlayUpdates()'));\n\n      final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();\n      expect(\n        appDelegate,\n        contains('if !DownloadNativeWaitingQueue.acceptsDartOverlayUpdates()'),\n      );\n    });\n\n    test('iOS background multipart refills the proven connection width natively', () {\n      final parallel = File('lib/core/services/persistent_parallel_download.dart')\n          .readAsStringSync();\n      expect(parallel, contains('nativeBackgroundPlans()'));\n      expect(parallel, contains('maxConcurrent: provenWidth.clamp('));\n      expect(parallel, contains('part.progress <= 0'));\n      expect(parallel, contains('!part.sourceValidationRequired'));\n      expect(parallel, contains('attemptGeneration == part.attemptGeneration'));\n\n      final swift = File('ios/Runner/DownloadNativeWaitingQueue.swift')\n          .readAsStringSync();\n      expect(swift, contains('struct MultipartPlan: Codable'));\n      expect(swift, contains('promoteMultipartIfPossible('));\n      expect(swift, contains('session.getAllTasks'));\n      expect(swift, contains('startMultipartChild(waiter, on: session)'));\n      expect(swift, contains('task.priority = URLSessionTask.highPriority'));\n      expect(swift, contains('background.multipart.promote'));\n      expect(swift, contains('values["attemptGeneration"] = attempt'));\n    });\n\n    test(\n      'multipart native bytes keep iOS continued-processing progress alive',\n''',
)

print('Applied iOS background multipart total/throughput hardening.')
