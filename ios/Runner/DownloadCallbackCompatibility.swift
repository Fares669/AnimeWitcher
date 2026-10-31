import Foundation
import CoreFoundation
import Darwin

/// Validated 9.6.1/9.6.2/9.6.4/9.6.5 emit supported status inside the delegate invocation.
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
  private var completionSettled = false

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

  func markCompletionSettled() {
    lock.lock()
    completionSettled = true
    lock.unlock()
  }

  var hasSettledCompletion: Bool {
    lock.lock()
    defer { lock.unlock() }
    return completionSettled
  }
}

/// A reusable child ID is insufficient: every mutation also fences its parent
/// and positive attempt generation. Invalid/plugin-owned chunks fail closed.
struct DownloadRangeIdentity: Hashable, Sendable {
  let taskId: String
  let parentTaskId: String
  let generation: Int

  init?(taskId: String, parentTaskId: String, generation: Int) {
    let prefix = parentTaskId + ".part."
    guard parentTaskId.hasPrefix("aw_v2_"), parentTaskId.count > "aw_v2_".count,
          taskId.hasPrefix(prefix), generation > 0 else { return nil }
    let index = taskId.dropFirst(prefix.count)
    guard !index.isEmpty, index.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    self.taskId = taskId
    self.parentTaskId = parentTaskId
    self.generation = generation
  }

  static func from(taskJson: String) -> DownloadRangeIdentity? {
    guard let data = taskJson.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["group"] as? String == "animewitcher_parts",
          let taskId = object["taskId"] as? String,
          let raw = object["metaData"] as? String,
          let metadataData = raw.data(using: .utf8),
          let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
          let parent = metadata["parentTaskId"] as? String,
          let generation = positiveInteger(metadata["attemptGeneration"])
    else { return nil }
    return DownloadRangeIdentity(taskId: taskId, parentTaskId: parent, generation: generation)
  }

  static func positiveInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite,
          number.doubleValue > 0,
          number.doubleValue < Double(Int.max),
          number.doubleValue.rounded(.down) == number.doubleValue
    else { return nil }
    return number.intValue
  }

  /// An older Dart attempt must never revoke a newer offer or native writer.
  func canRevoke(_ other: DownloadRangeIdentity) -> Bool {
    taskId == other.taskId && parentTaskId == other.parentTaskId
      && generation >= other.generation
  }
}

/// Installs only compatible delegate observation hooks. After the V2 cutover
/// those hooks must never claim retry/queue/completion ownership from
/// background_downloader. The dormant legacy source remains until Task 14.
final class DownloadHookInstallation {
  private(set) var isInstalled = false
  private(set) var rangePromotionAvailable = false
  private let transportOwnershipEnabled: Bool

  init(transportOwnershipEnabled: Bool = false) {
    self.transportOwnershipEnabled = transportOwnershipEnabled
  }

  func install(version: String?, available: [Bool], apply: () -> Void) -> Bool {
    // Repeated AppDelegate wake/install attempts must preserve the same
    // observation-vs-ownership result; never turn an installed observer into
    // transport ownership on the second call.
    if isInstalled { return transportOwnershipEnabled }
    guard ["9.6.1", "9.6.2", "9.6.4", "9.6.5"].contains(version ?? ""), available.count == 3,
          available.allSatisfy({ $0 }) else { return false }
    apply()
    isInstalled = true
    rangePromotionAvailable = true
    return transportOwnershipEnabled
  }
}

struct DownloadFilePromotionError: Error {
  let code: String
  let errnoValue: Int32?
}

/// Publishes a closed, verified source without ever replacing a destination.
/// Unsupported volumes fail closed; neither copying nor ordinary rename is safe.
enum DownloadFilePromotion {
  static func promoteCompletedFile(
    sourcePath: String,
    targetPath: String,
    expectedBytes: Int64
  ) throws {
    guard sourcePath.hasPrefix("/"), targetPath.hasPrefix("/"),
          !sourcePath.utf8.contains(0), !targetPath.utf8.contains(0),
          expectedBytes >= 0 else {
      throw DownloadFilePromotionError(code: "INVALID_ARGUMENTS", errnoValue: nil)
    }
    let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
    let target = URL(fileURLWithPath: targetPath).standardizedFileURL
    guard source.path != target.path else {
      throw DownloadFilePromotionError(code: "INVALID_ARGUMENTS", errnoValue: nil)
    }
    try source.withUnsafeFileSystemRepresentation { sourceFS in
      guard let sourceFS else {
        throw DownloadFilePromotionError(code: "INVALID_ARGUMENTS", errnoValue: nil)
      }
      var info = stat()
      if lstat(sourceFS, &info) != 0 {
        let failure = errno
        throw DownloadFilePromotionError(code: "PROMOTION_SOURCE_INVALID", errnoValue: failure)
      }
      guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            info.st_size == expectedBytes else {
        throw DownloadFilePromotionError(code: "PROMOTION_SOURCE_INVALID", errnoValue: nil)
      }
      try target.withUnsafeFileSystemRepresentation { targetFS in
        guard let targetFS else {
          throw DownloadFilePromotionError(code: "INVALID_ARGUMENTS", errnoValue: nil)
        }
        let result = renamex_np(sourceFS, targetFS, UInt32(RENAME_EXCL))
        let failure = errno
        guard result == 0 else {
          throw DownloadFilePromotionError(
            code: failure == EEXIST ? "DESTINATION_EXISTS" : "PROMOTION_FAILED",
            errnoValue: failure
          )
        }
      }
    }
  }
}
