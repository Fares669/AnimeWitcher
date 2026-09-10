from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:160]!r}")
    file.write_text(text.replace(old, new, 1))


dart_log = 'lib/core/services/download_diagnostic_log.dart'
swift = 'ios/Runner/DownloadNativeWaitingQueue.swift'

# One multipart parent can have up to 16 children. Sampling each child once per
# second still means up to 16 file appends/fsync candidates per second. Collapse
# hot chunk telemetry to the logical parent while keeping terminal events.
replace_once(
    dart_log,
    """    final taskId = fields['taskId']?.toString() ?? '';\n    if (taskId.isEmpty) return false;\n    final terminal =\n        fields['result'] == true ||\n        fields['status'] != null ||\n        fields['errorType'] != null ||\n        fields['httpStatus'] != null;\n    if (terminal) {\n      _lastHighFrequencyEventAt.removeWhere(\n        (key, _) => key.endsWith(':$taskId'),\n      );\n      return false;\n    }\n\n    final key = '$event:$taskId';\n""",
    """    final taskId = fields['taskId']?.toString() ?? '';\n    if (taskId.isEmpty) return false;\n    final parentTaskId = fields['parentTaskId']?.toString() ?? '';\n    final sampleId = parentTaskId.isNotEmpty ? parentTaskId : taskId;\n    final terminal =\n        fields['result'] == true ||\n        fields['status'] != null ||\n        fields['errorType'] != null ||\n        fields['httpStatus'] != null;\n    if (terminal) {\n      _lastHighFrequencyEventAt.remove('$event:$sampleId');\n      return false;\n    }\n\n    final key = '$event:$sampleId';\n""",
)

# Progress logging is diagnostic telemetry, not a durable checkpoint. Forcing
# fsync on every sampled URLSession progress row amplifies I/O and heat when a
# multipart episode has many active children. Structural/error rows remain
# synchronously durable.
replace_once(
    swift,
    """        try handle.write(contentsOf: data)\n        try handle.synchronize()\n        size += data.count\n""",
    """        try handle.write(contentsOf: data)\n        if event != \"progress\" { try handle.synchronize() }\n        size += data.count\n""",
)

# UserDefaults.set already updates the process-visible state immediately and
# persists asynchronously. synchronize() on the URLSession hot path forces a
# synchronous disk flush for every sampled child and is not required for the
# native presentation cache; JobStore/manifest remain the durable authorities.
replace_once(
    swift,
    """  private static func saveLocked(_ state: State) {\n    if let data = try? JSONEncoder().encode(state) {\n      UserDefaults.standard.set(data, forKey: stateKey)\n      UserDefaults.standard.synchronize()\n    }\n  }\n""",
    """  private static func saveLocked(_ state: State) {\n    if let data = try? JSONEncoder().encode(state) {\n      UserDefaults.standard.set(data, forKey: stateKey)\n    }\n  }\n""",
)
