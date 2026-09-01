import Flutter
import UIKit
import XCTest

class RunnerTests: XCTestCase {
  override func tearDown() {
    DownloadNativeWaitingQueue.resetForTests()
    super.tearDown()
  }

  func testWaiterKeepsResumeDataAndSavedProgress() {
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: [
      "maxConcurrent": 1,
      "transferringTaskIds": ["ep1"],
      "pausedTaskIds": [],
      "waiters": [[
        "taskId": "ep2",
        "taskJson": "{\"taskId\":\"ep2\",\"url\":\"https://127.0.0.1:1/ep2.mp4\",\"filename\":\"الحلقة 2.mp4\"}",
        "url": "https://127.0.0.1:1/ep2.mp4",
        "filename": "الحلقة 2.mp4",
        "displayName": "الحلقة 2.mp4",
        "headers": ["Authorization": "Bearer x"],
        "directory": "AnimeWitcher/Downloads/Show",
        "httpRequestMethod": "GET",
        "group": "downloads",
        "resumeDataBase64": "cmVzdW1l",
        "progress": 0.42,
        "expectedBytes": 8000,
      ]],
    ])
    let waiter = DownloadNativeWaitingQueue.load().waiters[0]
    XCTAssertEqual(waiter.taskId, "ep2")
    XCTAssertEqual(waiter.resumeDataBase64, "cmVzdW1l")
    XCTAssertEqual(waiter.savedProgress, 0.42, accuracy: 0.0001)
    XCTAssertEqual(waiter.savedExpectedBytes, 8000)
    XCTAssertEqual(waiter.transferredBytes, 3360)
  }
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: [
      "maxConcurrent": 1,
      "transferringTaskIds": ["ep1"],
      "pausedTaskIds": [],
      "waiters": [[
        "taskId": "ep2",
        "taskJson": "",
        "url": "https://cdn.test/ep2.mp4",
        "filename": "ep2.mp4",
      ]],
    ])
    XCTAssertTrue(DownloadNativeWaitingQueue.load().waiters.isEmpty)
  }

  func testPersistStoresUrlHeadersFilenameAndTaskJson() {
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: ep1TransferringEp2Waiting())
    let state = DownloadNativeWaitingQueue.load()
    XCTAssertEqual(state.maxConcurrent, 1)
    XCTAssertEqual(state.transferringTaskIds, ["ep1"])
    XCTAssertEqual(state.waiters.map(\.taskId), ["ep2"])
    XCTAssertEqual(state.waiters[0].url, "https://127.0.0.1:1/ep2.mp4")
    XCTAssertEqual(state.waiters[0].filename, "الحلقة 2.mp4")
    XCTAssertEqual(state.waiters[0].headers["Authorization"], "Bearer x")
    XCTAssertTrue(state.waiters[0].taskJson.contains("ep2"))
  }

  func testUserPausedWaiterIsNotPromoted() {
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: [
      "maxConcurrent": 1,
      "transferringTaskIds": ["ep1"],
      "pausedTaskIds": ["ep2"],
      "waiters": [ep2Waiter()],
    ])
    XCTAssertTrue(DownloadNativeWaitingQueue.load().waiters.isEmpty)

    let session = URLSession(configuration: .ephemeral)
    let ep1 = session.downloadTask(with: URL(string: "https://127.0.0.1:1/ep1.mp4")!)
    ep1.taskDescription = "{\"taskId\":\"ep1\"}"
    DownloadNativeWaitingQueue.handlePluginTaskCompleted(
      session: session,
      task: ep1,
      error: nil
    )
    let state = DownloadNativeWaitingQueue.load()
    XCTAssertFalse(state.transferringTaskIds.contains("ep2"))
    XCTAssertEqual(state.pausedTaskIds, ["ep2"])
  }

  func testFailedEpisodeParksPausedAndStartsNextWaiter() {
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: ep1TransferringEp2Waiting())

    let session = URLSession(configuration: .ephemeral)
    let ep1 = session.downloadTask(with: URL(string: "https://127.0.0.1:1/ep1.mp4")!)
    ep1.taskDescription = "{\"taskId\":\"ep1\"}"
    let error = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorTimedOut,
      userInfo: nil
    )
    DownloadNativeWaitingQueue.handlePluginTaskCompleted(
      session: session,
      task: ep1,
      error: error
    )

    let state = DownloadNativeWaitingQueue.load()
    XCTAssertEqual(state.pausedTaskIds, ["ep1"])
    XCTAssertFalse(state.completedTaskIds.contains("ep1"))
    XCTAssertFalse(state.transferringTaskIds.contains("ep1"))
    XCTAssertEqual(state.transferringTaskIds, ["ep2"])
    XCTAssertTrue(state.waiters.isEmpty)
    XCTAssertFalse(state.sessionIsIdle)
  }

  func testNativeCompletionStartsNextWaiterBeforeDartWakes() {
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: ep1TransferringEp2Waiting())

    let session = URLSession(configuration: .ephemeral)
    let ep1 = session.downloadTask(with: URL(string: "https://127.0.0.1:1/ep1.mp4")!)
    ep1.taskDescription = "{\"taskId\":\"ep1\"}"
    DownloadNativeWaitingQueue.handlePluginTaskCompleted(
      session: session,
      task: ep1,
      error: nil
    )

    let state = DownloadNativeWaitingQueue.load()
    XCTAssertEqual(state.transferringTaskIds, ["ep2"])
    XCTAssertTrue(state.waiters.isEmpty)
    XCTAssertTrue(state.completedTaskIds.contains("ep1"))
  }

  func testStaleDartSnapshotCannotUnstartANativePromotion() {
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: ep1TransferringEp2Waiting())

    let session = URLSession(configuration: .ephemeral)
    let ep1 = session.downloadTask(with: URL(string: "https://127.0.0.1:1/ep1.mp4")!)
    ep1.taskDescription = "{\"taskId\":\"ep1\"}"
    DownloadNativeWaitingQueue.handlePluginTaskCompleted(
      session: session,
      task: ep1,
      error: nil
    )

    DownloadNativeWaitingQueue.persist(from: [
      "maxConcurrent": 1,
      "transferringTaskIds": [],
      "pausedTaskIds": [],
      "waiters": [ep2Waiter()],
    ])

    let state = DownloadNativeWaitingQueue.load()
    XCTAssertEqual(state.transferringTaskIds, ["ep2"])
    XCTAssertTrue(state.waiters.isEmpty)
  }

  private func ep1TransferringEp2Waiting() -> [String: Any] {
    [
      "maxConcurrent": 1,
      "transferringTaskIds": ["ep1"],
      "pausedTaskIds": [],
      "waiters": [ep2Waiter()],
    ]
  }

  func testPersistRewritesWaiterOrderFromDart() {
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: [
      "maxConcurrent": 1,
      "transferringTaskIds": ["ep1"],
      "pausedTaskIds": [],
      "waiters": [ep2Waiter(), ep3Waiter()],
      "sessionTaskIds": ["ep1", "ep2", "ep3"],
    ])
    XCTAssertEqual(
      DownloadNativeWaitingQueue.load().waiters.map(\.taskId),
      ["ep2", "ep3"]
    )

    DownloadNativeWaitingQueue.persist(from: [
      "maxConcurrent": 1,
      "transferringTaskIds": ["ep1"],
      "pausedTaskIds": [],
      "waiters": [ep3Waiter(), ep2Waiter()],
      "sessionTaskIds": ["ep3", "ep1", "ep2"],
      "sessionCurrentIndex": 2,
    ])
    let state = DownloadNativeWaitingQueue.load()
    XCTAssertEqual(state.waiters.map(\.taskId), ["ep3", "ep2"])
    XCTAssertEqual(state.sessionTaskIds.first, "ep3")
    XCTAssertEqual(state.overlayCurrentIndex(runningTaskId: "ep1"), 1)
  }

  func testOverlayIndexIsStartedCountWhenSeveralTransfer() {
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: [
      "maxConcurrent": 3,
      "transferringTaskIds": ["ep1", "ep2", "ep3"],
      "pausedTaskIds": [],
      "waiters": [],
      "sessionTaskIds": ["ep1", "ep2", "ep3", "ep4", "ep5"],
      "sessionBatchTotal": 5,
      "sessionCurrentIndex": 1,
    ])
    let state = DownloadNativeWaitingQueue.load()
    XCTAssertEqual(state.overlayCurrentIndex(), 3)
  }

  func testDragParkReleasesNativeSlotSoNextFileCanStart() {
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: ep1TransferringEp2Waiting())
    XCTAssertEqual(DownloadNativeWaitingQueue.load().transferringTaskIds, ["ep1"])

    DownloadNativeWaitingQueue.persist(from: [
      "maxConcurrent": 1,
      "transferringTaskIds": ["ep2"],
      "pausedTaskIds": [],
      "queueWaitingTaskIds": ["ep1"],
      "waiters": [ep1Waiter(), ep3Waiter()],
      "sessionTaskIds": ["ep2", "ep1", "ep3"],
      "sessionCurrentTaskId": "ep2",
      "sessionBatchTotal": 3,
      "sessionCurrentIndex": 1,
    ])
    let state = DownloadNativeWaitingQueue.load()
    XCTAssertEqual(state.transferringTaskIds, ["ep2"])
    XCTAssertFalse(state.transferringTaskIds.contains("ep1"))
    XCTAssertEqual(state.waiters.map(\.taskId), ["ep1", "ep3"])
    XCTAssertEqual(state.sessionTaskIds.first, "ep2")
  }

  func testCompletedFileIsNotPromotedAsTheNextWaiter() {
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: ep1TransferringEp2Waiting())
    let session = URLSession(configuration: .ephemeral)
    let ep1 = session.downloadTask(with: URL(string: "https://127.0.0.1:1/ep1.mp4")!)
    ep1.taskDescription = "{\"taskId\":\"ep1\"}"
    DownloadNativeWaitingQueue.handlePluginTaskCompleted(
      session: session,
      task: ep1,
      error: nil
    )
    DownloadNativeWaitingQueue.persist(from: [
      "maxConcurrent": 1,
      "transferringTaskIds": ["ep2"],
      "pausedTaskIds": [],
      "waiters": [ep1Waiter(), ep3Waiter()],
      "sessionTaskIds": ["ep1", "ep2", "ep3"],
      "sessionCompletedCount": 1,
      "sessionBatchTotal": 3,
    ])
    let state = DownloadNativeWaitingQueue.load()
    XCTAssertEqual(state.transferringTaskIds, ["ep2"])
    XCTAssertFalse(state.waiters.contains(where: { $0.taskId == "ep1" }))
    XCTAssertEqual(state.waiters.map(\.taskId), ["ep3"])
  }

  func testFileSwitchPersistResetsSpeedAndBytes() {
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: [
      "maxConcurrent": 1,
      "transferringTaskIds": ["ep1"],
      "pausedTaskIds": [],
      "waiters": [ep2Waiter()],
      "sessionTaskIds": ["ep1", "ep2"],
      "sessionCurrentTaskId": "ep1",
      "sessionTransferredBytes": 4_000_000,
      "sessionTotalBytes": 10_000_000,
      "sessionSpeedBytesPerSecond": 859_000,
      "sessionBatchTotal": 4,
      "sessionCurrentIndex": 1,
    ])
    let session = URLSession(configuration: .ephemeral)
    let ep1 = session.downloadTask(with: URL(string: "https://127.0.0.1:1/ep1.mp4")!)
    ep1.taskDescription = "{\"taskId\":\"ep1\"}"
    DownloadNativeWaitingQueue.markPluginTaskCompleted(task: ep1)
    DownloadNativeWaitingQueue.persist(from: [
      "maxConcurrent": 1,
      "transferringTaskIds": [],
      "pausedTaskIds": [],
      "waiters": [ep2Waiter()],
      "sessionTaskIds": ["ep1", "ep2"],
      "sessionCurrentTaskId": "ep2",
      "sessionDisplayName": "الحلقة 11 (480p).mp4",
      "sessionTransferredBytes": 0,
      "sessionTotalBytes": 10_000_000,
      "sessionSpeedBytesPerSecond": 0,
      "sessionCompletedCount": 1,
      "sessionBatchTotal": 4,
      "sessionCurrentIndex": 2,
    ])
    let state = DownloadNativeWaitingQueue.load()
    XCTAssertEqual(state.sessionCurrentTaskId, "ep2")
    XCTAssertEqual(state.sessionTransferredBytes, 0)
    XCTAssertEqual(state.sessionSpeedBytesPerSecond, 0, accuracy: 0.1)
    XCTAssertEqual(state.overlayCurrentIndex(), 2)
  }

  func testOverlayIndexAfterCompleteWithNoTransferIsNextFile() {
    DownloadNativeWaitingQueue.resetForTests()
    DownloadNativeWaitingQueue.persist(from: ep1TransferringEp2Waiting())
    let session = URLSession(configuration: .ephemeral)
    let ep1 = session.downloadTask(with: URL(string: "https://127.0.0.1:1/ep1.mp4")!)
    ep1.taskDescription = "{\"taskId\":\"ep1\"}"
    DownloadNativeWaitingQueue.markPluginTaskCompleted(task: ep1)
    let state = DownloadNativeWaitingQueue.load()
    XCTAssertTrue(state.completedTaskIds.contains("ep1"))
    XCTAssertFalse(state.transferringTaskIds.contains("ep1"))
    XCTAssertEqual(state.overlayCurrentIndex(), 2)
  }

  private func ep1Waiter() -> [String: Any] {
    [
      "taskId": "ep1",
      "taskJson": "{\"taskId\":\"ep1\",\"url\":\"https://127.0.0.1:1/ep1.mp4\",\"filename\":\"الحلقة 1.mp4\"}",
      "url": "https://127.0.0.1:1/ep1.mp4",
      "filename": "الحلقة 1.mp4",
      "displayName": "الحلقة 1.mp4",
      "headers": ["Authorization": "Bearer x"],
      "directory": "AnimeWitcher/Downloads/Show",
      "httpRequestMethod": "GET",
      "group": "downloads",
    ]
  }

  private func ep3Waiter() -> [String: Any] {
    [
      "taskId": "ep3",
      "taskJson": "{\"taskId\":\"ep3\",\"url\":\"https://127.0.0.1:1/ep3.mp4\",\"filename\":\"الحلقة 3.mp4\"}",
      "url": "https://127.0.0.1:1/ep3.mp4",
      "filename": "الحلقة 3.mp4",
      "displayName": "الحلقة 3.mp4",
      "headers": ["Authorization": "Bearer x"],
      "directory": "AnimeWitcher/Downloads/Show",
      "httpRequestMethod": "GET",
      "group": "downloads",
    ]
  }

  private func ep2Waiter() -> [String: Any] {
    [
      "taskId": "ep2",
      "taskJson": "{\"taskId\":\"ep2\",\"url\":\"https://127.0.0.1:1/ep2.mp4\",\"filename\":\"الحلقة 2.mp4\"}",
      "url": "https://127.0.0.1:1/ep2.mp4",
      "filename": "الحلقة 2.mp4",
      "displayName": "الحلقة 2.mp4",
      "headers": ["Authorization": "Bearer x"],
      "directory": "AnimeWitcher/Downloads/Show",
      "httpRequestMethod": "GET",
      "group": "downloads",
    ]
  }
}
