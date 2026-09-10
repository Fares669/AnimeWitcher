from pathlib import Path

path = Path('ios/Runner/DownloadNativeWaitingQueue.swift')
text = path.read_text()
old = '''      promoteMultipartIfPossible(on: session, parentId: parentTaskId(from: downloadTask))\n      return\n    }\n    guard let id = taskId(from: downloadTask) else { return }\n'''
new = '''      // Progress does not free a connection slot. Re-probing URLSession here\n      // made every didWrite callback call getAllTasks while multiple ranges\n      // were active. Initial background handoff and child completion are the\n      // only ownership changes that can require a refill.\n      return\n    }\n    guard let id = taskId(from: downloadTask) else { return }\n'''
if text.count(old) != 1:
    raise SystemExit(f'expected exactly one multipart progress refill call, found {text.count(old)}')
path.write_text(text.replace(old, new, 1))
