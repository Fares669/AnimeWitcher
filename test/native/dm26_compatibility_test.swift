import Foundation

// Compile with the production compatibility file, not a reimplementation.
@main
enum DM26CompatibilityTests {
  static func main() {
    let observations = DownloadTerminalObservation()
    observations.record(taskId: "reused", succeeded: true) // delayed old status
    let newExecution = NSObject()
    let missing = observations.capture(execution: newExecution, taskId: "reused") {}
    precondition(missing == nil, "old terminal status must not classify a new execution")
    let failed = observations.capture(execution: newExecution, taskId: "reused") {
      observations.record(taskId: "other", succeeded: true)
      observations.record(taskId: "reused", succeeded: false)
    }
    precondition(failed == false, "the current plugin file-move failure must be retained")
    let later = observations.capture(execution: NSObject(), taskId: "reused") {}
    precondition(later == nil, "status must not survive its native delegate invocation")

    let old = DownloadExecutionCallbacks()
    old.retire()
    precondition(!old.beginFinish() && !old.beginComplete(), "retry predecessor is fenced")
    let current = DownloadExecutionCallbacks()
    precondition(current.beginFinish())
    precondition(!current.beginFinish(), "duplicate finish must not promote twice")
    precondition(current.beginComplete(), "plugin still needs its success cleanup")
    precondition(!current.hasSettledCompletion, "beginComplete alone is not plugin settlement")
    current.markCompletionSettled()
    precondition(current.hasSettledCompletion)
    precondition(!current.beginComplete(), "duplicate complete must not settle twice")

    // Every unavailable/partial combination must leave ALL implementations alone.
    for version in ["9.6.1", "9.6.2", "9.6.4"] {
      for mask in 0..<7 {
        let installer = DownloadHookInstallation()
        var writes = 0
        let available = (0..<3).map { mask & (1 << $0) != 0 }
        precondition(!installer.install(version: version, available: available) { writes += 1 })
        precondition(writes == 0 && !installer.isInstalled && !installer.rangePromotionAvailable)
        precondition(!installer.install(version: version, available: [true, true, true]) { writes += 1 },
                     "observer installation must not claim transport ownership")
        precondition(writes == 1 && installer.isInstalled && installer.rangePromotionAvailable,
                     "a validated observation seam grants only immutable V2 range promotion")
        precondition(!installer.install(version: version, available: [true, true, true]) { writes += 1 },
                     "observer installation must not claim transport ownership")
        precondition(writes == 1 && installer.isInstalled, "reinstall must not wrap its own IMP or claim ownership")
      }
    }
    for version in [nil, "0.0.1", "9.6.0", "9.6.3", "9.6.5", "9.7.0"] as [String?] {
      let installer = DownloadHookInstallation()
      precondition(!installer.install(version: version, available: [true, true, true]) {
        preconditionFailure("unsupported package must not install")
      })
      precondition(!installer.isInstalled && !installer.rangePromotionAvailable)
    }

    let parent = "aw_v2_test"
    let currentRange = DownloadRangeIdentity(taskId: parent + ".part.0", parentTaskId: parent, generation: 2)!
    let olderRange = DownloadRangeIdentity(taskId: parent + ".part.0", parentTaskId: parent, generation: 1)!
    precondition(currentRange.canRevoke(olderRange))
    precondition(!olderRange.canRevoke(currentRange), "stale Dart attempt cannot revoke a newer native claim")
    precondition(DownloadRangeIdentity(taskId: parent + ".part.bad", parentTaskId: parent, generation: 1) == nil)
    precondition(DownloadRangeIdentity(taskId: parent + ".part.0", parentTaskId: "other", generation: 1) == nil)
    precondition(DownloadRangeIdentity(taskId: parent + ".part.0", parentTaskId: parent, generation: 0) == nil)
    precondition(DownloadRangeIdentity.positiveInteger(true) == nil)
    precondition(DownloadRangeIdentity.positiveInteger(1.5) == nil)
    precondition(DownloadRangeIdentity.positiveInteger(2) == 2)
    let metadata = #"{\"parentTaskId\":\"aw_v2_test\",\"attemptGeneration\":2}"#
    let taskJson = "{\"taskId\":\"aw_v2_test.part.0\",\"group\":\"animewitcher_parts\",\"metaData\":\"" + metadata + "\"}"
    precondition(DownloadRangeIdentity.from(taskJson: taskJson) == currentRange)
    precondition(DownloadRangeIdentity.from(taskJson: taskJson.replacingOccurrences(of: "animewitcher_parts", with: "chunk")) == nil,
                 "plugin parallel chunks cannot grant V2 range ownership")
    print("DM-26 compatibility behavior: PASS")
  }
}
