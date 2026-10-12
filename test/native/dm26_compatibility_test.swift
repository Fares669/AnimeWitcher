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
    precondition(!current.beginComplete(), "duplicate complete must not settle twice")

    // Every unavailable/partial combination must leave ALL implementations alone.
    for mask in 0..<7 {
      let installer = DownloadHookInstallation()
      var writes = 0
      let available = (0..<3).map { mask & (1 << $0) != 0 }
      precondition(!installer.install(version: "9.6.1", available: available) { writes += 1 })
      precondition(writes == 0 && !installer.isInstalled)
      precondition(!installer.install(version: "9.6.1", available: [true, true, true]) { writes += 1 },
                   "observer installation must not claim transport ownership")
      precondition(writes == 1 && installer.isInstalled, "a partial attempt must not suppress recovery")
      precondition(!installer.install(version: "9.6.1", available: [true, true, true]) { writes += 1 },
                   "observer installation must not claim transport ownership")
      precondition(writes == 1 && installer.isInstalled, "reinstall must not wrap its own IMP or claim ownership")
    }
    for version in [nil, "0.0.1", "9.6.2"] as [String?] {
      let installer = DownloadHookInstallation()
      precondition(!installer.install(version: version, available: [true, true, true]) {
        preconditionFailure("unsupported package must not install")
      })
      precondition(!installer.isInstalled)
    }
    print("DM-26 compatibility behavior: PASS")
  }
}
