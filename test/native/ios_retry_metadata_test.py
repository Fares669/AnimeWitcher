"""Exercise the production native retry metadata store with isolated defaults."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[2]
queue = (root / "ios/Runner/DownloadNativeWaitingQueue.swift").read_text()
assert "enum DownloadNativeRetryMetadata" in queue, "Native Retry-After cache is missing"
source = queue[queue.index("enum DownloadNativeRetryMetadata"):queue.index("/// Keep the large queue")]
compat = (root / "ios/Runner/DownloadCallbackCompatibility.swift").read_text()
identity = compat[compat.index("struct DownloadRangeIdentity"):compat.index("/// Installs only compatible")]
suite = "animewitcher.retry-metadata-test." + str(uuid.uuid4())
source = source.replace("UserDefaults.standard", f'UserDefaults(suiteName: "{suite}")!')
checks = r'''
let first = DownloadRangeIdentity(taskId: "aw_v2_test.part.0", parentTaskId: "aw_v2_test", generation: 1)!
let second = DownloadRangeIdentity(taskId: first.taskId, parentTaskId: first.parentTaskId, generation: 2)!
func args(_ identity: DownloadRangeIdentity) -> [String: Any] {
  ["taskId": identity.taskId, "parentTaskId": identity.parentTaskId, "attemptGeneration": identity.generation]
}
DownloadNativeRetryMetadata.record(identity: first, httpStatus: 429, headers: [
  "ReTrY-AfTeR": "120", "Set-Cookie": "never-store", "Location": "https://secret.test/secret"
])
let row = DownloadNativeRetryMetadata.lookup(args(first))!
precondition(row["retryAfter"] as? String == "120")
precondition(row["httpStatus"] as? Int == 429)
precondition(Set(row.keys) == Set(["taskId", "parentTaskId", "attemptGeneration", "httpStatus", "retryAfter"]))
precondition(DownloadNativeRetryMetadata.lookup(args(second)) == nil, "Old attempts cannot delay a new attempt")
precondition(DownloadNativeRetryMetadata.lookup(["taskId": first.taskId, "parentTaskId": first.parentTaskId, "attemptGeneration": true]) == nil)
precondition(DownloadNativeRetryMetadata.lookup(["taskId": first.taskId, "parentTaskId": "aw_v2_other", "attemptGeneration": 1]) == nil)
let date = "Fri, 16 Oct 2026 08:05:00 GMT"
DownloadNativeRetryMetadata.record(identity: second, httpStatus: 503, headers: ["Retry-After": date, "DaTe": "Fri, 16 Oct 2026 08:03:00 GMT"])
DownloadNativeRetryMetadata.record(identity: first, httpStatus: 429, headers: ["Retry-After": "1"])
precondition(DownloadNativeRetryMetadata.lookup(args(first)) == nil)
precondition(DownloadNativeRetryMetadata.lookup(args(second))?["retryAfter"] as? String == date)
precondition(DownloadNativeRetryMetadata.lookup(args(second))?["responseDate"] as? String == "Fri, 16 Oct 2026 08:03:00 GMT")
DownloadNativeRetryMetadata.remove(identity: first)
precondition(DownloadNativeRetryMetadata.lookup(args(second)) != nil, "Late old completion cannot erase new metadata")
DownloadNativeRetryMetadata.remove(identity: second)
precondition(DownloadNativeRetryMetadata.lookup(args(second)) == nil)
DownloadNativeRetryMetadata.record(identity: second, httpStatus: 503, headers: ["Authorization": "never-store"])
precondition(DownloadNativeRetryMetadata.lookup(args(second))?["retryAfter"] == nil)
DownloadNativeRetryMetadata.removeParent("aw_v2_other")
precondition(DownloadNativeRetryMetadata.lookup(args(second)) != nil)
DownloadNativeRetryMetadata.removeParent(first.parentTaskId)
precondition(DownloadNativeRetryMetadata.lookup(args(second)) == nil)
print("PASS: Retry-After allowlist, HTTP date, exact generation, stale callback and parent cleanup")
'''
if not shutil.which("swiftc"):
    print("SKIP: Swift compiler unavailable; production-source extraction passed")
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix="ios-retry-metadata-") as directory:
    swift = Path(directory) / "main.swift"
    cleanup = f'\nUserDefaults(suiteName: "{suite}")!.removePersistentDomain(forName: "{suite}")\n'
    swift.write_text("import Foundation\nimport CoreFoundation\n" + identity + source + checks + cleanup)
    binary = Path(directory) / "checks"
    subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
