"""Exercise the production logger in isolated files/defaults on a Swift host."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[2]
queue = (root / "ios/Runner/DownloadNativeWaitingQueue.swift").read_text()
source = queue[queue.index("enum DownloadNativeDiagnosticLog"):queue.index("import ObjectiveC")]
assert "static func recordPluginProgress(" in source, "Supported progress journal is missing"
assert "static func recordSessionConfiguration(" in source, "Observed session configuration is missing"

# Only test boundaries change: isolate filesystem/defaults and freeze the clock.
suite = "animewitcher.download-diagnostics-test." + str(uuid.uuid4())
source = source.replace("UserDefaults.standard", f'UserDefaults(suiteName: "{suite}")!')
source = source.replace("Date().timeIntervalSince1970", "diagnosticTestNow")
source = source.replace("private static var lastProgress", "static var lastProgress")
source = source.replace('fm.urls(for: .documentDirectory, in: .userDomainMask)[0]',
                        'URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)')

checks = r'''
enum DownloadNativeWaitingQueue {
  static func taskId(from task: URLSessionTask) -> String? { nil }
}
func progress(_ id: String, generation: Int = 1, value: Double = 0.4) {
  DownloadNativeDiagnosticLog.recordPluginProgress(
    taskId: id, parentTaskId: "aw_v2_test", attemptGeneration: generation,
    progress: value, inForeground: false
  )
}
DownloadNativeDiagnosticLog.configure(false)
progress("disabled")
DownloadNativeDiagnosticLog.configure(true)
progress("aw_v2_test.part.0")
progress("aw_v2_test.part.0", value: 0.5)
progress("aw_v2_test.part.1", value: 0.2)
progress("aw_v2_test.part.0", generation: 2, value: 0.1)
DownloadNativeDiagnosticLog.clearPluginProgress(taskId: "aw_v2_test.part.0", attemptGeneration: 1)
progress("aw_v2_test.part.0", generation: 2, value: 0.2)
progress("aw_v2_test.part.0", value: 0.45)
diagnosticTestNow += 1.1
progress("aw_v2_test.part.0", value: 0.6)
diagnosticTestNow += 4.0
progress("aw_v2_test.part.0", value: 0.65)
progress("aw_v2_test.part.0", value: 0.66)
progress("aw_v2_test.part.0", value: 1.0)
progress("", value: 0.5)
for value in [Double.nan, .infinity, -0.1, 1.1] { progress("invalid", value: value) }
for index in 0..<300 { progress("bounded.part.\(index)") }
precondition(DownloadNativeDiagnosticLog.lastProgress.count <= 256,
             "Diagnostics cannot retain every historical child")

let config = URLSessionConfiguration.ephemeral
config.isDiscretionary = true
config.sessionSendsLaunchEvents = false
config.timeoutIntervalForRequest = 111
config.timeoutIntervalForResource = 222
let session = URLSession(configuration: config)
DownloadNativeDiagnosticLog.recordSessionConfiguration(session)
DownloadNativeDiagnosticLog.recordSessionConfiguration(session)
DownloadNativeDiagnosticLog.record("privacy.check", fields: ["taskId": "safe",
  "url": "never-store-secret", "headers": ["Authorization": "never-store-secret"],
  "displayName": "never-store-secret", "sessionIdentifier": "never-store-secret"])
DownloadNativeDiagnosticLog.configure(true)
DownloadNativeDiagnosticLog.recordSessionConfiguration(session)
DownloadNativeDiagnosticLog.configure(false)
progress("disabled-again")
session.invalidateAndCancel()

let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("log")
let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
var rows: [[String: Any]] = []
for file in files {
  let text = try String(contentsOf: file, encoding: .utf8)
  precondition(!text.contains("never-store-secret"), "Private fields must not enter the native journal")
  rows += try text.split(separator: "\n").map {
    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
  }
}
let samples = rows.filter { $0["event"] as? String == "progress.plugin" }
precondition(samples.count == 306, "Invalid/disabled/within-cadence progress must not be logged")
let tail = samples.filter { $0["taskId"] as? String == "aw_v2_test.part.0" }
precondition(tail.count == 5, "Child, attempt and terminal cleanup must be independent")
precondition(!tail.contains { $0["progress"] as? Double == 0.6 || $0["progress"] as? Double == 0.66 },
             "Ordinary progress is throttled for five seconds")
precondition(tail.filter { $0["progress"] as? Double == 1.0 }.count == 1,
             "Final progress bypasses the cadence")
precondition(tail.filter { $0["attemptGeneration"] as? Int == 2 }.count == 1)
precondition(samples.filter { $0["taskId"] as? String == "aw_v2_test.part.1" }.count == 1,
             "A sibling must not hide the tail's progress")
for row in samples {
  precondition(row["bytes"] == nil && row["nativeTaskId"] == nil,
               "Normalized plugin observation must not claim exact transport bytes or execution identity")
  precondition(row["parentTaskId"] as? String == "aw_v2_test")
  precondition(row["inForeground"] as? Bool == false)
}
let sessions = rows.filter { $0["event"] as? String == "urlsession.configuration" }
precondition(sessions.count == 2, "Log each observed session once per logging enablement")
for row in sessions {
  precondition(row["backgroundSession"] as? Bool == false)
  precondition(row["isDiscretionary"] as? Bool == true)
  precondition(row["sessionSendsLaunchEvents"] as? Bool == false)
  precondition(row["requestTimeoutSeconds"] as? Double == 111)
  precondition(row["resourceTimeoutSeconds"] as? Double == 222)
}
let sequences = rows.compactMap { $0["sequence"] as? Int }.sorted()
precondition(sequences == Array(1...rows.count), "Every journal row has a unique ordered sequence")
print("PASS: real diagnostic logger, independent bounded progress cadence, privacy and observed configuration")
'''

if not shutil.which("swiftc"):
    print("SKIP: Swift compiler unavailable; production-source extraction passed")
    raise SystemExit(0)
with tempfile.TemporaryDirectory(prefix="ios-download-diagnostics-") as directory:
    swift = Path(directory) / "main.swift"
    cleanup = f'\nUserDefaults(suiteName: "{suite}")!.removePersistentDomain(forName: "{suite}")\n'
    swift.write_text("import Foundation\nvar diagnosticTestNow: TimeInterval = 100\n" + source + checks + cleanup)
    binary = Path(directory) / "checks"
    subprocess.run(["swiftc", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary), directory], check=True)
