from pathlib import Path

path = Path('ios/Runner/DownloadContinuedProcessingManager.swift')
text = path.read_text()


def replace_once(old: str, new: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'expected exactly one match, found {count}: {old[:140]!r}')
    text = text.replace(old, new, 1)

replace_once(
    '''  private var identifier: String?\n  private var didRegisterIdentifier = false\n  private var currentEpisodeTaskId = ""\n''',
    '''  private var identifier: String?\n  private var submittedAt: Date?\n  private let attachmentGraceInterval: TimeInterval = 2.0\n  private var didRegisterIdentifier = false\n  private var currentEpisodeTaskId = ""\n''',
)

replace_once(
    '''    // Request already submitted for this session — never start a second\n    // Live Activity / continued-processing task when ep2 begins.\n    if let existingIdentifier = identifier {\n      return existingIdentifier\n    }\n\n    let sessionId = try sessionIdentifier()\n''',
    '''    // A submitted identifier is not proof that iOS actually attached a\n    // BGContinuedProcessingTask. Keep a short grace window for the scheduler\n    // callback, then clear a stale request so Dart can retry on the next live\n    // progress sample instead of believing a queued request is active forever.\n    if let existingIdentifier = identifier {\n      if let submittedAt,\n         Date().timeIntervalSince(submittedAt) < attachmentGraceInterval {\n        return existingIdentifier\n      }\n      cancelPendingRequest()\n      identifier = nil\n      submittedAt = nil\n    }\n\n    let sessionId = try sessionIdentifier()\n''',
)

replace_once(
    '''    request.strategy = .queue\n    do {\n      try scheduler.submit(request)\n    } catch {\n      identifier = nil\n      throw error\n    }\n    return sessionId\n''',
    '''    // This workload is user-initiated and only useful as system UI when\n    // it starts now. `.queue` can accept a request that never attaches while\n    // our Dart side incorrectly marks the overlay active. `.fail` gives an\n    // immediate rejection instead, and live progress will retry later.\n    request.strategy = .fail\n    do {\n      try scheduler.submit(request)\n      submittedAt = Date()\n    } catch {\n      identifier = nil\n      submittedAt = nil\n      throw error\n    }\n    return sessionId\n''',
)

replace_once(
    '''    if let task = activeTask {\n      apply(snapshot, to: task)\n    }\n    return activeTask != nil || identifier != nil\n  }\n''',
    '''    if let task = activeTask {\n      apply(snapshot, to: task)\n      return true\n    }\n\n    if let submittedAt,\n       Date().timeIntervalSince(submittedAt) < attachmentGraceInterval {\n      return true\n    }\n\n    // Submission was accepted but the launch handler never attached. Report\n    // the session as lost so Dart drops `_sessionOverlayActive` and retries.\n    if identifier != nil {\n      cancelPendingRequest()\n      identifier = nil\n      self.submittedAt = nil\n    }\n    return false\n  }\n''',
)

replace_once(
    '''    snapshot = nil\n    identifier = nil\n    currentEpisodeTaskId = ""\n  }\n\n  private func attach(_ task: BGContinuedProcessingTask) {\n    activeTask = task\n''',
    '''    snapshot = nil\n    identifier = nil\n    submittedAt = nil\n    currentEpisodeTaskId = ""\n  }\n\n  private func attach(_ task: BGContinuedProcessingTask) {\n    activeTask = task\n    submittedAt = nil\n''',
)

replace_once(
    '''        self.snapshot = nil\n        self.identifier = nil\n        self.currentEpisodeTaskId = ""\n''',
    '''        self.snapshot = nil\n        self.identifier = nil\n        self.submittedAt = nil\n        self.currentEpisodeTaskId = ""\n''',
)

path.write_text(text)
