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
      appendLocked(row, event: event)
    }
  }

  /// Lifecycle diagnostics use a closed field vocabulary. Never persist URLs,
  /// credentials, display names or arbitrary error descriptions from callers.
  static func record(_ event: String, fields: [String: Any] = [:]) {
    queue.sync {
      guard enabled else { return }
      let allowed: Set<String> = ["taskId", "parentTaskId", "leaseIdentifier",
        "requestAgeMillis", "leaseAgeMillis", "elapsedMillis", "progress",
        "transferredBytes", "totalBytes", "completedCount", "batchTotal",
        "activeLease", "success", "status", "failure", "errorCode", "errorKind",
        "completedUnits", "totalUnits", "attemptGeneration", "nativeTaskId"]
      sequence += 1
      var row = fields.filter { allowed.contains($0.key) }
      row["time"] = ISO8601DateFormatter().string(from: Date())
      row["session"] = session
      row["sequence"] = sequence
      row["source"] = "ios"
      row["event"] = event
      appendLocked(row, event: event)
    }
  }

  private static func appendLocked(_ row: [String: Any], event: String) {
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
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
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

import ObjectiveC
import UIKit
import CryptoKit
import Security
#if canImport(background_downloader)
import background_downloader
#endif

/// Failed plugin channel messages omit headers. Save the small allowlisted
/// response before that message can reach Dart, including across app relaunch.
enum DownloadNativeRetryMetadata {
  private static let lock = NSLock()
  private static let key = "com.animewitcher.download.retryMetadata.v1"

  static func record(identity: DownloadRangeIdentity, httpStatus: Int?, headers: [String: String]?) {
    guard let httpStatus, (100...599).contains(httpStatus) else { return }
    lock.lock()
    defer { lock.unlock() }
    var rows = UserDefaults.standard.dictionary(forKey: key) ?? [:]
    if let existing = rows[identity.taskId] as? [String: Any],
       let generation = DownloadRangeIdentity.positiveInteger(existing["attemptGeneration"]),
       generation > identity.generation { return }
    var row: [String: Any] = ["taskId": identity.taskId,
      "parentTaskId": identity.parentTaskId, "attemptGeneration": identity.generation,
      "httpStatus": httpStatus]
    if let retryAfter = headers?.first(where: { $0.key.lowercased() == "retry-after" })?.value {
      row["retryAfter"] = retryAfter
    }
    if let date = headers?.first(where: { $0.key.lowercased() == "date" })?.value {
      row["responseDate"] = date
    }
    rows[identity.taskId] = row
    UserDefaults.standard.set(rows, forKey: key)
  }

  static func lookup(_ arguments: [String: Any]) -> [String: Any]? {
    guard let taskId = arguments["taskId"] as? String,
          let parent = arguments["parentTaskId"] as? String,
          let generation = DownloadRangeIdentity.positiveInteger(arguments["attemptGeneration"]),
          DownloadRangeIdentity(taskId: taskId, parentTaskId: parent, generation: generation) != nil
    else { return nil }
    lock.lock()
    defer { lock.unlock() }
    guard let row = UserDefaults.standard.dictionary(forKey: key)?[taskId] as? [String: Any],
          row["taskId"] as? String == taskId,
          row["parentTaskId"] as? String == parent,
          DownloadRangeIdentity.positiveInteger(row["attemptGeneration"]) == generation
    else { return nil }
    return row
  }

  static func remove(identity: DownloadRangeIdentity) {
    lock.lock()
    defer { lock.unlock() }
    var rows = UserDefaults.standard.dictionary(forKey: key) ?? [:]
    guard let row = rows[identity.taskId] as? [String: Any],
          row["parentTaskId"] as? String == identity.parentTaskId,
          DownloadRangeIdentity.positiveInteger(row["attemptGeneration"]) == identity.generation
    else { return }
    rows.removeValue(forKey: identity.taskId)
    UserDefaults.standard.set(rows, forKey: key)
  }

  static func removeParent(_ parentTaskId: String) {
    lock.lock()
    defer { lock.unlock() }
    let rows = UserDefaults.standard.dictionary(forKey: key) ?? [:]
    UserDefaults.standard.set(rows.filter {
      ($0.value as? [String: Any])?["parentTaskId"] as? String != parentTaskId
    }, forKey: key)
  }
}

/// Keep the large queue in the existing batched defaults store, encrypted as a
/// whole: task JSON and resume blobs can also contain URLs and credentials.
/// Only the small encryption key goes into Keychain, never on every byte sample.
private enum DownloadNativeQueueEncryption {
  // All callers hold DownloadNativeWaitingQueue.lock.
  private static var cachedKey: SymmetricKey?
  private(set) static var keyMissing = false
  private static let service = "com.animewitcher.download.nativeQueueEncryption"

  private static func key(createIfMissing: Bool) -> SymmetricKey? {
    if let cachedKey { return cachedKey }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "queue-v2",
    ]
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    keyMissing = status == errSecItemNotFound
    if status == errSecSuccess, let data = item as? Data, data.count == 32 {
      let key = SymmetricKey(data: data)
      cachedKey = key
      return key
    }
    guard status == errSecItemNotFound, createIfMissing else {
      NSLog("[DownloadNativeWaitingQueue] encryption key unavailable (%d)", status)
      return nil
    }
    let key = SymmetricKey(size: .bits256)
    var insert = query
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    insert[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
    let inserted = SecItemAdd(insert as CFDictionary, nil)
    guard inserted == errSecSuccess else {
      NSLog("[DownloadNativeWaitingQueue] encryption key creation failed (%d)", inserted)
      return nil
    }
    cachedKey = key
    keyMissing = false
    return key
  }

  static func decrypt(_ data: Data) -> Data? {
    guard let key = key(createIfMissing: false),
          let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
    return try? AES.GCM.open(box, using: key)
  }

  static func encrypt(_ data: Data) -> Data? {
    guard let key = key(createIfMissing: true) else { return nil }
    return try? AES.GCM.seal(data, using: key).combined
  }
}

/// Full waiter payloads so Swift can start the next URLSession download when
/// ep1 completes — without Flutter, and without reconstructing the task in Dart.
/// Flutter method channels are a no-op while the engine is asleep, so this
/// store holds url/headers/filename/directory/task JSON for the plugin session.
enum DownloadNativeWaitingQueue {
  static let stateKey = "com.animewitcher.download.nativeWaitingQueue.v2"
  private static let encryptedStateKey = stateKey + ".encrypted"
  // A locked/corrupt store must never be overwritten by an empty native load.
  private static var stateReadFailed = false
  // A failed encrypted write must not let a later snapshot reoffer these bytes.
  private static var pendingRangeCompletions: [String: Int] = [:]

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
    var generation: Int?
    var claimId: String?
    var claimLeaseMillis: Int?

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
        expectedBytes: int64Value(arguments["expectedBytes"]),
        generation: intValue(arguments["generation"]),
        claimId: string(arguments["claimId"]),
        claimLeaseMillis: intValue(arguments["claimLeaseMillis"])
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

  struct MultipartClaim: Codable, Equatable, Sendable {
    var parentTaskId: String
    var maxConcurrent: Int
    var waiter: Waiter
    var generation: Int
    var claimId: String
    var expiresAtMillis: Int64
    var launchCommitted: Bool
    var launchCommittedAtMillis: Int64?
  }

  struct RunningSample: Codable, Equatable {
    var written: Int64
    var expected: Int64
    var speed: Double
    var displayName: String
  }

  struct State: Codable {
    var snapshotVersion: Int
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
    var sessionCompletedPages: Int?
    var sessionTotalPages: Int?
    var sessionSpeedBytesPerSecond: Double
    var sessionCurrentIndex: Int
    var runningSamples: [String: RunningSample]
    var multipartPlans: [MultipartPlan]
    var multipartClaims: [MultipartClaim]
    var dartRangeGenerations: [String: Int]
    var completedRangeGenerations: [String: Int]
    var rangeParentWithdrawnAtMicros: [String: Int64]

    init(
      snapshotVersion: Int = 0,
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
      sessionCompletedPages: Int? = nil,
      sessionTotalPages: Int? = nil,
      sessionSpeedBytesPerSecond: Double = 0,
      sessionCurrentIndex: Int = 0,
      runningSamples: [String: RunningSample] = [:],
      multipartPlans: [MultipartPlan] = [],
      multipartClaims: [MultipartClaim] = [],
      dartRangeGenerations: [String: Int] = [:],
      completedRangeGenerations: [String: Int] = [:],
      rangeParentWithdrawnAtMicros: [String: Int64] = [:]
    ) {
      self.snapshotVersion = snapshotVersion
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
      self.sessionCompletedPages = sessionCompletedPages
      self.sessionTotalPages = sessionTotalPages
      self.sessionSpeedBytesPerSecond = sessionSpeedBytesPerSecond
      self.sessionCurrentIndex = sessionCurrentIndex
      self.runningSamples = runningSamples
      self.multipartPlans = multipartPlans
      self.multipartClaims = multipartClaims
      self.dartRangeGenerations = dartRangeGenerations
      self.completedRangeGenerations = completedRangeGenerations
      self.rangeParentWithdrawnAtMicros = rangeParentWithdrawnAtMicros
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      snapshotVersion = try container.decodeIfPresent(Int.self, forKey: .snapshotVersion) ?? 0
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
      sessionCompletedPages = try container.decodeIfPresent(Int.self, forKey: .sessionCompletedPages)
      sessionTotalPages = try container.decodeIfPresent(Int.self, forKey: .sessionTotalPages)
      sessionSpeedBytesPerSecond = try container.decodeIfPresent(Double.self, forKey: .sessionSpeedBytesPerSecond) ?? 0
      sessionCurrentIndex = try container.decodeIfPresent(Int.self, forKey: .sessionCurrentIndex) ?? 0
      runningSamples = try container.decodeIfPresent([String: RunningSample].self, forKey: .runningSamples) ?? [:]
      multipartPlans = try container.decodeIfPresent([MultipartPlan].self, forKey: .multipartPlans) ?? []
      multipartClaims = try container.decodeIfPresent([MultipartClaim].self, forKey: .multipartClaims) ?? []
      dartRangeGenerations = try container.decodeIfPresent([String: Int].self, forKey: .dartRangeGenerations) ?? [:]
      completedRangeGenerations = try container.decodeIfPresent([String: Int].self, forKey: .completedRangeGenerations) ?? [:]
      rangeParentWithdrawnAtMicros = try container.decodeIfPresent([String: Int64].self, forKey: .rangeParentWithdrawnAtMicros) ?? [:]
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
  // Whole-episode scheduling/retry/completion stays with background_downloader.
  private static let legacyTransportOwnershipEnabled = false

  static var nativePromotionAvailable: Bool {
    lock.lock()
    defer { lock.unlock() }
    return hookInstalled
  }
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
  static let terminalObservation = DownloadTerminalObservation()
  private static var multipartChildSamples: [String: [String: RunningSample]] = [:]
  private static var lastMultipartOverlayTimes: [String: CFAbsoluteTime] = [:]
  private static var v2ParallelChildSamples: [String: [String: RunningSample]] = [:]
  private static var lastV2ParallelOverlayTimes: [String: CFAbsoluteTime] = [:]
  private static var latestDownloadSession: URLSession?
  private static var multipartPromotionParents = Set<String>()
  private static var multipartPromotionPendingParents = Set<String>()
  private static var multipartPromotionCompletions: [String: [() -> Void]] = [:]
  private static var nativeMultipartTasksByClaimId: [String: URLSessionTask] = [:]
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
    #if canImport(background_downloader)
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
    #endif
    hookInstalled = DownloadUrlSessionHook.install()
  }

  /// Dart persist is source of truth for waiters / paused / newly enqueued
  /// transfers, except: waiters already started natively stay transferring, and
  /// tasks native already completed cannot occupy a slot again.
  @discardableResult
  static func persist(from arguments: [String: Any]) -> Int {
    lock.lock()
    defer { lock.unlock() }
    var current = loadLocked()
    // A device-only key intentionally cannot migrate to a new device. Only a
    // fresh authoritative Dart snapshot may replace such restored ciphertext;
    // native callbacks cannot treat unreadable storage as an empty queue.
    if stateReadFailed && !DownloadNativeQueueEncryption.keyMissing { return -1 }
    stateReadFailed = false
    requeueExpiredMultipartClaimsLocked(&current)
    let snapshotVersion = intValue(arguments["snapshotVersion"])
    if let snapshotVersion, snapshotVersion < current.snapshotVersion {
      return current.snapshotVersion
    }
    if let snapshotVersion, snapshotVersion == current.snapshotVersion {
      return current.snapshotVersion
    }
    // Callers without an explicit version receive a native-allocated next version.
    // always supplies its own monotonic version and receives it back as ack.
    let acceptedVersion = snapshotVersion ?? (current.snapshotVersion + 1)
    let maxConcurrent = clamp(intValue(arguments["maxConcurrent"]) ?? 1)
    let dartTransferring = stringArray(arguments["transferringTaskIds"])
    let dartPaused = stringArray(arguments["pausedTaskIds"])
    let dartWaiters = dictionaryArray(arguments["waiters"]).compactMap(Waiter.from(arguments:))
    let dartSessionIds = stringArray(arguments["sessionTaskIds"])
    let dartCompletedCount = intValue(arguments["sessionCompletedCount"]) ?? 0
    let dartBatchTotal = intValue(arguments["sessionBatchTotal"]) ?? 0
    var dartMultipartPlans = dictionaryArray(arguments["multipartPlans"])
      .compactMap(MultipartPlan.from(arguments:))
    // A fresh Dart snapshot withdraws permission immediately on pause/cancel,
    // parent removal or a generation change. In-flight async scans must recheck
    // this authoritative plan again at the exact native commit boundary.
    let activeParents = Set(dartTransferring).subtracting(dartPaused)
    let snapshotCreatedAt = DownloadRangeIdentity.positiveInteger(arguments["snapshotCreatedAtMicros"]).map(Int64.init) ?? 0
    var withdrawnParents = current.rangeParentWithdrawnAtMicros
    dartMultipartPlans = dartMultipartPlans.filter {
      activeParents.contains($0.parentTaskId)
        && snapshotCreatedAt > (withdrawnParents[$0.parentTaskId] ?? -1)
    }
    // Platform-channel writes from another Dart async flow can arrive after
    // claimRangeForDart. Generation tombstones reject that stale same offer,
    // even when its enclosing snapshot has a newer delivery/version number.
    var dartGenerations = current.dartRangeGenerations
    for plan in dartMultipartPlans {
      for waiter in plan.waiters {
        if let identity = rangeIdentity(for: waiter),
           let reserved = dartGenerations[identity.taskId], identity.generation > reserved {
          dartGenerations[identity.taskId] = nil
        }
      }
    }
    for index in dartMultipartPlans.indices {
      let parent = dartMultipartPlans[index].parentTaskId
      dartMultipartPlans[index].waiters.removeAll {
        rangeIdentity(for: $0)?.parentTaskId != parent || !isImmutableRangeWaiter($0)
          || ($0.generation ?? 0) <= (dartGenerations[$0.taskId] ?? 0)
          || ($0.generation ?? 0) <= (current.completedRangeGenerations[$0.taskId] ?? 0)
      }
    }
    let plannedParents = Set(dartMultipartPlans.map(\.parentTaskId))
    current.multipartClaims.removeAll { claim in
      guard activeParents.contains(claim.parentTaskId),
            plannedParents.contains(claim.parentTaskId) else { return true }
      // A newer offer invalidates an older pending claim, without disturbing a
      // committed execution that still owns the same on-disk range path.
      return !claim.launchCommitted && dartMultipartPlans.contains { plan in
        plan.parentTaskId == claim.parentTaskId && plan.waiters.contains {
          $0.taskId == claim.waiter.taskId && ($0.generation ?? 0) > claim.generation
        }
      }
    }
    let claimedChildIds = Set(current.multipartClaims.map { $0.waiter.taskId })
    if !claimedChildIds.isEmpty {
      for index in dartMultipartPlans.indices {
        dartMultipartPlans[index].waiters.removeAll {
          claimedChildIds.contains($0.taskId)
        }
      }
    }
    // Bound control metadata to outstanding/paused parents. A fresh terminal
    // snapshot can prune it: its accepted monotonic version fences every older
    // in-flight payload, and Dart never retries stale data under a new version.
    // A snapshot predating withdrawal cannot prune that parent's cutoff.
    let knownParents = Set(dartTransferring + dartPaused + dartSessionIds)
    dartGenerations = dartGenerations.filter { childId, _ in
      guard let parent = rangeParentId(fromChildId: childId) else { return false }
      return knownParents.contains(parent) || snapshotCreatedAt <= (withdrawnParents[parent] ?? -1)
    }
    let completedRangeGenerations = current.completedRangeGenerations.filter { childId, _ in
      guard let parent = rangeParentId(fromChildId: childId) else { return false }
      return knownParents.contains(parent) || snapshotCreatedAt <= (withdrawnParents[parent] ?? -1)
    }
    withdrawnParents = withdrawnParents.filter {
      knownParents.contains($0.key) || snapshotCreatedAt <= $0.value
    }
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

    let saved = saveLocked(
      State(
        snapshotVersion: acceptedVersion,
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
          if switchedFile || arguments["sessionCompletedPages"] != nil { return (arguments["sessionProgress"] as? NSNumber)?.doubleValue ?? 0 }
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
        sessionCompletedPages: intValue(arguments["sessionCompletedPages"]),
        sessionTotalPages: intValue(arguments["sessionTotalPages"]),
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
        multipartPlans: dartMultipartPlans,
        multipartClaims: current.multipartClaims,
        dartRangeGenerations: dartGenerations,
        completedRangeGenerations: completedRangeGenerations,
        rangeParentWithdrawnAtMicros: withdrawnParents
      )
    )
    return saved ? acceptedVersion : -1
  }

  static func load() -> State {
    lock.lock()
    defer { lock.unlock() }
    return loadLocked()
  }

  static func resetForTests() {
    lock.lock()
    defer { lock.unlock() }
    pendingRangeCompletions.removeAll()
    UserDefaults.standard.removeObject(forKey: stateKey)
    UserDefaults.standard.removeObject(forKey: encryptedStateKey)
    stateReadFailed = false
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
    multipartPromotionPendingParents.removeAll()
    multipartPromotionCompletions.removeAll()
    nativeMultipartTasksByClaimId.removeAll()
  }

  private static func nowMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
  }

  private static func nowMicros() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000_000)
  }

  private static func rangeParentId(fromChildId childId: String) -> String? {
    guard let range = childId.range(of: ".part.", options: .backwards) else { return nil }
    return String(childId[..<range.lowerBound])
  }

  private static func rangeIdentity(for waiter: Waiter) -> DownloadRangeIdentity? {
    guard let identity = DownloadRangeIdentity.from(taskJson: waiter.taskJson),
          identity.taskId == waiter.taskId, identity.generation == waiter.generation,
          waiter.group == "animewitcher_parts" else { return nil }
    return identity
  }

  private static func rangeIdentity(for task: URLSessionTask) -> DownloadRangeIdentity? {
    guard let json = task.taskDescription?.components(separatedBy: "***<<<|>>>***").first
    else { return nil }
    return DownloadRangeIdentity.from(taskJson: json)
  }

  private static func isImmutableRangeWaiter(_ waiter: Waiter) -> Bool {
    guard let identity = rangeIdentity(for: waiter), waiter.savedProgress == 0,
          DownloadNativeRetryMetadata.lookup([
            "taskId": identity.taskId, "parentTaskId": identity.parentTaskId,
            "attemptGeneration": identity.generation
          ]) == nil,
          waiter.resumeDataBase64?.isEmpty ?? true,
          waiter.httpRequestMethod.uppercased() == "GET",
          let url = URL(string: waiter.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let data = waiter.taskJson.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["url"] as? String == waiter.url,
          json["filename"] as? String == waiter.filename,
          json["directory"] as? String == waiter.directory,
          (json["httpRequestMethod"] as? String ?? "GET").uppercased() == "GET",
          (json["post"] as? String ?? "").isEmpty,
          let jsonHeaders = json["headers"] as? [String: String], jsonHeaders == waiter.headers,
          let rawMetadata = json["metaData"] as? String,
          let metadataData = rawMetadata.data(using: .utf8),
          let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
          metadata["sourceValidationRequired"] as? Bool != true,
          let range = waiter.headers.first(where: { $0.key.caseInsensitiveCompare("Range") == .orderedSame })?.value,
          range.range(of: #"^bytes=[0-9]+-[0-9]+$"#, options: .regularExpression) != nil
    else { return false }
    let bounds = range.dropFirst(6).split(separator: "-")
    guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
          start >= 0, end >= start, end < Int64.max,
          waiter.savedExpectedBytes == end - start + 1 else { return false }
    return true
  }

  private static func parentMayRefillLocked(_ parentId: String, in state: State) -> Bool {
    state.transferringTaskIds.contains(parentId) && !state.pausedTaskIds.contains(parentId)
      && !state.completedTaskIds.contains(parentId)
      && state.multipartPlans.contains { $0.parentTaskId == parentId }
  }

  private static func requeueExpiredMultipartClaimsLocked(_ state: inout State) {
    // A slow live URLSession writer never loses ownership just because a lease
    // elapsed. Only uncommitted offers can expire without live-task evidence.
    let expired = state.multipartClaims.filter { !$0.launchCommitted && $0.expiresAtMillis <= nowMillis() }
    guard !expired.isEmpty else { return }
    for claim in expired where parentMayRefillLocked(claim.parentTaskId, in: state) {
      if let index = state.multipartPlans.firstIndex(where: { $0.parentTaskId == claim.parentTaskId }),
         !state.multipartPlans[index].waiters.contains(where: { $0.taskId == claim.waiter.taskId }) {
        state.multipartPlans[index].waiters.insert(claim.waiter, at: 0)
      }
    }
    let expiredIds = Set(expired.map { $0.claimId })
    state.multipartClaims.removeAll { expiredIds.contains($0.claimId) }
  }

  private static func releaseMultipartClaim(_ waiter: Waiter, requeue: Bool) {
    lock.lock()
    defer { lock.unlock() }
    var state = loadLocked()
    guard !stateReadFailed, let identity = rangeIdentity(for: waiter), let claimId = waiter.claimId,
          let index = state.multipartClaims.firstIndex(where: {
            $0.claimId == claimId && $0.waiter.taskId == identity.taskId
              && $0.parentTaskId == identity.parentTaskId && $0.generation == identity.generation
          }) else { return }
    let claim = state.multipartClaims.remove(at: index)
    nativeMultipartTasksByClaimId[claim.claimId] = nil
    if requeue, parentMayRefillLocked(claim.parentTaskId, in: state),
       let planIndex = state.multipartPlans.firstIndex(where: { $0.parentTaskId == claim.parentTaskId }),
       !state.multipartPlans[planIndex].waiters.contains(where: { $0.taskId == waiter.taskId }) {
      state.multipartPlans[planIndex].waiters.insert(waiter, at: 0)
    }
    saveLocked(state)
  }

  private static func commitMultipartClaimBeforeResume(
    _ waiter: Waiter, on session: URLSession, request: URLRequest
  ) -> URLSessionDownloadTask? {
    guard let claimId = waiter.claimId, let identity = rangeIdentity(for: waiter),
          isImmutableRangeWaiter(waiter) else { return nil }
    lock.lock()
    defer { lock.unlock() }
    var state = loadLocked()
    guard !stateReadFailed, !isAppInForeground(),
          parentMayRefillLocked(identity.parentTaskId, in: state),
          identity.generation > (state.dartRangeGenerations[identity.taskId] ?? 0),
          identity.generation > (state.completedRangeGenerations[identity.taskId] ?? 0),
          let index = state.multipartClaims.firstIndex(where: {
            $0.claimId == claimId && $0.waiter.taskId == identity.taskId
              && $0.parentTaskId == identity.parentTaskId && $0.generation == identity.generation
              && !$0.launchCommitted && $0.expiresAtMillis > nowMillis()
          }) else { return nil }
    state.multipartClaims[index].launchCommitted = true
    state.multipartClaims[index].launchCommittedAtMillis = nowMillis()
    guard saveLocked(state) else { return nil }
    // Resume is inside the same lock as Dart revocation and pause snapshots.
    // The concrete task also fences a stale allTasks observation from Dart.
    let task = session.downloadTask(with: request)
    task.taskDescription = waiter.taskDescription
    task.priority = URLSessionTask.highPriority
    nativeMultipartTasksByClaimId[claimId] = task
    task.resume()
    return task
  }

  /// The caller has queried package allTasks before asking. Revoke the offer
  /// and pending claim atomically, or refuse while a native execution owns it.
  /// Dart marks launched synchronously before awaiting this handshake. A
  /// generation tombstone also fences snapshots already in flight.
  static func claimRangeForDart(from arguments: [String: Any]) -> Bool {
    guard let taskId = arguments["taskId"] as? String,
          let parentId = arguments["parentTaskId"] as? String,
          let generation = DownloadRangeIdentity.positiveInteger(arguments["attemptGeneration"]),
          let requested = DownloadRangeIdentity(taskId: taskId, parentTaskId: parentId, generation: generation)
    else { return false }
    lock.lock()
    defer { lock.unlock() }
    var state = loadLocked()
    guard !stateReadFailed else { return false }
    // Ownership survives even a plan withdrawal while its task is canceling.
    if nativeMultipartTasksByClaimId.values.contains(where: {
      guard let owner = rangeIdentity(for: $0) else { return false }
      return owner.taskId == taskId && owner.parentTaskId == parentId
        && $0.state != .completed && !DownloadUrlSessionHook.callbacks(for: $0).hasSettledCompletion
    }) { return false }
    guard generation >= (state.dartRangeGenerations[taskId] ?? 0),
          generation > (state.completedRangeGenerations[taskId] ?? 0) else { return false }
    let claims = state.multipartClaims.filter { $0.waiter.taskId == taskId }
    for claim in claims {
      guard let owner = rangeIdentity(for: claim.waiter), requested.canRevoke(owner) else { return false }
      if claim.launchCommitted {
        guard arguments["nativeOwnerAbsent"] as? Bool == true,
              let observed = DownloadRangeIdentity.positiveInteger(arguments["observedAtMillis"]),
              Int64(observed) >= (claim.launchCommittedAtMillis ?? 0) else { return false }
      }
    }
    for plan in state.multipartPlans {
      for waiter in plan.waiters where waiter.taskId == taskId {
        guard let offer = rangeIdentity(for: waiter), requested.canRevoke(offer) else { return false }
      }
    }
    state.dartRangeGenerations[taskId] = generation
    state.multipartClaims.removeAll { $0.waiter.taskId == taskId }
    for index in state.multipartPlans.indices {
      state.multipartPlans[index].waiters.removeAll { $0.taskId == taskId }
    }
    return saveLocked(state)
  }

  /// Pause/cancel withdraws future launch permission before Dart awaits child
  /// reconciliation. Existing immutable writers may drain; native never retries
  /// them or creates another range after this transaction wins the lock.
  static func withdrawRangeParent(from arguments: [String: Any]) -> Bool {
    guard let parentId = arguments["parentTaskId"] as? String,
          DownloadRangeIdentity(taskId: parentId + ".part.0", parentTaskId: parentId, generation: 1) != nil
    else { return false }
    lock.lock()
    defer { lock.unlock() }
    var state = loadLocked()
    guard !stateReadFailed else { return false }
    state.rangeParentWithdrawnAtMicros[parentId] = nowMicros()
    state.multipartPlans.removeAll { $0.parentTaskId == parentId }
    state.multipartClaims.removeAll { $0.parentTaskId == parentId && !$0.launchCommitted }
    if !state.pausedTaskIds.contains(parentId) { state.pausedTaskIds.append(parentId) }
    return saveLocked(state)
  }

  /// Only the plugin's synchronous successful file-receipt status proves this
  /// execution wrote its destination. A nil transport error is not that proof.
  static func recordCompletedRange(task: URLSessionTask, succeeded: Bool?) {
    guard succeeded == true, let identity = rangeIdentity(for: task) else { return }
    lock.lock()
    defer { lock.unlock() }
    pendingRangeCompletions[identity.taskId] = max(
      pendingRangeCompletions[identity.taskId] ?? 0, identity.generation
    )
    let state = loadLocked()
    guard !stateReadFailed else { return }
    saveLocked(state)
  }

  private static func retainingPendingRangeCompletions(_ saved: State) -> State {
    var state = saved
    for (childId, generation) in pendingRangeCompletions {
      state.completedRangeGenerations[childId] = max(state.completedRangeGenerations[childId] ?? 0, generation)
    }
    let completed = state.completedRangeGenerations
    for index in state.multipartPlans.indices {
      state.multipartPlans[index].waiters.removeAll {
        ($0.generation ?? 0) <= (completed[$0.taskId] ?? 0)
      }
    }
    state.multipartClaims.removeAll {
      !$0.launchCommitted && $0.generation <= (completed[$0.waiter.taskId] ?? 0)
    }
    return state
  }

  private static func settleMultipartClaim(task: URLSessionTask) {
    guard let identity = rangeIdentity(for: task) else { return }
    lock.lock()
    defer { lock.unlock() }
    var state = loadLocked()
    guard !stateReadFailed else { return }
    let ids = Set(state.multipartClaims.filter {
      $0.waiter.taskId == identity.taskId && $0.parentTaskId == identity.parentTaskId
        && $0.generation == identity.generation && $0.launchCommitted
        && (nativeMultipartTasksByClaimId[$0.claimId] == nil || nativeMultipartTasksByClaimId[$0.claimId] === task)
    }.map(\.claimId))
    state.multipartClaims.removeAll { ids.contains($0.claimId) }
    nativeMultipartTasksByClaimId = nativeMultipartTasksByClaimId.filter { $0.value !== task }
    if !ids.isEmpty { saveLocked(state) }
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

  static func isNetworkUnavailableBackgroundTransportErrorCode(_ code: Int) -> Bool {
    [
      -1003, // cannot find host
      -1004, // cannot connect to host
      -1005, // network connection lost
      -1006, // DNS lookup failed
      -1009, // not connected to Internet
      -1018, // international roaming off
      -1019, // call is active
      -1020, // data not allowed
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
    receivedBytes: Int64,
    hasResumeData: Bool
  ) -> Bool {
    // Full-file retries must not silently throw away downloaded bytes unless
    // Apple supplied resumeData.
    hasResumeData || receivedBytes <= 0
  }

  static func noteBackgroundRetryProgress(_ task: URLSessionTask) {
    guard let id = taskId(from: task) else { return }
    noteBackgroundRetryProgress(taskId: id)
  }

  private static func noteBackgroundRetryProgress(taskId id: String) {
    guard !id.isEmpty else { return }
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
    guard legacyTransportOwnershipEnabled else { return false }
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

    if isNetworkUnavailableBackgroundTransportErrorCode(nsError.code) {
      DownloadNativeDiagnosticLog.record(
        "background.networkHold",
        task: task,
        error: error
      )
      // Do not spend the bounded server/transport retry budget while the
      // device has no usable network. The plugin surfaces this settlement and
      // Dart's durable waitingForNetwork state resumes it on connectivity.
      return false
    }

    let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    let hasResumeData = !(resumeData?.isEmpty ?? true)
    // Multipart Range retries are owned by V2/Dart. Native only refills
    // generation-fenced zero-byte candidates while Flutter is suspended.
    if isDownloadPart(task) {
      return false
    }
    guard canRecreateBackgroundDownload(
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
    DownloadUrlSessionHook.callbacks(for: task).retire()

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
    error: Error?,
    terminalSuccess: Bool? = nil,
    requiresTerminalObservation: Bool = false
  ) {
    guard legacyTransportOwnershipEnabled else { return }
    // Silence/interception is unknown ownership, never a successful file move.
    // Keep the slot until Dart's foreground ownership reconciliation.
    if requiresTerminalObservation && terminalSuccess == nil { return }
    rememberDownloadSession(session)
    // A native part is not an episode, but its URLSession byte/completion
    // evidence belongs to the Dart multipart parent. didFinishDownloadingTo
    // calls us after the plugin moved the temp file, so completion can now be
    // verified against the exact `.part` path by PersistentParallelDownload.
    if isDownloadPart(task) {
      guard isObservableMultipartPart(task) else { return }
      postMultipartChunkUpdate(
        task,
        totalWritten: task.countOfBytesReceived,
        totalExpected: task.countOfBytesExpectedToReceive,
        completed: terminalSuccess ?? (error == nil)
      )
      if isPromotableMultipartPart(task) {
        promoteMultipartIfPossible(on: session, parentId: parentTaskId(from: task))
      }
      return
    }
    let httpFailed = (task.response as? HTTPURLResponse).map {
      !(200...299).contains($0.statusCode)
    } ?? false
    let succeeded = terminalSuccess ?? (error == nil && !httpFailed)
    if succeeded {
      markPluginTaskCompleted(task: task)
    } else {
      parkFailedTask(task: task)
    }

    // Promote / update the SAME overlay before any finish. Finishing the
    // session task here is what suspended the process on ep1 complete.
    promoteNext(on: session)
    refreshSessionOverlay(success: succeeded)
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
    guard legacyTransportOwnershipEnabled else { return }
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
      guard !stateReadFailed else { lock.unlock(); return }
      let cap = clamp(state.maxConcurrent)
      if state.transferringTaskIds.count >= cap {
        lock.unlock()
        return
      }
      waiter = popWaiterLocked(&state)
      if waiter != nil, !saveLocked(state) { lock.unlock(); return }
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

  private static let foregroundStateLock = NSLock()
  private static var cachedForegroundState = true
  private static var foregroundObservers: [NSObjectProtocol] = []

  /// Installed at launch on main, before URLSession delegate callbacks. Byte
  /// callbacks only read the lock-protected cache, never wait for the UI thread.
  @MainActor
  static func installLifecycleObservers() {
    guard foregroundObservers.isEmpty else { return }
    refreshForegroundState()
    let names: [Notification.Name] = [
      UIScene.didActivateNotification,
      UIScene.willDeactivateNotification,
      UIScene.didEnterBackgroundNotification,
      UIScene.didDisconnectNotification,
      UIApplication.didBecomeActiveNotification,
      UIApplication.willResignActiveNotification,
      UIApplication.didEnterBackgroundNotification,
    ]
    foregroundObservers = names.map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
        MainActor.assumeIsolated {
          refreshForegroundState(notification)
        }
      }
    }
  }

  @MainActor
  private static func refreshForegroundState(_ notification: Notification? = nil) {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let resigningScene = notification?.name == UIScene.willDeactivateNotification
      || notification?.name == UIScene.didDisconnectNotification
      ? notification?.object as? UIScene : nil
    let appResigning = notification?.name == UIApplication.willResignActiveNotification
      || notification?.name == UIApplication.didEnterBackgroundNotification
    let active = !appResigning && (scenes.isEmpty
      ? UIApplication.shared.applicationState == .active
      : scenes.contains { $0 !== resigningScene && $0.activationState == .foregroundActive })
    foregroundStateLock.lock()
    cachedForegroundState = active
    foregroundStateLock.unlock()
  }

  /// Scene visibility is authoritative: BGContinuedProcessing can keep the
  /// application active even while its windows are backgrounded.
  private static func isAppInForeground() -> Bool {
    if NSClassFromString("XCTestCase") != nil { return false }
    foregroundStateLock.lock()
    defer { foregroundStateLock.unlock() }
    return cachedForegroundState
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
    return DownloadRangeIdentity.positiveInteger(metadata["attemptGeneration"])
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
  /// A persisted multipart plan is explicit permission to refill a finished
  /// URLSession slot while Dart is suspended. It does not grant native retry
  /// ownership over V2 transport failures.
  private static func ownsPromotableMultipartParent(_ parentId: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let state = loadLocked()
    return !stateReadFailed && parentMayRefillLocked(parentId, in: state)
  }

  /// Recognition for V2's durable immutable range children.
  private static func isV2DurableMultipartPart(_ task: URLSessionTask) -> Bool {
    rangeIdentity(for: task) != nil
  }

  /// A Range can be promoted only when Dart persisted a generation-fenced
  /// plan for its parent. Transient failures return to the V2 coordinator.
  private static func isPromotableMultipartPart(_ task: URLSessionTask) -> Bool {
    guard let identity = rangeIdentity(for: task) else { return false }
    return ownsPromotableMultipartParent(identity.parentTaskId)
  }

  private static func isObservableMultipartParent(_ parentId: String) -> Bool {
    ownsPromotableMultipartParent(parentId) || parentId.hasPrefix("aw_v2_")
  }

  private static func isObservableMultipartPart(_ task: URLSessionTask) -> Bool {
    isPromotableMultipartPart(task) || isV2DurableMultipartPart(task)
  }
  private static func postMultipartChunkUpdate(
    _ task: URLSessionTask,
    totalWritten: Int64,
    totalExpected: Int64,
    completed: Bool
  ) {
    guard isObservableMultipartPart(task),
          let childId = taskId(from: task),
          let parentId = parentTaskId(from: task)
    else {
      return
    }
    let taskJson = task.taskDescription?
      .components(separatedBy: "***<<<|>>>***").first ?? ""
    postMultipartChunkSample(
      childId: childId,
      parentId: parentId,
      childDirectory: stringFromTaskJson(taskJson, key: "directory"),
      totalWritten: totalWritten,
      totalExpected: totalExpected,
      normalizedProgress: totalExpected > 0
        ? min(max(Double(totalWritten) / Double(totalExpected), 0), 1)
        : nil,
      completed: completed,
      attemptGeneration: attemptGeneration(from: task)
    )
  }

  #if canImport(background_downloader)
  private static func postSupportedMultipartProgress(
    task: background_downloader.Task,
    progress: Double
  ) -> Bool {
    guard task.group == "chunk" || task.group == "animewitcher_parts",
          let parentId = parentTaskId(fromPluginTask: task),
          isObservableMultipartParent(parentId)
    else { return false }

    let expected = expectedMultipartBytes(forPluginTask: task, parentId: parentId)
    let written = expected > 0
      ? Int64((Double(expected) * progress).rounded(.down))
      : -1
    postMultipartChunkSample(
      childId: task.taskId,
      parentId: parentId,
      childDirectory: task.directory,
      totalWritten: written,
      totalExpected: expected,
      normalizedProgress: progress,
      completed: false,
      attemptGeneration: attemptGeneration(fromPluginTask: task)
    )
    return true
  }

  private static func parentTaskId(
    fromPluginTask task: background_downloader.Task
  ) -> String? {
    if let data = task.metaData.data(using: .utf8),
       let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let parent = metadata["parentTaskId"] as? String,
       !parent.isEmpty {
      return parent
    }
    if let range = task.taskId.range(of: ".part.", options: .backwards) {
      let parent = String(task.taskId[..<range.lowerBound])
      return parent.isEmpty ? nil : parent
    }
    return nil
  }

  private static func attemptGeneration(
    fromPluginTask task: background_downloader.Task
  ) -> Int? {
    guard let data = task.metaData.data(using: .utf8),
          let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return DownloadRangeIdentity.positiveInteger(metadata["attemptGeneration"])
  }

  private static func expectedMultipartBytes(
    forPluginTask task: background_downloader.Task,
    parentId: String
  ) -> Int64 {
    if let rangeHeader = task.headers.first(where: {
      $0.key.caseInsensitiveCompare("Range") == .orderedSame
    })?.value,
       let expected = expectedBytesFromRangeHeader(rangeHeader) {
      return expected
    }

    lock.lock()
    defer { lock.unlock() }
    let state = loadLocked()
    if let claim = state.multipartClaims.first(where: {
      $0.parentTaskId == parentId && $0.waiter.taskId == task.taskId
    }), claim.waiter.savedExpectedBytes > 0 {
      return claim.waiter.savedExpectedBytes
    }
    for plan in state.multipartPlans where plan.parentTaskId == parentId {
      if let waiter = plan.waiters.first(where: { $0.taskId == task.taskId }),
         waiter.savedExpectedBytes > 0 {
        return waiter.savedExpectedBytes
      }
    }
    return -1
  }

  private static func expectedBytesFromRangeHeader(_ header: String) -> Int64? {
    let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.lowercased().hasPrefix("bytes=") else { return nil }
    let range = value.dropFirst("bytes=".count)
    let parts = range.split(separator: "-", maxSplits: 1).map(String.init)
    guard parts.count == 2,
          let start = Int64(parts[0]),
          let end = Int64(parts[1]),
          start >= 0,
          end >= start
    else { return nil }
    return end - start + 1
  }
  #endif

  private static func postMultipartChunkSample(
    childId: String,
    parentId: String,
    childDirectory: String,
    totalWritten: Int64,
    totalExpected: Int64,
    normalizedProgress: Double?,
    completed: Bool,
    attemptGeneration: Int?
  ) {
    guard isObservableMultipartParent(parentId) else { return }
    let now = CFAbsoluteTimeGetCurrent()
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
    let speed = totalWritten >= 0
      ? rollingSpeedLocked(
          windows: &chunkSpeedWindows,
          taskId: childId,
          totalWritten: totalWritten,
          now: now,
          completed: completed
        )
      : 0

    var state = loadLocked()
    var children = multipartChildSamples[parentId] ?? [:]
    var sample = children[childId] ?? RunningSample(
      written: 0,
      expected: -1,
      speed: 0,
      displayName: inferredParentName
    )
    if totalWritten >= 0 {
      // A URLSession retry can reset its local byte counter. Keep native overlay
      // progress monotonic while the replacement catches up; this sample is UI
      // lease telemetry only and is never used as durable resume evidence.
      sample.written = max(sample.written, totalWritten)
    }
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
    }
    if completed {
      values["progress"] = 1.0
    } else if let normalizedProgress {
      values["progress"] = min(max(normalizedProgress, 0), 1)
    }
    if let attemptGeneration {
      values["attemptGeneration"] = attemptGeneration
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
    // same BGContinuedProcessingTask alive from native plugin progress so iOS
    // sees real progress instead of an apparently stalled long task.
    if shouldUpdateNativeOverlay && !isAppInForeground() {
      let overlayProgress = aggregateExpected > 0
        ? presentation.progress
        : (normalizedProgress ?? presentation.progress)
      upsertSessionOverlay(
        currentTaskId: presentation.currentTaskId,
        displayName: presentation.displayName,
        progress: overlayProgress,
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

  /// A successful URLSession completion has no second supported status in
  /// the validated versions. Refill immutable children after the delegate settles;
  /// this never classifies or assembles a logical parent as complete.
  static func observeRangeCompletion(on session: URLSession, task: URLSessionTask) {
    guard nativePromotionAvailable, let identity = rangeIdentity(for: task) else { return }
    rememberDownloadSession(session)
    settleMultipartClaim(task: task)
    promoteMultipartIfPossible(on: session, parentId: identity.parentTaskId)
  }

  static func refillAfterBackgroundEvents(on session: URLSession, original: () -> Void) {
    guard nativePromotionAvailable, !isAppInForeground() else { original(); return }
    // Acquire before the plugin queues UIApplication's completion on main.
    // It protects only query/persist/resume work, never the network transfer.
    let assertion = runOnMainActor { DownloadRangeBackgroundAssertion() }
    original()
    promoteMultipartIfPossible(on: session) {
      DispatchQueue.main.async { assertion.finish() }
    }
  }

  static func promoteMultipartIfPossible(
    on suppliedSession: URLSession? = nil,
    parentId: String? = nil,
    completion: (() -> Void)? = nil
  ) {
    guard nativePromotionAvailable else { completion?(); return }
    guard !isAppInForeground() else { completion?(); return }

    lock.lock()
    if let suppliedSession { latestDownloadSession = suppliedSession }
    let session = suppliedSession ?? latestDownloadSession
    let state = loadLocked()
    guard !stateReadFailed else { lock.unlock(); completion?(); return }
    let parents = state.multipartPlans.filter {
      (parentId == nil || $0.parentTaskId == parentId)
        && parentMayRefillLocked($0.parentTaskId, in: state)
        && (!$0.waiters.isEmpty || multipartPromotionParents.contains($0.parentTaskId))
    }.map(\.parentTaskId)
    lock.unlock()

    guard let session, !parents.isEmpty else { completion?(); return }
    let group = DispatchGroup()
    for parent in Set(parents) {
      group.enter()
      promoteMultipartPlan(parent, on: session) { group.leave() }
    }
    group.notify(queue: .global(qos: .utility)) { completion?() }
  }

  private static func promoteMultipartPlan(
    _ parentId: String, on session: URLSession, completion: @escaping () -> Void
  ) {
    lock.lock()
    multipartPromotionCompletions[parentId, default: []].append(completion)
    if multipartPromotionParents.contains(parentId) {
      // Preserve a completion/finish-events request arriving during enumeration.
      // The older getAllTasks snapshot may still count that execution as live.
      multipartPromotionPendingParents.insert(parentId)
      lock.unlock()
      return
    }
    multipartPromotionParents.insert(parentId)
    lock.unlock()
    scanMultipartPlan(parentId, on: session)
  }

  private static func finishMultipartPromotionPass(_ parentId: String, on session: URLSession) {
    lock.lock()
    let again = multipartPromotionPendingParents.remove(parentId) != nil
    if again {
      lock.unlock()
      scanMultipartPlan(parentId, on: session)
      return
    }
    multipartPromotionParents.remove(parentId)
    let completions = multipartPromotionCompletions.removeValue(forKey: parentId) ?? []
    lock.unlock()
    completions.forEach { $0() }
  }

  private static func scanMultipartPlan(_ parentId: String, on session: URLSession) {
    session.getAllTasks { tasks in
      defer { finishMultipartPromotionPass(parentId, on: session) }
      guard !isAppInForeground() else { return }

      let liveChildIds = Set(tasks.compactMap { task -> String? in
        guard task.state != .completed,
              !DownloadUrlSessionHook.callbacks(for: task).hasSettledCompletion,
              let identity = rangeIdentity(for: task), identity.parentTaskId == parentId
        else { return nil }
        return identity.taskId
      })

      let selected: [Waiter]
      lock.lock()
      var state = loadLocked()
      guard !stateReadFailed, parentMayRefillLocked(parentId, in: state),
            let index = state.multipartPlans.firstIndex(where: { $0.parentTaskId == parentId })
      else { lock.unlock(); return }
      requeueExpiredMultipartClaimsLocked(&state)
      var plan = state.multipartPlans[index]
      // Count pending and committed claims as slots too. A task may have been
      // created after this getAllTasks snapshot, before Dart's concurrent call.
      let claimedIds = Set(state.multipartClaims.filter { $0.parentTaskId == parentId }.map { $0.waiter.taskId })
      let occupiedIds = liveChildIds.union(claimedIds)
      plan.waiters.removeAll { occupiedIds.contains($0.taskId) }
      let available = max(min(plan.maxConcurrent, 16) - occupiedIds.count, 0)
      let claimable = plan.waiters.filter {
        isImmutableRangeWaiter($0) && ($0.generation ?? 0) > (state.dartRangeGenerations[$0.taskId] ?? 0)
          && ($0.generation ?? 0) > (state.completedRangeGenerations[$0.taskId] ?? 0)
          && !($0.claimId ?? "").isEmpty && ($0.claimLeaseMillis ?? 0) > 0
      }
      selected = Array(claimable.prefix(available))
      if !selected.isEmpty {
        let selectedIds = Set(selected.map(\.taskId))
        plan.waiters.removeAll { selectedIds.contains($0.taskId) }
        for waiter in selected {
          guard let generation = waiter.generation, let claimId = waiter.claimId,
                let lease = waiter.claimLeaseMillis else { continue }
          state.multipartClaims.append(MultipartClaim(
            parentTaskId: parentId, maxConcurrent: plan.maxConcurrent, waiter: waiter,
            generation: generation, claimId: claimId,
            expiresAtMillis: nowMillis() + Int64(min(max(lease, 1), 15 * 60 * 1000)),
            launchCommitted: false, launchCommittedAtMillis: nil
          ))
        }
      }
      state.multipartPlans[index] = plan
      guard saveLocked(state) else { lock.unlock(); return }
      lock.unlock()

      for waiter in selected { startMultipartChild(waiter, on: session) }
    }
  }

  private static func startMultipartChild(_ waiter: Waiter, on session: URLSession) {
    guard isImmutableRangeWaiter(waiter), !isAppInForeground(), let url = URL(string: waiter.url) else {
      releaseMultipartClaim(waiter, requeue: true)
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    for (key, value) in waiter.headers { request.setValue(value, forHTTPHeaderField: key) }
    guard let task = commitMultipartClaimBeforeResume(waiter, on: session, request: request) else {
      // Revoked/paused claims create no task, so they cannot emit a spurious
      // cancellation status for a newer Dart execution with the same task ID.
      releaseMultipartClaim(waiter, requeue: true)
      return
    }
    DownloadNativeDiagnosticLog.record("background.multipart.promote", task: task)
  }

  #if canImport(background_downloader)
  /// Only the synchronous status emitted by the original delegate invocation
  /// may classify that execution. Out-of-band/delayed statuses are discarded.
  /// Read-only throughput bridge for background_downloader's V2 parallel
  /// child tasks. It never starts, pauses, resumes, retries, or owns transport.
  @discardableResult
  private static func postV2ParallelChunkMetric(
    task: background_downloader.Task,
    progress: Double?,
    completed: Bool,
    statusOrdinal: Int? = nil
  ) -> Bool {
    guard task.group == "chunk" || task.group == "animewitcher_parts",
          let parentId = parentTaskId(fromPluginTask: task),
          parentId.hasPrefix("aw_v2_")
    else { return false }

    let expected = task.headers.first(where: {
      $0.key.caseInsensitiveCompare("Range") == .orderedSame
    }).flatMap { expectedBytesFromRangeHeader($0.value) } ?? -1
    let normalized = progress.map { min(max($0, 0), 1) }
    let written: Int64
    if expected > 0, let normalized {
      written = Int64((Double(expected) * normalized).rounded(.down))
    } else {
      written = -1
    }

    let now = CFAbsoluteTimeGetCurrent()
    let appIsBackground = !isAppInForeground()
    var aggregateWritten: Int64 = 0
    var aggregateSpeed = 0.0
    var shouldUpdateNativeOverlay = false
    var shouldBridgeToDart = false

    lock.lock()
    let speed: Double
    if completed {
      chunkSpeedWindows[task.taskId] = nil
      speed = 0
    } else if written >= 0 {
      speed = rollingSpeedLocked(
        windows: &chunkSpeedWindows,
        taskId: task.taskId,
        totalWritten: written,
        now: now
      )
    } else {
      speed = 0
    }

    var children = v2ParallelChildSamples[parentId] ?? [:]
    var sample = children[task.taskId] ?? RunningSample(
      written: 0,
      expected: expected > 0 ? expected : -1,
      speed: 0,
      displayName: ""
    )
    if written >= 0 {
      // Native resume can restart a child's local counter. System-overlay
      // presentation stays monotonic while background_downloader owns the
      // actual resume decision and bytes.
      sample.written = max(sample.written, written)
    }
    if expected > 0 {
      sample.expected = max(sample.expected, expected)
    }
    if let normalized, normalized >= 0.999_999, sample.expected > 0 {
      sample.written = sample.expected
    }
    if completed {
      sample.speed = 0
    } else if speed > 0, speed.isFinite {
      sample.speed = speed
    }
    children[task.taskId] = sample
    v2ParallelChildSamples[parentId] = children

    aggregateWritten = children.values.reduce(Int64(0)) {
      $0 + max($1.written, 0)
    }
    aggregateSpeed = children.values.reduce(0.0) {
      $0 + ($1.speed.isFinite && $1.speed > 0 ? $1.speed : 0)
    }
    let lastOverlay = lastV2ParallelOverlayTimes[parentId] ?? 0
    shouldUpdateNativeOverlay = appIsBackground
      && ((normalized ?? 0) >= 0.999_999
        || now - lastOverlay >= chunkBridgeInterval)
    if shouldUpdateNativeOverlay {
      lastV2ParallelOverlayTimes[parentId] = now
    }

    // background_downloader already delivers child progress to Dart while the
    // app is active. This native bridge exists for iOS-specific speed/pause
    // observation, so do not mirror every URLSession callback through
    // NotificationCenter -> main queue -> Flutter MethodChannel. Preserve every
    // status/completion transition, and sample foreground progress at most once
    // per child per second. In background, the native overlay is updated below
    // without waking a suspended Flutter isolate for progress-only telemetry.
    if completed || statusOrdinal != nil {
      shouldBridgeToDart = true
      if completed {
        lastChunkBridgeTimes[task.taskId] = nil
      } else {
        lastChunkBridgeTimes[task.taskId] = now
      }
    } else if !appIsBackground {
      let lastBridge = lastChunkBridgeTimes[task.taskId] ?? 0
      if now - lastBridge >= chunkBridgeInterval {
        lastChunkBridgeTimes[task.taskId] = now
        shouldBridgeToDart = true
      }
    }
    lock.unlock()

    if shouldBridgeToDart {
      var values: [String: Any] = [
        "parentTaskId": parentId,
        "chunkTaskId": task.taskId,
        "completed": completed,
      ]
      if let generation = attemptGeneration(fromPluginTask: task) {
        values["attemptGeneration"] = generation
      }
      if let normalized {
        values["progress"] = normalized
      }
      if let statusOrdinal {
        values["status"] = statusOrdinal
      }
      if written >= 0 {
        values["writtenBytes"] = written
      }
      if expected > 0 {
        values["expectedBytes"] = expected
      }
      if speed > 0, speed.isFinite {
        values["speedBytesPerSecond"] = speed
      }

      NotificationCenter.default.post(
        name: Notification.Name("AnimeWitcherBackgroundDownloaderChunkUpdate"),
        object: nil,
        userInfo: values
      )
    }

    // Dart owns foreground presentation. During iOS background URLSession
    // wake-ups the Flutter isolate can be suspended, so update the already
    // created system overlay directly from the supported native callback.
    if !isAppInForeground() && shouldUpdateNativeOverlay {
      // Child samples cover only ranges observed so far. They are safe byte
      // and throughput telemetry, but never proof of the full parent length.
      // Passing their subtotal as totalBytesHint recreated the 31/62/93% jumps
      // whenever the system overlay did not already know the real parent size.
      // Let the manager use its existing full size when available; otherwise
      // keep progress unchanged until package parent progress arrives.
      runOnMainActor {
        if #available(iOS 26.0, *) {
          _ = DownloadContinuedProcessingManager.shared.updateFromNativeIfCurrent(
            taskId: parentId,
            progress: nil,
            totalBytesHint: -1,
            transferredBytes: aggregateWritten,
            speedBytesPerSecond: aggregateSpeed
          )
        }
      }
    }

    if !completed, written >= 0 {
      let observedAt = now
      let childId = task.taskId
      DispatchQueue.global(qos: .utility).asyncAfter(
        deadline: .now() + speedStaleInterval
      ) {
        var staleAggregateWritten: Int64 = 0
        var staleAggregateSpeed = 0.0

        lock.lock()
        guard let last = chunkSpeedWindows[childId]?.last,
              last.time <= observedAt + 0.000_001,
              CFAbsoluteTimeGetCurrent() - last.time >= speedStaleInterval
        else {
          lock.unlock()
          return
        }
        chunkSpeedWindows[childId] = nil
        if var children = v2ParallelChildSamples[parentId],
           var sample = children[childId] {
          sample.speed = 0
          children[childId] = sample
          v2ParallelChildSamples[parentId] = children
          staleAggregateWritten = children.values.reduce(Int64(0)) {
            $0 + max($1.written, 0)
          }
          staleAggregateSpeed = children.values.reduce(0.0) {
            $0 + ($1.speed.isFinite && $1.speed > 0 ? $1.speed : 0)
          }
        }
        lock.unlock()

        // Unlike a missing speed field, explicit zero means this child has
        // produced no bytes for the stale interval.
        if isAppInForeground() {
          NotificationCenter.default.post(
            name: Notification.Name("AnimeWitcherBackgroundDownloaderChunkUpdate"),
            object: nil,
            userInfo: [
              "parentTaskId": parentId,
              "chunkTaskId": childId,
              "completed": false,
              "speedBytesPerSecond": 0.0,
            ]
          )
        }

        if !isAppInForeground() {
          runOnMainActor {
            if #available(iOS 26.0, *) {
              _ = DownloadContinuedProcessingManager.shared.updateFromNativeIfCurrent(
                taskId: parentId,
                progress: nil,
                totalBytesHint: -1,
                transferredBytes: staleAggregateWritten,
                speedBytesPerSecond: staleAggregateSpeed
              )
            }
          }
        }
      }
    }
    return true
  }

  private static func handleSupportedPluginStatus(
    task: background_downloader.Task,
    statusUpdate: background_downloader.TaskStatusUpdate
  ) {
    guard !task.taskId.isEmpty else { return }

    let status = statusUpdate.taskStatus
    if task.group == "animewitcher_parts",
       let parent = parentTaskId(fromPluginTask: task),
       let generation = attemptGeneration(fromPluginTask: task),
       let identity = DownloadRangeIdentity(taskId: task.taskId, parentTaskId: parent, generation: generation) {
      if status == .failed {
        DownloadNativeRetryMetadata.record(
          identity: identity,
          httpStatus: statusUpdate.responseStatusCode ?? statusUpdate.exception?.httpResponseCode,
          headers: statusUpdate.responseHeaders
        )
      } else if status == .complete {
        DownloadNativeRetryMetadata.remove(identity: identity)
      }
    }
    let inactiveForSpeed: Bool
    switch status {
    case .complete, .notFound, .failed, .canceled, .paused:
      inactiveForSpeed = true
    default:
      inactiveForSpeed = false
    }

    // V2 uses child status only as observation. In particular, every paused
    // child must be observed before Dart attempts a parallel resume.
    if postV2ParallelChunkMetric(
      task: task,
      progress: status == .complete ? 1 : nil,
      completed: inactiveForSpeed,
      statusOrdinal: status.rawValue
    ) {
      if inactiveForSpeed {
        terminalObservation.record(
          taskId: task.taskId,
          succeeded: status == .complete
        )
      }
      return
    }

    switch status {
    case .complete, .notFound, .failed, .canceled, .paused:
      terminalObservation.record(
        taskId: task.taskId,
        succeeded: status == .complete
      )
    default:
      break
    }
  }

  /// Validated background_downloader versions expose throttled native progress.
  /// Prefer that supported contract over replacing its didWriteData IMP. When
  /// native/Dart state already knows the expected byte count, keep the exact
  /// byte/speed bridge; otherwise preserve normalized progress without
  /// inventing a total size.
  private static func handleSupportedPluginProgress(
    task: background_downloader.Task,
    progress: Double
  ) {
    guard progress.isFinite, progress >= 0 else { return }
    let normalized = min(max(progress, 0), 1)
    let id = task.taskId
    guard !id.isEmpty else { return }

    // Observation is independent from native promotion capability.
    // V2 child metrics leave background_downloader as the sole transport owner.
    if postV2ParallelChunkMetric(
      task: task,
      progress: normalized,
      completed: false
    ) {
      return
    }

    // V2 parent progress is observation-only and must not depend on the
    // retired native transport-promotion capability. This keeps the iOS 26
    // system task fresh while Dart is suspended, including single-part files.
    if id.hasPrefix("aw_v2_") {
      if !isAppInForeground() {
        // Child Range callbacks carry their own throughput. For a whole-file
        // V2 task, compute speed from native progress while Flutter sleeps.
        // Do not overwrite a multipart parent's live child speed samples.
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let state = loadLocked()
        let expected = state.sessionCurrentTaskId == id
          ? state.sessionTotalBytes : -1
        var nativeSpeed = -1.0
        if expected > 0,
           state.transferringTaskIds.contains(id),
           v2ParallelChildSamples[id]?.isEmpty ?? true {
          let written = Int64((Double(expected) * normalized).rounded(.down))
          nativeSpeed = rollingSpeedLocked(
            windows: &taskSpeedWindows,
            taskId: id,
            totalWritten: written,
            now: now
          )
        }
        lock.unlock()
        runOnMainActor {
          if #available(iOS 26.0, *) {
            _ = DownloadContinuedProcessingManager.shared.updateFromNativeIfCurrent(
              taskId: id,
              progress: normalized,
              speedBytesPerSecond: nativeSpeed
            )
          }
        }
      }
      return
    }

    guard nativePromotionAvailable else { return }
    noteBackgroundRetryProgress(taskId: id)
    if postSupportedMultipartProgress(task: task, progress: normalized) {
      return
    }

    let now = CFAbsoluteTimeGetCurrent()
    let name = task.displayName.isEmpty
      ? (task.filename.isEmpty ? id : task.filename)
      : task.displayName

    lock.lock()
    var state = loadLocked()
    // This callback has no URLSession execution identity. It may update an
    // existing sample, but cannot acquire/release ownership or resurrect a
    // terminal task from a delayed plugin progress callback.
    guard state.transferringTaskIds.contains(id) else {
      lock.unlock()
      return
    }
    var sample = state.runningSamples[id] ?? RunningSample(
      written: 0,
      expected: -1,
      speed: 0,
      displayName: name
    )
    let waiterExpected = state.waiters.first(where: { $0.taskId == id })?.savedExpectedBytes ?? -1
    let multipartExpected = state.multipartPlans
      .flatMap(\.waiters)
      .first(where: { $0.taskId == id })?
      .savedExpectedBytes ?? -1
    let sessionExpected = state.sessionCurrentTaskId == id ? state.sessionTotalBytes : -1
    // Keep expected-byte candidates concretely typed. Swift otherwise infers
    // an optional element through first(where:) in this callback context,
    // leaking Int64? into all byte arithmetic.
    let expectedCandidates: [Int64] = [
      sample.expected, waiterExpected, multipartExpected, sessionExpected
    ]
    let knownExpected: Int64 = expectedCandidates.first(where: { $0 > 0 }) ?? -1
    let totalWritten = knownExpected > 0
      ? Int64((Double(knownExpected) * normalized).rounded(.down))
      : max(sample.written, 0)
    if knownExpected > 0 {
      sample.written = totalWritten
      sample.expected = knownExpected
      sample.speed = rollingSpeedLocked(
        windows: &taskSpeedWindows,
        taskId: id,
        totalWritten: totalWritten,
        now: now
      )
    }
    if sample.displayName.isEmpty { sample.displayName = name }
    state.runningSamples[id] = sample
    let transferringSet = Set(state.transferringTaskIds)
    state.runningSamples = state.runningSamples.filter { transferringSet.contains($0.key) }
    let presentation = overlayPresentation(from: state, fallbackId: id, fallbackName: name)
    let stableSpeed = sample.speed
    saveLocked(state)
    lock.unlock()

    if knownExpected > 0 {
      scheduleNativeSpeedStaleReset(taskId: id, observedAt: now)
      _ = postSingleTaskUpdate(
        taskId: id,
        trackingUrl: task.metaData.isEmpty ? task.url : task.metaData,
        totalWritten: totalWritten,
        totalExpected: knownExpected,
        speedBytesPerSecond: stableSpeed,
        now: now
      )
    }

    if !isAppInForeground() {
      let overlayProgress = knownExpected > 0 ? presentation.progress : normalized
      upsertSessionOverlay(
        currentTaskId: presentation.currentTaskId.isEmpty ? id : presentation.currentTaskId,
        displayName: presentation.displayName.isEmpty ? name : presentation.displayName,
        progress: overlayProgress,
        totalBytes: knownExpected > 0 ? presentation.totalBytes : -1,
        transferredBytes: knownExpected > 0 ? presentation.transferredBytes : totalWritten,
        speedBytesPerSecond: knownExpected > 0 ? presentation.speedBytesPerSecond : 0
      )
    }
  }
  #endif

  static func handleBytesWritten(
    _ downloadTask: URLSessionDownloadTask,
    session: URLSession? = nil,
    totalWritten: Int64,
    totalExpected: Int64
  ) {
    if let session { rememberDownloadSession(session) }
    if isDownloadPart(downloadTask) {
      guard isObservableMultipartPart(downloadTask) else { return }
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
    guard !stateReadFailed else { lock.unlock(); return }
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
    let keepPages = currentTaskId == state.sessionCurrentTaskId
    state.sessionCompletedPages = keepPages ? state.sessionCompletedPages : nil
    state.sessionTotalPages = keepPages ? state.sessionTotalPages : nil
    let pageProgress = keepPages && state.sessionCompletedPages != nil
      ? state.sessionProgress : progress
    state.sessionCurrentTaskId = currentTaskId
    if !displayName.isEmpty {
      state.sessionDisplayName = displayName
    }
    if resetOnSwitch {
      state.sessionProgress = pageProgress
      state.sessionTotalBytes = totalBytes > 0 ? totalBytes : -1
      state.sessionTransferredBytes = transferredBytes
      state.sessionSpeedBytesPerSecond = max(speedBytesPerSecond, 0)
    } else {
      state.sessionProgress = pageProgress
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
          progress: pageProgress,
          totalBytes: totalBytes > 0 ? totalBytes : snapshot.sessionTotalBytes,
          transferredBytes: transferredBytes,
          completedCount: snapshot.sessionCompletedCount,
          batchTotal: max(snapshot.sessionBatchTotal, 1),
          speedBytesPerSecond: snapshot.sessionSpeedBytesPerSecond,
          currentIndex: snapshot.sessionCurrentIndex,
          completedPages: snapshot.sessionCompletedPages,
          totalPages: snapshot.sessionTotalPages
        )
      }
    }
  }

  private static func loadLocked() -> State {
    stateReadFailed = false
    let data: Data?
    if let encrypted = UserDefaults.standard.data(forKey: encryptedStateKey) {
      data = DownloadNativeQueueEncryption.decrypt(encrypted)
      stateReadFailed = data == nil
    } else {
      data = UserDefaults.standard.data(forKey: stateKey)
    }
    guard let data, var state = try? JSONDecoder().decode(State.self, from: data) else {
      if data != nil { stateReadFailed = true }
      return retainingPendingRangeCompletions(State(
        maxConcurrent: 1,
        transferringTaskIds: [],
        pausedTaskIds: [],
        waiters: [],
        completedTaskIds: []
      ))
    }
    state = retainingPendingRangeCompletions(state)
    // Migrate old plaintext only after preserving every waiter, task JSON,
    // auth header and resume blob in authenticated encrypted storage.
    if UserDefaults.standard.object(forKey: stateKey) != nil {
      if !saveLocked(state) { stateReadFailed = true }
    }
    return state
  }

  @discardableResult
  private static func saveLocked(_ state: State) -> Bool {
    let state = retainingPendingRangeCompletions(state)
    guard !stateReadFailed,
          let data = try? JSONEncoder().encode(state),
          let encrypted = DownloadNativeQueueEncryption.encrypt(data) else { return false }
    UserDefaults.standard.set(encrypted, forKey: encryptedStateKey)
    UserDefaults.standard.removeObject(forKey: stateKey)
    pendingRangeCompletions.removeAll()
    return true
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  private static func clamp(_ value: Int) -> Int {
    min(max(value, 1), 10)
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

/// UIApplication's completion may run before asynchronous enumeration returns.
/// This bounded main-thread assertion covers that short handoff only.
@MainActor
private final class DownloadRangeBackgroundAssertion {
  private var identifier: UIBackgroundTaskIdentifier = .invalid

  init() {
    identifier = UIApplication.shared.beginBackgroundTask(withName: "V2 range refill") { [weak self] in
      DispatchQueue.main.async { self?.finish() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish() }
  }

  func finish() {
    guard identifier != .invalid else { return }
    let previous = identifier
    identifier = .invalid
    UIApplication.shared.endBackgroundTask(previous)
  }
}

/// Keeps only the plugin `UrlSessionDelegate` completion-ordering hooks that
/// still require the live URLSession. Progress uses supported package-native
/// callback above, so Flutter method channels are never required to observe it.
///
/// Uses IMP replacement (not Swift `self.hooked()` after `method_exchange`),
/// because a Swift call to the hooked method is a direct recursive call and
/// never hits the original ObjC IMP.
private enum DownloadUrlSessionHook {
  private static let installation = DownloadHookInstallation()
  private static var callbacksKey: UInt8 = 0
  private static let callbacksLock = NSLock()

  static func callbacks(for task: URLSessionTask) -> DownloadExecutionCallbacks {
    callbacksLock.lock()
    defer { callbacksLock.unlock() }
    if let value = objc_getAssociatedObject(task, &callbacksKey) as? DownloadExecutionCallbacks {
      return value
    }
    let value = DownloadExecutionCallbacks()
    objc_setAssociatedObject(task, &callbacksKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return value
  }
  private static let completeSelector = NSSelectorFromString(
    "URLSession:task:didCompleteWithError:"
  )
  private static let finishDownloadSelector = NSSelectorFromString(
    "URLSession:downloadTask:didFinishDownloadingToURL:"
  )
  private static let finishEventsSelector = NSSelectorFromString(
    "URLSessionDidFinishEventsForBackgroundURLSession:"
  )

  private static var originalComplete: IMP?
  private static var originalFinishDownload: IMP?
  private static var originalFinishEvents: IMP?

  static func install() -> Bool {
    #if canImport(background_downloader)
    // Generated from the installed pubspec by Podfile. The upstream podspec
    // advertises 0.0.1, so Bundle's framework version is not the pub version.
    // V9.6.4 source validated at 3098b05e65445a12b57a8182755982ae3a77e6dd:
    // finish-download validates/moves before return; successful didComplete has
    // no new terminal status; finish-events queues its completion onto main.
    let pluginVersion: String? = animeWitcherBackgroundDownloaderVersion
    let delegateClass: AnyClass = UrlSessionDelegate.self
    #else
    let pluginVersion: String? = nil
    guard let delegateClass = findUrlSessionDelegateClass() else { return false }
    #endif
    let available = [completeSelector, finishDownloadSelector, finishEventsSelector].map {
      class_getInstanceMethod(delegateClass, $0) != nil
    }
    _ = installation.install(version: pluginVersion, available: available) {
      hookComplete(on: delegateClass)
      hookFinishDownload(on: delegateClass)
      hookFinishEvents(on: delegateClass)
    }
    let installed = installation.rangePromotionAvailable
    DownloadNativeDiagnosticLog.record("background.capability", fields: [
      "status": pluginVersion ?? "unknown", "success": installed,
    ])
    if !installed {
      NSLog("[DownloadNativeWaitingQueue] native promotion unavailable; plugin continues; queued work recovers on foreground reconciliation (package %@)", pluginVersion ?? "unknown")
    }
    return installed
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
      let observation = callbacks(for: task)
      let firstCompletion = observation.beginComplete()
      DownloadNativeDiagnosticLog.record("complete.beforePlugin", task: task, error: error)
      // Always forward every plugin callback. This seam owns neither retries
      // nor terminal status, and never suppresses HoldingQueue settlement.
      _ = DownloadNativeWaitingQueue.terminalObservation.capture(
        execution: task, taskId: DownloadNativeWaitingQueue.taskId(from: task) ?? ""
      ) {
        guard let original = DownloadUrlSessionHook.originalComplete else { return }
        let fn = unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector, URLSession, URLSessionTask, Error?) -> Void).self)
        fn(slf, completeSelector, session, task, error)
      }
      DownloadNativeDiagnosticLog.record("complete.afterPlugin", task: task, error: error)
      guard firstCompletion else { return }
      observation.markCompletionSettled()
      // Success didComplete emits no fresh supported status in pinned 9.6.4.
      // It still frees a native range slot after the original returns.
      DownloadNativeWaitingQueue.observeRangeCompletion(on: session, task: task)
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func hookFinishDownload(on cls: AnyClass) {
    guard let method = class_getInstanceMethod(cls, finishDownloadSelector) else { return }
    originalFinishDownload = method_getImplementation(method)
    let block: @convention(block) (AnyObject, URLSession, URLSessionDownloadTask, URL) -> Void = { slf, session, downloadTask, location in
      let firstFinish = callbacks(for: downloadTask).beginFinish()
      DownloadNativeDiagnosticLog.record("file.received.beforePlugin", task: downloadTask)
      // Validated versions check HTTP and move the temporary file synchronously.
      // Only plugin-supported status/progress observers publish that outcome.
      let succeeded = DownloadNativeWaitingQueue.terminalObservation.capture(
        execution: downloadTask, taskId: DownloadNativeWaitingQueue.taskId(from: downloadTask) ?? ""
      ) {
        guard let original = DownloadUrlSessionHook.originalFinishDownload else { return }
        let fn = unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector, URLSession, URLSessionDownloadTask, URL) -> Void).self)
        fn(slf, finishDownloadSelector, session, downloadTask, location)
      }
      if firstFinish {
        DownloadNativeWaitingQueue.recordCompletedRange(task: downloadTask, succeeded: succeeded)
      }
      DownloadNativeDiagnosticLog.record("file.received.afterPlugin", task: downloadTask)
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func hookFinishEvents(on cls: AnyClass) {
    guard let method = class_getInstanceMethod(cls, finishEventsSelector) else { return }
    originalFinishEvents = method_getImplementation(method)
    let block: @convention(block) (AnyObject, URLSession) -> Void = { slf, session in
      DownloadNativeWaitingQueue.refillAfterBackgroundEvents(on: session) {
        guard let original = DownloadUrlSessionHook.originalFinishEvents else { return }
        let fn = unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector, URLSession) -> Void).self)
        fn(slf, finishEventsSelector, session)
      }
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }
}
#endif
