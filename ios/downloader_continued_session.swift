import Foundation

/// Copied into background_downloader by the Podfile patch. The package keeps
/// ownership of tasks, retries, files and callbacks on both sessions.
public enum AnimeWitcherDownloadSessions {
  private final class State: @unchecked Sendable {
    let lock = NSLock()
    var lease: ObjectIdentifier?
    var foreground = true
    var directSession: URLSession?
  }
  private static let state = State()

  public static func activate(_ lease: AnyObject) {
    state.lock.lock()
    defer { state.lock.unlock() }
    state.lease = ObjectIdentifier(lease)
  }

  public static func deactivate(_ lease: AnyObject) {
    state.lock.lock()
    defer { state.lock.unlock() }
    if state.lease == ObjectIdentifier(lease) { state.lease = nil }
  }

  public static func setForeground(_ foreground: Bool) {
    state.lock.lock()
    defer { state.lock.unlock() }
    state.foreground = foreground
  }

  static func session(forTaskId taskId: String) -> URLSession {
    let background = UrlSessionDelegate.urlSession!
    state.lock.lock()
    defer { state.lock.unlock() }
    // Foreground-created background URLSession tasks survive suspension.
    // Only background-created pages use the lease-bound direct session to
    // avoid iOS scheduling those background-created requests discretionary.
    guard state.lease != nil, !state.foreground,
          taskId.range(of: #"^aw_v2_manga_[0-9a-f]{32}_g[1-9][0-9]*_p[0-9]{4,}$"#,
                       options: .regularExpression) != nil else { return background }
    if let session = state.directSession { return session }
    let original = background.configuration
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = original.timeoutIntervalForRequest
    config.timeoutIntervalForResource = original.timeoutIntervalForResource
    config.connectionProxyDictionary = original.connectionProxyDictionary
    config.httpMaximumConnectionsPerHost = original.httpMaximumConnectionsPerHost
    config.allowsCellularAccess = original.allowsCellularAccess
    config.allowsExpensiveNetworkAccess = original.allowsExpensiveNetworkAccess
    config.allowsConstrainedNetworkAccess = original.allowsConstrainedNetworkAccess
    config.waitsForConnectivity = true
    let session = URLSession(configuration: config,
      delegate: UrlSessionDelegate.instance, delegateQueue: background.delegateQueue)
    state.directSession = session
    return session
  }

  private static func directSession() -> URLSession? {
    state.lock.lock()
    defer { state.lock.unlock() }
    return state.directSession
  }

  // Retain upstream's optional inventory shape so every guarded package read
  // can use this combined view, including pause/cancel, Wi-Fi and holding queue.
  // Expiration changes NEW task selection; existing tasks stay discoverable.
  static func allTasks() async -> [URLSessionTask]? {
    let backgroundTasks = await UrlSessionDelegate.urlSession?.allTasks ?? []
    let directTasks = await directSession()?.allTasks ?? []
    return backgroundTasks + directTasks
  }
}
