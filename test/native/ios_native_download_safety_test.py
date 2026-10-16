"""Run real production crypto and completion gate checks on a macOS Swift host."""
from pathlib import Path
import subprocess
import plistlib
import sys
import tempfile
import uuid

if sys.platform != "darwin":
    print("SKIP: native CryptoKit/Security checks require macOS Swift")
    raise SystemExit(0)

root = Path(__file__).resolve().parents[2]
subprocess.run([sys.executable, str(root / "test/native/ios_download_diagnostics_test.py")], check=True)
privacy = plistlib.loads((root / "ios/Runner/PrivacyInfo.xcprivacy").read_bytes())
reasons = {entry["NSPrivacyAccessedAPIType"]: entry["NSPrivacyAccessedAPITypeReasons"]
           for entry in privacy["NSPrivacyAccessedAPITypes"]}
assert "E174.1" in reasons["NSPrivacyAccessedAPICategoryDiskSpace"]
assert "CA92.1" in reasons["NSPrivacyAccessedAPICategoryUserDefaults"]
assert "PrivacyInfo.xcprivacy in Resources" in (root / "ios/Runner.xcodeproj/project.pbxproj").read_text()
queue = (root / "ios/Runner/DownloadNativeWaitingQueue.swift").read_text()
manager = (root / "ios/Runner/DownloadContinuedProcessingManager.swift").read_text()
encryption = queue[queue.index("private enum DownloadNativeQueueEncryption"):queue.index("/// Full waiter payloads")]
gate = manager[manager.index("private final class DownloadContinuedProcessingCompletion"):manager.index("/// Owns the **one**")]
# An isolated service avoids touching real app secrets when run locally.
service = "com.animewitcher.native-safety-test." + str(uuid.uuid4())
encryption = encryption.replace("com.animewitcher.download.nativeQueueEncryption", service)
checks = r'''
assert(DownloadPageProgress.acceptsDartUpdate(inForeground: false, incomingPages: 12, currentPages: nil))
assert(DownloadPageProgress.acceptsDartUpdate(inForeground: false, incomingPages: nil, currentPages: 23), "Manga to video must switch out of page mode while background")
assert(!DownloadPageProgress.acceptsDartUpdate(inForeground: false, incomingPages: nil, currentPages: nil), "Video keeps native background precedence")
assert(DownloadPageProgress.acceptsDartUpdate(inForeground: true, incomingPages: nil, currentPages: nil))
assert(abs(DownloadPageProgress.fraction(completed: 12, total: 23, progress: 0.9) - 12.0 / 23.0) < 0.000001)
assert(DownloadPageProgress.fraction(completed: 23, total: 23, progress: 0.999) < 1)
assert(DownloadPageProgress.fraction(completed: 23, total: 23, progress: 1) == 1)
assert(DownloadPageProgress.fraction(completed: 0, total: -1, progress: 0.9) == 0)
assert(DownloadPageProgress.label(completed: 12, total: 23) == "12/23 pages")
assert(DownloadPageProgress.label(completed: 0, total: -1) == "0/? pages")
let payload = Data(#"{\"url\":\"https://example.test/video?sig=secret\",\"headers\":{\"Authorization\":\"Bearer secret\",\"Cookie\":\"session=secret\"},\"taskJson\":\"embedded credentials\",\"resumeDataBase64\":\"resume payload\"}"#.utf8)
guard let encrypted = DownloadNativeQueueEncryption.encrypt(payload) else {
  fatalError("Cannot create the isolated test Keychain item")
}
assert(encrypted != payload)
assert(DownloadNativeQueueEncryption.decrypt(encrypted) == payload)
assert(DownloadNativeQueueEncryption.encrypt(payload) != encrypted, "Each write needs a fresh nonce")
var tampered = encrypted
tampered[tampered.count - 1] ^= 1
assert(DownloadNativeQueueEncryption.decrypt(tampered) == nil, "Reject unauthenticated payloads")
assert(DownloadNativeQueueEncryption.decrypt(Data([1, 2, 3])) == nil)

private let gate = DownloadContinuedProcessingCompletion()
final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var value = 0
  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }
}
let counter = Counter()
DispatchQueue.concurrentPerform(iterations: 1000) { _ in
  gate.finish { counter.increment() }
}
assert(counter.value == 1, "Expiration and explicit completion must acknowledge once")
print("PASS: real queue encryption, nonce freshness, tamper rejection, concurrent completion gate")
'''
cleanup = '\nSecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "' + service + '"] as CFDictionary)\n'
with tempfile.TemporaryDirectory(prefix="ios-native-safety-") as directory:
    swift = Path(directory) / "main.swift"
    swift.write_text("import Foundation\nimport CryptoKit\nimport Security\n" + encryption + gate + checks + cleanup)
    executable = Path(directory) / "checks"
    subprocess.run(["swiftc", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

with tempfile.TemporaryDirectory(prefix="ios-download-promotion-") as directory:
    main = Path(directory) / "main.swift"
    main.write_text((root / "test/native/download_file_promotion_test.swift").read_text())
    executable = Path(directory) / "promotion-checks"
    subprocess.run([
        "swiftc", str(root / "ios/Runner/DownloadCallbackCompatibility.swift"),
        str(main), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True)
