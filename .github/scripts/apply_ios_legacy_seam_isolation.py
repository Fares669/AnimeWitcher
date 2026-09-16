from pathlib import Path


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return source.replace(old, new, 1)


path = Path("ios/Runner/DownloadNativeWaitingQueue.swift")
source = path.read_text()

source = replace_once(
    source,
    '''  static func isDownloadPart(_ task: URLSessionTask) -> Bool {
    let json = task.taskDescription?.components(separatedBy: "***<<<|>>>***").first ?? ""
    let group = stringFromTaskJson(json, key: "group")
    return group == "chunk" || group == "animewitcher_parts"
  }
''',
    '''  private static func downloadTaskGroup(_ task: URLSessionTask) -> String {
    let json = task.taskDescription?.components(separatedBy: "***<<<|>>>***").first ?? ""
    return stringFromTaskJson(json, key: "group") ?? ""
  }

  static func isPluginDownloadChunk(_ task: URLSessionTask) -> Bool {
    return downloadTaskGroup(task) == "chunk"
  }

  static func isLegacyDownloadPart(_ task: URLSessionTask) -> Bool {
    return downloadTaskGroup(task) == "animewitcher_parts"
  }

  static func isDownloadPart(_ task: URLSessionTask) -> Bool {
    return isPluginDownloadChunk(task) || isLegacyDownloadPart(task)
  }
''',
    "split plugin and legacy chunk identity",
)

source = replace_once(
    source,
    '''    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain,''',
    '''    // background_downloader owns retries for its own ParallelDownloadTask
    // chunks. The native seam only recreates migration-era legacy range parts.
    if isPluginDownloadChunk(task) { return false }

    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain,''',
    "plugin retry authority guard",
)
source = replace_once(
    source,
    "    let multipartPart = isDownloadPart(task)",
    "    let multipartPart = isLegacyDownloadPart(task)",
    "legacy-only manual retry",
)

source = replace_once(
    source,
    '''    // A native part is not an episode, but its URLSession byte/completion
    // evidence belongs to the Dart multipart parent. didFinishDownloadingTo
    // calls us after the plugin moved the temp file, so completion can now be
    // verified against the exact `.part` path by PersistentParallelDownload.
    if isDownloadPart(task) {''',
    '''    // background_downloader's own chunk completion is fully owned by its
    // native callback/Transfer pipeline. Do not let the migration seam free an
    // episode slot or promote another logical download when one chunk finishes.
    if isPluginDownloadChunk(task) { return }

    // A legacy PR #231 part is not an episode, but its URLSession byte/completion
    // evidence belongs to the Dart multipart parent. didFinishDownloadingTo
    // calls us after the plugin moved the temp file, so completion can now be
    // verified against the exact `.part` path by PersistentParallelDownload.
    if isLegacyDownloadPart(task) {''',
    "plugin completion authority guard",
)

source = replace_once(
    source,
    '''    guard isDownloadPart(task),
          let childId = taskId(from: task),''',
    '''    guard isLegacyDownloadPart(task),
          let childId = taskId(from: task),''',
    "legacy-only chunk bridge",
)

source = replace_once(
    source,
    '''        guard task.state != .completed,
              isDownloadPart(task),
              parentTaskId(from: task) == parentId''',
    '''        guard task.state != .completed,
              isLegacyDownloadPart(task),
              parentTaskId(from: task) == parentId''',
    "legacy-only promotion inventory",
)

source = replace_once(
    source,
    '''    if let session { rememberDownloadSession(session) }
    if isDownloadPart(downloadTask) {''',
    '''    if let session { rememberDownloadSession(session) }
    if isPluginDownloadChunk(downloadTask) { return }
    if isLegacyDownloadPart(downloadTask) {''',
    "legacy-only swizzled progress",
)

path.write_text(source)
