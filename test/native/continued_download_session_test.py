"""Run patched production session selection with fake Foundation transport boundaries.

Requires ruby, swiftc and either flutter pub get or an extracted package at
BACKGROUND_DOWNLOADER_PLUGIN_ROOT. This exercises the CocoaPods patch
against the installed package, not a duplicate of its scheduling expression.
It does not simulate Apple's scheduling or replace an iOS device test.
"""
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
if os.environ.get('BACKGROUND_DOWNLOADER_PLUGIN_ROOT'):
    plugin = Path(os.environ['BACKGROUND_DOWNLOADER_PLUGIN_ROOT'])
else:
    packages = json.loads((ROOT / '.dart_tool/package_config.json').read_text())['packages']
    package = next(p for p in packages if p['name'] == 'background_downloader')
    plugin = Path(urlparse(package['rootUri']).path)
    if not plugin.is_absolute():
        plugin = (ROOT / '.dart_tool' / plugin).resolve()
relative = Path('ios/background_downloader/Sources/background_downloader')

FAKES = r'''
import Foundation
final class URLSessionConfiguration {
  var identifier: String?
  var timeoutIntervalForRequest = 45.0
  var timeoutIntervalForResource = 900.0
  var connectionProxyDictionary: [AnyHashable: Any]? = ["proxy": "test"]
  var httpMaximumConnectionsPerHost = 6
  var allowsCellularAccess = false
  var allowsExpensiveNetworkAccess = false
  var allowsConstrainedNetworkAccess = false
  var waitsForConnectivity = false
  static var `default`: URLSessionConfiguration { URLSessionConfiguration() }
}
class URLSessionTask {
  let taskIdentifier = 1
  let session: URLSession?
  init(session: URLSession? = nil) { self.session = session }
}
final class URLSessionUploadTask: URLSessionTask {}
final class URLSession {
  let configuration: URLSessionConfiguration
  let delegateQueue: OperationQueue
  var tasks: [URLSessionTask] = []
  init(configuration: URLSessionConfiguration, delegate: AnyObject?, delegateQueue: OperationQueue?) {
    self.configuration = configuration
    self.delegateQueue = delegateQueue ?? OperationQueue()
  }
  var allTasks: [URLSessionTask] { get async { tasks } }
  func downloadTask(with request: String) -> URLSessionTask { URLSessionTask(session: self) }
  func downloadTask(withResumeData data: Data) -> URLSessionTask { URLSessionTask(session: self) }
}
enum UrlSessionDelegate {
  static let instance = NSObject()
  static var urlSession: URLSession? = {
    let config = URLSessionConfiguration()
    config.identifier = "background"
    return URLSession(configuration: config, delegate: instance, delegateQueue: nil)
  }()
}
struct PageTask { var taskId: String }
enum BDPlugin {
  static let propertyLock = NSLock()
  static var uploaderForUrlSessionTaskIdentifier: [Int: String] = [1: "unrelated upload"]
}
'''
CHECKS = r'''
@main enum SessionChecks {
  static func main() async {
    let page = "aw_v2_manga_421dc0c7ff38d8deb02f962e5a88c399_g1_p0001"
    let background = UrlSessionDelegate.urlSession!
    let oldLease = NSObject(), newLease = NSObject()
    precondition(select(page) === background, "no lease uses daemon transport")
    AnimeWitcherDownloadSessions.activate(oldLease)
    precondition(select(page) === background,
                 "foreground page transfers must use the daemon-owned background URLSession")
    AnimeWitcherDownloadSessions.setForeground(false)
    let direct = select(page)
    precondition(direct !== background && direct.configuration.identifier == nil,
                 "a live continued lease must start manga pages without discretionary background scheduling")
    precondition(direct.delegateQueue === background.delegateQueue, "preserve serial delegate ordering")
    precondition(direct.configuration.timeoutIntervalForRequest == 45)
    precondition(direct.configuration.timeoutIntervalForResource == 900)
    precondition(direct.configuration.connectionProxyDictionary?["proxy"] as? String == "test")
    precondition(!direct.configuration.allowsCellularAccess &&
                 !direct.configuration.allowsExpensiveNetworkAccess &&
                 !direct.configuration.allowsConstrainedNetworkAccess,
                 "direct session preserves the network policies of the background session")
    precondition(direct.configuration.waitsForConnectivity)
    for id in ["aw_v2_video_x_g1", "aw_v2_manga_x_g1_p0001", page + ".part.0", "unrelated"] {
      precondition(select(id) === background, "other transfers keep background ownership")
    }
    AnimeWitcherDownloadSessions.activate(newLease)
    AnimeWitcherDownloadSessions.deactivate(oldLease)
    precondition(select(page) === direct, "stale expiration cannot revoke a replacement lease")
    AnimeWitcherDownloadSessions.setForeground(true)
    precondition(select(page) === background, "foreground return must select durable transport for new work")
    AnimeWitcherDownloadSessions.setForeground(false)
    let backgroundTask = URLSessionTask(), directTask = URLSessionTask()
    background.tasks = [backgroundTask]; direct.tasks = [directTask]
    let all = await AnimeWitcherDownloadSessions.allTasks()!
    precondition(all.count == 2 && all.contains { $0 === directTask } && all.contains { $0 === backgroundTask },
                 "pause/cancel/recovery inventory must see both sessions despite duplicate numeric task IDs")
    cleanUploader(for: directTask)
    precondition(BDPlugin.uploaderForUrlSessionTaskIdentifier[1] == "unrelated upload",
                 "a page completion cannot retire an upload with the same session-local numeric ID")
    cleanUploader(for: URLSessionUploadTask())
    precondition(BDPlugin.uploaderForUrlSessionTaskIdentifier.isEmpty)
    AnimeWitcherDownloadSessions.deactivate(newLease)
    precondition(select(page) === background, "expired lease restores daemon fallback for NEW work")
    let retained = await AnimeWitcherDownloadSessions.allTasks()!
    precondition(retained.count == 2 && direct.tasks.count == 1,
                 "expiry must not cancel, hide or recreate already-submitted direct transfers")
    print("PASS: lease-bound selection, stale expiry, config, inventory, upload ID safety, expiry fallback")
  }
}
'''
with tempfile.TemporaryDirectory(prefix='continued-download-session-') as directory:
    temp = Path(directory)
    shutil.copytree(plugin / relative, temp / relative)
    shutil.copyfile(plugin / 'pubspec.yaml', temp / 'pubspec.yaml')
    patch = ROOT / 'ios/downloader_continued_session_patch.rb'
    if patch.exists():
        invocation = f"require {json.dumps(str(patch))}; patch_background_downloader_continued_session(ARGV[0])"
        # Reject unsupported dependencies before touching any plugin source.
        original_version = (temp / 'pubspec.yaml').read_text()
        (temp / 'pubspec.yaml').write_text(original_version.replace('version: 9.6.5', 'version: 9.7.0'))
        original = {p.name: p.read_bytes() for p in (temp / relative).glob('*.swift')}
        rejected = subprocess.run(['ruby', '-e', invocation, str(temp)], capture_output=True)
        assert rejected.returncode != 0
        assert original == {p.name: p.read_bytes() for p in (temp / relative).glob('*.swift')}
        (temp / 'pubspec.yaml').write_text(original_version)
        subprocess.run(['ruby', '-e', invocation, str(temp)], check=True)
        before = {p.name: p.read_bytes() for p in (temp / relative).glob('*.swift')}
        subprocess.run(['ruby', '-e', invocation, str(temp)], check=True)
        assert before == {p.name: p.read_bytes() for p in (temp / relative).glob('*.swift')}, 'patch must be idempotent'
    if patch.exists():
        # The real plugin exports a Task struct. A broad import would shadow
        # Swift's concurrency Task in the manager's actor-hop closures.
        module = temp / 'plugin.swift'
        module.write_text('public struct Task { public init(url: String) {} }\n'
                          'public enum AnimeWitcherDownloadSessions {}\n')
        subprocess.run(['swiftc', '-emit-module', '-module-name', 'background_downloader',
                        str(module), '-emit-module-path', str(temp / 'background_downloader.swiftmodule')], check=True)
        manager = (ROOT / 'ios/Runner/DownloadContinuedProcessingManager.swift').read_text()
        imported = next(line for line in manager.splitlines() if line.startswith('import ') and 'background_downloader' in line)
        probe = temp / 'import.swift'
        probe.write_text(imported + '\nfunc launch() { Task { @MainActor in } }\n')
        subprocess.run(['swiftc', '-typecheck', '-I', str(temp), str(probe)], check=True)
        subprocess.run(['swiftc', '-frontend', '-parse', '-target', 'arm64-apple-ios15.0',
                        *map(str, (temp / relative).glob('*.swift'))], check=True)
    # The app's scene lifecycle must feed the plugin selection cache.
    runner = (ROOT / 'ios/Runner/DownloadNativeWaitingQueue.swift').read_text()
    assert 'AnimeWitcherDownloadSessions.setForeground(active)' in runner
    source = (temp / relative / 'BDPlugin.swift').read_text()
    expression = next(line.strip() for line in source.splitlines() if 'let urlSessionDownloadTask = resumeData' in line)
    selection = '''func select(_ id: String) -> URLSession {
      let task = PageTask(taskId: id), request = "test", resumeData: Data? = nil
      %s
      _ = urlSessionDownloadTask
      return %s
    }\n''' % (expression, 'urlSessionDownloadTask.session!')
    delegate = (temp / relative / 'UrlSessionDelegate.swift').read_text()
    cleanup = re.search(r'let multipartUploader = BDPlugin.propertyLock.withLock \{.*?\n        \}', delegate, re.S).group()
    helper = temp / relative / 'AnimeWitcherDownloadSessions.swift'
    if helper.exists():
        helper_source = helper.read_text()
        # No task lookup may omit direct transfers, including Wi-Fi and holding queue.
        for name in ['BDPlugin.swift', 'UrlSessionDelegate.swift', 'WiFi.swift', 'HoldingQueue.swift']:
            assert 'UrlSessionDelegate.urlSession?.allTasks' not in (temp / relative / name).read_text(), name
    else:
        # Characterize the old production scheduling expression before the fix.
        helper_source = '''enum AnimeWitcherDownloadSessions {
          static func activate(_ lease: AnyObject) {}
          static func deactivate(_ lease: AnyObject) {}
          static func allTasks() async -> [URLSessionTask]? { await UrlSessionDelegate.urlSession?.allTasks }
        }'''
    swift = temp / 'checks.swift'
    swift.write_text(FAKES + helper_source.replace('import Foundation', '') + '\n' + selection +
                     'func cleanUploader(for task: URLSessionTask) {\n' + cleanup + '\n_ = multipartUploader\n}\n' + CHECKS)
    executable = temp / 'checks'
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
