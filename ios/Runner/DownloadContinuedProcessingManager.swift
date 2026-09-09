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
    var currentIndex: Int
  }

  /// Reserved for a real explicit cancel action. BGContinuedProcessingTask
  /// expiration is only the end of the OS processing lease and must never be
  /// translated into pausing the independent background URLSession transfer.
  var cancellationHandler: ((String) -> Void)?

  private let scheduler = BGTaskScheduler.shared
  private var activeTask: BGContinuedProcessingTask?
  private var snapshot: Snapshot?
  private var identifier: String?
  private var didRegisterIdentifier = false
  private var currentEpisodeTaskId = ""
  private var lastAppliedUpdateAt: TimeInterval = 0
  private let minimumUpdateInterval: TimeInterval = 1.0

  private init() {}

  func start(
    taskId: String,
    displayName: String,
    progress: Double,
    totalBytes: Int64,
    transferredBytes: Int64 = -1,
    completedCount: Int = 0,
    batchTotal: Int = 1,
    speedBytesPerSecond: Double = 0,
    currentIndex: Int = 0
  ) throws -> String? {
    // BGContinuedProcessingTaskRequest itself validates that submission is
    // associated with the foreground app. Avoid an additional UIApplication
    // state check here: transient `.inactive` states during UI transitions can
    // otherwise make a user-initiated download silently skip system UI.

    let previousEpisodeTaskId = currentEpisodeTaskId
    if taskId != Self.sessionKey, !taskId.isEmpty {
      currentEpisodeTaskId = taskId
    }

    let normalized = min(max(progress, 0.0), 1.0)
    let transferred = transferredBytes >= 0
      ? transferredBytes
      : overlayTransferredBytes(progress: normalized, totalBytes: totalBytes)
    let switched = !previousEpisodeTaskId.isEmpty
      && taskId != Self.sessionKey
      && taskId != previousEpisodeTaskId
    let keepSpeed = switched
      ? max(speedBytesPerSecond, 0)
      : (speedBytesPerSecond >= 0
        ? speedBytesPerSecond
        : max(snapshot?.speedBytesPerSecond ?? 0, 0))
    let snapshot = Snapshot(
      displayName: displayName,
      progress: normalized,
      totalBytes: totalBytes,
      transferredBytes: transferred,
      completedCount: max(completedCount, 0),
      batchTotal: max(batchTotal, 1),
      speedBytesPerSecond: keepSpeed,
      currentTaskId: currentEpisodeTaskId.isEmpty ? taskId : currentEpisodeTaskId,
      currentIndex: currentIndex > 0
        ? currentIndex
        : (self.snapshot?.currentIndex ?? 0)
    )
    self.snapshot = snapshot

    if let active = activeTask {
      applyIfDue(snapshot, to: active)
      return identifier
    }

    // Request already submitted for this session — never start a second
    // Live Activity / continued-processing task when ep2 begins.
    if let existingIdentifier = identifier {
      return existingIdentifier
    }

    let sessionId = try sessionIdentifier()
    identifier = sessionId

    guard isPermittedTaskIdentifier(sessionId) else {
      identifier = nil
      throw DownloadContinuedProcessingError.identifierNotPermitted(sessionId)
    }

    if !didRegisterIdentifier {
      let accepted = scheduler.register(
        forTaskWithIdentifier: sessionId,
        using: DispatchQueue.main
      ) { [weak self] task in
        guard let continuedTask = task as? BGContinuedProcessingTask else {
          task.setTaskCompleted(success: false)
          return
        }

        Task { @MainActor in
          self?.attach(continuedTask)
        }
      }

      guard accepted else {
        identifier = nil
        throw DownloadContinuedProcessingError.registrationRejected(sessionId)
      }
      didRegisterIdentifier = true
    }

    let request = BGContinuedProcessingTaskRequest(
      identifier: sessionId,
      title: title(for: snapshot),
      subtitle: subtitle(for: snapshot)
    )
    request.strategy = .queue
    do {
      try scheduler.submit(request)
    } catch {
      identifier = nil
      throw error
    }
    return sessionId
  }

  func update(
    taskId: String,
    progress: Double,
    totalBytes: Int64,
    transferredBytes: Int64 = -1,
    completedCount: Int = -1,
    batchTotal: Int = -1,
    speedBytesPerSecond: Double = -1,
    displayName: String = "",
    currentIndex: Int = -1
  ) {
    let previousEpisodeTaskId = currentEpisodeTaskId
    if taskId != Self.sessionKey, !taskId.isEmpty {
      currentEpisodeTaskId = taskId
    }
    guard var snapshot = snapshot else { return }

    let switched = !previousEpisodeTaskId.isEmpty
      && taskId != Self.sessionKey
      && taskId != previousEpisodeTaskId

    snapshot.progress = min(max(progress, 0.0), 1.0)
    if totalBytes > 0 {
      snapshot.totalBytes = totalBytes
    } else if switched {
      snapshot.totalBytes = -1
    }
    if transferredBytes >= 0 {
      snapshot.transferredBytes = transferredBytes
    } else if switched {
      snapshot.transferredBytes = 0
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
    if switched {
      snapshot.speedBytesPerSecond = max(speedBytesPerSecond, 0)
    } else if speedBytesPerSecond >= 0 {
      snapshot.speedBytesPerSecond = max(speedBytesPerSecond, 0)
    }
    if !displayName.isEmpty {
      snapshot.displayName = displayName
    }
    if currentIndex > 0 {
      snapshot.currentIndex = currentIndex
    }
    snapshot.currentTaskId = currentEpisodeTaskId
    self.snapshot = snapshot

    if let task = activeTask {
      applyIfDue(snapshot, to: task)
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
    cancelPendingRequest()

    // Flutter can decide that the session has no *running* entries after an
    // unexpected child pause, even though the logical episode is only 36% done.
    // Never let that bookkeeping race become the iOS "Download complete"
    // banner seen by the user. A real final episode reaches progress 1.0 and,
    // for a batch, all earlier episodes are already counted as completed.
    let snapshotLooksComplete: Bool
    if let snapshot {
      snapshotLooksComplete = snapshot.progress >= 0.999_999
        && snapshot.completedCount + 1 >= max(snapshot.batchTotal, 1)
    } else {
      snapshotLooksComplete = false
    }
    let verifiedSuccess = success && snapshotLooksComplete

    if let task = activeTask {
      activeTask = nil
      if verifiedSuccess {
        if task.progress.totalUnitCount <= 0 {
          task.progress.totalUnitCount = 1000
        }
        task.progress.completedUnitCount = task.progress.totalUnitCount
        task.updateTitle(
          "Download complete",
          subtitle: sessionCountSubtitle(snapshot)
        )
      } else if status == "canceled" {
        task.updateTitle(
          "Download stopped",
          subtitle: sessionCountSubtitle(snapshot)
        )
      } else {
        task.updateTitle(
          "Download paused",
          subtitle: sessionCountSubtitle(snapshot)
        )
      }
      task.expirationHandler = nil
      task.setTaskCompleted(success: verifiedSuccess)
    }

    snapshot = nil
    identifier = nil
    currentEpisodeTaskId = ""
    lastAppliedUpdateAt = 0
  }

  private func attach(_ task: BGContinuedProcessingTask) {
    activeTask = task

    task.expirationHandler = { [weak self, weak task] in
      Task { @MainActor in
        guard let self else { return }

        // Expiration only revokes the BGContinuedProcessingTask lease / system
        // overlay. The actual episode is owned by background URLSession (or by
        // PersistentParallelDownload's child URLSession tasks), which is
        // intentionally independent and must keep transferring. Mapping this
        // callback to `cancellationHandler` used to mark the logical parent
        // paused and promote the next episode while its parts were still live.
        task?.setTaskCompleted(success: false)
        self.activeTask = nil
        self.snapshot = nil
        self.identifier = nil
        self.currentEpisodeTaskId = ""
        self.lastAppliedUpdateAt = 0
      }
    }

    if let snapshot {
      applyIfDue(snapshot, to: task, force: true)
    } else {
      task.progress.totalUnitCount = 1000
      task.progress.completedUnitCount = 0
    }
  }

  /// System continued-processing UI is expensive and user-visible. Keep its
  /// cadence at most once per second even if native/Dart producers burst.
  /// The latest snapshot is still retained on every call, so the next eligible
  /// callback uses current bytes and speed rather than an arbitrary old sample.
  private func applyIfDue(
    _ snapshot: Snapshot,
    to task: BGContinuedProcessingTask,
    force: Bool = false
  ) {
    let now = ProcessInfo.processInfo.systemUptime
    if !force,
       lastAppliedUpdateAt > 0,
       now - lastAppliedUpdateAt < minimumUpdateInterval {
      return
    }
    apply(snapshot, to: task)
    lastAppliedUpdateAt = now
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

  private func cancelPendingRequest() {
    guard let identifier else { return }
    scheduler.cancel(taskRequestWithIdentifier: identifier)
  }

  private func sessionIdentifier() throws -> String {
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
    let index = snapshot.currentIndex > 0
      ? snapshot.currentIndex
      : snapshot.completedCount + 1
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
