from pathlib import Path

path = Path('lib/core/services/persistent_parallel_download.dart')
text = path.read_text()

replacements = [
    (
        """      try {\n        await pausePart(part.task);\n      } catch (_) {\n        // The worker can already be a stale URLSession bookkeeping entry.\n      }\n\n      if (await _adoptExactSizePart(session, part, settleNativeOwner: false)) {\n""",
        """      try {\n        await pausePart(part.task);\n      } catch (_) {\n        // Do not free/reuse the Range while the previous native writer may\n        // still own it. Keep the same child live and retry settlement later.\n        part.tailRecoveryAttempted = false;\n        _armTailStallWatch(session, part);\n        return;\n      }\n\n      if (await _adoptExactSizePart(session, part, settleNativeOwner: false)) {\n""",
    ),
    (
        """    _cancelTailStallWatch(part);\n    _activeConnectionIds.remove(part.task.taskId);\n    part.launched = false;\n    part.speed = 0;\n    session.currentBatchPendingIds.remove(part.task.taskId);\n\n    try {\n      await cancelParts(<String>[part.task.taskId]);\n    } catch (_) {\n      // Recovery remains safe even if native already forgot this child.\n    }\n\n    if (backup != null) {\n""",
        """    try {\n      await cancelParts(<String>[part.task.taskId]);\n    } catch (_) {\n      // Unknown cancellation outcome means ownership is still unsettled.\n      // Preserve the active lease and never expose this Range to a new writer.\n      if (backup != null) {\n        try {\n          if (await backup.exists()) await backup.delete();\n        } catch (_) {}\n      }\n      _armTailStallWatch(session, part);\n      return;\n    }\n\n    _cancelTailStallWatch(part);\n    _activeConnectionIds.remove(part.task.taskId);\n    part.launched = false;\n    part.speed = 0;\n    session.currentBatchPendingIds.remove(part.task.taskId);\n\n    if (backup != null) {\n""",
    ),
    (
        """    if (settleNativeOwner) {\n      try {\n        await pausePart(part.task);\n      } catch (_) {\n        // A task that has already finished natively may no longer be pausable.\n        // The second exact-size verification below remains the source of truth.\n      }\n    }\n""",
        """    if (settleNativeOwner) {\n      try {\n        await pausePart(part.task);\n      } catch (_) {\n        // Exact bytes prove content, not that the prior writer relinquished\n        // ownership. Fail closed until native ownership is acknowledged settled.\n        return false;\n      }\n    }\n""",
    ),
]

for old, new in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'expected exactly one DM-23 anchor, found {count}: {old[:80]!r}')
    text = text.replace(old, new, 1)

path.write_text(text)
