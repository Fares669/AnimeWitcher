import Foundation

/// 9.6.1 emits supported status synchronously inside the delegate invocation.
/// Task.taskId is NOT an execution ID; no observation survives that invocation.
final class DownloadTerminalObservation {
  private final class Frame {
    let execution: AnyObject
    let taskId: String
    var succeeded: Bool?
    init(execution: AnyObject, taskId: String) {
      self.execution = execution
      self.taskId = taskId
    }
  }
  private let key = "animewitcher.download.terminal.\(UUID().uuidString)"

  func capture(execution: AnyObject, taskId: String, body: () -> Void) -> Bool? {
    let dictionary = Thread.current.threadDictionary
    let previous = dictionary[key]
    let frame = Frame(execution: execution, taskId: taskId)
    dictionary[key] = frame
    defer {
      if let previous { dictionary[key] = previous }
      else { dictionary.removeObject(forKey: key) }
    }
    body()
    return frame.succeeded
  }

  func record(taskId: String, succeeded: Bool) {
    guard let frame = Thread.current.threadDictionary[key] as? Frame,
          frame.taskId == taskId else { return }
    frame.succeeded = succeeded
  }
}

/// Attached to the concrete URLSessionTask, never the reusable plugin taskId.
final class DownloadExecutionCallbacks {
  private let lock = NSLock()
  private var retired = false
  private var finished = false
  private var completed = false

  func retire() {
    lock.lock()
    defer { lock.unlock() }
    retired = true
  }

  func beginFinish() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !retired, !finished, !completed else { return false }
    finished = true
    return true
  }

  func beginComplete() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !retired, !completed else { return false }
    completed = true
    return true
  }
}

/// Installs only compatible delegate observation hooks. After the V2 cutover
/// those hooks must never claim retry/queue/completion ownership from
/// background_downloader. The dormant legacy source remains until Task 14.
final class DownloadHookInstallation {
  private(set) var isInstalled = false
  private let transportOwnershipEnabled: Bool

  init(transportOwnershipEnabled: Bool = false) {
    self.transportOwnershipEnabled = transportOwnershipEnabled
  }

  func install(version: String?, available: [Bool], apply: () -> Void) -> Bool {
    // Repeated AppDelegate wake/install attempts must preserve the same
    // observation-vs-ownership result; never turn an installed observer into
    // transport ownership on the second call.
    if isInstalled { return transportOwnershipEnabled }
    guard version == "9.6.1", available.count == 3,
          available.allSatisfy({ $0 }) else { return false }
    apply()
    isInstalled = true
    return transportOwnershipEnabled
  }
}
