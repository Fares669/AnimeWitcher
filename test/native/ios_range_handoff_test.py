"""Execute production range queue transactions with deterministic platform fakes.

This is a portable Swift behavior test, not an iOS framework/build substitute.
Only UIKit, storage, task enumeration and URLSession execution are faked; the
claim, snapshot, expiry, selection and resume transactions are extracted verbatim
from production so concurrency regressions exercise the actual implementation.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
QUEUE = (ROOT / "ios/Runner/DownloadNativeWaitingQueue.swift").read_text()
COMPAT = (ROOT / "ios/Runner/DownloadCallbackCompatibility.swift").read_text()
COMPAT = COMPAT[:COMPAT.index("struct DownloadFilePromotionError")].replace("import Darwin", "")
RETRY_METADATA = QUEUE[QUEUE.index("enum DownloadNativeRetryMetadata"):QUEUE.index("/// Keep the large queue")]
RETRY_METADATA = RETRY_METADATA.replace("UserDefaults.standard", 'UserDefaults(suiteName: "animewitcher.range-handoff-tests")!')
COMPAT += "\n" + RETRY_METADATA



def declaration(marker):
    start = QUEUE.index(marker)
    end = QUEUE.index("\n  }", start) + len("\n  }")
    return QUEUE[start:end]


def function(name):
    for prefix in ("  private static func ", "  static func "):
        marker = prefix + name + "("
        if marker in QUEUE:
            return declaration(marker)
    raise AssertionError(name)


TYPES = "\n".join(declaration("  struct " + name + ":") for name in (
    "Waiter", "MultipartPlan", "MultipartClaim", "RunningSample", "State"))
FUNCTIONS = "\n".join(function(name) for name in (
    "persist", "nowMillis", "nowMicros", "rangeParentId", "rangeIdentity", "isImmutableRangeWaiter",
    "parentMayRefillLocked", "requeueExpiredMultipartClaimsLocked",
    "releaseMultipartClaim", "commitMultipartClaimBeforeResume",
    "claimRangeForDart", "withdrawRangeParent", "settleMultipartClaim", "recordCompletedRange",
    "retainingPendingRangeCompletions", "rememberDownloadSession",
    "promoteMultipartIfPossible", "promoteMultipartPlan",
    "finishMultipartPromotionPass", "scanMultipartPlan", "startMultipartChild",
    "unique", "clamp", "string", "stringArray", "dictionaryArray", "stringMap",
    "intValue", "doubleValue", "int64Value", "urlFromTaskJson", "filenameFromTaskJson",
    "stringFromTaskJson"))
# rangeIdentity has a waiter and URLSessionTask overload, both used by production.
FUNCTIONS += "\n" + declaration("  private static func rangeIdentity(for task:")

FAKES = r'''
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class URLSessionTask: @unchecked Sendable {
  enum State { case running, suspended, canceling, completed }
  static let highPriority: Float = 0.75
  var taskDescription: String?
  var state = State.suspended
  var priority: Float = 0
  var resumes = 0
  func resume() { resumes += 1; state = .running }
}
typealias URLSessionDownloadTask = URLSessionTask
final class URLSession: @unchecked Sendable {
  var tasks: [URLSessionTask] = []
  var queries: [([URLSessionTask]) -> Void] = []
  func getAllTasks(completionHandler: @escaping ([URLSessionTask]) -> Void) { queries.append(completionHandler) }
  func downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
    let task = URLSessionTask(); tasks.append(task); return task
  }
  func answer(_ snapshot: [URLSessionTask]? = nil) {
    let query = queries.removeFirst(); query(snapshot ?? tasks)
  }
}
enum DownloadUrlSessionHook {
  static var observations: [ObjectIdentifier: DownloadExecutionCallbacks] = [:]
  static func callbacks(for task: URLSessionTask) -> DownloadExecutionCallbacks {
    let key = ObjectIdentifier(task)
    if let value = observations[key] { return value }
    let value = DownloadExecutionCallbacks(); observations[key] = value; return value
  }
}
enum DownloadNativeDiagnosticLog {
  static func record(_ event: String, task: URLSessionTask) {}
}
enum DownloadNativeQueueEncryption { static let keyMissing = false }
'''

STATE = r'''
  private static let lock = NSLock()
  private static var stateReadFailed = false
  private static var pendingRangeCompletions: [String: Int] = [:]
  static var saveSucceeds = true
  static var stored = State(maxConcurrent: 2, transferringTaskIds: [], pausedTaskIds: [], waiters: [])
  static var foreground = false
  static let nativePromotionAvailable = true
  private static var seenTransferringIds = Set<String>()
  private static var multipartChildSamples: [String: [String: RunningSample]] = [:]
  private static var lastMultipartOverlayTimes: [String: Double] = [:]
  private static var latestDownloadSession: URLSession?
  private static var multipartPromotionParents = Set<String>()
  private static var multipartPromotionPendingParents = Set<String>()
  private static var multipartPromotionCompletions: [String: [() -> Void]] = [:]
  private static var nativeMultipartTasksByClaimId: [String: URLSessionTask] = [:]
  private static func isAppInForeground() -> Bool { foreground }
  private static func loadLocked() -> State { retainingPendingRangeCompletions(stored) }
  @discardableResult private static func saveLocked(_ state: State) -> Bool {
    guard saveSucceeds else { return false }
    stored = retainingPendingRangeCompletions(state)
    pendingRangeCompletions = [:]
    return true
  }
'''

CHECKS = r'''
  static let parent = "aw_v2_test"
  static func waiter(_ index: Int, generation: Int = 1, lease: Int = 30000) -> Waiter {
    let id = parent + ".part.\(index)"
    let metadata = try! JSONSerialization.data(withJSONObject: ["parentTaskId": parent, "attemptGeneration": generation])
    let object: [String: Any] = ["taskId": id, "url": "https://example.test/media", "filename": "\(index).part",
      "directory": "movie.parts", "headers": ["Range": "bytes=\(index * 10)-\(index * 10 + 9)"],
      "group": "animewitcher_parts", "httpRequestMethod": "GET", "metaData": String(data: metadata, encoding: .utf8)!]
    let json = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    return Waiter.from(arguments: ["taskId": id, "taskJson": json, "url": object["url"]!, "filename": object["filename"]!,
      "directory": object["directory"]!, "headers": object["headers"]!, "group": "animewitcher_parts", "progress": 0,
      "expectedBytes": 10, "generation": generation, "claimId": "\(id):g\(generation)", "claimLeaseMillis": lease])!
  }
  static func payload(_ waiter: Waiter) -> [String: Any] {
    ["taskId": waiter.taskId, "taskJson": waiter.taskJson, "url": waiter.url, "filename": waiter.filename,
      "directory": waiter.directory, "headers": waiter.headers, "group": waiter.group, "progress": 0,
      "expectedBytes": 10, "generation": waiter.generation!, "claimId": waiter.claimId!, "claimLeaseMillis": 30000]
  }
  static func plans(_ waiters: [Waiter]) -> [[String: Any]] {
    [["parentTaskId": parent, "maxConcurrent": 2, "waiters": waiters.map(payload)]]
  }
  static func claim(_ waiter: Waiter, committed: Bool = false, committedAt: Int64? = nil, expires: Int64? = nil) -> MultipartClaim {
    MultipartClaim(parentTaskId: parent, maxConcurrent: 2, waiter: waiter, generation: waiter.generation!, claimId: waiter.claimId!,
      expiresAtMillis: expires ?? (nowMillis() + 30000), launchCommitted: committed, launchCommittedAtMillis: committedAt)
  }
  static func reset(_ waiters: [Waiter], claims: [MultipartClaim] = [], width: Int = 2) {
    foreground = false
    DownloadNativeRetryMetadata.removeParent(parent)
    pendingRangeCompletions = [:]; saveSucceeds = true
    nativeMultipartTasksByClaimId = [:]
    multipartPromotionParents = []; multipartPromotionPendingParents = []; multipartPromotionCompletions = [:]
    DownloadUrlSessionHook.observations = [:]
    stored = State(maxConcurrent: width, transferringTaskIds: [parent], pausedTaskIds: [], waiters: [],
      multipartPlans: [MultipartPlan(parentTaskId: parent, maxConcurrent: width, waiters: waiters)], multipartClaims: claims)
  }
  static func dart(_ waiter: Waiter, observed: Int64? = nil) -> Bool {
    var args: [String: Any] = ["taskId": waiter.taskId, "parentTaskId": parent, "attemptGeneration": waiter.generation!]
    if let observed { args["nativeOwnerAbsent"] = true; args["observedAtMillis"] = observed }
    return claimRangeForDart(from: args)
  }
  static func snapshot(plans: [[String: Any]], paused: Bool = false) -> [String: Any] {
    ["snapshotVersion": stored.snapshotVersion + 1, "snapshotCreatedAtMicros": nowMicros(), "maxConcurrent": 2,
      "transferringTaskIds": paused ? [] : [parent], "pausedTaskIds": paused ? [parent] : [], "multipartPlans": plans]
  }
  static func runChecks() {
    let first = waiter(0), second = waiter(1), third = waiter(2)
    reset([first], claims: [claim(first)])
    let failedIdentity = rangeIdentity(for: first)!
    DownloadNativeRetryMetadata.record(identity: failedIdentity, httpStatus: 429, headers: ["Retry-After": "120"])
    precondition(!isImmutableRangeWaiter(first), "A failed attempt cannot refill before Dart persists its retry wait")
    precondition(isImmutableRangeWaiter(waiter(0, generation: 2)), "Resolved newer attempt keeps ordinary admission")
    DownloadNativeRetryMetadata.removeParent(parent)
    precondition(dart(first), "Dart atomically revokes the pending native claim")
    precondition(stored.multipartClaims.isEmpty && stored.multipartPlans[0].waiters.isEmpty)
    _ = persist(from: snapshot(plans: plans([first])))
    precondition(stored.multipartPlans[0].waiters.isEmpty, "in-flight Dart snapshot cannot republish its revoked offer")
    precondition(stored.dartRangeGenerations[first.taskId] == 1)
    let revokedSession = URLSession()
    startMultipartChild(first, on: revokedSession)
    precondition(revokedSession.tasks.isEmpty, "revoked async launch creates no task or cancellation status")

    reset([second], claims: [claim(first)])
    let native = URLSession()
    startMultipartChild(first, on: native)
    precondition(native.tasks.count == 1 && native.tasks[0].resumes == 1)
    precondition(stored.multipartClaims[0].launchCommitted)
    precondition(!dart(first, observed: nowMillis() + 1000), "live native execution beats even a stale absent result")
    var state = stored
    state.multipartClaims[0].expiresAtMillis = 0
    requeueExpiredMultipartClaimsLocked(&state)
    precondition(state.multipartClaims.count == 1, "slow live writers never expire into a duplicate")

    // A callback from an older concrete execution cannot retire a new writer,
    // even when the plugin task ID and attempt generation happen to match.
    let staleExecution = URLSessionTask(); staleExecution.taskDescription = first.taskDescription
    settleMultipartClaim(task: staleExecution)
    precondition(stored.multipartClaims.count == 1, "same-generation stale execution cannot settle the current writer")

    let newer = waiter(0, generation: 2)
    _ = persist(from: snapshot(plans: plans([newer])))
    precondition(stored.dartRangeGenerations[first.taskId] == nil, "new attempt may offer a fresh native generation")
    reset([newer], claims: [claim(newer)])
    precondition(!dart(first), "stale Dart generation cannot revoke a newer offer")
    precondition(stored.multipartClaims.count == 1 && stored.multipartPlans[0].waiters == [newer])
    releaseMultipartClaim(first, requeue: true)
    precondition(stored.multipartClaims.count == 1, "stale async release cannot remove a newer claim")
    _ = persist(from: snapshot(plans: plans([first])))
    precondition(stored.multipartClaims.count == 1 && stored.multipartClaims[0].generation == 2,
                 "a stale-generation snapshot cannot reset a newer pending native claim")
    precondition(stored.multipartPlans[0].waiters.isEmpty)

    reset([], claims: [claim(first, committed: true, committedAt: 2000)])
    precondition(!dart(first, observed: 1999), "absence observed before commit is stale")
    precondition(dart(first, observed: 2000), "cold-launch orphan is released by supported package absence evidence")

    reset([second], claims: [claim(first)])
    _ = persist(from: snapshot(plans: [], paused: true))
    precondition(stored.multipartClaims.isEmpty && stored.multipartPlans.isEmpty)
    releaseMultipartClaim(first, requeue: true)
    var cleared = stored
    requeueExpiredMultipartClaimsLocked(&cleared)
    precondition(cleared.multipartPlans.isEmpty, "expiration/release cannot resurrect a withdrawn parent")
    let pausedSession = URLSession()
    startMultipartChild(first, on: pausedSession)
    precondition(pausedSession.tasks.isEmpty, "pause wins over pending async commit")

    reset([second], claims: [claim(first)])
    let withdrawSession = URLSession()
    promoteMultipartIfPossible(on: withdrawSession)
    precondition(withdrawRangeParent(from: ["parentTaskId": parent]))
    withdrawSession.answer()
    precondition(stored.multipartPlans.isEmpty && stored.multipartClaims.isEmpty && withdrawSession.tasks.isEmpty,
                 "withdrawal before async enumeration wins prevents new pause/cancel launches")
    releaseMultipartClaim(first, requeue: true)
    precondition(stored.multipartPlans.isEmpty)
    var staleSnapshot = snapshot(plans: plans([first]))
    staleSnapshot["snapshotCreatedAtMicros"] = stored.rangeParentWithdrawnAtMicros[parent]!
    _ = persist(from: staleSnapshot)
    precondition(stored.multipartPlans.isEmpty, "pre-withdraw snapshot cannot resurrect a paused parent")
    var resumed = snapshot(plans: plans([first]))
    resumed["snapshotCreatedAtMicros"] = stored.rangeParentWithdrawnAtMicros[parent]! + 1
    _ = persist(from: resumed)
    precondition(stored.multipartPlans[0].waiters == [first], "fresh resumed parent can export native candidates")

    // Success belongs to the exact synchronous plugin file-receipt callback,
    // not URLSession's nil transport error, a byte count, or a reusable task ID.
    reset([first, second])
    let receipts = DownloadTerminalObservation()
    let finished = URLSessionTask(); finished.taskDescription = first.taskDescription
    let success = receipts.capture(execution: finished, taskId: first.taskId) {
      receipts.record(taskId: first.taskId, succeeded: true)
    }
    recordCompletedRange(task: finished, succeeded: success)
    settleMultipartClaim(task: finished)
    precondition(stored.completedRangeGenerations[first.taskId] == 1)
    _ = persist(from: snapshot(plans: plans([first, second])))
    precondition(stored.multipartPlans[0].waiters == [second], "stale snapshot cannot reoffer successful range")
    let afterSuccess = URLSession()
    promoteMultipartIfPossible(on: afterSuccess); afterSuccess.answer()
    precondition(afterSuccess.tasks.count == 1 && rangeIdentity(for: afterSuccess.tasks[0])?.taskId == second.taskId,
                 "completion frees a slot for the next range, never its completed bytes")
    stored = try! JSONDecoder().decode(State.self, from: JSONEncoder().encode(stored))
    _ = persist(from: snapshot(plans: plans([first])))
    precondition(stored.multipartPlans[0].waiters.isEmpty, "completion fence survives process storage round trip")
    _ = persist(from: snapshot(plans: plans([newer])))
    precondition(stored.multipartPlans[0].waiters == [newer], "explicit newer Dart attempt may retry invalidated bytes")
    precondition(stored.completedRangeGenerations[first.taskId] == 1, "new offer cannot erase the old completion fence")
    _ = persist(from: snapshot(plans: plans([first])))
    precondition(stored.multipartPlans[0].waiters.isEmpty, "older offer remains fenced after a newer offer")

    reset([], claims: [claim(first)])
    let completedNative = URLSession()
    startMultipartChild(first, on: completedNative)
    let nativeFinished = completedNative.tasks[0]
    recordCompletedRange(task: nativeFinished, succeeded: true)
    precondition(stored.multipartClaims.count == 1, "file receipt must retain committed ownership until didComplete settles")
    nativeFinished.state = .completed
    settleMultipartClaim(task: nativeFinished)
    _ = persist(from: snapshot(plans: plans([first])))
    precondition(stored.multipartClaims.isEmpty && stored.multipartPlans[0].waiters.isEmpty,
                 "completed native claim cannot be reoffered after settlement")
    precondition(!dart(first), "same-generation Dart launch is also fenced")
    precondition(dart(newer), "newer Dart recovery can explicitly claim the immutable range")

    reset([first])
    let newerFinished = URLSessionTask(); newerFinished.taskDescription = newer.taskDescription
    recordCompletedRange(task: newerFinished, succeeded: true)
    recordCompletedRange(task: finished, succeeded: true)
    precondition(stored.completedRangeGenerations[first.taskId] == 2, "late older receipt never lowers a completed generation")
    _ = persist(from: snapshot(plans: plans([first, newer])))
    precondition(stored.multipartPlans[0].waiters.isEmpty, "same and older generations stay fenced")

    reset([first])
    for result: Bool? in [nil, false] {
      recordCompletedRange(task: finished, succeeded: result)
      precondition(stored.completedRangeGenerations.isEmpty && stored.multipartPlans[0].waiters == [first],
                   "unknown/failed plugin receipt cannot fence a retryable range")
    }
    let failedReceipt = URLSession()
    promoteMultipartIfPossible(on: failedReceipt); failedReceipt.answer()
    precondition(failedReceipt.tasks.count == 1, "failed receipts remain retryable")

    // Even an already selected waiter must recheck a success that won the lock.
    reset([], claims: [claim(first)])
    recordCompletedRange(task: finished, succeeded: true)
    let selectedBeforeCompletion = URLSession()
    startMultipartChild(first, on: selectedBeforeCompletion)
    precondition(selectedBeforeCompletion.tasks.isEmpty && stored.multipartClaims.isEmpty)

    // Keep an unsaved success authoritative until encryption/storage recovers.
    reset([first], claims: [claim(first)])
    saveSucceeds = false
    recordCompletedRange(task: finished, succeeded: true)
    precondition(pendingRangeCompletions[first.taskId] == 1 && stored.completedRangeGenerations.isEmpty)
    let duringWriteFailure = URLSession()
    startMultipartChild(first, on: duringWriteFailure)
    precondition(duringWriteFailure.tasks.isEmpty, "failed fence persistence must not create a duplicate")
    saveSucceeds = true
    _ = persist(from: snapshot(plans: plans([first])))
    precondition(pendingRangeCompletions.isEmpty && stored.completedRangeGenerations[first.taskId] == 1)
    precondition(stored.multipartPlans[0].waiters.isEmpty, "next snapshot durably retains the unsaved fence")

    reset([first])
    recordCompletedRange(task: finished, succeeded: true)
    precondition(withdrawRangeParent(from: ["parentTaskId": parent]))
    let completionCutoff = stored.rangeParentWithdrawnAtMicros[parent]!
    var preWithdrawal = snapshot(plans: [])
    preWithdrawal["transferringTaskIds"] = []; preWithdrawal["pausedTaskIds"] = []
    preWithdrawal["snapshotCreatedAtMicros"] = completionCutoff
    _ = persist(from: preWithdrawal)
    precondition(stored.completedRangeGenerations[first.taskId] == 1, "old empty snapshot cannot prune completion evidence")
    var pausedCompletion = snapshot(plans: [], paused: true)
    pausedCompletion["snapshotCreatedAtMicros"] = completionCutoff + 1
    _ = persist(from: pausedCompletion)
    precondition(stored.completedRangeGenerations[first.taskId] == 1, "paused parent retains completed bytes across resume")
    let beforeTerminalVersion = stored.snapshotVersion
    _ = persist(from: ["snapshotVersion": beforeTerminalVersion + 1, "snapshotCreatedAtMicros": completionCutoff + 2,
      "transferringTaskIds": [], "pausedTaskIds": [], "sessionTaskIds": [], "multipartPlans": []])
    precondition(stored.completedRangeGenerations.isEmpty, "authoritative terminal snapshot bounds completion metadata")
    _ = persist(from: ["snapshotVersion": beforeTerminalVersion, "snapshotCreatedAtMicros": completionCutoff,
      "transferringTaskIds": [parent], "multipartPlans": plans([first])])
    precondition(stored.multipartPlans.isEmpty, "old snapshot cannot replay after terminal pruning")

    // Exercise the real production lock from competing Dart/native workers.
    for _ in 0..<100 {
      reset([first], claims: [claim(first)])
      let raced = URLSession()
      let resultLock = NSLock()
      var dartWon = false
      DispatchQueue.concurrentPerform(iterations: 2) { side in
        if side == 0 {
          let granted = dart(first)
          resultLock.lock(); dartWon = granted; resultLock.unlock()
        } else { startMultipartChild(first, on: raced) }
      }
      precondition((dartWon && raced.tasks.isEmpty) || (!dartWon && raced.tasks.count == 1),
                   "atomic handshake selects exactly one execution owner")
    }

    let savedState = try! JSONEncoder().encode(stored)
    var oldState = try! JSONSerialization.jsonObject(with: savedState) as! [String: Any]
    oldState.removeValue(forKey: "completedRangeGenerations")
    let previousSchema = try! JSONDecoder().decode(State.self, from: JSONSerialization.data(withJSONObject: oldState))
    precondition(previousSchema.completedRangeGenerations.isEmpty,
                 "previous encrypted payload schema defaults new completion fences to empty")
    precondition(previousSchema.multipartPlans == stored.multipartPlans
      && previousSchema.multipartClaims == stored.multipartClaims
      && previousSchema.dartRangeGenerations == stored.dartRangeGenerations
      && previousSchema.rangeParentWithdrawnAtMicros == stored.rangeParentWithdrawnAtMicros,
      "adding completion fences preserves the prior queue and ownership metadata")
    oldState.removeValue(forKey: "dartRangeGenerations")
    oldState.removeValue(forKey: "rangeParentWithdrawnAtMicros")
    let decoded = try! JSONDecoder().decode(State.self, from: JSONSerialization.data(withJSONObject: oldState))
    precondition(decoded.completedRangeGenerations.isEmpty && decoded.dartRangeGenerations.isEmpty && decoded.rangeParentWithdrawnAtMicros.isEmpty,
                 "existing encrypted queue state decodes safely across upgrade")

    reset([first, second])
    let overlap = URLSession()
    let settled = DispatchSemaphore(value: 0)
    let finishing = URLSessionTask(); finishing.taskDescription = first.taskDescription; finishing.state = .running
    overlap.tasks = [finishing]
    promoteMultipartIfPossible(on: overlap) { settled.signal() }
    precondition(overlap.queries.count == 1)
    let observation = DownloadUrlSessionHook.callbacks(for: finishing)
    _ = observation.beginComplete()
    recordCompletedRange(task: finishing, succeeded: true)
    observation.markCompletionSettled()
    promoteMultipartIfPossible(on: overlap) { settled.signal() }
    precondition(overlap.queries.count == 1, "overlapping completion coalesces enumeration")
    overlap.answer([finishing])
    precondition(overlap.tasks.count == 2, "settled successful execution refills the next range even while its state still says running")
    precondition(overlap.queries.count == 1, "a completion during enumeration schedules a rescan")
    precondition(settled.wait(timeout: .now()) == .timedOut, "finish-events completion barrier stays pending through the rescan")
    overlap.answer()
    precondition(overlap.queries.isEmpty && overlap.tasks.count == 2, "rescan respects committed slots and cannot duplicate")
    precondition(settled.wait(timeout: .now() + 1) == .success)
    precondition(settled.wait(timeout: .now() + 1) == .success, "all coalesced callers settle after resume commits")

    reset([first, second, third], width: 2)
    let cap = URLSession()
    let running = URLSessionTask(); running.taskDescription = first.taskDescription; running.state = .running
    cap.tasks = [running]
    promoteMultipartIfPossible(on: cap)
    cap.answer()
    precondition(cap.tasks.count == 2, "native refill respects live child cap")
    precondition(stored.multipartPlans[0].waiters == [third])

    reset([first])
    let foregroundSession = URLSession()
    promoteMultipartIfPossible(on: foregroundSession)
    foreground = true
    foregroundSession.answer()
    precondition(foregroundSession.tasks.isEmpty && stored.multipartPlans[0].waiters == [first], "foreground transition leaves Dart's range intact")

    reset([])
    for index in 0..<1000 {
      let doneParent = "aw_v2_completed_\(index)"
      let child = doneParent + ".part.0"
      precondition(claimRangeForDart(from: ["taskId": child, "parentTaskId": doneParent, "attemptGeneration": 1]))
      var completedWaiter = waiter(0)
      completedWaiter.taskId = child
      completedWaiter.taskJson = completedWaiter.taskJson.replacingOccurrences(of: parent, with: doneParent)
      completedWaiter.claimId = "\(child):g1"
      let completedExecution = URLSessionTask()
      completedExecution.taskDescription = completedWaiter.taskDescription
      recordCompletedRange(task: completedExecution, succeeded: true)
      precondition(stored.completedRangeGenerations == [child: 1],
                   "each parent records its completion without retaining earlier terminal parents")
      precondition(withdrawRangeParent(from: ["parentTaskId": doneParent]))
      let cutoff = stored.rangeParentWithdrawnAtMicros[doneParent]!
      let oldVersion = stored.snapshotVersion
      _ = persist(from: ["snapshotVersion": oldVersion + 1, "snapshotCreatedAtMicros": cutoff + 1,
        "transferringTaskIds": [], "pausedTaskIds": [], "sessionTaskIds": [], "multipartPlans": []])
      precondition(stored.dartRangeGenerations.isEmpty && stored.rangeParentWithdrawnAtMicros.isEmpty
        && stored.completedRangeGenerations.isEmpty && pendingRangeCompletions.isEmpty,
        "terminal snapshots bound claims, withdrawals and completion fences across 1000 parents")
      for replayVersion in [oldVersion, oldVersion + 1] {
        let accepted = persist(from: ["snapshotVersion": replayVersion, "snapshotCreatedAtMicros": cutoff - 1,
          "transferringTaskIds": [doneParent], "pausedTaskIds": [], "sessionTaskIds": [doneParent],
          "multipartPlans": [["parentTaskId": doneParent, "maxConcurrent": 2, "waiters": [payload(completedWaiter)]]]])
        precondition(accepted == oldVersion + 1 && stored.multipartPlans.isEmpty && stored.completedRangeGenerations.isEmpty,
                     "older/equal snapshot with a real completed offer cannot replay after terminal pruning")
      }
      let replaySession = URLSession()
      promoteMultipartIfPossible(on: replaySession)
      precondition(replaySession.tasks.isEmpty && replaySession.queries.isEmpty,
                   "pruned terminal parent never reaches native promotion after stale replay")
    }

    reset([first])
    var invalid = first; invalid.group = "chunk"
    precondition(!isImmutableRangeWaiter(invalid), "plugin internal chunk cannot be promoted")
    invalid = first; invalid.headers["Range"] = "bytes=0-"
    precondition(!isImmutableRangeWaiter(invalid), "open-ended range fails closed")
    invalid = first; invalid.progress = 0.1
    precondition(!isImmutableRangeWaiter(invalid), "native never restarts partial progress from byte zero")
    print("PASS: production range revocation, native ownership, generation/completion fencing, failed-write recovery, orphan recovery, pause, expiry, cap and coalescing")
  }
'''

# The UIKit-only handoff must acquire its bounded assertion before the original
# plugin schedules UIApplication's completion, then refill after settlement.
handoff = function("refillAfterBackgroundEvents")
assert handoff.index("DownloadRangeBackgroundAssertion()") < handoff.index("\n    original()") < handoff.index("promoteMultipartIfPossible")
assert "DispatchQueue.main.asyncAfter(deadline: .now() + 10)" in QUEUE
hook = QUEUE[QUEUE.index("  private static func hookComplete(on cls:"):QUEUE.index("  private static func hookFinishDownload(on cls:")]
assert hook.index("fn(slf, completeSelector") < hook.index("observeRangeCompletion")
assert "retryBackgroundTransferIfNeeded" not in hook
assert "handlePluginTaskCompleted" not in hook
receipt_hook = QUEUE[QUEUE.index("  private static func hookFinishDownload(on cls:"):QUEUE.index("  private static func hookFinishEvents(on cls:")]
assert receipt_hook.index("let succeeded = DownloadNativeWaitingQueue.terminalObservation.capture(") < receipt_hook.index("fn(slf, finishDownloadSelector") < receipt_hook.index("recordCompletedRange(task: downloadTask, succeeded: succeeded)")
assert "if firstFinish {" in receipt_hook

swiftc = shutil.which("swiftc")
if not swiftc:
    raise SystemExit("Swift compiler is required for the production range handoff behavior test")
source = COMPAT + FAKES + "\nenum DownloadNativeWaitingQueue {\n" + TYPES + STATE + FUNCTIONS + CHECKS + "\n}\nDownloadNativeWaitingQueue.runChecks()\n"
with tempfile.TemporaryDirectory(prefix="ios-range-handoff-") as directory:
    main = Path(directory) / "main.swift"
    main.write_text(source)
    executable = Path(directory) / "checks"
    flags = []
    if os.environ.get("SWIFT_MODULE_CACHE"):
        flags += ["-module-cache-path", os.environ["SWIFT_MODULE_CACHE"]]
    if shutil.which("ld.lld"):
        flags += ["-use-ld=lld"]
    subprocess.run([swiftc, *flags, str(main), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

# Exercise the actual UIKit handoff assertion with a main-actor application fake.
assertion_start = QUEUE.index("@MainActor\nprivate final class DownloadRangeBackgroundAssertion")
assertion_end = QUEUE.index("\n}\n", assertion_start) + 3
assertion_source = r'''import Foundation
struct UIBackgroundTaskIdentifier: Equatable {
  let value: Int
  static let invalid = UIBackgroundTaskIdentifier(value: -1)
}
@MainActor final class UIApplication {
  static let shared = UIApplication()
  var starts = 0
  var ends = 0
  var expiration: (() -> Void)?
  func beginBackgroundTask(withName name: String, expirationHandler: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
    starts += 1
    expiration = expirationHandler
    return UIBackgroundTaskIdentifier(value: starts)
  }
  func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) { ends += 1 }
}
''' + QUEUE[assertion_start:assertion_end] + r'''
@main enum AssertionChecks {
  @MainActor static func main() async {
    let first = DownloadRangeBackgroundAssertion()
    precondition(UIApplication.shared.starts == 1)
    first.finish(); first.finish()
    precondition(UIApplication.shared.ends == 1)
    let expired = DownloadRangeBackgroundAssertion()
    UIApplication.shared.expiration?()
    try? await Task.sleep(nanoseconds: 50_000_000)
    precondition(UIApplication.shared.ends == 2)
    expired.finish()
    precondition(UIApplication.shared.ends == 2, "expiration and explicit completion release exactly once")
    print("PASS: production main-actor refill assertion expiration and idempotent completion")
  }
}
'''
with tempfile.TemporaryDirectory(prefix="ios-range-assertion-") as directory:
    main = Path(directory) / "assertion.swift"
    main.write_text(assertion_source)
    executable = Path(directory) / "checks"
    subprocess.run([swiftc, *flags, "-parse-as-library", str(main), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
