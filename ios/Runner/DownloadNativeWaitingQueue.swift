#if os(iOS)
import Foundation
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

  struct Waiter: Codable, Equatable {
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

    var taskDescription: String {
      if let notificationConfigJson, !notificationConfigJson.isEmpty {
        return taskJson + "***<<<|>>>***" + notificationConfigJson
      }
      return taskJson
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
        group: string(arguments["group"]) ?? "FileDownloaderGroup"
      )
    }
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
      sessionSpeedBytesPerSecond: Double = 0
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
    }

    var sessionIsIdle: Bool {
      transferringTaskIds.isEmpty && waiters.isEmpty
    }
  }

  private struct WriteSample {
    var taskId: String
    var bytes: Int64
    var time: CFAbsoluteTime
  }

  private static let lock = NSLock()
  private static var hookInstalled = false
  /// Task IDs that already have URLSession bytes (plugin HQ or our start).
  /// Do not query plugin-internal HoldingQueue APIs.
  private static var seenTransferringIds = Set<String>()
  private static var lastWrite: WriteSample?

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

    let pausedSet = Set(dartPaused)
    let sessionIds = unique(
      current.sessionTaskIds + dartSessionIds + dartTransferring + dartWaiters.map(\.taskId)
    )
    // Keep completed-in-session IDs so `1 of 5` survives Dart snapshots that
    // no longer list ep1 as transferring. Drop them only when the session is idle.
    var completed = unique(current.completedTaskIds)
    if !sessionIds.isEmpty {
      completed = completed.filter { sessionIds.contains($0) }
    }

    let transferring = unique(current.transferringTaskIds + dartTransferring)
      .filter { !pausedSet.contains($0) && !completed.contains($0) }
    let transferringSet = Set(transferring)
    let waiters = dartWaiters.filter {
      !transferringSet.contains($0.taskId) && !pausedSet.contains($0.taskId)
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
    let batchTotal = idle && dartBatchTotal == 0
      ? 0
      : max(
        max(current.sessionBatchTotal, dartBatchTotal),
        max(computedBatch, sessionIds.count)
      )

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
        sessionProgress: (arguments["sessionProgress"] as? NSNumber)?.doubleValue
          ?? current.sessionProgress,
        sessionTotalBytes: int64Value(arguments["sessionTotalBytes"]).flatMap { $0 > 0 ? $0 : nil }
          ?? current.sessionTotalBytes,
        sessionTransferredBytes: int64Value(arguments["sessionTransferredBytes"])
          ?? current.sessionTransferredBytes,
        sessionSpeedBytesPerSecond: (arguments["sessionSpeedBytesPerSecond"] as? NSNumber)?.doubleValue
          ?? current.sessionSpeedBytesPerSecond
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
  }

  /// Called from the plugin URLSession delegate after ep1's native completion.
  /// Starts the next waiter on **this same session** synchronously, then
  /// the caller may invoke `completionHandler()`.
  static func handlePluginTaskCompleted(
    session: URLSession,
    task: URLSessionTask,
    error: Error?
  ) {
    let completedId = taskId(from: task)
    lock.lock()
    var state = loadLocked()
    if let completedId {
      state.transferringTaskIds.removeAll { $0 == completedId }
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
        max(
          state.sessionBatchTotal,
          state.transferringTaskIds.count + state.waiters.count + state.completedTaskIds.count
        ),
        state.sessionTaskIds.count
      )
    }
    saveLocked(state)
    lock.unlock()

    // Promote / update the SAME overlay before any finish. Finishing the
    // session task here is what suspended the process on ep1 complete.
    promoteNext(on: session)
    refreshSessionOverlay(success: error == nil)
  }

  static func promoteNext(on session: URLSession) {
    // In-app, Dart + plugin HoldingQueue own promotion. Starting a second
    // URLSession task here while the app is `.active` double-downloads.
    // Background/suspended: HoldingQueue's async `taskFinished` often never
    // runs, so this callback must start the persisted waiter now.
    let isActive = runOnMainActor {
      UIApplication.shared.applicationState == .active
    }
    if isActive {
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

  /// One URLSession task per episode. If this waiter is already transferring,
  /// only update the session overlay.
  private static func startIfNotAlreadyNative(_ waiter: Waiter, on session: URLSession) {
    lock.lock()
    let alreadyTransferring = seenTransferringIds.contains(waiter.taskId)
    let alreadyCompleted = loadLocked().completedTaskIds.contains(waiter.taskId)
    lock.unlock()
    if alreadyTransferring || alreadyCompleted {
      NSLog("[DownloadNativeWaitingQueue] already native %@", waiter.taskId)
      startLiveActivity(taskId: waiter.taskId, displayName: waiter.displayName)
      return
    }
    start(waiter, on: session)
  }

  private static func popWaiterLocked(_ state: inout State) -> Waiter? {
    let paused = Set(state.pausedTaskIds)
    guard let index = state.waiters.firstIndex(where: { !paused.contains($0.taskId) })
    else {
      return nil
    }
    let waiter = state.waiters.remove(at: index)
    if !state.transferringTaskIds.contains(waiter.taskId) {
      state.transferringTaskIds.append(waiter.taskId)
    }
    return waiter
  }

  private static func start(_ waiter: Waiter, on session: URLSession) {
    guard let url = URL(string: waiter.url) else {
      NSLog("[DownloadNativeWaitingQueue] invalid url for %@", waiter.taskId)
      requeue(waiter)
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = waiter.httpRequestMethod.isEmpty ? "GET" : waiter.httpRequestMethod
    for (key, value) in waiter.headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    if let post = postFromTaskJson(waiter.taskJson), !post.isEmpty {
      request.httpBody = post.data(using: .utf8)
    }
    let downloadTask = session.downloadTask(with: request)
    downloadTask.taskDescription = waiter.taskDescription
    downloadTask.resume()
    lock.lock()
    seenTransferringIds.insert(waiter.taskId)
    lock.unlock()
    NSLog("[DownloadNativeWaitingQueue] started %@", waiter.taskId)
    upsertSessionOverlay(
      currentTaskId: waiter.taskId,
      displayName: waiter.displayName,
      progress: 0,
      totalBytes: -1,
      transferredBytes: 0,
      speedBytesPerSecond: 0
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

  static func handleBytesWritten(
    _ downloadTask: URLSessionDownloadTask,
    totalWritten: Int64,
    totalExpected: Int64
  ) {
    guard let id = taskId(from: downloadTask) else { return }
    let now = CFAbsoluteTimeGetCurrent()
    var speed: Double = 0
    lock.lock()
    seenTransferringIds.insert(id)
    if let last = lastWrite, last.taskId == id, now > last.time {
      let deltaBytes = Double(max(totalWritten - last.bytes, 0))
      let deltaTime = now - last.time
      if deltaTime > 0 {
        speed = deltaBytes / deltaTime
      }
    }
    lastWrite = WriteSample(taskId: id, bytes: totalWritten, time: now)
    lock.unlock()
    let json = downloadTask.taskDescription?
      .components(separatedBy: "***<<<|>>>***").first ?? ""
    let display = stringFromTaskJson(json, key: "displayName")
    let filename = stringFromTaskJson(json, key: "filename")
    let name = display.isEmpty ? (filename.isEmpty ? id : filename) : display
    let progress = totalExpected > 0
      ? min(max(Double(totalWritten) / Double(totalExpected), 0), 1)
      : 0
    upsertSessionOverlay(
      currentTaskId: id,
      displayName: name,
      progress: progress,
      totalBytes: totalExpected,
      transferredBytes: totalWritten,
      speedBytesPerSecond: speed
    )
  }

  private static func startLiveActivity(taskId: String, displayName: String) {
    upsertSessionOverlay(
      currentTaskId: taskId,
      displayName: displayName,
      progress: 0,
      totalBytes: -1,
      transferredBytes: 0,
      speedBytesPerSecond: 0
    )
  }

  private static func refreshSessionOverlay(success: Bool) {
    lock.lock()
    let state = loadLocked()
    let idle = state.sessionIsIdle
    let nextId = state.transferringTaskIds.first ?? state.waiters.first?.taskId
    let nextName: String
    if let next = state.waiters.first(where: { $0.taskId == nextId }) {
      nextName = next.displayName
    } else {
      nextName = state.sessionDisplayName
    }
    let completed = state.sessionCompletedCount
    let batch = max(state.sessionBatchTotal, 1)
    lock.unlock()

    if idle {
      runOnMainActor {
        if #available(iOS 26.0, *) {
          DownloadContinuedProcessingManager.shared.finish(
            taskId: DownloadContinuedProcessingManager.sessionKey,
            success: success,
            status: success ? "completed" : "failed",
            endSession: true
          )
        }
      }
      return
    }

    upsertSessionOverlay(
      currentTaskId: nextId ?? state.sessionCurrentTaskId,
      displayName: nextName,
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
    state.sessionCurrentTaskId = currentTaskId
    if !displayName.isEmpty {
      state.sessionDisplayName = displayName
    }
    state.sessionProgress = progress
    if totalBytes > 0 {
      state.sessionTotalBytes = totalBytes
    }
    state.sessionTransferredBytes = transferredBytes
    if speedBytesPerSecond > 0 {
      state.sessionSpeedBytesPerSecond = speedBytesPerSecond
    }
    if let completedCount {
      state.sessionCompletedCount = max(state.sessionCompletedCount, completedCount)
    }
    if let batchTotal {
      state.sessionBatchTotal = max(state.sessionBatchTotal, batchTotal)
    }
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
          speedBytesPerSecond: snapshot.sessionSpeedBytesPerSecond
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
      UserDefaults.standard.synchronize()
    }
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  private static func clamp(_ value: Int) -> Int {
    min(max(value, 1), 5)
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
    "urlSession:task:didCompleteWithError:"
  )
  private static let finishDownloadSelector = NSSelectorFromString(
    "urlSession:downloadTask:didFinishDownloadingToURL:"
  )
  private static let finishEventsSelector = NSSelectorFromString(
    "urlSessionDidFinishEventsForBackgroundURLSession:"
  )
  private static let writeSelector = NSSelectorFromString(
    "urlSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:"
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
      DownloadNativeWaitingQueue.handlePluginTaskCompleted(
        session: session,
        task: task,
        error: error
      )
      if let original = DownloadUrlSessionHook.originalComplete {
        let fn = unsafeBitCast(
          original,
          to: (@convention(c) (AnyObject, Selector, URLSession, URLSessionTask, Error?) -> Void).self
        )
        fn(slf, completeSelector, session, task, error)
      }
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
  }

  private static func hookFinishDownload(on cls: AnyClass) {
    guard let method = class_getInstanceMethod(cls, finishDownloadSelector) else { return }
    originalFinishDownload = method_getImplementation(method)
    let block: @convention(block) (AnyObject, URLSession, URLSessionDownloadTask, URL) -> Void = { slf, session, downloadTask, location in
      // Original must run first so the plugin can move the temp file.
      if let original = DownloadUrlSessionHook.originalFinishDownload {
        let fn = unsafeBitCast(
          original,
          to: (@convention(c) (AnyObject, Selector, URLSession, URLSessionDownloadTask, URL) -> Void).self
        )
        fn(slf, finishDownloadSelector, session, downloadTask, location)
      }
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
      if let original = DownloadUrlSessionHook.originalWrite {
        let fn = unsafeBitCast(
          original,
          to: (@convention(c) (
            AnyObject, Selector, URLSession, URLSessionDownloadTask, Int64, Int64, Int64
          ) -> Void).self
        )
        fn(slf, writeSelector, session, downloadTask, bytesWritten, totalWritten, totalExpected)
      }
      DownloadNativeWaitingQueue.handleBytesWritten(
        downloadTask,
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
