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
let payload = Data(#"{"url":"https://example.test/video?sig=secret","headers":{"Authorization":"Bearer secret","Cookie":"session=secret"},"taskJson":"embedded credentials","resumeDataBase64":"resume payload"}"#.utf8)
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

let gate = DownloadContinuedProcessingCompletion()
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
