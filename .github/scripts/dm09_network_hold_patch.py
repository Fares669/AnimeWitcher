from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"DM-09 patch drift in {path}: expected 1 occurrence, got {count}: {old[:120]!r}")
    p.write_text(text.replace(old, new, 1))


retry = "lib/core/services/download_retry_policy.dart"
replace_once(
    retry,
    "enum DownloadFailureAction {\n  retry,\n  refreshUrl,\n",
    "enum DownloadFailureAction {\n  retry,\n  waitForNetwork,\n  refreshUrl,\n",
)
replace_once(
    retry,
    "  if (connectionFailure || isRetryableDownloadStatus(statusCode)) {\n    return DownloadRetryDecision(\n      DownloadFailureAction.retry,\n      delay: downloadRetryDelay(\n        retryIndex: retryIndex,\n        retryAfter: retryAfter,\n        jitterUnit: jitterUnit,\n      ),\n    );\n  }\n",
    "  if (connectionFailure) {\n    return const DownloadRetryDecision(DownloadFailureAction.waitForNetwork);\n  }\n  if (isRetryableDownloadStatus(statusCode)) {\n    return DownloadRetryDecision(\n      DownloadFailureAction.retry,\n      delay: downloadRetryDelay(\n        retryIndex: retryIndex,\n        retryAfter: retryAfter,\n        jitterUnit: jitterUnit,\n      ),\n    );\n  }\n",
)

job_state = "lib/core/services/download_job_state.dart"
replace_once(
    job_state,
    "  running,\n  retryWaiting,\n  pausing,\n",
    "  running,\n  retryWaiting,\n  waitingForNetwork,\n  pausing,\n",
)
replace_once(
    job_state,
    "    DownloadJobState.queued ||\n    DownloadJobState.pausedByUser ||\n",
    "    DownloadJobState.queued ||\n    DownloadJobState.waitingForNetwork ||\n    DownloadJobState.pausedByUser ||\n",
)
replace_once(
    job_state,
    "    DownloadJobState.retryWaiting => TaskStatus.waitingToRetry,\n",
    "    DownloadJobState.retryWaiting ||\n    DownloadJobState.waitingForNetwork => TaskStatus.waitingToRetry,\n",
)
replace_once(
    job_state,
    "    DownloadJobState.retryWaiting => TaskStatus.waitingToRetry,\n",
    "    DownloadJobState.retryWaiting ||\n    DownloadJobState.waitingForNetwork => TaskStatus.waitingToRetry,\n",
)
replace_once(
    job_state,
    "  /// An explicit user pause is durable across process death.\n  keepPaused,\n\n  /// The row is terminal",
    "  /// An explicit user pause is durable across process death.\n  keepPaused,\n\n  /// Connectivity is unavailable and no executor currently owns the writer.\n  /// Keep durable bytes parked until a connectivity restoration reconciliation.\n  keepNetworkHeld,\n\n  /// The row is terminal",
)
replace_once(
    job_state,
    "  required bool stillInNativeQueue,\n  required bool hasMetadata,\n}) {",
    "  required bool stillInNativeQueue,\n  required bool hasMetadata,\n  bool networkAvailable = true,\n}) {",
)
replace_once(
    job_state,
    "  if (userPaused) {\n    return const DownloadRecoveryPlan(\n      state: DownloadJobState.pausedByUser,\n      action: DownloadRecoveryAction.keepPaused,\n    );\n  }\n\n  if (stillInNativeQueue) {",
    "  if (userPaused) {\n    return const DownloadRecoveryPlan(\n      state: DownloadJobState.pausedByUser,\n      action: DownloadRecoveryAction.keepPaused,\n    );\n  }\n\n  if (!networkAvailable && !queueWaiting) {\n    final recoverableOffline = persisted != TaskStatus.complete &&\n        (persisted != TaskStatus.canceled || hasMetadata);\n    if (recoverableOffline) {\n      return DownloadRecoveryPlan(\n        state: DownloadJobState.waitingForNetwork,\n        action: stillInNativeQueue\n            ? DownloadRecoveryAction.keepNative\n            : DownloadRecoveryAction.keepNetworkHeld,\n      );\n    }\n  }\n\n  if (stillInNativeQueue) {",
)
replace_once(
    job_state,
    "  bool authoritativeUserPaused = false,\n  bool authoritativeQueueWaiting = false,\n}) {\n  if (authoritativeState == null) {",
    "  bool authoritativeUserPaused = false,\n  bool authoritativeQueueWaiting = false,\n  bool networkAvailable = true,\n}) {\n  if (authoritativeState == null) {",
)
replace_once(
    job_state,
    "      stillInNativeQueue: stillInNativeQueue,\n      hasMetadata: hasMetadata,\n    );\n",
    "      stillInNativeQueue: stillInNativeQueue,\n      hasMetadata: hasMetadata,\n      networkAvailable: networkAvailable,\n    );\n",
)
replace_once(
    job_state,
    "  if (stillInNativeQueue) {\n    final state = switch (authoritativeState) {",
    "  if (authoritativeState == DownloadJobState.waitingForNetwork) {\n    if (!networkAvailable) {\n      return DownloadRecoveryPlan(\n        state: DownloadJobState.waitingForNetwork,\n        action: stillInNativeQueue\n            ? DownloadRecoveryAction.keepNative\n            : DownloadRecoveryAction.keepNetworkHeld,\n      );\n    }\n    if (!stillInNativeQueue) {\n      return const DownloadRecoveryPlan(\n        state: DownloadJobState.interrupted,\n        action: DownloadRecoveryAction.requeue,\n      );\n    }\n  }\n\n  if (!networkAvailable &&\n      authoritativeState != DownloadJobState.queued) {\n    return DownloadRecoveryPlan(\n      state: DownloadJobState.waitingForNetwork,\n      action: stillInNativeQueue\n          ? DownloadRecoveryAction.keepNative\n          : DownloadRecoveryAction.keepNetworkHeld,\n    );\n  }\n\n  if (stillInNativeQueue) {\n    final state = switch (authoritativeState) {",
)
replace_once(
    job_state,
    "      DownloadJobState.retryWaiting => DownloadJobState.retryWaiting,\n      DownloadJobState.assembling =>",
    "      DownloadJobState.retryWaiting => DownloadJobState.retryWaiting,\n      DownloadJobState.waitingForNetwork => DownloadJobState.waitingForNetwork,\n      DownloadJobState.assembling =>",
)

range_file = "lib/core/services/download_range_transfer.dart"
replace_once(
    range_file,
    "        reconnects++;\n        await output.flush();\n        final reconnectDecision = planDownloadFailure(\n          connectionFailure: true,\n          retryIndex: reconnects - 1,\n          jitterUnit: _random.nextDouble(),\n        );\n        await _retryDelay(operation, reconnectDecision.delay);\n",
    "        reconnects++;\n        await output.flush();\n        final reconnectDecision = planDownloadFailure(\n          connectionFailure: true,\n          retryIndex: reconnects - 1,\n          jitterUnit: _random.nextDouble(),\n        );\n        if (reconnectDecision.action == DownloadFailureAction.waitForNetwork) {\n          operation.failure = DownloadRangeFailure(\n            action: DownloadFailureAction.waitForNetwork,\n            error: streamError,\n          );\n          throw streamError ?? const HttpException('Network unavailable');\n        }\n        await _retryDelay(operation, reconnectDecision.delay);\n",
)

service = "lib/core/services/download_service.dart"
replace_once(
    service,
    "import 'package:background_downloader/background_downloader.dart';\nimport 'package:dio/dio.dart';\n",
    "import 'package:background_downloader/background_downloader.dart';\nimport 'package:connectivity_plus/connectivity_plus.dart';\nimport 'package:dio/dio.dart';\n",
)
replace_once(
    service,
    "    DownloadJobState.retryWaiting ||\n    DownloadJobState.interrupted => DownloadCommandOutcome.recoverableFailure,\n",
    "    DownloadJobState.retryWaiting ||\n    DownloadJobState.waitingForNetwork ||\n    DownloadJobState.interrupted => DownloadCommandOutcome.recoverableFailure,\n",
)
replace_once(
    service,
    "  StreamSubscription<TaskUpdate>? _updatesSubscription;\n  bool _isInitialized = false;\n",
    "  StreamSubscription<TaskUpdate>? _updatesSubscription;\n  final Connectivity _connectivity = Connectivity();\n  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;\n  bool _networkAvailable = true;\n  bool _isInitialized = false;\n",
)
replace_once(
    service,
    "    _updatesSubscription?.cancel();\n    unawaited(_continuedProcessing.dispose());\n",
    "    _updatesSubscription?.cancel();\n    _connectivitySubscription?.cancel();\n    unawaited(_continuedProcessing.dispose());\n",
)
replace_once(
    service,
    "  Future<void> init() {\n",
    "  bool _hasConnectivity(List<ConnectivityResult> results) =>\n      results.any((result) => result != ConnectivityResult.none);\n\n  Future<void> _initializeConnectivity() async {\n    try {\n      _networkAvailable = _hasConnectivity(await _connectivity.checkConnectivity());\n    } catch (_) {\n      // A platform connectivity probe failure is unknown, not proof of offline.\n      _networkAvailable = true;\n    }\n    await _connectivitySubscription?.cancel();\n    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(\n      _handleConnectivityChanged,\n    );\n    diagnosticLog.record('network.state', {'available': _networkAvailable});\n  }\n\n  void _handleConnectivityChanged(List<ConnectivityResult> results) {\n    final available = _hasConnectivity(results);\n    final restored = !_networkAvailable && available;\n    _networkAvailable = available;\n    diagnosticLog.record('network.state', {\n      'available': available,\n      'restored': restored,\n    });\n    if (restored && _isInitialized && !_disposed) {\n      unawaited(_resumeNetworkHeldDownloads());\n    }\n  }\n\n  Future<void> _holdDownloadForNetwork(DownloadTask task) async {\n    if (_disposed ||\n        _terminalJobIds.contains(task.taskId) ||\n        _userPausedIds.contains(task.taskId)) {\n      return;\n    }\n    final saved = await _savedProgressFor(task);\n    final checkpointed = await _checkpointLogicalJob(\n      task,\n      state: DownloadJobState.waitingForNetwork,\n      durableBytes: saved.partialBytes,\n      durableByteProvenance: DownloadDurableByteProvenance.exactDisk,\n      expectedBytes: saved.totalSize,\n      userPaused: false,\n      queueWaiting: false,\n    );\n    if (!checkpointed) return;\n    final hold = await _jobStore.beginOperation(\n      task.taskId,\n      state: DownloadJobState.waitingForNetwork,\n    );\n    if (hold == null) return;\n    _queueWaitingIds.remove(task.taskId);\n    _waitingPayloads.remove(task.taskId);\n    await FileDownloader().database.updateRecord(\n      TaskRecord(\n        task,\n        TaskStatus.waitingToRetry,\n        saved.progress,\n        saved.totalSize,\n      ),\n    );\n    _publishProgress(\n      trackingUrl: downloadTrackingUrl(task),\n      taskId: task.taskId,\n      progress: saved.progress,\n      totalSize: saved.totalSize,\n      status: TaskStatus.waitingToRetry,\n    );\n    _updatesController.add(TaskStatusUpdate(task, TaskStatus.waitingToRetry));\n    diagnosticLog.record('network.hold', {\n      'taskId': task.taskId,\n      'generation': hold.generation,\n    });\n  }\n\n  Future<void> _resumeNetworkHeldDownloads() async {\n    if (!_networkAvailable || _disposed) return;\n    await _serializeQueue(() async {\n      if (!_networkAvailable || _disposed) return;\n      final held = (await _jobStore.all())\n          .where((job) => job.state == DownloadJobState.waitingForNetwork)\n          .toList(growable: false);\n      for (final job in held) {\n        if (_terminalJobIds.contains(job.taskId) ||\n            _userPausedIds.contains(job.taskId)) {\n          continue;\n        }\n        final ownership = await _runtimeOwnershipFor(job.taskId);\n        if (ownership == DownloadRuntimeOwnership.owned) {\n          diagnosticLog.record('network.restoreOwned', {'taskId': job.taskId});\n          continue;\n        }\n        if (ownership != DownloadRuntimeOwnership.notOwned) {\n          diagnosticLog.record('network.restoreDeferred', {\n            'taskId': job.taskId,\n            'ownership': ownership.name,\n          });\n          continue;\n        }\n        final record = await FileDownloader().database.recordForId(job.taskId);\n        final task = record?.task is DownloadTask\n            ? record!.task as DownloadTask\n            : job.restoreTaskSnapshot();\n        if (task == null) continue;\n        final claim = await _jobStore.beginOperation(\n          job.taskId,\n          state: DownloadJobState.interrupted,\n        );\n        if (claim == null) continue;\n        await _enqueueExistingTaskAsWaiterUnlocked(task);\n        diagnosticLog.record('network.restoreQueued', {\n          'taskId': job.taskId,\n          'generation': claim.generation,\n        });\n      }\n      await _syncQueueToCapUnlocked();\n      await _syncSessionOverlay();\n    });\n  }\n\n  Future<void> _acknowledgeNativeNetworkResume(DownloadTask task) async {\n    final job = await _jobStore.get(task.taskId);\n    if (job?.state != DownloadJobState.waitingForNetwork) return;\n    final ownership = await _runtimeOwnershipFor(task.taskId);\n    if (ownership != DownloadRuntimeOwnership.owned) return;\n    final token = await _jobStore.beginOperation(\n      task.taskId,\n      state: DownloadJobState.running,\n    );\n    if (token != null) {\n      diagnosticLog.record('network.nativeResumeAck', {\n        'taskId': task.taskId,\n        'generation': token.generation,\n      });\n    }\n  }\n\n  Future<void> init() {\n",
)
replace_once(
    service,
    "    diagnosticLog.record('service.initialize');\n    // Restore durable user intent before native/plugin callbacks can race the\n",
    "    diagnosticLog.record('service.initialize');\n    await _initializeConnectivity();\n    // Restore durable user intent before native/plugin callbacks can race the\n",
)
replace_once(
    service,
    "      // Ghost cancel/fail from HQ dequeue while URLSession still owns this\n",
    "      if (update is TaskStatusUpdate &&\n          update.task is DownloadTask &&\n          !_networkAvailable &&\n          (update.status == TaskStatus.waitingToRetry ||\n              update.status == TaskStatus.failed ||\n              update.status == TaskStatus.canceled ||\n              update.status == TaskStatus.notFound)) {\n        unawaited(_holdDownloadForNetwork(update.task as DownloadTask));\n        return;\n      }\n\n      if (update is TaskStatusUpdate &&\n          update.task is DownloadTask &&\n          update.status == TaskStatus.running) {\n        unawaited(\n          _acknowledgeNativeNetworkResume(update.task as DownloadTask),\n        );\n      }\n\n      // Ghost cancel/fail from HQ dequeue while URLSession still owns this\n",
)
replace_once(
    service,
    "        authoritativeQueueWaiting: oldJob?.queueWaiting ?? false,\n      );\n",
    "        authoritativeQueueWaiting: oldJob?.queueWaiting ?? false,\n        networkAvailable: _networkAvailable,\n      );\n",
)
replace_once(
    service,
    "      if (oldJob != null &&\n          recoveryPlan.action == DownloadRecoveryAction.ignore) {\n        _queueWaitingIds.remove(task.taskId);\n        _waitingPayloads.remove(task.taskId);\n        _forgetSessionTask(task.taskId);\n        continue;\n      }\n\n      var userPauseSettled = !userPaused;\n",
    "      if (oldJob != null &&\n          recoveryPlan.action == DownloadRecoveryAction.ignore) {\n        _queueWaitingIds.remove(task.taskId);\n        _waitingPayloads.remove(task.taskId);\n        _forgetSessionTask(task.taskId);\n        continue;\n      }\n\n      if (recoveryPlan.action == DownloadRecoveryAction.keepNetworkHeld) {\n        _queueWaitingIds.remove(task.taskId);\n        _waitingPayloads.remove(task.taskId);\n        _rememberSessionTask(task.taskId);\n        await FileDownloader().database.updateRecord(\n          TaskRecord(\n            task,\n            TaskStatus.waitingToRetry,\n            progress,\n            expectedBytes,\n          ),\n        );\n        _publishProgress(\n          trackingUrl: trackingUrl,\n          taskId: task.taskId,\n          progress: progress,\n          totalSize: expectedBytes,\n          status: TaskStatus.waitingToRetry,\n        );\n        diagnosticLog.record('recovery.networkHeld', {'taskId': task.taskId});\n        continue;\n      }\n\n      var userPauseSettled = !userPaused;\n",
)
replace_once(
    service,
    "      if (job != null) {\n        if (downloadJobOccupiesSlot(job.state)) occupying.add(taskId);\n        continue;\n      }\n",
    "      if (job != null) {\n        if (downloadJobOccupiesSlot(job.state)) {\n          occupying.add(taskId);\n        } else if (job.state == DownloadJobState.waitingForNetwork) {\n          final ownership = await _runtimeOwnershipFor(taskId);\n          if (ownership.blocksNewWriter) occupying.add(taskId);\n        }\n        continue;\n      }\n",
)
replace_once(
    service,
    "  Future<void> _syncQueueToCapUnlocked() async {\n    final max = clampDownloadConcurrency(\n",
    "  Future<void> _syncQueueToCapUnlocked() async {\n    if (!_networkAvailable) return;\n    final max = clampDownloadConcurrency(\n",
)
replace_once(
    service,
    "  Future<bool> _resumeDownloadTask(DownloadTask task) async {\n    if (_parallel.isActive(task.taskId) ||\n",
    "  Future<bool> _resumeDownloadTask(DownloadTask task) async {\n    if (!_networkAvailable) {\n      await _holdDownloadForNetwork(task);\n      return true;\n    }\n    if (_parallel.isActive(task.taskId) ||\n",
)
replace_once(
    service,
    "  Future<DownloadRuntimeOwnership> _runtimeOwnershipFor(String taskId) async {\n    if (_rangeTransfers.isActive(taskId)) {\n",
    "  Future<DownloadRuntimeOwnership> _runtimeOwnershipFor(String taskId) async {\n    if (_rangeTransfers.isActive(taskId) ||\n        _parallel.isActive(taskId) ||\n        _parallel.hasLiveConnections(taskId)) {\n",
)
replace_once(
    service,
    "  Future<bool> _enqueueTransfer(DownloadTask task, int totalBytes) async {\n    if (task is! ParallelDownloadTask) return _nativeTransport.start(task);\n",
    "  Future<bool> _enqueueTransfer(DownloadTask task, int totalBytes) async {\n    if (!_networkAvailable) {\n      await _holdDownloadForNetwork(task);\n      return true;\n    }\n    if (task is! ParallelDownloadTask) return _nativeTransport.start(task);\n",
)
replace_once(
    service,
    "      onFailure: (failure) async {\n        if (!logical || token == null) {\n          if (parallelParent != null &&\n              failure.action == DownloadFailureAction.refreshUrl) {\n            _scheduleParallelParentRefresh(parallelParent.taskId);\n          }\n          return;\n        }\n",
    "      onFailure: (failure) async {\n        if (!logical || token == null) {\n          if (parallelParent != null &&\n              failure.action == DownloadFailureAction.waitForNetwork) {\n            await _holdDownloadForNetwork(parallelParent);\n          } else if (parallelParent != null &&\n              failure.action == DownloadFailureAction.refreshUrl) {\n            _scheduleParallelParentRefresh(parallelParent.taskId);\n          }\n          return;\n        }\n",
)
replace_once(
    service,
    "        if (!await _jobStore.accepts(activeToken)) return;\n        if (failure.action == DownloadFailureAction.refreshUrl) {\n",
    "        if (!await _jobStore.accepts(activeToken)) return;\n        if (failure.action == DownloadFailureAction.waitForNetwork) {\n          await _holdDownloadForNetwork(task);\n          return;\n        }\n        if (failure.action == DownloadFailureAction.refreshUrl) {\n",
)

swift = "ios/Runner/DownloadNativeWaitingQueue.swift"
replace_once(
    swift,
    "  static func backgroundRetryDelay(forConsecutiveFailure failure: Int) -> TimeInterval {\n",
    "  static func isNetworkUnavailableBackgroundTransportErrorCode(_ code: Int) -> Bool {\n    [\n      -1003, // cannot find host\n      -1004, // cannot connect to host\n      -1005, // network connection lost\n      -1006, // DNS lookup failed\n      -1009, // not connected to Internet\n      -1018, // international roaming off\n      -1019, // call is active\n      -1020, // data not allowed\n    ].contains(code)\n  }\n\n  static func backgroundRetryDelay(forConsecutiveFailure failure: Int) -> TimeInterval {\n",
)
replace_once(
    swift,
    "    let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data\n",
    "    if isNetworkUnavailableBackgroundTransportErrorCode(nsError.code) {\n      DownloadNativeDiagnosticLog.record(\n        \"background.networkHold\",\n        task: task,\n        error: error\n      )\n      // Do not spend the bounded server/transport retry budget while the\n      // device has no usable network. The plugin surfaces this settlement and\n      // Dart's durable waitingForNetwork state resumes it on connectivity.\n      return false\n    }\n\n    let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data\n",
)

retry_test = "test/core/services/download_retry_policy_test.dart"
text = Path(retry_test).read_text()
old = """  test('connection failure is retryable without an HTTP status', () {\n    final decision = planDownloadFailure(connectionFailure: true);\n    expect(decision.action, DownloadFailureAction.retry);\n    expect(decision.delay, kDownloadRetryBaseDelay);\n  });\n"""
new = """  test('connection failure enters network hold without backoff budget', () {\n    final decision = planDownloadFailure(connectionFailure: true);\n    expect(decision.action, DownloadFailureAction.waitForNetwork);\n    expect(decision.delay, Duration.zero);\n  });\n"""
if old not in text:
    raise SystemExit('DM-09 retry policy test drift')
Path(retry_test).write_text(text.replace(old, new, 1))
