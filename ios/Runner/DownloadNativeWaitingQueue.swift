#if os(iOS)
import Foundation
// Separate native journal survives Dart suspension. Synchronous, serial appends
// finish before background completion handlers can suspend the process.
enum DownloadNativeDiagnosticLog {
  private static let queue = DispatchQueue(label: "animewitcher.download.log")
  private static let key = "downloadDiagnosticLogEnabled"
  private static var enabled = UserDefaults.standard.bool(forKey: key)
  private static var file: URL?
  private static var size = 0
  private static var sequence = 0
  private static var lastProgress: [String: TimeInterval] = [:]
  private static let session = String(Int64(Date().timeIntervalSince1970 * 1000000))

  static func configure(_ value: Bool) {
    queue.sync {
      enabled = value
      UserDefaults.standard.set(value, forKey: key)
      lastProgress.removeAll()
    }
  }

  private static func progressOwnerKey(_ task: URLSessionTask) -> String {
    if let taskId = DownloadNativeWaitingQueue.taskId(from: task), !taskId.isEmpty {
      if let part = taskId.range(of: ".part.", options: .backwards) {
        return String(taskId[..<part.lowerBound])
      }
      return taskId
    }
    return "native:\(task.taskIdentifier)"
  }

  static func record(_ event: String, task: URLSessionTask, error: Error? = nil) {
    queue.sync {
      guard enabled else { return }
      let now = Date().timeIntervalSince1970
      let progressKey = progressOwnerKey(task)
      if event == "progress" {
        if let previous = lastProgress[progressKey], now - previous < 1.0 { return }
        lastProgress[progressKey] = now
      } else {
        lastProgress.removeValue(forKey: progressKey)
      }
      sequence += 1
      var row: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()),
        "session": session, "sequence": sequence, "source": "ios", "event": event,
        "nativeTaskId": task.taskIdentifier, "bytes": task.countOfBytesReceived,
        "total": task.countOfBytesExpectedToReceive, "state": task.state.rawValue]
      if let id = DownloadNativeWaitingQueue.taskId(from: task) { row["taskId"] = id }
      if let response = task.response as? HTTPURLResponse { row["httpStatus"] = response.statusCode }
      if let error = error as NSError? { row["errorDomain"] = error.domain; row["errorCode"] = error.code }
      do {
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(0x0a)
        let fm = FileManager.default
        let directory = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("log", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if file == nil || size + data.count > 4 * 1024 * 1024 {
          file = directory.appendingPathComponent("download-ios-\(session)-\(String(format: "%020d", sequence)).log")
          try Data().write(to: file!)
          size = 0
          let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("download-ios-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
          for old in files.dropFirst(5) where old != file { try fm.removeItem(at: old) }
        }
        let handle = try FileHandle(forWritingTo: file!)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        if event != "progress" { try handle.synchronize() }
        size += data.count
      } catch {
        // Logging must never fail or interrupt URLSession delegate handling.
        file = nil
      }
    }
  }
}

import ObjectiveC
import UIKit
#if canImport(background_downloader)
import background_downloader
#endif

/// Full waiter payloads so Swift can start the next URLSession download when
/// ep1 completes — without Flutter, and without reconstructing the task in Dart.
/// Flutter method channels are a no-op while the engine is asleep, so this
/// store holds url/headers/filename/directory/task JSON for the plugin session.
enum DownloadNativeWaitingQueue {
  static let stateKey = "com.animewitcher.download.nativeWaitingQueue.v2"

  struct Waiter: Codable, Equatable, Sendable {
    var taskId: String
    var taskJson: String
    var notificationConfigJson: String?
    var displayName: String
    var url: String
    var headers: [String: String]
    var filename: String
    var directory: String
    var httpRequestMethod: String
    var group: String
    var resumeDataBase64: String?
    var progress: Double?
    var expectedBytes: Int64?

    var taskDescription: String {
      if let notificationConfigJson, !notificationConfigJson.isEmpty {
        return taskJson + "***<<<|>>>***" + notificationConfigJson
      }
      return taskJson
    }

    var savedProgress: Double {
      let value = progress ?? 0
      return value > 0 && value <= 1 ? value : 0
    }

    var savedExpectedBytes: Int64 {
      expectedBytes ?? -1
    }

    var transferredBytes: Int64 {
      guard savedExpectedBytes > 0, savedProgress > 0 else { return 0 }
      return Int64((Double(savedExpectedBytes) * savedProgress).rounded(.down))
    }

    static func from(arguments: [String: Any]) -> Waiter? {
      guard let taskId = string(arguments["taskId"]), !taskId.isEmpty else {
        return nil
      }
      let taskJson = string(arguments["taskJson"]) ?? ""
      let url = string(arguments["url"]).flatMap { $0.isEmpty ? nil : $0 }
        ?? DownloadNativeWaitingQueue.urlFromTaskJson(taskJson)
      let filename = string(arguments["filename"]).flatMap { $0.isEmpty ? nil : $0 }
        ?? DownloadNativeWaitingQueue.filenameFromTaskJson(taskJson)
      guard !url.isEmpty, !taskJson.isEmpty, !filename.isEmpty else { return nil }
      return Waiter(
        taskId: taskId,
        taskJson: taskJson,
        notificationConfigJson: string(arguments["notificationConfigJson"]),
        displayName: string(arguments["displayName"]).flatMap { $0.isEmpty ? nil : $0 }
          ?? filename,
        url: url,
        headers: stringMap(arguments["headers"]),
        filename: filename,
        directory: string(arguments["directory"]) ?? "",
        httpRequestMethod: string(arguments["httpRequestMethod"]) ?? "GET",
        group: string(arguments["group"]) ?? "FileDownloaderGroup",
        resumeDataBase64: string(arguments["resumeDataBase64"]),
        progress: doubleValue(arguments["progress"]),
        expectedBytes: int64Value(arguments["expectedBytes"])
      )
    }
  }

  struct MultipartPlan: Codable, Equatable, Sendable {
    var parentTaskId: String
    var maxConcurrent: Int
    var waiters: [Waiter]

    static func from(arguments: [String: Any]) -> MultipartPlan? {
      guard let parentTaskId = string(arguments["parentTaskId"]),
            !parentTaskId.isEmpty else { return nil }
      let cap = min(max(intValue(arguments["maxConcurrent"]) ?? 1, 1), 16)
      let waiters = dictionaryArray(arguments["waiters"]).compactMap(Waiter.from(arguments:))
      return MultipartPlan(
        parentTaskId: parentTaskId,
        maxConcurrent: cap,
        waiters: waiters
      )
    }
  }

  struct RunningSample: Codable, Equatable {
    var written: Int64
    var expected: Int64
    var speed: Double
    var displayName: String
  }

  struct State: Codable {
    var maxConcurrent: Int
    var transferringTaskIds: [String]
    var pausedTaskIds: [String]
    var waiters: [Waiter]
    var completedTaskIds: [String]
    var sessionTaskIds: [String]
    var sessionCompletedCount: Int
    var sessionBatchTotal: Int
    var sessionCurrentTaskId: String
    var sessionDisplayName: String
    var sessionProgress: Double
    var sessionTotalBytes: Int64
    var sessionTransferredBytes: Int64
    var sessionSpeedBytesPerSecond: Double
    var sessionCurrentIndex: Int
    var runningSamples: [String: RunningSample]
    var multipartPlans: [MultipartPlan]

    init(
      maxConcurrent: Int,
      transferringTaskIds: [String],
      pausedTaskIds: [String],
      waiters: [Waiter],
      completedTaskIds: [String] = [],
      sessionTaskIds: [String] = [],
      sessionCompletedCount: Int = 0,
      sessionBatchTotal: Int = 0,
      sessionCurrentTaskId: String = "",
      sessionDisplayName: String = "",
      sessionProgress: Double = 0,
      sessionTotalBytes: Int64 = -1,
      sessionTransferredBytes: Int64 = 0,
      sessionSpeedBytesPerSecond: Double = 0,
      sessionCurrentIndex: Int = 0,
      runningSamples: [String: RunningSample] = [:],
      multipartPlans: [MultipartPlan] = []
    ) {
      self.maxConcurrent = maxConcurrent
      self.transferringTaskIds = transferringTaskIds
      self.pausedTaskIds = pausedTaskIds
      self.waiters = waiters
      self.completedTaskIds = completedTaskIds
      self.sessionTaskIds = sessionTaskIds
      self.sessionCompletedCount = sessionCompletedCount
      self.sessionBatchTotal = sessionBatchTotal
      self.sessionCurrentTaskId = sessionCurrentTaskId
      self.sessionDisplayName = sessionDisplayName
      self.sessionProgress = sessionProgress
      self.sessionTotalBytes = sessionTotalBytes
      self.sessionTransferredBytes = sessionTransferredBytes
      self.sessionSpeedBytesPerSecond = sessionSpeedBytesPerSecond
      self.sessionCurrentIndex = sessionCurrentIndex
      self.runningSamples = runningSamples
      self.multipartPlans = multipartPlans
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      maxConcurrent = try container.decodeIfPresent(Int.self, forKey: .maxConcurrent) ?? 1
      transferringTaskIds = try container.decodeIfPresent([String].self, forKey: .transferringTaskIds) ?? []
      pausedTaskIds = try container.decodeIfPresent([String].self, forKey: .pausedTaskIds) ?? []
      waiters = try container.decodeIfPresent([Waiter].self, forKey: .waiters) ?? []
      completedTaskIds = try container.decodeIfPresent([String].self, forKey: .completedTaskIds) ?? []
      sessionTaskIds = try container.decodeIfPresent([String].self, forKey: .sessionTaskIds) ?? []
      sessionCompletedCount = try container.decodeIfPresent(Int.self, forKey: .sessionCompletedCount) ?? 0
      sessionBatchTotal = try container.decodeIfPresent(Int.self, forKey: .sessionBatchTotal) ?? 0
      sessionCurrentTaskId = try container.decodeIfPresent(String.self, forKey: .sessionCurrentTaskId) ?? ""
      sessionDisplayName = try container.decodeIfPresent(String.self, forKey: .sessionDisplayName) ?? ""
      sessionProgress = try container.decodeIfPresent(Double.self, forKey: .sessionProgress) ?? 0
      sessionTotalBytes = try container.decodeIfPresent(Int64.self, forKey: .sessionTotalBytes) ?? -1
      sessionTransferredBytes = try container.decodeIfPresent(Int64.self, forKey: .sessionTransferredBytes) ?? 0
      sessionSpeedBytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .sessionSpeedBytesPerSecond) ?? 0
      sessionCurrentIndex = try container.decodeIfPresent(Int.self, forKey: .sessionCurrentIndex) ?? 0
      runningSamples = try container.decodeIfPresent([String: RunningSample].self, forKey: .runningSamples) ?? [:]
      multipartPlans = try container.decodeIfPresent([MultipartPlan].self, forKey: .multipartPlans) ?? []
    }

    func overlayCurrentIndex(runningTaskId: String? = nil) -> Int {
      let total = max(sessionBatchTotal, 1)
      if transferringTaskIds.isEmpty && !completedTaskIds.isEmpty {
        return min(max(completedTaskIds.count + 1, 1), total)
      }
      let started = transferringTaskIds.count + completedTaskIds.count
      if started > 0 {
        return min(max(started, 1), total)
      }
      if sessionCurrentIndex > 0 {
        return min(max(sessionCurrentIndex, 1), total)
      }
      return min(max(sessionCompletedCount + 1, 1), total)
    }

    var sessionIsIdle: Bool {
      guard transferringTaskIds.isEmpty && waiters.isEmpty else { return false }
      if sessionBatchTotal <= 0 && sessionTaskIds.isEmpty { return true }

      let terminalIds = Set(completedTaskIds).union(pausedTaskIds)
      let hasKnownOutstandingEpisode = sessionTaskIds.contains {
        !terminalIds.contains($0)
      }
      let terminalCount = min(terminalIds.count, max(sessionBatchTotal, 0))
      let batchStillOutstanding = sessionBatchTotal > 0
        && terminalCount < sessionBatchTotal
      return !hasKnownOutstandingEpisode && !batchStillOutstanding
    }
  }

  private struct ThroughputPoint {
    var bytes: Int64
    var time: CFAbsoluteTime
  }

  private struct BackgroundRetryState {
    var consecutiveFailures = 0
    var totalRetries = 0
    var sawProgressSinceLastFailure = false
  }

  private static let backgroundRetryMaxConsecutiveFailures = 12
  private static let backgroundRetryMaxTotalRetries = 128
  private static let lock = NSLock()
  private static var hookInstalled = false
  /// Task IDs that already have URLSession bytes (plugin HQ or our start).
  /// Do not query plugin-internal HoldingQueue APIs.
  private static var seenTransferringIds = Set<String>()

  /// Logical episode keys observed in THIS process only. Unlike the old
  /// duplicate fix, these are never rebuilt from UserDefaults / persisted
  /// `transferringTaskIds`, so a paused/failed task cannot stay "live" after
  /// relaunch and block a real resume.
  private static var activeEpisodeKeysByTaskId: [String: String] = [:]
  private static var startingEpisodeKeys = Set<String>()
  private static var taskSpeedWindows: [String: [ThroughputPoint]] = [:]
  private static var chunkSpeedWindows: [String: [ThroughputPoint]] = [:]
  private static var lastChunkBridgeTimes: [String: CFAbsoluteTime] = [:]
  private static var lastTaskBridgeTimes: [String: CFAbsoluteTime] = [:]
  private static var backgroundRetryStates: [String: BackgroundRetryState] = [:]
  private static var multipartChildSamples: [String: [String: RunningSample]] = [:]
  private static var lastMultipartOverlayTimes: [String: CFAbsoluteTime] = [:]
  private static var latestDownloadSession: URLSession?
  private static var multipartPromotionParents = Set<String>()
  private static let chunkBridgeInterval: CFTimeInterval = 1.0
  private static let taskBridgeInterval: CFTimeInterval = 1.0
  private static let speedWindowInterval: CFTimeInterval = 4.0
  private static let speedMinimumWindow: CFTimeInterval = 0.75
  private static let speedStaleInterval: CFTimeInterval = 3.0
  private static let speedWindowMaxPoints = 32

  static func installUrlSessionHook() {
    lock.lock()
    defer { lock.unlock() }
    guard !hookInstalled else { return }
    hookInstalled = DownloadUrlSessionHook.install()
  }

  /// Dart persist is source of truth for waiters / paused / newly enqueued
  /// transfers, except: waiters already started natively stay transferring, and
  /// tasks native already completed cannot occupy a slot again.
  static func persist(from arguments: [String: Any]) {
    lock.lock()
    defer { lock.unlock() }
    let current = loadLocked()
    let maxConcurrent = clamp(intValue(arguments["maxConcurrent"]) ?? 1)
    let dartTransferring = stringArray(arguments["transferringTaskIds"])
    let dartPaused = stringArray(arguments["pausedTaskIds"])
    let dartWaiters = dictionaryArray(arguments["waiters"]).compactMap(Waiter.from(arguments:))
    let dartSessionIds = stringArray(arguments["sessionTaskIds"])
    let dartCompletedCount = intValue(arguments["sessionCompletedCount"]) ?? 0
    let dartBatchTotal = intValue(arguments["sessionBatchTotal"]) ?? 0
    let dartMultipartPlans = dictionaryArray(arguments["multipartPlans"])
      .compactMap(MultipartPlan.from(arguments:))
    let released = Set(stringArray(arguments["queueWaitingTaskIds"]))

    let pausedSet = Set(dartPaused)
    // Enqueue FIFO from Dart is source of truth for session / waiter order.
    let sessionIds = unique(
      dartSessionIds + current.sessionTaskIds + dartTransferring + dartWaiters.map(\.taskId)
    )
    // Keep completed-in-session IDs so `1 of 5` survives Dart snapshots that
    // no longer list ep1 as transferring. Drop them only when the session is idle.
    var completed = unique(current.completedTaskIds)
    if !sessionIds.isEmpty {
      completed = completed.filter { sessionIds.contains($0) }
    }

    // Leftover Dart-parked waiters must not occupy a native transferring slot.
    seenTransferringIds.subtract(released)
    // Persisted liveness is not runtime ownership. Keep an old logical ID
    // only when this process has actual URLSession evidence for it; otherwise a
    // relaunch plus a new taskId for the same episode made the overlay sum the
    // same 452 MB resource two or three times.
    let multipartRuntimeParents = Set(
      multipartChildSamples.compactMap { $0.value.isEmpty ? nil : $0.key }
    )
    let retainedNativeOwners = current.transferringTaskIds.filter {
      seenTransferringIds.contains($0) || multipartRuntimeParents.contains($0)
    }
    let transferring = unique(retainedNativeOwners + dartTransferring)
      .filter {
        !pausedSet.contains($0)
          && !completed.contains($0)
          && !released.contains($0)
      }
    let transferringSet = Set(transferring)
    multipartChildSamples = multipartChildSamples.filter { transferringSet.contains($0.key) }
    lastMultipartOverlayTimes = lastMultipartOverlayTimes.filter { transferringSet.contains($0.key) }
    let completedSet = Set(completed)
    let waiters = dartWaiters.filter {
      !transferringSet.contains($0.taskId)
        && !pausedSet.contains($0.taskId)
        && !completedSet.contains($0.taskId)
    }

    let idle = transferring.isEmpty && waiters.isEmpty
    if idle && dartBatchTotal == 0 && dartCompletedCount == 0 {
      completed = []
    }

    let completedCount = max(
      max(current.sessionCompletedCount, dartCompletedCount),
      completed.count
    )
    let computedBatch = transferring.count + waiters.count + completed.count
    // Dart's overlay planner counts logical episodes, not raw task IDs. When it
    // supplies a batch total, trust it so duplicate task rows cannot turn one
    // episode into "4 of 4". Native-only background continuation falls back to
    // the existing state/computed count when Dart is asleep.
    let batchTotal: Int
    if idle && dartBatchTotal == 0 {
      batchTotal = 0
    } else if dartBatchTotal > 0 {
      batchTotal = dartBatchTotal
    } else {
      batchTotal = max(current.sessionBatchTotal, computedBatch)
    }

    let dartCurrentId = string(arguments["sessionCurrentTaskId"]) ?? ""
    let switchedFile = !dartCurrentId.isEmpty
      && dartCurrentId != "session"
      && dartCurrentId != current.sessionCurrentTaskId

    saveLocked(
      State(
        maxConcurrent: maxConcurrent,
        transferringTaskIds: transferring,
        pausedTaskIds: unique(dartPaused),
        waiters: waiters,
        completedTaskIds: idle && dartBatchTotal == 0 ? [] : completed,
        sessionTaskIds: idle && dartBatchTotal == 0 ? [] : sessionIds,
        sessionCompletedCount: idle && dartBatchTotal == 0 ? 0 : completedCount,
        sessionBatchTotal: batchTotal,
        sessionCurrentTaskId: {
          let dart = string(arguments["sessionCurrentTaskId"]) ?? ""
          return dart.isEmpty ? current.sessionCurrentTaskId : dart
        }(),
        sessionDisplayName: {
          let dart = string(arguments["sessionDisplayName"]) ?? ""
          return dart.isEmpty ? current.sessionDisplayName : dart
        }(),
        sessionProgress: {
          if switchedFile { return (arguments["sessionProgress"] as? NSNumber)?.doubleValue ?? 0 }
          let dart = (arguments["sessionProgress"] as? NSNumber)?.doubleValue
          if let dart, dart > 0 { return dart }
          return current.sessionProgress
        }(),
        sessionTotalBytes: {
          if switchedFile {
            return int64Value(arguments["sessionTotalBytes"]) ?? -1
          }
          return int64Value(arguments["sessionTotalBytes"]).flatMap { $0 > 0 ? $0 : nil }
            ?? current.sessionTotalBytes
        }(),
        sessionTransferredBytes: {
          let dart = int64Value(arguments["sessionTransferredBytes"])
          if switchedFile { return dart ?? 0 }
          if let dart, dart > 0 { return dart }
          return current.sessionTransferredBytes
        }(),
        sessionSpeedBytesPerSecond: {
          let dart = (arguments["sessionSpeedBytesPerSecond"] as? NSNumber)?.doubleValue
          if switchedFile { return dart ?? 0 }
          if let dart, dart > 0 { return dart }
          return current.sessionSpeedBytesPerSecond
        }(),
        sessionCurrentIndex: {
          let dart = intValue(arguments["sessionCurrentIndex"]) ?? 0
          let started = transferring.count + completed.count
          let nextWaiter = transferring.isEmpty && !completed.isEmpty
            ? completed.count + 1
            : started
          if dart > 0 { return max(dart, nextWaiter) }
          if nextWaiter > 0 { return nextWaiter }
          return current.sessionCurrentIndex
        }(),
        runningSamples: current.runningSamples.filter { transferringSet.contains($0.key) },
        multipartPlans: dartMultipartPlans
      )
    )
  }

  static func load() -> State {
    lock.lock()
    defer { lock.unlock() }
    return loadLocked()
  }

  static func resetForTests() {
    lock.lock()
    defer { lock.unlock() }
    UserDefaults.standard.removeObject(forKey: stateKey)
    seenTransferringIds.removeAll()
    activeEpisodeKeysByTaskId.removeAll()
    startingEpisodeKeys.removeAll()
    taskSpeedWindows.removeAll()
    chunkSpeedWindows.removeAll()
    lastChunkBridgeTimes.removeAll()
    lastTaskBridgeTimes.removeAll()
    backgroundRetryStates.removeAll()
    multipartChildSamples.removeAll()
    lastMultipartOverlayTimes.removeAll()
    latestDownloadSession = nil
    multipartPromotionParents.removeAll()
  }

  /// URLSession transport failures that are worth retrying without waking
  /// Flutter. -999 (cancelled) is deliberately excluded so user pause/cancel
  /// can never be resurrected by the background recovery layer.
  static func isRetryableBackgroundTransportErrorCode(_ code: Int) -> Bool {
    [
      -997,  // NSURLErrorBackgroundSessionWasDisconnected
      -1001, // timed out
      -1003, // cannot find host
      -1004, // cannot connect to host
      -1005, // network connection lost
      -1006, // DNS lookup failed
      -1009, // not connected to Internet
      -1018, // international roaming off
      -1019, // call is active
      -1020, // data not allowed
      -1200, // secure connection failed (transient TLS reconnects do occur)
    ].contains(code)
  }

  static func backgroundRetryDelay(forConsecutiveFailure failure: Int) -> TimeInterval {
    switch max(failure, 1) {
    case 1: return 1
    case 2: return 2
    case 3: return 4
    case 4: return 8
    case 5: return 16
    default: return 30
    }
  }

  static func canRecreateBackgroundDownload(
    isMultipartPart: Bool,
    receivedBytes: Int64,
    hasResumeData: Bool
  ) -> Bool {
    // Reissuing an immutable multipart Range only loses that one child's
    // volatile prefix. For a full-file transfer, do not silently throw away
    // already-downloaded bytes unless Apple gave us resumeData.
    hasResumeData || isMultipartPart || receivedBytes <= 0
  }

  static func noteBackgroundRetryProgress(_ task: URLSessionTask) {
    guard let id = taskId(from: task) else { return }
    lock.lock()
    if var retry = backgroundRetryStates[id] {
      retry.sawProgressSinceLastFailure = true
      retry.consecutiveFailures = 0
      backgroundRetryStates[id] = retry
    }
    lock.unlock()
  }

  static func clearBackgroundRetry(_ task: URLSessionTask) {
    guard let id = taskId(from: task) else { return }
    lock.lock()
    backgroundRetryStates[id] = nil
    lock.unlock()
  }

  /// Returns true when this completion was consumed by a replacement native
  /// URLSessionDownloadTask. The caller must then skip the plugin's original
  /// didComplete callback; otherwise background_downloader would emit
  /// `Task failed`, free its HoldingQueue slot, and leave the replacement as an
  /// unowned duplicate. The eventual successful/exhausted replacement is what
  /// settles the original plugin task.
  static func retryBackgroundTransferIfNeeded(
    session: URLSession,
    task: URLSessionTask,
    error: Error
  ) -> Bool {
    guard task is URLSessionDownloadTask,
          !isAppInForeground(),
          let taskId = taskId(from: task),
          !taskId.isEmpty
    else {
      return false
    }

    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain,
          isRetryableBackgroundTransportErrorCode(nsError.code)
    else {
      return false
    }

    let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    let hasResumeData = !(resumeData?.isEmpty ?? true)
    let multipartPart = isDownloadPart(task)
    guard canRecreateBackgroundDownload(
      isMultipartPart: multipartPart,
      receivedBytes: task.countOfBytesReceived,
      hasResumeData: hasResumeData
    ) else {
      return false
    }

    let request = task.currentRequest ?? task.originalRequest
    if !hasResumeData && request == nil { return false }

    let consecutive: Int
    lock.lock()
    var retry = backgroundRetryStates[taskId] ?? BackgroundRetryState()
    if retry.sawProgressSinceLastFailure {
      retry.consecutiveFailures = 0
    }
    retry.consecutiveFailures += 1
    retry.totalRetries += 1
    retry.sawProgressSinceLastFailure = false
    consecutive = retry.consecutiveFailures
    if retry.consecutiveFailures > backgroundRetryMaxConsecutiveFailures ||
        retry.totalRetries > backgroundRetryMaxTotalRetries {
      backgroundRetryStates[taskId] = nil
      lock.unlock()
      DownloadNativeDiagnosticLog.record(
        "background.retry.exhausted",
        task: task,
        error: error
      )
      return false
    }
    backgroundRetryStates[taskId] = retry
    lock.unlock()

    let replacement: URLSessionDownloadTask
    if let resumeData, !resumeData.isEmpty {
      replacement = session.downloadTask(withResumeData: resumeData)
    } else {
      replacement = session.downloadTask(with: request!)
    }
    replacement.taskDescription = task.taskDescription
    replacement.priority = task.priority
    replacement.earliestBeginDate = Date().addingTimeInterval(
      backgroundRetryDelay(forConsecutiveFailure: consecutive)
    )

    DownloadNativeDiagnosticLog.record(
      hasResumeData ? "background.retry.resumeData" : "background.retry.rangeRestart",
      task: task,
      error: error
    )
    replacement.resume()
    return true
  }

  /// Called from the plugin URLSession delegate after a native completion
  /// or failure. Parks a failed file as paused, starts the next waiter on
  /// **this same session**, and never finishes the overlay as "failed".
  static func handlePluginTaskCompleted(
    session: URLSession,
    task: URLSessionTask,
    error: Error?
  ) {
    rememberDownloadSession(session)
    // A native part is not an episode, but its URLSession byte/completion
    // evidence belongs to the Dart multipart parent. didFinishDownloadingTo
    // calls us after the plugin moved the temp file, so completion can now be
    // verified against the exact `.part` path by PersistentParallelDownload.
    if isDownloadPart(task) {
      postMultipartChunkUpdate(
        task,
        totalWritten: task.countOfBytesReceived,
        totalExpected: task.countOfBytesExpectedToReceive,
        completed: error == nil
      )
      promoteMultipartIfPossible(on: session, parentId: parentTaskId(from: task))
      return
    }
    if let response = task.response as? HTTPURLResponse,
       !(200...299).contains(response.statusCode) {
      parkFailedTask(task: task)
      promoteNext(on: session)
      refreshSessionOverlay(success: false)
      return
    }
    if error != nil {
      parkFailedTask(task: task)
    } else {
      markPluginTaskCompleted(task: task)
    }

    // Promote / update the SAME overlay before any finish. Finishing the
    // session task here is what suspended the process on ep1 complete.
    promoteNext(on: session)
    refreshSessionOverlay(success: error == nil)
  }

  /// Keep a failed episode in the batch as paused and free its slot so the
  /// next waiter can start. Do not treat it as a successful completion.
  static func parkFailedTask(task: URLSessionTask) {
    guard !isDownloadPart(task) else { return }
    let failedId = taskId(from: task)
    lock.lock()
    var state = loadLocked()
    if let failedId {
      state.transferringTaskIds.removeAll { $0 == failedId }
      state.runningSamples[failedId] = nil
      taskSpeedWindows[failedId] = nil
      lastTaskBridgeTimes[failedId] = nil
      seenTransferringIds.remove(failedId)
      if let key = activeEpisodeKeysByTaskId.removeValue(forKey: failedId) {
        startingEpisodeKeys.remove(key)
      }
      if !state.pausedTaskIds.contains(failedId) {
        state.pausedTaskIds.append(failedId)
      }
      state.waiters.removeAll { $0.taskId == failedId }
      if !state.sessionTaskIds.contains(failedId) {
        state.sessionTaskIds.append(failedId)
      }
      state.sessionBatchTotal = max(
        state.sessionBatchTotal,
        state.transferringTaskIds.count + state.waiters.count
          + state.completedTaskIds.count + state.pausedTaskIds.count
      )
    }
    saveLocked(state)
    lock.unlock()
  }

  /// Record native completion without starting the next file. Used from
  /// `didFinishDownloadingToURL` so ep2 is not created before `didComplete`.
  static func markPluginTaskCompleted(task: URLSessionTask) {
    guard !isDownloadPart(task) else { return }
    let completedId = taskId(from: task)
    lock.lock()
    var state = loadLocked()
    if let completedId {
      state.transferringTaskIds.removeAll { $0 == completedId }
      state.runningSamples[completedId] = nil
      taskSpeedWindows[completedId] = nil
      lastTaskBridgeTimes[completedId] = nil
      seenTransferringIds.remove(completedId)
      if let key = activeEpisodeKeysByTaskId.removeValue(forKey: completedId) {
        startingEpisodeKeys.remove(key)
      }
      if !state.completedTaskIds.contains(completedId) {
        state.completedTaskIds.append(completedId)
      }
      state.sessionCompletedCount = max(
        state.sessionCompletedCount,
        state.completedTaskIds.count
      )
      if !state.sessionTaskIds.contains(completedId) {
        state.sessionTaskIds.append(completedId)
      }
      state.sessionBatchTotal = max(
        state.sessionBatchTotal,
        state.transferringTaskIds.count + state.waiters.count + state.completedTaskIds.count
      )
    }
    saveLocked(state)
    lock.unlock()
  }

  static func promoteNext(on session: URLSession) {
    // In-app (scene foregroundActive), Dart + plugin HoldingQueue own
    // promotion. Starting a second URLSession task while the user is in
    // the app double-downloads.
    // Home screen / Dynamic Island: applicationState can still look `.active`
    // because BGContinuedProcessing keeps the process alive — HQ then never
    // starts ep2 and the island sits at 0B. Scene activation is the
    // foreground check that still skips in-app.
    if isAppInForeground() {
      return
    }
    while true {
      let waiter: Waiter?
      lock.lock()
      var state = loadLocked()
      let cap = clamp(state.maxConcurrent)
      if state.transferringTaskIds.count >= cap {
        lock.unlock()
        return
      }
      waiter = popWaiterLocked(&state)
      if waiter != nil {
        saveLocked(state)
      }
      lock.unlock()
      guard let waiter else { return }
      startIfNotAlreadyNative(waiter, on: session)
    }
  }

  /// One URLSession transfer per logical episode without persisting liveness.
  /// A second taskId for the same episode can be produced by competing native
  /// promotion callbacks; block it only while this process has actually seen
  /// (or is synchronously starting) the first transfer. Pause/fail/relaunch
  /// clears this volatile ownership and leaves the original resume path intact.
  private static func startIfNotAlreadyNative(_ waiter: Waiter, on session: URLSession) {
    let key = episodeKey(for: waiter)
    lock.lock()
    let state = loadLocked()
    let activeTaskId = activeEpisodeKeysByTaskId.first(where: { $0.value == key })?.key
    let alreadyTransferring = seenTransferringIds.contains(waiter.taskId)
      || activeTaskId != nil
      || startingEpisodeKeys.contains(key)
    let alreadyCompleted = state.completedTaskIds.contains(waiter.taskId)
    if !alreadyTransferring && !alreadyCompleted {
      startingEpisodeKeys.insert(key)
      activeEpisodeKeysByTaskId[waiter.taskId] = key
    }
    lock.unlock()

    if alreadyTransferring || alreadyCompleted {
      discardDuplicatePromotion(waiter, activeTaskId: activeTaskId)
      NSLog("[DownloadNativeWaitingQueue] duplicate episode blocked %@", waiter.taskId)
      startLiveActivity(
        taskId: activeTaskId ?? waiter.taskId,
        displayName: waiter.displayName,
        progress: waiter.savedProgress,
        totalBytes: waiter.savedExpectedBytes,
        transferredBytes: waiter.transferredBytes
      )
      return
    }

    // The plugin HoldingQueue can create its URLSession task before the first
    // didWrite callback. The volatile sets above cannot see that short window,
    // which was enough for our background promoter to create a second copy.
    // Ask the real URLSession before creating anything. This is runtime-only:
    // paused/resume state is never persisted or inferred from this check.
    session.getAllTasks { tasks in
      if let nativeTaskId = matchingLiveTaskId(for: waiter, among: tasks) {
        lock.lock()
        startingEpisodeKeys.remove(key)
        activeEpisodeKeysByTaskId.removeValue(forKey: waiter.taskId)
        activeEpisodeKeysByTaskId[nativeTaskId] = key
        seenTransferringIds.insert(nativeTaskId)
        lock.unlock()
        discardDuplicatePromotion(waiter, activeTaskId: nativeTaskId)
        NSLog(
          "[DownloadNativeWaitingQueue] live URLSession duplicate blocked %@ -> %@",
          waiter.taskId,
          nativeTaskId
        )
        startLiveActivity(
          taskId: nativeTaskId,
          displayName: waiter.displayName,
          progress: waiter.savedProgress,
          totalBytes: waiter.savedExpectedBytes,
          transferredBytes: waiter.transferredBytes
        )
        return
      }
      start(waiter, on: session, episodeKey: key)
    }
  }

  private static func discardDuplicatePromotion(_ waiter: Waiter, activeTaskId: String?) {
    lock.lock()
    defer { lock.unlock() }
    var state = loadLocked()
    state.waiters.removeAll { $0.taskId == waiter.taskId }
    if activeTaskId != waiter.taskId {
      state.transferringTaskIds.removeAll { $0 == waiter.taskId }
      state.sessionTaskIds.removeAll { $0 == waiter.taskId }
      activeEpisodeKeysByTaskId.removeValue(forKey: waiter.taskId)
    }
    if let activeTaskId, !state.sessionTaskIds.contains(activeTaskId) {
      state.sessionTaskIds.append(activeTaskId)
    }
    saveLocked(state)
  }

  private static func popWaiterLocked(_ state: inout State) -> Waiter? {
    let paused = Set(state.pausedTaskIds)
    let completed = Set(state.completedTaskIds)
    guard let index = state.waiters.firstIndex(where: {
      !paused.contains($0.taskId) && !completed.contains($0.taskId)
    })
    else {
      return nil
    }
    let waiter = state.waiters.remove(at: index)
    if !state.transferringTaskIds.contains(waiter.taskId) {
      state.transferringTaskIds.append(waiter.taskId)
    }
    return waiter
  }

  /// Skip native promotion while the user is looking at the app. Home
  /// screen / island must still promote — `applicationState == .active` is
  /// true under BGContinuedProcessing even when the scene is backgrounded.
  private static func isAppInForeground() -> Bool {
    if NSClassFromString("XCTestCase") != nil {
      return false
    }
    return runOnMainActor {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      if !scenes.isEmpty {
        return scenes.contains { $0.activationState == .foregroundActive }
      }
      return UIApplication.shared.applicationState == .active
    }
  }

  private static func start(
    _ waiter: Waiter,
    on session: URLSession,
    episodeKey key: String? = nil
  ) {
    let logicalKey = key ?? episodeKey(for: waiter)
    // Progress without a native resume blob belongs to Dart's Range recovery.
    // Never silently start that episode from byte zero in the background.
    if waiter.savedProgress > 0 && (waiter.resumeDataBase64?.isEmpty ?? true) {
      lock.lock()
      var state = loadLocked()
      state.transferringTaskIds.removeAll { $0 == waiter.taskId }
      if !state.pausedTaskIds.contains(waiter.taskId) { state.pausedTaskIds.append(waiter.taskId) }
      startingEpisodeKeys.remove(logicalKey)
      activeEpisodeKeysByTaskId.removeValue(forKey: waiter.taskId)
      saveLocked(state)
      lock.unlock()
      return
    }
    guard let url = URL(string: waiter.url) else {
      lock.lock()
      startingEpisodeKeys.remove(logicalKey)
      activeEpisodeKeysByTaskId.removeValue(forKey: waiter.taskId)
      lock.unlock()
      NSLog("[DownloadNativeWaitingQueue] invalid url for %@", waiter.taskId)
      requeue(waiter)
      return
    }

    lock.lock()
    if let activeTaskId = activeEpisodeKeysByTaskId.first(where: {
      $0.value == logicalKey && $0.key != waiter.taskId
    })?.key {
      startingEpisodeKeys.remove(logicalKey)
      lock.unlock()
      discardDuplicatePromotion(waiter, activeTaskId: activeTaskId)
      NSLog("[DownloadNativeWaitingQueue] duplicate episode blocked %@", waiter.taskId)
      return
    }
    activeEpisodeKeysByTaskId[waiter.taskId] = logicalKey
    startingEpisodeKeys.remove(logicalKey)
    seenTransferringIds.insert(waiter.taskId)
    lock.unlock()

    let downloadTask: URLSessionDownloadTask
    if let resume = waiter.resumeDataBase64,
       !resume.isEmpty,
       let data = Data(base64Encoded: resume),
       !data.isEmpty {
      downloadTask = session.downloadTask(withResumeData: data)
      NSLog("[DownloadNativeWaitingQueue] resume %@", waiter.taskId)
    } else {
      var request = URLRequest(url: url)
      request.httpMethod = waiter.httpRequestMethod.isEmpty ? "GET" : waiter.httpRequestMethod
      for (key, value) in waiter.headers {
        request.setValue(value, forHTTPHeaderField: key)
      }
      if let post = postFromTaskJson(waiter.taskJson), !post.isEmpty {
        request.httpBody = post.data(using: .utf8)
      }
      downloadTask = session.downloadTask(with: request)
    }
    downloadTask.taskDescription = waiter.taskDescription
    downloadTask.resume()
    NSLog("[DownloadNativeWaitingQueue] started %@", waiter.taskId)
    startLiveActivity(
      taskId: waiter.taskId,
      displayName: waiter.displayName,
      progress: waiter.savedProgress,
      totalBytes: waiter.savedExpectedBytes,
      transferredBytes: waiter.transferredBytes
    )
  }

  private static func requeue(_ waiter: Waiter) {
    lock.lock()
    defer { lock.unlock() }
    var state = loadLocked()
    state.transferringTaskIds.removeAll { $0 == waiter.taskId }
    if !state.waiters.contains(where: { $0.taskId == waiter.taskId }) {
      state.waiters.insert(waiter, at: 0)
    }
    saveLocked(state)
  }

  /// `DownloadContinuedProcessingManager` is `@MainActor`. URLSession
  /// callbacks are not. Xcode 26 (Build Preview) rejects a direct call from a
  /// synchronous nonisolated context (`ActorIsolatedCall`). Hop to the main
  /// actor synchronously so ep2's overlay still starts before `completionHandler()`.
  private static func runOnMainActor<T: Sendable>(
    _ work: @escaping @MainActor @Sendable () -> T
  ) -> T {
    if Thread.isMainThread {
      return MainActor.assumeIsolated(work)
    }
    return DispatchQueue.main.sync {
      MainActor.assumeIsolated(work)
    }
  }

  /// Sum every transferring file so the island does not flip sizes/titles
  /// when N>1. Title stays the first running filename in queue order.
  private static func overlayPresentation(
    from state: State,
    fallbackId: String,
    fallbackName: String
  ) -> (
    currentTaskId: String,
    displayName: String,
    progress: Double,
    totalBytes: Int64,
    transferredBytes: Int64,
    speedBytesPerSecond: Double
  ) {
    let transferringSet = Set(state.transferringTaskIds)
    // One logical episode must have one byte denominator. Even if a stale
    // persisted ID survives briefly during foreground/background handoff, never
    // add two samples for a `1 of 1` session. This is a presentation guard; the
    // persisted-owner filter above fixes the underlying state.
    if state.sessionBatchTotal <= 1 {
      let candidateId = transferringSet.contains(state.sessionCurrentTaskId)
        && state.runningSamples[state.sessionCurrentTaskId] != nil
        ? state.sessionCurrentTaskId
        : state.transferringTaskIds.first(where: { state.runningSamples[$0] != nil })
      if let candidateId, let running = state.runningSamples[candidateId] {
        let total = running.expected > 0 ? running.expected : state.sessionTotalBytes
        let transferred = total > 0
          ? min(max(running.written, 0), total)
          : max(running.written, 0)
        let progress = total > 0
          ? min(max(Double(transferred) / Double(total), 0), 1)
          : state.sessionProgress
        let name = !running.displayName.isEmpty
          ? running.displayName
          : (!state.sessionDisplayName.isEmpty ? state.sessionDisplayName : fallbackName)
        return (
          currentTaskId: candidateId,
          displayName: name,
          progress: progress,
          totalBytes: total,
          transferredBytes: transferred,
          speedBytesPerSecond: max(running.speed, 0)
        )
      }
    }
    var written: Int64 = 0
    var expected: Int64 = 0
    var combinedSpeed = 0.0
    var hasExpected = false
    for taskId in state.transferringTaskIds {
      guard let running = state.runningSamples[taskId] else { continue }
      written += running.written
      if running.expected > 0 {
        hasExpected = true
        expected += running.expected
      }
      if running.speed > 0 { combinedSpeed += running.speed }
    }
    if written == 0 && expected <= 0 {
      let sameFile = transferringSet.contains(state.sessionCurrentTaskId)
        || state.transferringTaskIds.isEmpty
      if sameFile {
        written = state.sessionTransferredBytes
        expected = state.sessionTotalBytes
        hasExpected = expected > 0
        if combinedSpeed <= 0 {
          combinedSpeed = state.sessionSpeedBytesPerSecond
        }
      }
    }
    let firstRunningId = state.sessionTaskIds.first(where: { transferringSet.contains($0) })
      ?? state.transferringTaskIds.first
      ?? fallbackId
    let name: String
    if state.transferringTaskIds.count > 1 {
      if let sample = state.runningSamples[firstRunningId], !sample.displayName.isEmpty {
        name = sample.displayName
      } else if !state.sessionDisplayName.isEmpty {
        name = state.sessionDisplayName
      } else {
        name = fallbackName
      }
    } else if !fallbackName.isEmpty {
      name = fallbackName
    } else if let sample = state.runningSamples[firstRunningId], !sample.displayName.isEmpty {
      name = sample.displayName
    } else {
      name = state.sessionDisplayName
    }
    let progress = hasExpected && expected > 0
      ? min(max(Double(written) / Double(expected), 0), 1)
      : state.sessionProgress
    return (
      currentTaskId: firstRunningId,
      displayName: name,
      progress: progress,
      totalBytes: hasExpected ? expected : -1,
      transferredBytes: written,
      speedBytesPerSecond: combinedSpeed
    )
  }


  private static func attemptGeneration(from task: URLSessionTask) -> Int? {
    let description = task.taskDescription ?? ""
    let json = description.components(separatedBy: "***<<<|>>>***").first ?? description
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let meta = object["metaData"] as? String,
          let metaData = meta.data(using: .utf8),
          let metadata = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any]
    else { return nil }
    return (metadata["attemptGeneration"] as? NSNumber)?.intValue
  }

  private static func parentTaskId(from task: URLSessionTask) -> String? {
    let description = task.taskDescription ?? ""
    let json = description.components(separatedBy: "***<<<|>>>***").first ?? description
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }

    if let meta = object["metaData"] as? String,
       let metaData = meta.data(using: .utf8),
       let metadata = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
       let parent = metadata["parentTaskId"] as? String,
       !parent.isEmpty {
      return parent
    }

    let child = object["taskId"] as? String ?? ""
    if let range = child.range(of: ".part.", options: .backwards) {
      let parent = String(child[..<range.lowerBound])
      return parent.isEmpty ? nil : parent
    }
    return nil
  }

  private static func rollingSpeedLocked(
    windows: inout [String: [ThroughputPoint]],
    taskId: String,
    totalWritten: Int64,
    now: CFAbsoluteTime,
    completed: Bool = false
  ) -> Double {
    var points = windows[taskId] ?? []
    if let last = points.last, totalWritten < last.bytes {
      // Resume-data handoff can restart URLSession's counter. Treat it as a new
      // observation window instead of creating a negative/huge delta.
      points.removeAll()
    }
    if points.last?.bytes != totalWritten || points.isEmpty {
      points.append(ThroughputPoint(bytes: max(totalWritten, 0), time: now))
    }
    let cutoff = now - speedWindowInterval
    points.removeAll { $0.time < cutoff }
    if points.count > speedWindowMaxPoints {
      points.removeFirst(points.count - speedWindowMaxPoints)
    }

    if completed {
      windows[taskId] = nil
    } else {
      windows[taskId] = points
    }
    guard points.count >= 2,
          let first = points.first,
          let last = points.last
    else { return 0 }
    let elapsed = last.time - first.time
    let delta = last.bytes - first.bytes
    guard elapsed >= speedMinimumWindow, delta > 0 else { return 0 }
    return Double(delta) / elapsed
  }

  private static func scheduleNativeSpeedStaleReset(
    taskId: String,
    observedAt: CFAbsoluteTime
  ) {
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + speedStaleInterval
    ) {
      lock.lock()
      guard let last = taskSpeedWindows[taskId]?.last,
            last.time <= observedAt + 0.000_001,
            CFAbsoluteTimeGetCurrent() - last.time >= speedStaleInterval
      else {
        lock.unlock()
        return
      }
      var state = loadLocked()
      guard state.transferringTaskIds.contains(taskId),
            var sample = state.runningSamples[taskId]
      else {
        lock.unlock()
        return
      }
      sample.speed = 0
      state.runningSamples[taskId] = sample
      let presentation = overlayPresentation(
        from: state,
        fallbackId: taskId,
        fallbackName: sample.displayName
      )
      saveLocked(state)
      lock.unlock()

      upsertSessionOverlay(
        currentTaskId: presentation.currentTaskId,
        displayName: presentation.displayName,
        progress: presentation.progress,
        totalBytes: presentation.totalBytes,
        transferredBytes: presentation.transferredBytes,
        speedBytesPerSecond: presentation.speedBytesPerSecond
      )
    }
  }

  /// Forward native URLSession byte counts for multipart children while the
  /// body still lives in Apple's temporary file. Dart cannot stat that file,
  /// which is why polling only `0.part`/`1.part` updated in whole-part jumps.
  private static func postMultipartChunkUpdate(
    _ task: URLSessionTask,
    totalWritten: Int64,
    totalExpected: Int64,
    completed: Bool
  ) {
    guard isDownloadPart(task),
          let childId = taskId(from: task),
          let parentId = parentTaskId(from: task)
    else {
      return
    }

    let now = CFAbsoluteTimeGetCurrent()
    let taskJson = task.taskDescription?
      .components(separatedBy: "***<<<|>>>***").first ?? ""
    let childDirectory = stringFromTaskJson(taskJson, key: "directory")
    let partsComponent = URL(fileURLWithPath: childDirectory).lastPathComponent
    let inferredParentName = partsComponent.hasSuffix(".parts")
      ? String(partsComponent.dropLast(".parts".count))
      : parentId

    lock.lock()
    if !completed,
       let lastBridge = lastChunkBridgeTimes[childId],
       now - lastBridge < chunkBridgeInterval {
      lock.unlock()
      return
    }
    if completed {
      lastChunkBridgeTimes[childId] = nil
    } else {
      lastChunkBridgeTimes[childId] = now
    }
    let speed = rollingSpeedLocked(
      windows: &chunkSpeedWindows,
      taskId: childId,
      totalWritten: totalWritten,
      now: now,
      completed: completed
    )

    var state = loadLocked()
    var children = multipartChildSamples[parentId] ?? [:]
    var sample = children[childId] ?? RunningSample(
      written: 0,
      expected: -1,
      speed: 0,
      displayName: inferredParentName
    )
    // A URLSession retry can reset its local byte counter. Keep native overlay
    // progress monotonic while the replacement catches up; this sample is UI
    // lease telemetry only and is never used as durable resume evidence.
    sample.written = max(sample.written, max(totalWritten, 0))
    if totalExpected > 0 {
      sample.expected = max(sample.expected, totalExpected)
      if completed { sample.written = sample.expected }
    }
    sample.speed = completed ? 0 : max(speed, 0)
    if sample.displayName.isEmpty { sample.displayName = inferredParentName }
    children[childId] = sample
    multipartChildSamples[parentId] = children

    let aggregateWritten = children.values.reduce(Int64(0)) { $0 + max($1.written, 0) }
    let sampledExpected = children.values.reduce(Int64(0)) {
      $0 + ($1.expected > 0 ? $1.expected : 0)
    }
    let knownParentTotal = state.sessionCurrentTaskId == parentId && state.sessionTotalBytes > 0
      ? state.sessionTotalBytes
      : -1
    let aggregateExpected = knownParentTotal > 0 ? knownParentTotal : sampledExpected
    let aggregateSpeed = children.values.reduce(0.0) {
      $0 + ($1.speed.isFinite && $1.speed > 0 ? $1.speed : 0)
    }
    let parentName = state.sessionCurrentTaskId == parentId && !state.sessionDisplayName.isEmpty
      ? state.sessionDisplayName
      : inferredParentName

    let parentIsTransferring = state.transferringTaskIds.contains(parentId)
    if parentIsTransferring {
      state.runningSamples[parentId] = RunningSample(
        written: min(aggregateWritten, aggregateExpected > 0 ? aggregateExpected : aggregateWritten),
        expected: aggregateExpected,
        speed: aggregateSpeed,
        displayName: parentName
      )
    }
    let presentation = overlayPresentation(
      from: state,
      fallbackId: parentId,
      fallbackName: parentName
    )
    let lastOverlay = lastMultipartOverlayTimes[parentId] ?? 0
    let shouldUpdateNativeOverlay = parentIsTransferring
      && (completed || now - lastOverlay >= chunkBridgeInterval)
    if shouldUpdateNativeOverlay { lastMultipartOverlayTimes[parentId] = now }
    if shouldUpdateNativeOverlay || completed {
      saveLocked(state)
    }
    lock.unlock()

    var values: [String: Any] = [
      "parentTaskId": parentId,
      "chunkTaskId": childId,
      "completed": completed,
    ]
    if totalWritten >= 0 {
      values["writtenBytes"] = totalWritten
    }
    if totalExpected > 0 {
      values["expectedBytes"] = totalExpected
      values["progress"] = completed
        ? 1.0
        : min(max(Double(totalWritten) / Double(totalExpected), 0), 1)
    } else if completed {
      values["progress"] = 1.0
    }
    if let attempt = attemptGeneration(from: task) {
      values["attemptGeneration"] = attempt
    }
    if speed > 0 {
      values["speedBytesPerSecond"] = speed
    }

    NotificationCenter.default.post(
      name: Notification.Name("AnimeWitcherBackgroundDownloaderChunkUpdate"),
      object: nil,
      userInfo: values
    )

    // Dart owns the overlay while foreground. When it is suspended, keep the
    // same BGContinuedProcessingTask alive from URLSession's native bytes so
    // iOS sees real progress instead of an apparently stalled long task.
    if shouldUpdateNativeOverlay && !isAppInForeground() {
      upsertSessionOverlay(
        currentTaskId: presentation.currentTaskId,
        displayName: presentation.displayName,
        progress: presentation.progress,
        totalBytes: presentation.totalBytes,
        transferredBytes: presentation.transferredBytes,
        speedBytesPerSecond: presentation.speedBytesPerSecond
      )
    }
  }

  private static func rememberDownloadSession(_ session: URLSession) {
    lock.lock()
    latestDownloadSession = session
    lock.unlock()
  }

  static func acceptsDartOverlayUpdates() -> Bool {
    isAppInForeground()
  }

  static func promoteMultipartIfPossible(
    on suppliedSession: URLSession? = nil,
    parentId: String? = nil
  ) {
    guard !isAppInForeground() else { return }

    lock.lock()
    if let suppliedSession { latestDownloadSession = suppliedSession }
    let session = suppliedSession ?? latestDownloadSession
    let state = loadLocked()
    let plans = state.multipartPlans.filter { parentId == nil || $0.parentTaskId == parentId }
    lock.unlock()

    guard let session else { return }
    for plan in plans where !plan.waiters.isEmpty {
      promoteMultipartPlan(plan.parentTaskId, on: session)
    }
  }

  private static func promoteMultipartPlan(_ parentId: String, on session: URLSession) {
    lock.lock()
    if multipartPromotionParents.contains(parentId) {
      lock.unlock()
      return
    }
    multipartPromotionParents.insert(parentId)
    lock.unlock()

    session.getAllTasks { tasks in
      defer {
        lock.lock()
        multipartPromotionParents.remove(parentId)
        lock.unlock()
      }
      guard !isAppInForeground() else { return }

      let liveChildIds = Set(tasks.compactMap { task -> String? in
        guard task.state != .completed,
              isDownloadPart(task),
              parentTaskId(from: task) == parentId
        else { return nil }
        return taskId(from: task)
      })

      let selected: [Waiter]
      lock.lock()
      var state = loadLocked()
      guard let index = state.multipartPlans.firstIndex(where: { $0.parentTaskId == parentId }) else {
        lock.unlock()
        return
      }
      var plan = state.multipartPlans[index]
      plan.waiters.removeAll { liveChildIds.contains($0.taskId) }
      let available = max(min(plan.maxConcurrent, 16) - liveChildIds.count, 0)
      selected = Array(plan.waiters.prefix(available))
      if !selected.isEmpty {
        let selectedIds = Set(selected.map(\.taskId))
        plan.waiters.removeAll { selectedIds.contains($0.taskId) }
      }
      state.multipartPlans[index] = plan
      saveLocked(state)
      lock.unlock()

      for waiter in selected {
        startMultipartChild(waiter, on: session)
      }
    }
  }

  private static func startMultipartChild(_ waiter: Waiter, on session: URLSession) {
    guard waiter.savedProgress <= 0,
          waiter.resumeDataBase64?.isEmpty ?? true,
          let url = URL(string: waiter.url)
    else { return }
    var request = URLRequest(url: url)
    request.httpMethod = waiter.httpRequestMethod.isEmpty ? "GET" : waiter.httpRequestMethod
    for (key, value) in waiter.headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    if let post = postFromTaskJson(waiter.taskJson), !post.isEmpty {
      request.httpBody = post.data(using: .utf8)
    }
    let task = session.downloadTask(with: request)
    task.taskDescription = waiter.taskDescription
    task.priority = URLSessionTask.highPriority
    DownloadNativeDiagnosticLog.record("background.multipart.promote", task: task)
    task.resume()
  }

  static func handleBytesWritten(
    _ downloadTask: URLSessionDownloadTask,
    session: URLSession? = nil,
    totalWritten: Int64,
    totalExpected: Int64
  ) {
    if let session { rememberDownloadSession(session) }
    if isDownloadPart(downloadTask) {
      postMultipartChunkUpdate(
        downloadTask,
        totalWritten: totalWritten,
        totalExpected: totalExpected,
        completed: false
      )
      // Progress does not free a connection slot. Re-probing URLSession here
      // made every didWrite callback call getAllTasks while multiple ranges
      // were active. Initial background handoff and child completion are the
      // only ownership changes that can require a refill.
      return
    }
    guard let id = taskId(from: downloadTask) else { return }
    let json = downloadTask.taskDescription?
      .components(separatedBy: "***<<<|>>>***").first ?? ""
    let display = stringFromTaskJson(json, key: "displayName")
    let filename = stringFromTaskJson(json, key: "filename")
    let directory = stringFromTaskJson(json, key: "directory")
    let metaData = stringFromTaskJson(json, key: "metaData")
    let url = stringFromTaskJson(json, key: "url")
    let name = display.isEmpty ? (filename.isEmpty ? id : filename) : display
    let now = CFAbsoluteTimeGetCurrent()
    let logicalKey = episodeKey(
      taskId: id,
      trackingUrl: metaData,
      directory: directory,
      filename: filename,
      url: url
    )

    lock.lock()
    seenTransferringIds.insert(id)
    activeEpisodeKeysByTaskId[id] = logicalKey
    startingEpisodeKeys.remove(logicalKey)
    let speed = rollingSpeedLocked(
      windows: &taskSpeedWindows,
      taskId: id,
      totalWritten: totalWritten,
      now: now
    )
    var state = loadLocked()
    if !state.transferringTaskIds.contains(id) {
      state.transferringTaskIds.append(id)
    }
    var sample = state.runningSamples[id] ?? RunningSample(
      written: 0,
      expected: -1,
      speed: 0,
      displayName: ""
    )
    sample.written = totalWritten
    if totalExpected > 0 { sample.expected = totalExpected }
    sample.speed = speed
    if sample.displayName.isEmpty {
      sample.displayName = name
    }
    state.runningSamples[id] = sample
    let transferringSet = Set(state.transferringTaskIds)
    state.runningSamples = state.runningSamples.filter { transferringSet.contains($0.key) }
    let presentation = overlayPresentation(from: state, fallbackId: id, fallbackName: name)
    let stableExpected = sample.expected > 0 ? sample.expected : totalExpected
    let stableSpeed = sample.speed
    saveLocked(state)
    lock.unlock()
    scheduleNativeSpeedStaleReset(taskId: id, observedAt: now)

    let bridgedToDart = postSingleTaskUpdate(
      taskId: id,
      trackingUrl: metaData.isEmpty ? url : metaData,
      totalWritten: totalWritten,
      totalExpected: stableExpected,
      speedBytesPerSecond: stableSpeed,
      now: now
    )

    // While Flutter is foregrounded, Dart owns the single one-second sample
    // used by both the in-app card and the iOS task. Publishing native overlay
    // samples in parallel creates two clocks and visibly different speeds. In
    // background, Dart may be suspended, so native keeps the same task alive.
    if bridgedToDart && !isAppInForeground() {
      upsertSessionOverlay(
        currentTaskId: presentation.currentTaskId,
        displayName: presentation.displayName,
        progress: presentation.progress,
        totalBytes: presentation.totalBytes,
        transferredBytes: presentation.transferredBytes,
        speedBytesPerSecond: presentation.speedBytesPerSecond
      )
    }
  }


  /// Exact byte telemetry for ordinary URLSession downloads. The system
  /// notification already has these values; forwarding the same source of
  /// truth fixes Flutter's `-- / -- MB` when background_downloader reports an
  /// unknown expectedFileSize. Throttle transport events, while Dart owns the
  /// one-second UI cadence and the longer smoothing window.
  private static func postSingleTaskUpdate(
    taskId: String,
    trackingUrl: String,
    totalWritten: Int64,
    totalExpected: Int64,
    speedBytesPerSecond: Double,
    now: CFAbsoluteTime
  ) -> Bool {
    guard !taskId.isEmpty, !trackingUrl.isEmpty, totalWritten >= 0 else { return false }
    lock.lock()
    if let last = lastTaskBridgeTimes[taskId], now - last < taskBridgeInterval {
      lock.unlock()
      return false
    }
    lastTaskBridgeTimes[taskId] = now
    lock.unlock()

    var values: [String: Any] = [
      "taskId": taskId,
      "trackingUrl": trackingUrl,
      "writtenBytes": totalWritten,
    ]
    if totalExpected > 0 {
      values["expectedBytes"] = totalExpected
    }
    if speedBytesPerSecond > 0, speedBytesPerSecond.isFinite {
      values["speedBytesPerSecond"] = speedBytesPerSecond
    }
    NotificationCenter.default.post(
      name: Notification.Name("AnimeWitcherBackgroundDownloaderTaskUpdate"),
      object: nil,
      userInfo: values
    )
    return true
  }

  private static func startLiveActivity(
    taskId: String,
    displayName: String,
    progress: Double = 0,
    totalBytes: Int64 = -1,
    transferredBytes: Int64 = 0
  ) {
    lock.lock()
    let state = loadLocked()
    let presentation = overlayPresentation(
      from: state,
      fallbackId: taskId,
      fallbackName: displayName
    )
    let keepExisting = state.transferringTaskIds.count > 1
    lock.unlock()
    let initialProgress = progress > 0 ? progress : 0
    upsertSessionOverlay(
      currentTaskId: keepExisting ? presentation.currentTaskId : taskId,
      displayName: keepExisting && !presentation.displayName.isEmpty
        ? presentation.displayName
        : displayName,
      progress: keepExisting ? presentation.progress : initialProgress,
      totalBytes: keepExisting ? presentation.totalBytes : totalBytes,
      transferredBytes: keepExisting ? presentation.transferredBytes : transferredBytes,
      speedBytesPerSecond: keepExisting ? presentation.speedBytesPerSecond : 0
    )
  }

  private static func refreshSessionOverlay(success: Bool) {
    lock.lock()
    let state = loadLocked()
    let idle = state.sessionIsIdle
    let transferringCount = state.transferringTaskIds.count
    let presentation = overlayPresentation(
      from: state,
      fallbackId: state.sessionCurrentTaskId,
      fallbackName: state.sessionDisplayName
    )
    let nextWaiterId = state.waiters.first?.taskId
    let nextWaiterName = state.waiters.first?.displayName ?? state.sessionDisplayName
    let sessionCurrent = state.sessionCurrentTaskId
    let completed = state.sessionCompletedCount
    let batch = max(state.sessionBatchTotal, 1)
    lock.unlock()

    if idle {
      runOnMainActor {
        if #available(iOS 26.0, *) {
          DownloadContinuedProcessingManager.shared.finish(
            taskId: DownloadContinuedProcessingManager.sessionKey,
            success: success,
            status: success ? "completed" : "canceled",
            endSession: true
          )
        }
      }
      return
    }

    if transferringCount > 0 {
      upsertSessionOverlay(
        currentTaskId: presentation.currentTaskId,
        displayName: presentation.displayName,
        progress: presentation.progress,
        totalBytes: presentation.totalBytes,
        transferredBytes: presentation.transferredBytes,
        speedBytesPerSecond: presentation.speedBytesPerSecond,
        completedCount: completed,
        batchTotal: batch
      )
      return
    }

    upsertSessionOverlay(
      currentTaskId: nextWaiterId ?? sessionCurrent,
      displayName: nextWaiterName,
      progress: 0,
      totalBytes: -1,
      transferredBytes: 0,
      speedBytesPerSecond: 0,
      completedCount: completed,
      batchTotal: batch
    )
  }

  private static func upsertSessionOverlay(
    currentTaskId: String,
    displayName: String,
    progress: Double,
    totalBytes: Int64,
    transferredBytes: Int64,
    speedBytesPerSecond: Double,
    completedCount: Int? = nil,
    batchTotal: Int? = nil
  ) {
    lock.lock()
    var state = loadLocked()
    let switched = !currentTaskId.isEmpty
      && currentTaskId != state.sessionCurrentTaskId
      && currentTaskId != "session"
    let resetOnSwitch = switched && state.transferringTaskIds.count <= 1
    state.sessionCurrentTaskId = currentTaskId
    if !displayName.isEmpty {
      state.sessionDisplayName = displayName
    }
    if resetOnSwitch {
      state.sessionProgress = progress
      state.sessionTotalBytes = totalBytes > 0 ? totalBytes : -1
      state.sessionTransferredBytes = transferredBytes
      state.sessionSpeedBytesPerSecond = max(speedBytesPerSecond, 0)
    } else {
      state.sessionProgress = progress
      if totalBytes > 0 {
        state.sessionTotalBytes = totalBytes
      }
      state.sessionTransferredBytes = transferredBytes
      if speedBytesPerSecond >= 0 {
        state.sessionSpeedBytesPerSecond = max(speedBytesPerSecond, 0)
      }
    }
    if let completedCount {
      state.sessionCompletedCount = max(state.sessionCompletedCount, completedCount)
    }
    if let batchTotal {
      state.sessionBatchTotal = max(state.sessionBatchTotal, batchTotal)
    }
    state.sessionCurrentIndex = state.overlayCurrentIndex(runningTaskId: currentTaskId)
    let snapshot = state
    saveLocked(state)
    lock.unlock()

    runOnMainActor {
      if #available(iOS 26.0, *) {
        _ = try? DownloadContinuedProcessingManager.shared.start(
          taskId: currentTaskId,
          displayName: displayName.isEmpty ? snapshot.sessionDisplayName : displayName,
          progress: progress,
          totalBytes: totalBytes > 0 ? totalBytes : snapshot.sessionTotalBytes,
          transferredBytes: transferredBytes,
          completedCount: snapshot.sessionCompletedCount,
          batchTotal: max(snapshot.sessionBatchTotal, 1),
          speedBytesPerSecond: snapshot.sessionSpeedBytesPerSecond,
          currentIndex: snapshot.sessionCurrentIndex
        )
      }
    }
  }

  private static func loadLocked() -> State {
    guard let data = UserDefaults.standard.data(forKey: stateKey),
          let state = try? JSONDecoder().decode(State.self, from: data)
    else {
      return State(
        maxConcurrent: 1,
        transferringTaskIds: [],
        pausedTaskIds: [],
        waiters: [],
        completedTaskIds: []
      )
    }
    return state
  }

  private static func saveLocked(_ state: State) {
    if let data = try? JSONEncoder().encode(state) {
      UserDefaults.standard.set(data, forKey: stateKey)
    }
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  private static func clamp(_ value: Int) -> Int {
    min(max(value, 1), 5)
  }

  static func episodeKey(
    taskId: String,
    trackingUrl: String = "",
    directory: String = "",
    filename: String = "",
    url: String = ""
  ) -> String {
    let tracking = trackingUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = url.trimmingCharacters(in: .whitespacesAndNewlines)
    // startDownload uses the server URL as metaData when no separate episode
    // tracking URL exists. Do not let a server switch change episode identity.
    if !tracking.isEmpty && tracking != source { return "track:\(tracking)" }
    let file = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    if !file.isEmpty {
      let dir = directory.replacingOccurrences(of: "\\", with: "/")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return "file:\(dir)|\(file)"
    }
    if !source.isEmpty { return "url:\(source)" }
    if !tracking.isEmpty { return "url:\(tracking)" }
    return "id:\(taskId)"
  }

  static func episodeKey(for waiter: Waiter) -> String {
    episodeKey(
      taskId: waiter.taskId,
      trackingUrl: stringFromTaskJson(waiter.taskJson, key: "metaData"),
      directory: waiter.directory,
      filename: waiter.filename,
      url: waiter.url
    )
  }

  /// Logical identity read from the task that actually exists in URLSession.
  /// A plugin-created task is visible here even before it writes its first byte.
  static func episodeKey(from urlSessionTask: URLSessionTask) -> String? {
    guard let description = urlSessionTask.taskDescription, !description.isEmpty else {
      return nil
    }
    let json = description.components(separatedBy: "***<<<|>>>***").first ?? description
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    let taskId = object["taskId"] as? String ?? ""
    let trackingUrl = object["metaData"] as? String ?? ""
    let directory = object["directory"] as? String ?? ""
    let filename = object["filename"] as? String ?? ""
    let url = (object["url"] as? String)
      ?? urlSessionTask.originalRequest?.url?.absoluteString
      ?? ""
    return episodeKey(
      taskId: taskId,
      trackingUrl: trackingUrl,
      directory: directory,
      filename: filename,
      url: url
    )
  }

  /// Returns the taskId of an already-created native task for this episode.
  /// Suspended tasks count too: they are owned by the plugin/HoldingQueue and
  /// must not be duplicated by our background promoter.
  static func matchingLiveTaskId(
    for waiter: Waiter,
    among tasks: [URLSessionTask]
  ) -> String? {
    let key = episodeKey(for: waiter)
    for task in tasks {
      if task.state == .completed || task.state == .canceling { continue }
      guard episodeKey(from: task) == key else { continue }
      if let id = taskId(from: task), !id.isEmpty { return id }
      return waiter.taskId
    }
    return nil
  }

  static func isDownloadPart(_ task: URLSessionTask) -> Bool {
    let json = task.taskDescription?.components(separatedBy: "***<<<|>>>***").first ?? ""
    let group = stringFromTaskJson(json, key: "group")
    return group == "chunk" || group == "animewitcher_parts"
  }

  private static func urlFromTaskJson(_ taskJson: String) -> String {
    stringFromTaskJson(taskJson, key: "url")
  }

  private static func filenameFromTaskJson(_ taskJson: String) -> String {
    stringFromTaskJson(taskJson, key: "filename")
  }

  private static func postFromTaskJson(_ taskJson: String) -> String? {
    let value = stringFromTaskJson(taskJson, key: "post")
    return value.isEmpty ? nil : value
  }

  private static func stringFromTaskJson(_ taskJson: String, key: String) -> String {
    guard let data = taskJson.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let value = object[key] as? String
    else {
      return ""
    }
    return value
  }

  static func taskId(from urlSessionTask: URLSessionTask) -> String? {
    guard let description = urlSessionTask.taskDescription, !description.isEmpty else {
      return nil
    }
    let json = description.components(separatedBy: "***<<<|>>>***").first ?? description
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return object["taskId"] as? String
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let int = value as? Int { return int }
    return nil
  }

  private static func doubleValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    return nil
  }

  private static func int64Value(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let int = value as? Int { return Int64(int) }
    if let int64 = value as? Int64 { return int64 }
    return nil
  }

  private static func string(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    return nil
  }

  private static func stringArray(_ value: Any?) -> [String] {
    if let strings = value as? [String] { return strings }
    if let any = value as? [Any] { return any.compactMap { $0 as? String } }
    return []
  }

  private static func dictionaryArray(_ value: Any?) -> [[String: Any]] {
    if let typed = value as? [[String: Any]] { return typed }
    if let any = value as? [Any] { return any.compactMap { $0 as? [String: Any] } }
    return []
  }

  private static func stringMap(_ value: Any?) -> [String: String] {
    if let typed = value as? [String: String] { return typed }
    guard let any = value as? [String: Any] else { return [:] }
    var headers: [String: String] = [:]
    for (key, nested) in any {
      if let string = nested as? String {
        headers[key] = string
      } else {
        headers[key] = String(describing: nested)
      }
    }
    return headers
  }
}

/// Swizzles the plugin `UrlSessionDelegate` so promotion runs in the native
/// completion callback. Flutter method channels are never used to start files.
///
/// Uses IMP replacement (not Swift `self.hooked()` after `method_exchange`),
/// because a Swift call to the hooked method is a direct recursive call and
/// never hits the original ObjC IMP.
private enum DownloadUrlSessionHook {
  private static let completeSelector = NSSelectorFromString(
    "URLSession:task:didCompleteWithError:"
  )
  private static let finishDownloadSelector = NSSelectorFromString(
    "URLSession:downloadTask:didFinishDownloadingToURL:"
  )
  private static let finishEventsSelector = NSSelectorFromString(
    "URLSessionDidFinishEventsForBackgroundURLSession:"
  )
  private static let writeSelector = NSSelectorFromString(
    "URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:"
  )

  private static var originalComplete: IMP?
  private static var originalFinishDownload: IMP?
  private static var originalFinishEvents: IMP?
  private static var originalWrite: IMP?

  static func install() -> Bool {
    #if canImport(background_downloader)
    let delegateClass: AnyClass = UrlSessionDelegate.self
    #else
    guard let delegateClass = findUrlSessionDelegateClass() else {
      NSLog("[DownloadNativeWaitingQueue] UrlSessionDelegate class not found")
      return false
    }
    #endif
    hookComplete(on: delegateClass)
    hookFinishDownload(on: delegateClass)
    hookFinishEvents(on: delegateClass)
    hookWrite(on: delegateClass)
    let hooked = originalComplete != nil || originalFinishDownload != nil || originalFinishEvents != nil || originalWrite != nil
    if hooked {
      NSLog("[DownloadNativeWaitingQueue] hooked UrlSessionDelegate %@", String(cString: class_getName(delegateClass)))
    } else {
      NSLog(
        "[DownloadNativeWaitingQueue] ERROR: no NSURLSession delegate selectors were hooked on %@",
        String(cString: class_getName(delegateClass))
      )
    }
    return hooked
  }

  private static func findUrlSessionDelegateClass() -> AnyClass? {
    let names = [
      "background_downloader.UrlSessionDelegate",
      "UrlSessionDelegate",
      "_TtC22background_downloader18UrlSessionDelegate",
    ]
    for name in names {
      if let cls = NSClassFromString(name) {
        return cls
      }
    }
    return nil
  }

  private static func hookComplete(on cls: AnyClass) {
    guard let method = class_getInstanceMethod(cls, completeSelector) else { return }
    originalComplete = method_getImplementation(method)
    let block: @convention(block) (AnyObject, URLSession, URLSessionTask, Error?) -> Void = { slf, session, task, error in
      DownloadNativeDiagnosticLog.record("complete", task: task, error: error)
      if let error, DownloadNativeWaitingQueue.retryBackgroundTransferIfNeeded(
        session: session,
        task: task,
        error: error
      ) {
        return
      }

      // Non-transient/exhausted failures and normal success still belong to
      // background_downloader. Only those reach the original callback.
      if let original = DownloadUrlSessionHook.originalComplete {
        let fn = unsafeBitCast(
          original,
          to: (@convention(c) (AnyObject, Selector, URLSession, URLSessionTask, Error?) -> Void).self
        )
        fn(slf, completeSelector, session, task, error)
      }
      // A successful URLSessionDownloadTask already went through
      // didFinishDownloadingTo, where the plugin moved the file and we mark
      // the logical episode complete. Do not process success twice.
      guard error != nil else { return }
      DownloadNativeWaitingQueue.handlePluginTaskCompleted(
        session: session,
        task: task,
        error: error
      )
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func hookFinishDownload(on cls: AnyClass) {
    guard let method = class_getInstanceMethod(cls, finishDownloadSelector) else { return }
    originalFinishDownload = method_getImplementation(method)
    let block: @convention(block) (AnyObject, URLSession, URLSessionDownloadTask, URL) -> Void = { slf, session, downloadTask, location in
      DownloadNativeDiagnosticLog.record("file.received", task: downloadTask)
      DownloadNativeWaitingQueue.clearBackgroundRetry(downloadTask)
      // Original must run first so the plugin can move the temp file.
      // Then promote like pre-tabs: ep2 must start before the session sleeps.
      if let original = DownloadUrlSessionHook.originalFinishDownload {
        let fn = unsafeBitCast(
          original,
          to: (@convention(c) (AnyObject, Selector, URLSession, URLSessionDownloadTask, URL) -> Void).self
        )
        fn(slf, finishDownloadSelector, session, downloadTask, location)
      }
      // Same as before the Downloads tabs split: promote the next waiter
      // from this callback so ep2 starts before the session goes to sleep.
      DownloadNativeWaitingQueue.handlePluginTaskCompleted(
        session: session,
        task: downloadTask,
        error: nil
      )
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func hookWrite(on cls: AnyClass) {
    guard let method = class_getInstanceMethod(cls, writeSelector) else { return }
    originalWrite = method_getImplementation(method)
    let block: @convention(block) (
      AnyObject, URLSession, URLSessionDownloadTask, Int64, Int64, Int64
    ) -> Void = { slf, session, downloadTask, bytesWritten, totalWritten, totalExpected in
      DownloadNativeDiagnosticLog.record("progress", task: downloadTask)
      if let original = DownloadUrlSessionHook.originalWrite {
        let fn = unsafeBitCast(
          original,
          to: (@convention(c) (
            AnyObject, Selector, URLSession, URLSessionDownloadTask, Int64, Int64, Int64
          ) -> Void).self
        )
        fn(slf, writeSelector, session, downloadTask, bytesWritten, totalWritten, totalExpected)
      }
      DownloadNativeWaitingQueue.noteBackgroundRetryProgress(downloadTask)
      DownloadNativeWaitingQueue.handleBytesWritten(
        downloadTask,
        session: session,
        totalWritten: totalWritten,
        totalExpected: totalExpected
      )
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func hookFinishEvents(on cls: AnyClass) {
    guard let method = class_getInstanceMethod(cls, finishEventsSelector) else { return }
    originalFinishEvents = method_getImplementation(method)
    let block: @convention(block) (AnyObject, URLSession) -> Void = { slf, session in
      DownloadNativeWaitingQueue.promoteNext(on: session)
      if let original = DownloadUrlSessionHook.originalFinishEvents {
        let fn = unsafeBitCast(
          original,
          to: (@convention(c) (AnyObject, Selector, URLSession) -> Void).self
        )
        fn(slf, finishEventsSelector, session)
      }
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }
}
#endif
