import Foundation
import Darwin

let files = FileManager.default
let root = files.temporaryDirectory.appendingPathComponent("download-promotion-\(UUID().uuidString)")
try files.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? files.removeItem(at: root) }

func write(_ name: String, _ bytes: [UInt8] = [1, 2, 3]) throws -> URL {
  let url = root.appendingPathComponent(name)
  try Data(bytes).write(to: url)
  return url
}

func reject(_ source: URL, _ target: URL, _ size: Int64 = 3) throws {
  do {
    try DownloadFilePromotion.promoteCompletedFile(
      sourcePath: source.path, targetPath: target.path, expectedBytes: size
    )
    fatalError("Publication unexpectedly succeeded: \(target.lastPathComponent)")
  } catch is DownloadFilePromotionError {
    assert(files.fileExists(atPath: source.path), "Rejected publication must retain its source")
  }
}

let source = try write("success-source")
let target = root.appendingPathComponent("success-target")
try DownloadFilePromotion.promoteCompletedFile(sourcePath: source.path, targetPath: target.path, expectedBytes: 3)
assert(!files.fileExists(atPath: source.path))
assert(try! Data(contentsOf: target) == Data([1, 2, 3]))

let collidingBodies: [[UInt8]] = [[], [9, 8], [9, 8, 7]]
for bytes in collidingBodies {
  let suffix = String(bytes.count)
  let retained = try write("collision-source-\(suffix)")
  let foreign = try write("collision-target-\(suffix)", bytes)
  try reject(retained, foreign)
  assert(try! Data(contentsOf: retained) == Data([1, 2, 3]))
  assert(try! Data(contentsOf: foreign) == Data(bytes))
}

let directorySource = try write("directory-source")
let directoryTarget = root.appendingPathComponent("directory-target")
try files.createDirectory(at: directoryTarget, withIntermediateDirectories: false)
try reject(directorySource, directoryTarget)
assert((try! files.contentsOfDirectory(atPath: directoryTarget.path)).isEmpty)

let linkSource = try write("link-source")
let linkValue = try write("link-value", [7, 7, 7])
let linkTarget = root.appendingPathComponent("link-target")
try files.createSymbolicLink(at: linkTarget, withDestinationURL: linkValue)
try reject(linkSource, linkTarget)
assert(try! files.destinationOfSymbolicLink(atPath: linkTarget.path) == linkValue.path)
assert(try! Data(contentsOf: linkValue) == Data([7, 7, 7]))

let hardSource = try write("hard-source")
let hardTarget = root.appendingPathComponent("hard-target")
try files.linkItem(at: hardSource, to: hardTarget)
try reject(hardSource, hardTarget)
assert(try! Data(contentsOf: hardTarget) == Data([1, 2, 3]))

let invalidSize = try write("invalid-size")
try reject(invalidSize, root.appendingPathComponent("invalid-size-target"), 4)
try reject(invalidSize, invalidSize)
try reject(invalidSize, root.appendingPathComponent("negative-target"), -1)
try reject(invalidSize, root.appendingPathComponent("missing/target"))
let sourceLink = root.appendingPathComponent("source-symlink")
try files.createSymbolicLink(at: sourceLink, withDestinationURL: invalidSize)
try reject(sourceLink, root.appendingPathComponent("source-symlink-target"))
try reject(directoryTarget, root.appendingPathComponent("invalid-directory-target"), 0)
assert(try! Data(contentsOf: invalidSize) == Data([1, 2, 3]))

do {
  try DownloadFilePromotion.promoteCompletedFile(sourcePath: "relative-source", targetPath: target.path, expectedBytes: 3)
  fatalError("Relative paths must be rejected")
} catch let error as DownloadFilePromotionError {
  assert(error.code == "INVALID_ARGUMENTS")
}

final class PromotionResults: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var winners: [Int] = []
  func win(_ index: Int) {
    lock.lock()
    winners.append(index)
    lock.unlock()
  }
}
let competing = [try write("race-source-0", [10]), try write("race-source-1", [20])]
let raceTarget = root.appendingPathComponent("race-target")
let results = PromotionResults()
DispatchQueue.concurrentPerform(iterations: 2) { index in
  do {
    try DownloadFilePromotion.promoteCompletedFile(
      sourcePath: competing[index].path, targetPath: raceTarget.path, expectedBytes: 1
    )
    results.win(index)
  } catch let error as DownloadFilePromotionError {
    assert(error.code == "DESTINATION_EXISTS", "A racing loser must fail exclusively")
    assert(error.errnoValue == EEXIST)
  } catch {
    fatalError("Unexpected publication error")
  }
}
assert(results.winners.count == 1)
let winner = results.winners[0]
assert(!files.fileExists(atPath: competing[winner].path))
assert(files.fileExists(atPath: competing[1 - winner].path))
assert(try! Data(contentsOf: raceTarget) == Data([winner == 0 ? 10 : 20]))
assert(try! Data(contentsOf: competing[1 - winner]) == Data([winner == 0 ? 20 : 10]))
print("PASS: production exclusive publication, retained collisions, invalid sources, one racing winner")
