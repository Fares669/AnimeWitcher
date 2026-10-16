"""Exercise the production continued-processing manager with platform fakes.

The scheduler can deliver a launch after cancellation, as in the device log.
Only the Apple task/scheduler and bundle boundaries are replaced; all manager
state transitions and completion logic are compiled from the production file.
This portable test does not replace an iOS build or real-device overlay check.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "ios/Runner/DownloadContinuedProcessingManager.swift").read_text()
SOURCE = SOURCE.removeprefix("#if os(iOS)\n").rstrip().removesuffix("#endif")
SOURCE = SOURCE.replace("import BackgroundTasks\n", "").replace("import UIKit\n", "")
SOURCE = SOURCE.replace("Bundle.main", "TestBundle.main")

FAKES = r'''
struct TestBundle {
  static let main = TestBundle()
  var bundleIdentifier: String? { "com.animewitcher.test" }
  func object(forInfoDictionaryKey key: String) -> Any? {
    ["com.animewitcher.test.download.*"]
  }
}
class BGTask {
  let identifier: String
  var expirationHandler: (() -> Void)?
  var completions: [Bool] = []
  init(identifier: String) { self.identifier = identifier }
  func setTaskCompleted(success: Bool) { completions.append(success) }
}
final class BGContinuedProcessingTask: BGTask {
  let progress = Progress(totalUnitCount: 0)
  var titles: [String] = []
  func updateTitle(_ title: String, subtitle: String) { titles.append(title) }
}
final class BGContinuedProcessingTaskRequest {
  enum Strategy { case queue }
  let identifier: String
  var strategy = Strategy.queue
  init(identifier: String, title: String, subtitle: String) { self.identifier = identifier }
}
final class BGTaskScheduler {
  static let shared = BGTaskScheduler()
  var handler: ((BGTask) -> Void)?
  var requests: [BGContinuedProcessingTaskRequest] = []
  var canceled: [String] = []
  func register(forTaskWithIdentifier id: String, using queue: DispatchQueue?,
                launchHandler: @escaping (BGTask) -> Void) -> Bool {
    handler = launchHandler
    return true
  }
  func submit(_ request: BGContinuedProcessingTaskRequest) throws { requests.append(request) }
  func cancel(taskRequestWithIdentifier id: String) { canceled.append(id) }
  func deliver(_ task: BGTask) { handler!(task) }
}
enum DownloadNativeDiagnosticLog {
  static var events: [String] = []
  static var fieldsByEvent: [String: [[String: Any]]] = [:]
  static func record(_ event: String, fields: [String: Any] = [:]) {
    events.append(event)
    fieldsByEvent[event, default: []].append(fields)
  }
}
'''

CHECKS = r'''
struct CheckFailure: Error, CustomStringConvertible { let description: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw CheckFailure(description: message) }
}
@main enum LifecycleChecks {
  @MainActor static func drainCallbacks() async {
    for _ in 0..<20 { await Task.yield() }
  }
  @MainActor static func main() async {
    do {
      try await run(CommandLine.arguments[1])
      print("PASS: " + CommandLine.arguments[1])
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }
  @MainActor static func run(_ scenario: String) async throws {
    let manager = DownloadContinuedProcessingManager.shared
    let scheduler = BGTaskScheduler.shared
    let id = try manager.start(taskId: "episode", displayName: "Episode", progress: 0.14,
                               totalBytes: 100, transferredBytes: 14)!
    let task = BGContinuedProcessingTask(identifier: id)
    switch scenario {
    case "cancel-before-attach":
      manager.stop(taskId: "session", endSession: true)
      scheduler.deliver(task)
      await drainCallbacks()
      try check(task.completions == [false], "a late launch after cancellation must be completed immediately")
      try check(task.titles.isEmpty, "a canceled session must not attach an orphan overlay")
      try check(!manager.update(taskId: "episode", progress: 0.14, totalBytes: 100), "the canceled session stays inactive")
      manager.stop(taskId: "session", endSession: true)
      try check(task.completions == [false], "a rejected task must not be completed twice")
    case "finish-before-attach":
      manager.finish(taskId: "session", success: true, status: "completed", endSession: true)
      scheduler.deliver(task)
      await drainCallbacks()
      try check(task.completions == [false], "a launch after session finish must not revive the session")
    case "cancel-between-delivery-and-actor-hop":
      scheduler.deliver(task)
      manager.stop(taskId: "session", endSession: true)
      await drainCallbacks()
      try check(task.completions == [false], "cancel must win before the queued main-actor attachment executes")
      try check(task.titles.isEmpty, "the queued callback must not resurrect a stopped overlay")
    case "valid-attach-and-stop":
      scheduler.deliver(task)
      await drainCallbacks()
      try check(task.completions.isEmpty && task.progress.completedUnitCount == 14, "a live session attaches with its checkpoint")
      try check(manager.update(taskId: "episode", progress: 0.25, totalBytes: 100), "a live lease accepts progress")
      try check(task.progress.completedUnitCount == 25, "the real manager updates the attached lease")
      manager.stop(taskId: "session", endSession: true)
      manager.stop(taskId: "session", endSession: true)
      try check(task.completions == [false], "stop completes the lease exactly once")
      try check(task.expirationHandler == nil, "explicit stop detaches the expiration callback")
      try check(scheduler.canceled == [id], "explicit stop withdraws the pending request once")
      try check(!DownloadNativeDiagnosticLog.events.contains("continued.expired"),
                "explicit app stop is not an ambiguous expiration")
      try check(DownloadNativeDiagnosticLog.fieldsByEvent["continued.finished"]?.last?["status"] as? String == "canceled",
                "explicit app stop records a known canceled status")
    case "duplicate-attach":
      scheduler.deliver(task)
      await drainCallbacks()
      let duplicate = BGContinuedProcessingTask(identifier: id)
      scheduler.deliver(duplicate)
      await drainCallbacks()
      try check(duplicate.completions == [false], "an additional task cannot overwrite and leak the current lease")
      manager.stop(taskId: "session", endSession: true)
      try check(task.completions == [false], "the original active task remains owned until stop")
    case "repeat-same-task":
      scheduler.deliver(task)
      await drainCallbacks()
      scheduler.deliver(task)
      await drainCallbacks()
      try check(task.completions.isEmpty, "a repeated callback for the owned task must not finish it")
      manager.stop(taskId: "session", endSession: true)
      try check(task.completions == [false], "the owned task still completes once")
    case "wrong-identifier":
      let wrong = BGContinuedProcessingTask(identifier: id + ".stale")
      scheduler.deliver(wrong)
      await drainCallbacks()
      try check(wrong.completions == [false], "an unrelated identifier must not acquire the current session")
      scheduler.deliver(task)
      await drainCallbacks()
      manager.stop(taskId: "session", endSession: true)
      try check(task.completions == [false], "rejecting a stale task must preserve the pending current request")
    case "expiration-only":
      scheduler.deliver(task)
      await drainCallbacks()
      task.expirationHandler!()
      try check(task.completions == [false], "expiration acknowledges the OS before the main-actor cleanup")
      try check(scheduler.canceled.isEmpty, "ambiguous expiration must not issue an explicit cancellation")
      await drainCallbacks()
      try check(!manager.update(taskId: "episode", progress: 0.25, totalBytes: 100),
                "expiration releases the old presentation lease")
      try check(scheduler.requests.count == 1, "expiration must not submit a replacement background lease")
      try check(DownloadNativeDiagnosticLog.events.contains("continued.expired")
                && !DownloadNativeDiagnosticLog.events.contains("continued.finished"),
                "expiration is not relabeled as an explicit stop or successful download")
      let fields = DownloadNativeDiagnosticLog.fieldsByEvent["continued.expired"]!.last!
      try check(fields["reason"] == nil && fields["status"] == nil,
                "a reasonless Apple callback must not fabricate a user-cancel reason")
    case "expiration-and-stop", "stop-and-expiration":
      scheduler.deliver(task)
      await drainCallbacks()
      let expiration = task.expirationHandler!
      if scenario == "stop-and-expiration" {
        manager.stop(taskId: "session", endSession: true)
      }
      expiration()
      manager.stop(taskId: "session", endSession: true)
      await drainCallbacks()
      expiration()
      await drainCallbacks()
      try check(task.completions == [false], "expiration racing explicit stop acknowledges the OS once")
    case "restart-late-old-first", "restart-late-new-first":
      manager.stop(taskId: "session", endSession: true)
      let nextId = try manager.start(taskId: "new-episode", displayName: "New Episode", progress: 0.60,
                                    totalBytes: 100, transferredBytes: 60)!
      try check(nextId == id, "the regression must reuse the fixed scheduler identifier")
      let next = BGContinuedProcessingTask(identifier: nextId)
      // Exercise each ordering explicitly; do not assume the scheduler is FIFO.
      let first = scenario == "restart-late-old-first" ? task : next
      let second = first === task ? next : task
      scheduler.deliver(first)
      await drainCallbacks()
      scheduler.deliver(second)
      await drainCallbacks()
      try check(first.completions.isEmpty && second.completions == [false],
                "exactly one same-identifier lease can own the live umbrella session")
      try check(first.progress.completedUnitCount == 60 && first.titles.last == "Downloading “New Episode”",
                "the owning lease must bind the current valid snapshot, never the canceled episode")
      try check(manager.update(taskId: "new-episode", progress: 0.70, totalBytes: 100),
                "rejecting the additional lease cannot deactivate the current session")
      try check(first.progress.completedUnitCount == 70 && second.titles.isEmpty,
                "only the owned lease receives the new episode progress")
      manager.stop(taskId: "session", endSession: true)
      try check(task.completions == [false] && next.completions == [false],
                "both concrete leases must finish exactly once after the new session stops")
    case "old-expiration-after-restart", "queued-old-expiration-during-restart":
      scheduler.deliver(task)
      await drainCallbacks()
      let oldExpiration = task.expirationHandler!
      if scenario == "queued-old-expiration-during-restart" {
        oldExpiration()
      }
      manager.stop(taskId: "session", endSession: true)
      let nextId = try manager.start(taskId: "new-episode", displayName: "New Episode", progress: 0.60,
                                    totalBytes: 100, transferredBytes: 60)!
      try check(nextId == id, "expiration fencing must use concrete task identity, not the reused identifier")
      let next = BGContinuedProcessingTask(identifier: nextId)
      scheduler.deliver(next)
      await drainCallbacks()
      oldExpiration()
      await drainCallbacks()
      try check(task.completions == [false] && next.completions.isEmpty,
                "an old expiration cannot finish the new concrete lease")
      try check(manager.update(taskId: "new-episode", progress: 0.70, totalBytes: 100),
                "an old expiration callback must not clear the current snapshot or identifier")
      try check(next.progress.completedUnitCount == 70, "the new lease still receives current progress")
      manager.stop(taskId: "session", endSession: true)
      try check(next.completions == [false], "the new lease stays owned until its own stop")
    default: throw CheckFailure(description: "unknown scenario")
    }
  }
}
'''

swiftc = shutil.which("swiftc")
if not swiftc:
    raise SystemExit("Swift compiler is required for the production lifecycle behavior test")
flags = []
if os.environ.get("SWIFT_MODULE_CACHE"):
    flags += ["-module-cache-path", os.environ["SWIFT_MODULE_CACHE"], "-use-ld=lld"]

with tempfile.TemporaryDirectory(prefix="continued-processing-lifecycle-") as directory:
    main = Path(directory) / "lifecycle.swift"
    main.write_text("import Foundation\n" + FAKES + SOURCE + CHECKS)
    executable = Path(directory) / "checks"
    subprocess.run([swiftc, *flags, "-parse-as-library", str(main), "-o", str(executable)], check=True)
    failures = []
    for scenario in (
        "cancel-before-attach", "finish-before-attach", "cancel-between-delivery-and-actor-hop",
        "valid-attach-and-stop", "duplicate-attach", "repeat-same-task", "wrong-identifier",
        "expiration-only", "expiration-and-stop", "stop-and-expiration",
        "restart-late-old-first", "restart-late-new-first",
        "old-expiration-after-restart", "queued-old-expiration-during-restart",
    ):
        result = subprocess.run([str(executable), scenario], check=False)
        if result.returncode:
            failures.append(scenario)
    if failures:
        raise SystemExit("Failed lifecycle scenarios: " + ", ".join(failures))
