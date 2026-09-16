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
    """      completed: completed,\n      attemptGeneration: attemptGeneration(from: task)\n""",
    """      completed: completed,\n      attemptGeneration: attemptGeneration(from: task),\n      bridgeToDart: true\n""",
    "legacy chunk bridge ownership",
)

source = replace_once(
    source,
    """      completed: false,\n      attemptGeneration: attemptGeneration(fromPluginTask: task)\n""",
    """      completed: false,\n      attemptGeneration: attemptGeneration(fromPluginTask: task),\n      bridgeToDart: task.group == \"animewitcher_parts\"\n""",
    "supported plugin bridge ownership",
)

source = replace_once(
    source,
    """    normalizedProgress: Double?,\n    completed: Bool,\n    attemptGeneration: Int?\n  ) {\n    if totalWritten > 0 || completed || (normalizedProgress ?? 0) > 0 {\n      settleMultipartClaim(childTaskId: childId)\n    }\n""",
    """    normalizedProgress: Double?,\n    completed: Bool,\n    attemptGeneration: Int?,\n    bridgeToDart: Bool\n  ) {\n    if bridgeToDart &&\n       (totalWritten > 0 || completed || (normalizedProgress ?? 0) > 0) {\n      settleMultipartClaim(childTaskId: childId)\n    }\n""",
    "chunk sample ownership parameter",
)

old_notification = """    NotificationCenter.default.post(\n      name: Notification.Name(\"AnimeWitcherBackgroundDownloaderChunkUpdate\"),\n      object: nil,\n      userInfo: values\n    )\n"""
new_notification = """    if bridgeToDart {\n      NotificationCenter.default.post(\n        name: Notification.Name(\"AnimeWitcherBackgroundDownloaderChunkUpdate\"),\n        object: nil,\n        userInfo: values\n      )\n    }\n"""
source = replace_once(
    source,
    old_notification,
    new_notification,
    "legacy-only Dart notification",
)

path.write_text(source)
