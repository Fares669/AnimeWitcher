#if os(iOS)
import BackgroundTasks
import Foundation
import UIKit

@available(iOS 26.0, *)
private enum DownloadContinuedProcessingError: LocalizedError {
  case missingBundleIdentifier
  case identifierNotPermitted(String)
  case registrationRejected(String)

  var errorDescription: String? {
    switch self {
    case .missingBundleIdentifier:
      return "Unable to resolve the app bundle identifier for continued processing."
    case .identifierNotPermitted(let identifier):
      return "The continued-processing identifier is not permitted: \(identifier)."
    case .registrationRejected(let identifier):
      return "BGTaskScheduler rejected registration for \(identifier)."
    }
  }
}

/// Owns the **one** iOS 26 BGContinuedProcessingTask for an active download
/// session (the whole queue), not one task per episode.
///
/// Rivera: finishing the overlay when ep1 completes and starting a new one
/// for ep2 suspends the process and breaks promotion. `start` always updates
/// this session. `finish` / `stop` are no-ops unless `endSession` is true.
@available(iOS 26.0, *)
@MainActor
final class DownloadContinuedProcessingManager {
  static let shared = DownloadContinuedProcessingManager()

  /// Stable key / identifier suffix. Info.plist `download.*` matches.
  static let sessionKey = "session"

  struct Snapshot {
    var displayName: String
    var progress: Double
    var totalBytes: Int64
    var transferredBytes: Int64
    var completedCount: Int
    var batchTotal: Int
    var speedBytesPerSecond: Double
    var currentTaskId: String
  }

  var cancellationHandler: ((String) -> Void)?

  private let scheduler = BGTaskScheduler.shared
  private var activeTasks: [String: BGContinuedProcessingTask] = [:]
  private var snapshots: [String: Snapshot] = [:]
  private var identifiers: [String: String] = [:]
  private var registeredIdentifiers = Set<String>()
  private var currentEpisodeTaskId = ""

  private init() {}

  var isSessionActive: Bool {
    activeTasks[Self.sessionKey] != nil || identifiers[Self.sessionKey] != nil
  }

  func start(
    taskId: String,
    displayName: String,
    progress: Double,
    totalBytes: Int64,
    transferredBytes: Int64 = -1,
    completedCount: Int = 0,
    batchTotal: Int = 1,
    speedBytesPerSecond: Double = 0
  ) throws -> String? {
    // BGContinuedProcessingTaskRequest itself validates that submission is
    // associated with the foreground app. Avoid an additional UIApplication
    // state check here: transient `.inactive` states during UI transitions can
    // otherwise make a user-initiated download silently skip system UI.

    if taskId != Self.sessionKey, !taskId.isEmpty {
      currentEpisodeTaskId = taskId
    }

    let normalized = min(max(progress, 0.0), 1.0)
    let transferred = transferredBytes >= 0
      ? transferredBytes
      : overlayTransferredBytes(progress: normalized, totalBytes: totalBytes)
    let snapshot = Snapshot(
      displayName: displayName,
      progress: normalized,
      totalBytes: totalBytes,
      transferredBytes: transferred,
      completedCount: max(completedCount, 0),
      batchTotal: max(batchTotal, 1),
      speedBytesPerSecond: max(speedBytesPerSecond, 0),
      currentTaskId: currentEpisodeTaskId.isEmpty ? taskId : currentEpisodeTaskId
    )
    snapshots[Self.sessionKey] = snapshot

    if let active = activeTasks[Self.sessionKey] {
      apply(snapshot, to: active)
      return identifiers[Self.sessionKey]
    }

    // Request already submitted for this session — never start a second
    // Live Activity / continued-processing task when ep2 begins.
    if let existingIdentifier = identifiers[Self.sessionKey] {
      return existingIdentifier
    }

    let identifier = try taskIdentifier(for: Self.sessionKey)
    identifiers[Self.sessionKey] = identifier

    guard isPermittedTaskIdentifier(identifier) else {
      identifiers.removeValue(forKey: Self.sessionKey)
      throw DownloadContinuedProcessingError.identifierNotPermitted(identifier)
    }

    if !registeredIdentifiers.contains(identifier) {
      let accepted = scheduler.register(
        forTaskWithIdentifier: identifier,
        using: DispatchQueue.main
      ) { [weak self] task in
        guard let continuedTask = task as? BGContinuedProcessingTask else {
          task.setTaskCompleted(success: false)
          return
        }

        Task { @MainActor in
          self?.attach(continuedTask, taskId: Self.sessionKey)
        }
      }

      guard accepted else {
        identifiers.removeValue(forKey: Self.sessionKey)
        throw DownloadContinuedProcessingError.registrationRejected(identifier)
      }
      registeredIdentifiers.insert(identifier)
    }

    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier,
      title: title(for: snapshot),
      subtitle: subtitle(for: snapshot)
    )
    request.strategy = .queue
    do {
      try scheduler.submit(request)
    } catch {
      identifiers.removeValue(forKey: Self.sessionKey)
      throw error
    }
    return identifier
  }

  func update(
    taskId: String,
    progress: Double,
    totalBytes: Int64,
    transferredBytes: Int64 = -1,
    completedCount: Int = -1,
    batchTotal: Int = -1,
    speedBytesPerSecond: Double = -1,
    displayName: String = ""
  ) {
    if taskId != Self.sessionKey, !taskId.isEmpty {
      currentEpisodeTaskId = taskId
    }
    guard var snapshot = snapshots[Self.sessionKey] else { return }

    snapshot.progress = min(max(progress, 0.0), 1.0)
    if totalBytes > 0 {
      snapshot.totalBytes = totalBytes
    }
    if transferredBytes >= 0 {
      snapshot.transferredBytes = transferredBytes
    } else if snapshot.totalBytes > 0 {
      snapshot.transferredBytes = overlayTransferredBytes(
        progress: snapshot.progress,
        totalBytes: snapshot.totalBytes
      )
    }
    if completedCount >= 0 {
      snapshot.completedCount = completedCount
    }
    if batchTotal > 0 {
      snapshot.batchTotal = batchTotal
    }
    if speedBytesPerSecond >= 0 {
      snapshot.speedBytesPerSecond = speedBytesPerSecond
    }
    if !displayName.isEmpty {
      snapshot.displayName = displayName
    }
    snapshot.currentTaskId = currentEpisodeTaskId
    snapshots[Self.sessionKey] = snapshot

    if let task = activeTasks[Self.sessionKey] {
      apply(snapshot, to: task)
    }
  }

  func finish(taskId: String, success: Bool, status: String, endSession: Bool = false) {
    // Hard rule: never complete the system task for a single episode while
    // the batch still has running or waiting files. Callers must pass
    // endSession only when running+waiting is zero.
    guard endSession else { return }
    completeSession(success: success, status: status)
  }

  func stop(taskId: String, endSession: Bool = false) {
    guard endSession else { return }
    completeSession(success: false, status: "canceled")
  }

  private func completeSession(success: Bool, status: String) {
    cancelPendingRequest(for: Self.sessionKey)

    if let task = activeTasks.removeValue(forKey: Self.sessionKey) {
      let snapshot = snapshots[Self.sessionKey]
      if success {
        if task.progress.totalUnitCount <= 0 {
          task.progress.totalUnitCount = 1000
        }
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.updateTitle(
          "Download complete",
          subtitle: sessionCountSubtitle(snapshot)
        )
      } else if status == "failed" {
        task.updateTitle(
          "Download failed",
          subtitle: sessionCountSubtitle(snapshot)
        )
      }
      task.expirationHandler = nil
      task.setTaskCompleted(success: success)
    }

    snapshots.removeValue(forKey: Self.sessionKey)
    identifiers.removeValue(forKey: Self.sessionKey)
    currentEpisodeTaskId = ""
  }

  private func attach(
    _ task: BGContinuedProcessingTask,
    taskId: String
  ) {
    activeTasks[Self.sessionKey] = task

    task.expirationHandler = { [weak self, weak task] in
      Task { @MainActor in
        guard let self else { return }
        let cancelId = self.currentEpisodeTaskId.isEmpty
          ? Self.sessionKey
          : self.currentEpisodeTaskId
        self.cancellationHandler?(cancelId)
        task?.setTaskCompleted(success: false)
        self.activeTasks.removeValue(forKey: Self.sessionKey)
        self.snapshots.removeValue(forKey: Self.sessionKey)
        self.identifiers.removeValue(forKey: Self.sessionKey)
        self.currentEpisodeTaskId = ""
      }
    }

    if let snapshot = snapshots[Self.sessionKey] {
      apply(snapshot, to: task)
    } else {
      task.progress.totalUnitCount = 1000
      task.progress.completedUnitCount = 0
    }
  }

  private func apply(
    _ snapshot: Snapshot,
    to task: BGContinuedProcessingTask
  ) {
    let normalized = min(max(snapshot.progress, 0.0), 1.0)

    if snapshot.totalBytes > 0 {
      task.progress.totalUnitCount = snapshot.totalBytes
      let completed = snapshot.transferredBytes >= 0
        ? snapshot.transferredBytes
        : overlayTransferredBytes(
          progress: normalized,
          totalBytes: snapshot.totalBytes
        )
      task.progress.completedUnitCount = min(
        max(completed, 0),
        snapshot.totalBytes
      )
    } else {
      task.progress.totalUnitCount = 1000
      task.progress.completedUnitCount = Int64(
        (normalized * 1000.0).rounded(.down)
      )
    }

    task.updateTitle(
      title(for: snapshot),
      subtitle: subtitle(for: snapshot)
    )
  }

  private func cancelPendingRequest(for taskId: String) {
    guard let identifier = identifiers[taskId] else { return }
    scheduler.cancel(taskRequestWithIdentifier: identifier)
  }

  private func taskIdentifier(for taskId: String) throws -> String {
    guard let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty else {
      throw DownloadContinuedProcessingError.missingBundleIdentifier
    }
    return "\(bundleId).download.\(Self.sessionKey)"
  }

  private func isPermittedTaskIdentifier(_ identifier: String) -> Bool {
    let permitted = Bundle.main.object(
      forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers"
    ) as? [String] ?? []

    return permitted.contains { pattern in
      if pattern == identifier { return true }
      guard pattern.hasSuffix(".*") else { return false }
      let prefix = String(pattern.dropLast())
      return identifier.hasPrefix(prefix)
    }
  }

  private func title(for snapshot: Snapshot) -> String {
    let name = snapshot.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty {
      return "Downloading"
    }
    return "Downloading “\(name)”"
  }

  private func currentIndex(for snapshot: Snapshot) -> Int {
    let total = max(snapshot.batchTotal, 1)
    let index = snapshot.completedCount + 1
    return min(max(index, 1), total)
  }

  private func subtitle(for snapshot: Snapshot) -> String {
    let count = "\(currentIndex(for: snapshot)) of \(max(snapshot.batchTotal, 1))"
    var parts: [String] = []
    let speed = formatSpeed(snapshot.speedBytesPerSecond)
    if !speed.isEmpty {
      parts.append(speed)
    }
    if snapshot.totalBytes > 0 {
      parts.append(
        "\(formatCompactBytes(snapshot.transferredBytes))/\(formatCompactBytes(snapshot.totalBytes))"
      )
    }
    parts.append(count)
    return parts.joined(separator: " • ")
  }

  private func sessionCountSubtitle(_ snapshot: Snapshot?) -> String {
    guard let snapshot else { return "" }
    return "\(currentIndex(for: snapshot)) of \(max(snapshot.batchTotal, 1))"
  }

  private func overlayTransferredBytes(progress: Double, totalBytes: Int64) -> Int64 {
    guard totalBytes > 0 else { return 0 }
    return Int64((Double(totalBytes) * progress).rounded(.down))
  }

  private func formatCompactBytes(_ bytes: Int64) -> String {
    let value = Double(max(bytes, 0))
    if value >= 1_000_000_000 {
      let gb = value / 1_000_000_000
      return gb >= 10
        ? String(format: "%.0fGB", gb)
        : String(format: "%.1fGB", gb)
    }
    if value >= 1_000_000 {
      let mb = value / 1_000_000
      return mb >= 10
        ? String(format: "%.0fMB", mb)
        : String(format: "%.1fMB", mb)
    }
    if value >= 1_000 {
      return String(format: "%.0fKB", value / 1_000)
    }
    return String(format: "%.0fB", value)
  }

  private func formatSpeed(_ bytesPerSecond: Double) -> String {
    guard bytesPerSecond > 0 else { return "" }
    if bytesPerSecond >= 1_000_000 {
      return String(format: "%.1fMB/s", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1_000 {
      return String(format: "%.0fKB/s", bytesPerSecond / 1_000)
    }
    return String(format: "%.0fB/s", bytesPerSecond)
  }
}
#endif
