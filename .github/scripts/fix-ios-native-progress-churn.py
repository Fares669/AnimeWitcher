from pathlib import Path

path = Path('ios/Runner/DownloadNativeWaitingQueue.swift')
text = path.read_text()

old = '  private static var lastProgress: [Int: TimeInterval] = [:]'
new = '  private static var lastProgress: [String: TimeInterval] = [:]'
if old not in text:
    raise SystemExit('lastProgress declaration not found')
text = text.replace(old, new, 1)

record_marker = '  static func record(_ event: String, task: URLSessionTask, error: Error? = nil) {'
helper = '''  private static func progressOwnerKey(_ task: URLSessionTask) -> String {
    if let taskId = DownloadNativeWaitingQueue.taskId(from: task), !taskId.isEmpty {
      if let part = taskId.range(of: ".part.", options: .backwards) {
        return String(taskId[..<part.lowerBound])
      }
      return taskId
    }
    return "native:\\(task.taskIdentifier)"
  }

'''
if record_marker not in text:
    raise SystemExit('record marker not found')
if 'private static func progressOwnerKey(' not in text:
    text = text.replace(record_marker, helper + record_marker, 1)

old_progress = '''      if event == "progress" {
        if let previous = lastProgress[task.taskIdentifier], now - previous < 1.0 { return }
        lastProgress[task.taskIdentifier] = now
      } else {
        lastProgress.removeValue(forKey: task.taskIdentifier)
      }
'''
new_progress = '''      let progressKey = progressOwnerKey(task)
      if event == "progress" {
        if let previous = lastProgress[progressKey], now - previous < 1.0 { return }
        lastProgress[progressKey] = now
      } else {
        lastProgress.removeValue(forKey: progressKey)
      }
'''
if old_progress not in text:
    raise SystemExit('progress sampling block not found')
text = text.replace(old_progress, new_progress, 1)

old_save = '''    if shouldUpdateNativeOverlay { lastMultipartOverlayTimes[parentId] = now }
    saveLocked(state)
    lock.unlock()
'''
new_save = '''    if shouldUpdateNativeOverlay { lastMultipartOverlayTimes[parentId] = now }
    if shouldUpdateNativeOverlay || completed {
      saveLocked(state)
    }
    lock.unlock()
'''
if old_save not in text:
    raise SystemExit('multipart persistence block not found')
text = text.replace(old_save, new_save, 1)

path.write_text(text)
