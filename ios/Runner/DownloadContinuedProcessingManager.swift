#if os(iOS)
import BackgroundTasks
import Foundation
#if canImport(background_downloader)
import enum background_downloader.AnimeWitcherDownloadSessions
#endif
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

/// Expiration can race an explicit endSession on another callback queue.
/// Claim completion once without holding a lock while calling into the OS.
private final class DownloadContinuedProcessingCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false

  func finish(_ completion: () -> Void) {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    completed = true
    lock.unlock()
    completion()
  }
}

/// Only Dart's validated page checkpoints can advance Manga presentation.
private enum DownloadPageProgress {
  static func acceptsDartUpdate(inForeground: Bool, incomingPages: Int?, currentPages: Int?) -> Bool {
    inForeground || incomingPages != nil || currentPages != nil
  }

  static func fraction(completed: Int, total: Int, progress: Double) -> Double {
    guard total > 0 else { return 0 }
    return min(max(Double(completed) / Double(total), 0), progress < 1 ? 0.999 : 1)
  }

  static func label(completed: Int, total: Int) -> String {
    let count = min(max(completed, 0), max(total, 0))
    return "\(count)/\(total > 0 ? String(total) : "?") pages"
  }
}

/// Rate-limited presentation of measured download activity. Updating a title
/// cannot extend an OS lease or substitute for real Progress advancement.
enum DownloadPresentationPulse {
  static let interval: TimeInterval = 1.0

  static func title(displayName: String, filled: Bool) -> String {
    let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let dot = filled ? "◉" : "○"
    if name.isEmpty {
      return "\(dot) Downloading"
    }
    return "\(dot) Downloading “\(name)”"
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
    var completedPages: Int?
    var totalPages: Int?
    var completedCount: Int
    var batchTotal: Int
    var speedBytesPerSecond: Double
    var currentTaskId: String
    var currentIndex: Int
  }

  private let scheduler = BGTaskScheduler.shared
  private var activeTask: BGContinuedProcessingTask?
  private var activeTaskCompletion: DownloadContinuedProcessingCompletion?
  private var snapshot: Snapshot?
  private var identifier: String?
  private var didRegisterIdentifier = false
  private var currentEpisodeTaskId = ""
  private var requestSubmittedAt: Date?
  private var leaseStartedAt: Date?
  private var pulseTimer: Timer?
  private var pulseFilled = true
  private var lastSpeedSampleAt: TimeInterval = 0
  private var lastNativePageActivityAt: TimeInterval = 0
  private var nativePageFractions: [String: (initial: Double, latest: Double)] = [:]
  private var nativePageBaseline: Double?
  private var lastNativeRejectionTaskId = ""
  /// Stamp of the last presentation actually applied to the system task.
  /// Every feeder (Dart updates, the native background feed, the pulse)
  /// funnels through this one clock, so the banner changes at most once
  /// per second no matter how the feeders interleave (device logs,
  /// 2026-10-30: bursts of 3-5 native feeds inside one second).
  private var lastPresentationAt: CFTimeInterval = 0
  // Rebase only when a queue grows. A larger denominator would otherwise
  // pin the OS progress bar until the fresh percentage catches up.
  private var lastPresentedBatchTotal = 0
  private var progressRebase: (display: Double, raw: Double)?
  // V2 ranged children report a subtotal of child bytes, not a whole-file
  // absolute byte count. Capture that subtotal at the foreground -> background
  // handoff and advance the system UI by its delta over the latest Dart parent
  // checkpoint.
  private var nativeAggregateBaselineTaskId = ""
  private var nativeAggregateBaselineBytes: Int64 = -1
  private var nativeParentBaselineBytes: Int64 = -1

  private init() {}

  private func resetNativeAggregateBaseline() {
    nativeAggregateBaselineTaskId = ""
    nativeAggregateBaselineBytes = -1
    nativeParentBaselineBytes = -1
  }

  /// Keep lifecycle evidence separate from display text, source URLs and errors.
  private func recordLifecycle(_ event: String, fields: [String: Any] = [:]) {
    var metadata = fields
    if let identifier { metadata["leaseIdentifier"] = identifier }
    if !currentEpisodeTaskId.isEmpty { metadata["taskId"] = currentEpisodeTaskId }
    if let requestSubmittedAt {
      metadata["requestAgeMillis"] = max(Int(Date().timeIntervalSince(requestSubmittedAt) * 1000), 0)
    }
    if let leaseStartedAt {
      metadata["leaseAgeMillis"] = max(Int(Date().timeIntervalSince(leaseStartedAt) * 1000), 0)
    }
    if let snapshot {
      metadata["progress"] = snapshot.progress
      metadata["transferredBytes"] = snapshot.transferredBytes
      metadata["totalBytes"] = snapshot.totalBytes
      metadata["completedCount"] = snapshot.completedCount
      metadata["batchTotal"] = snapshot.batchTotal
    }
    DownloadNativeDiagnosticLog.record(event, fields: metadata)
  }

  func start(
    taskId: String,
    displayName: String,
    progress: Double,
    totalBytes: Int64,
    transferredBytes: Int64 = -1,
    completedCount: Int = 0,
    batchTotal: Int = 1,
    speedBytesPerSecond: Double = 0,
    currentIndex: Int = 0,
    completedPages: Int? = nil,
    totalPages: Int? = nil
  ) throws -> String? {
    // BGContinuedProcessingTaskRequest itself validates that submission is
    // associated with the foreground app. Avoid an additional UIApplication
    // state check here: transient `.inactive` states during UI transitions can
    // otherwise make a user-initiated download silently skip system UI.

    let previousEpisodeTaskId = currentEpisodeTaskId
    if taskId != Self.sessionKey, !taskId.isEmpty {
      currentEpisodeTaskId = taskId
    }
    resetNativeAggregateBaseline()

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
      completedPages: completedPages,
      totalPages: totalPages,
      completedCount: max(completedCount, 0),
      batchTotal: max(batchTotal, 1),
      speedBytesPerSecond: keepSpeed,
      currentTaskId: currentEpisodeTaskId.isEmpty ? taskId : currentEpisodeTaskId,
      currentIndex: currentIndex > 0
        ? currentIndex
        : (self.snapshot?.currentIndex ?? 0)
    )
    if switched || self.snapshot == nil {
      nativePageFractions.removeAll()
      nativePageBaseline = nil
      lastNativePageActivityAt = 0
    }
    if speedBytesPerSecond >= 0 { lastSpeedSampleAt = Date().timeIntervalSinceReferenceDate }
    self.snapshot = snapshot

    if let active = activeTask {
      apply(snapshot, to: active)
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
      recordLifecycle("continued.submit.failed", fields: ["failure": "identifierNotPermitted"])
      identifier = nil
      throw DownloadContinuedProcessingError.identifierNotPermitted(sessionId)
    }

    // Unlike BGProcessingTask, iOS 26 continued-processing handlers may be
    // registered when user intent is expressed, after app launch (WWDC25/227).
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
        recordLifecycle("continued.submit.failed", fields: ["failure": "registrationRejected"])
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
    requestSubmittedAt = Date()
    recordLifecycle("continued.submit.requested")
    do {
      try scheduler.submit(request)
      recordLifecycle("continued.submit.accepted")
    } catch {
      recordLifecycle("continued.submit.failed", fields: [
        "failure": "schedulerSubmission",
        "errorCode": (error as NSError).code,
      ])
      identifier = nil
      requestSubmittedAt = nil
      throw error
    }
    return sessionId
  }

  func acceptsDartUpdate(
    inForeground: Bool,
    completedPages: Int?,
    taskId: String = "",
    progress: Double = -1,
    transferredBytes: Int64 = -1
  ) -> Bool {
    if DownloadPageProgress.acceptsDartUpdate(
      inForeground: inForeground, incomingPages: completedPages, currentPages: snapshot?.completedPages
    ) {
      return true
    }
    // Background, non-page session: the pure gate gives native observation
    // precedence because a briefly-woken Dart may hold a stale snapshot.
    // But a Dart kept alive by the lease reports authoritative durable
    // bytes, and a native feed that goes silent must not freeze the
    // presentation until the system expires the task. Accept only what a
    // stale snapshot cannot fake: a different episode Dart is driving, or
    // values that strictly advance the current presentation.
    guard let snapshot, completedPages == nil, snapshot.completedPages == nil
    else { return false }
    if !taskId.isEmpty, taskId != Self.sessionKey,
       taskId != snapshot.currentTaskId {
      return true
    }
    if transferredBytes >= 0 {
      return transferredBytes > snapshot.transferredBytes
    }
    return progress > snapshot.progress
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
    currentIndex: Int = -1,
    completedPages: Int? = nil,
    totalPages: Int? = nil,
    preserveNativeAggregateBaseline: Bool = false
  ) -> Bool {
    let previousEpisodeTaskId = currentEpisodeTaskId
    if taskId != Self.sessionKey, !taskId.isEmpty {
      currentEpisodeTaskId = taskId
    }
    guard var snapshot = snapshot else { return false }
    if !preserveNativeAggregateBaseline {
      resetNativeAggregateBaseline()
    }

    let switched = !previousEpisodeTaskId.isEmpty
      && taskId != Self.sessionKey
      && taskId != previousEpisodeTaskId

    if switched {
      nativePageFractions.removeAll()
      nativePageBaseline = nil
      lastNativePageActivityAt = 0
    }
    if speedBytesPerSecond >= 0 { lastSpeedSampleAt = Date().timeIntervalSinceReferenceDate }
    snapshot.progress = min(max(progress, 0.0), 1.0)
    snapshot.completedPages = completedPages
    snapshot.totalPages = totalPages
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
      presentIfDue(snapshot, to: task)
    }
    return activeTask != nil || identifier != nil
  }

  /// Native background URLSession observation may keep the existing iOS
  /// continued-processing overlay fresh while Dart is suspended. It may only
  /// update the episode that Dart already selected; it cannot switch tasks.
  func updateFromNativeIfCurrent(
    taskId: String,
    progress: Double? = nil,
    totalBytesHint: Int64 = -1,
    transferredBytes: Int64 = -1,
    speedBytesPerSecond: Double = -1
  ) -> Bool {
    // Manga page tasks have no Range metadata. Route only an exact page child
    // of the current generation; a child fraction is activity, not a validated
    // completed page. Dart alone owns the page count and chapter completion.
    if let current = snapshot, current.completedPages != nil,
       let total = current.totalPages, total > 0,
       taskId.hasPrefix(currentEpisodeTaskId + "_p"),
       taskId.dropFirst(currentEpisodeTaskId.count + 2).count >= 4,
       taskId.dropFirst(currentEpisodeTaskId.count + 2).allSatisfy({ $0.isASCII && $0.isNumber }),
       let progress, progress.isFinite, progress >= 0 {
      let fraction = min(progress, 1)
      let sample = nativePageFractions[taskId] ?? (initial: fraction, latest: fraction)
      nativePageFractions[taskId] = (sample.initial, max(sample.latest, fraction))
      if fraction > sample.latest {
        // A positive native fraction delta proves nonzero throughput even
        // when this callback does not expose a byte/s value to Dart.
        lastNativePageActivityAt = Date().timeIntervalSinceReferenceDate
      }
      if nativePageBaseline == nil { nativePageBaseline = current.progress }
      // Count only movement since first observation, including final progress
      // 1. A delayed first callback must not credit bytes already checkpointed
      // by Dart. Keep this baseline fixed as later Dart page counts catch up.
      let movement = nativePageFractions.values.reduce(0.0) { $0 + $1.latest - $1.initial }
      var next = current
      next.progress = max(current.progress, min((nativePageBaseline ?? 0) + movement / Double(total), 0.999))
      snapshot = next
      if let task = activeTask { presentIfDue(next, to: task) }
      return true
    }
    guard taskId == currentEpisodeTaskId,
          let current = snapshot
    else {
      // A native observation for a task the session does not own is the
      // signature of a silently broken background feed; make it visible in
      // the diagnostic log instead of dropping it without a trace.
      if snapshot != nil, taskId != lastNativeRejectionTaskId {
        lastNativeRejectionTaskId = taskId
        recordLifecycle("continued.native.rejected", fields: ["taskId": taskId])
      }
      return false
    }

    guard current.completedPages == nil else { return false }

    let totalBytes = current.totalBytes > 0
      ? current.totalBytes
      : totalBytesHint

    let hasAuthoritativeByteCoverage =
      progress == nil
      && transferredBytes >= 0
      && current.totalBytes > 0
      && totalBytesHint >= current.totalBytes

    var nextProgress = progress.map { min(max($0, 0), 1) }
      ?? current.progress
    var nextTransferred = transferredBytes >= 0
      ? transferredBytes
      : current.transferredBytes
    let currentTransferred = max(current.transferredBytes, 0)

    let hasChildAggregateOnly =
      progress == nil
      && transferredBytes >= 0
      && !hasAuthoritativeByteCoverage

    if hasChildAggregateOnly {
      if nativeAggregateBaselineTaskId != taskId
        || nativeAggregateBaselineBytes < 0
        || nativeParentBaselineBytes < 0
        || transferredBytes < nativeAggregateBaselineBytes {
        nativeAggregateBaselineTaskId = taskId
        nativeAggregateBaselineBytes = transferredBytes
        nativeParentBaselineBytes = currentTransferred
      }
      let aggregateDelta = transferredBytes - nativeAggregateBaselineBytes
      nextTransferred = nativeParentBaselineBytes + max(aggregateDelta, 0)
    }

    if hasAuthoritativeByteCoverage {
      // Once every range is represented, aggregated bytes describe the whole
      // file and may correct an older inflated partial-denominator snapshot.
      nextTransferred = min(max(transferredBytes, 0), totalBytes)
      nextProgress = Double(nextTransferred) / Double(totalBytes)
    } else {
      nextProgress = max(current.progress, nextProgress)
      if totalBytes > 0 {
        let progressBytes = overlayTransferredBytes(
          progress: nextProgress,
          totalBytes: totalBytes
        )
        nextTransferred = min(
          max(max(nextTransferred, currentTransferred), progressBytes),
          totalBytes
        )
        nextProgress = max(
          nextProgress,
          Double(nextTransferred) / Double(totalBytes)
        )
      } else {
        nextTransferred = max(nextTransferred, currentTransferred)
      }
    }

    return update(
      taskId: taskId,
      progress: nextProgress,
      totalBytes: totalBytes,
      transferredBytes: nextTransferred,
      speedBytesPerSecond: speedBytesPerSecond,
      preserveNativeAggregateBaseline: true
    )
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
    stopPulse()
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
        && (snapshot.completedPages == nil
          || ((snapshot.totalPages ?? 0) > 0
            && (snapshot.completedPages ?? 0) >= (snapshot.totalPages ?? 0)))
    } else {
      snapshotLooksComplete = false
    }
    let verifiedSuccess = success && snapshotLooksComplete

    if activeTask != nil || identifier != nil {
      recordLifecycle("continued.finished", fields: [
        "activeLease": activeTask != nil,
        "success": verifiedSuccess,
        "status": verifiedSuccess ? "completed" : (status == "canceled" ? "canceled" : "paused"),
      ])
    }

    if let task = activeTask {
      #if canImport(background_downloader)
      AnimeWitcherDownloadSessions.deactivate(task)
      #endif
      activeTask = nil
      let completion = activeTaskCompletion
      activeTaskCompletion = nil
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
      if let completion {
        completion.finish { task.setTaskCompleted(success: verifiedSuccess) }
      } else {
        task.setTaskCompleted(success: verifiedSuccess)
      }
    }

    progressRebase = nil
    lastPresentedBatchTotal = 0
    snapshot = nil
    identifier = nil
    requestSubmittedAt = nil
    leaseStartedAt = nil
    currentEpisodeTaskId = ""
    lastPresentationAt = 0
    nativePageFractions.removeAll()
    nativePageBaseline = nil
    lastNativePageActivityAt = 0
    lastSpeedSampleAt = 0
    resetNativeAggregateBaseline()
  }

  private func attach(_ task: BGContinuedProcessingTask) {
    // Canceling a request cannot retract an already-delivered launch callback.
    guard identifier == task.identifier, snapshot != nil else {
      recordLifecycle("continued.attach.rejected", fields: [
        "leaseIdentifier": task.identifier, "failure": "inactiveSession",
      ])
      task.setTaskCompleted(success: false)
      return
    }
    if let activeTask {
      if activeTask !== task {
        recordLifecycle("continued.attach.rejected", fields: [
          "leaseIdentifier": task.identifier, "failure": "duplicateLease",
        ])
        task.setTaskCompleted(success: false)
      }
      return
    }

    activeTask = task
    #if canImport(background_downloader)
    AnimeWitcherDownloadSessions.activate(task)
    #endif
    let completion = DownloadContinuedProcessingCompletion()
    activeTaskCompletion = completion
    let attachedAt = Date()
    leaseStartedAt = attachedAt
    let leaseIdentifier = task.identifier

    task.expirationHandler = { [weak self, weak task] in
      guard let task else { return }
      // Revoke direct request admission before relinquishing runtime, even if
      // main-actor cleanup is delayed. Concrete identity fences stale expiry.
      #if canImport(background_downloader)
      AnimeWitcherDownloadSessions.deactivate(task)
      #endif
      // Log synchronously before relinquishing runtime. Expiration does not
      // expose a reason, and must not be labelled as a user cancellation.
      DownloadNativeDiagnosticLog.record("continued.expired", fields: [
        "leaseIdentifier": leaseIdentifier,
        "leaseAgeMillis": max(Int(Date().timeIntervalSince(attachedAt) * 1000), 0),
        "completedUnits": task.progress.completedUnitCount,
        "totalUnits": task.progress.totalUnitCount,
      ])
      completion.finish { task.setTaskCompleted(success: false) }
      Task { @MainActor in
        guard let self, self.activeTask === task else { return }

        // Apple uses this reasonless callback for both OS expiration and a
        // person stopping the task in the system UI. Our continuity policy
        // releases this lease without canceling independent URLSession work;
        // treating every callback as app cancellation would also stop downloads
        // on ordinary OS expiry. System UI stop therefore cannot be a reliable
        // download cancel action here. Explicit in-app cancellation remains
        // owned by the download coordinator. See download_background_lifecycle.md.
        self.activeTask = nil
        self.activeTaskCompletion = nil
        self.progressRebase = nil
        self.lastPresentedBatchTotal = 0
        self.snapshot = nil
        self.identifier = nil
        self.requestSubmittedAt = nil
        self.leaseStartedAt = nil
        self.currentEpisodeTaskId = ""
        self.lastPresentationAt = 0
        self.nativePageFractions.removeAll()
        self.nativePageBaseline = nil
        self.lastNativePageActivityAt = 0
        self.lastSpeedSampleAt = 0
        self.stopPulse()
        self.resetNativeAggregateBaseline()
      }
    }

    recordLifecycle("continued.attached")

    // A fresh task starts a fresh presentation clock: attach presents the
    // checkpoint immediately, and the first progress update after attach
    // also presents immediately; the once-per-second gate applies from
    // there on.
    lastPresentationAt = 0
    progressRebase = nil
    lastPresentedBatchTotal = 0
    if let snapshot {
      apply(snapshot, to: task)
    } else {
      task.progress.totalUnitCount = 1000
      task.progress.completedUnitCount = 0
    }
    startPulse()
  }

  /// Applies a progress presentation only when the shared clock says the
  /// task is due for one — at most once per
  /// `DownloadPresentationPulse.interval`. A skipped presentation is not
  /// lost: the caller has already stored the snapshot, and the pulse tick
  /// presents the latest stored snapshot on a later beat.
  private func presentIfDue(
    _ snapshot: Snapshot,
    to task: BGContinuedProcessingTask
  ) {
    let now = Date().timeIntervalSinceReferenceDate
    guard now - lastPresentationAt >= DownloadPresentationPulse.interval
    else { return }
    lastPresentationAt = now
    apply(snapshot, to: task)
  }

  private func apply(
    _ snapshot: Snapshot,
    to task: BGContinuedProcessingTask
  ) {
    let normalized = min(max(snapshot.progress, 0.0), 1.0)

    // The system task represents the whole queue. Resetting it to each
    // episode's percentage can leave iOS seeing no forward work even while
    // the next episode downloads. Sub-page precision also avoids waiting for
    // a complete page (or a rounded MB) to demonstrate real network progress.
    let fraction: Double
    if let completed = snapshot.completedPages {
      let durable = DownloadPageProgress.fraction(
        completed: completed, total: snapshot.totalPages ?? -1, progress: normalized
      )
      fraction = max(durable, min(normalized, 0.999))
    } else {
      fraction = normalized
    }
    if snapshot.batchTotal > 1 || snapshot.completedPages != nil {
      let batch = Double(max(snapshot.batchTotal, 1))
      let sessionFraction = min((Double(snapshot.completedCount) + fraction) / batch, 0.999_999_999)
      if lastPresentedBatchTotal > 0 && snapshot.batchTotal > lastPresentedBatchTotal {
        progressRebase = (display: task.progress.fractionCompleted, raw: sessionFraction)
      }
      lastPresentedBatchTotal = snapshot.batchTotal
      let reweighted: Double
      if let progressRebase {
        let remainingRaw = max(1 - progressRebase.raw, 0.000_001)
        reweighted = progressRebase.display
          + max(sessionFraction - progressRebase.raw, 0)
            * (1 - progressRebase.display) / remainingRaw
      } else {
        reweighted = sessionFraction
      }
      let monotonic = min(max(task.progress.fractionCompleted, reweighted), 0.999_999_999)
      task.progress.totalUnitCount = 1_000_000_000_000
      task.progress.completedUnitCount = Int64((monotonic * 1_000_000_000_000).rounded(.down))
    } else if snapshot.totalBytes > 0 {
      task.progress.totalUnitCount = snapshot.totalBytes
      task.progress.completedUnitCount = min(max(snapshot.transferredBytes, 0), snapshot.totalBytes)
    } else {
      task.progress.totalUnitCount = 1_000_000_000_000
      task.progress.completedUnitCount = Int64((fraction * 1_000_000_000_000).rounded(.down))
    }

    task.updateTitle(
      title(for: snapshot),
      subtitle: subtitle(for: snapshot)
    )
  }

  private func startPulse() {
    guard pulseTimer == nil else { return }
    let timer = Timer(
      timeInterval: DownloadPresentationPulse.interval, repeats: true
    ) { [weak self] _ in
      Task { @MainActor in self?.pulseTick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    pulseTimer = timer
  }

  private func stopPulse() {
    pulseTimer?.invalidate()
    pulseTimer = nil
    pulseFilled = true
  }

  /// Speed controls the activity indicator, not completion or lease ownership.
  /// An old nonzero sample must not keep claiming activity on a stalled socket.
  private func pulseTick() {
    guard let task = activeTask, let snapshot else {
      stopPulse()
      return
    }
    let now = Date().timeIntervalSinceReferenceDate
    let hasMeasuredSpeed = snapshot.speedBytesPerSecond.isFinite
      && snapshot.speedBytesPerSecond > 0 && now - lastSpeedSampleAt < 3
    if hasMeasuredSpeed || now - lastNativePageActivityAt < 3 {
      pulseFilled.toggle()
    } else {
      pulseFilled = false
    }
    presentIfDue(snapshot, to: task)
  }

  private func cancelPendingRequest() {
    guard let identifier else { return }
    scheduler.cancel(taskRequestWithIdentifier: identifier)
  }

  private func sessionIdentifier() throws -> String {
    guard let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty else {
      recordLifecycle("continued.submit.failed", fields: ["failure": "missingBundleIdentifier"])
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
    DownloadPresentationPulse.title(
      displayName: snapshot.displayName, filled: pulseFilled
    )
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
    if let completed = snapshot.completedPages {
      parts.append(DownloadPageProgress.label(completed: completed, total: snapshot.totalPages ?? -1))
    } else if snapshot.totalBytes > 0 {
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

