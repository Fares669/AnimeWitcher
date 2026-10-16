"""Supplementary lifecycle/privacy wiring guards; Apple runtime tests still apply."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "ios/Runner/DownloadContinuedProcessingManager.swift").read_text()
QUEUE = (ROOT / "ios/Runner/DownloadNativeWaitingQueue.swift").read_text()


class ContinuedProcessingDiagnosticsTests(unittest.TestCase):
    def test_supported_progress_is_recorded_before_multipart_early_return(self):
        start = QUEUE.index("private static func handleSupportedPluginProgress(")
        end = QUEUE.index("\n  static func handleBytesWritten(", start)
        callback = QUEUE[start:end]
        self.assertIn("DownloadNativeDiagnosticLog.recordPluginProgress(", callback)
        journal = callback.index("DownloadNativeDiagnosticLog.recordPluginProgress(")
        self.assertLess(journal, callback.index("if postV2ParallelChunkMetric("))
        for field in ("parentTaskId(fromPluginTask: task)", "attemptGeneration(fromPluginTask: task)",
                      "progress: normalized", "inForeground: isAppInForeground()"):
            self.assertIn(field, callback[:callback.index("if postV2ParallelChunkMetric(")])

    def test_progress_throttle_is_per_child_attempt_bounded_and_does_not_fsync(self):
        self.assertIn("static func recordPluginProgress(", QUEUE)
        start = QUEUE.index("static func recordPluginProgress(")
        end = QUEUE.index("static func recordSessionConfiguration(", start)
        progress = QUEUE[start:end]
        self.assertIn("taskId", progress)
        self.assertIn("attemptGeneration", progress)
        self.assertNotIn("progressOwnerKey", progress)
        self.assertTrue("now - previous < 5.0" in progress, "Progress diagnostics need a five-second cadence")
        self.assertTrue("progress < 1" in progress, "Final plugin progress must bypass throttling")
        self.assertIn("lastProgress.count > 256", progress)
        self.assertIn('recordLocked("progress.plugin"', progress)
        self.assertIn('event != "progress" && event != "progress.plugin"', QUEUE)
        status = QUEUE[QUEUE.index("private static func handleSupportedPluginStatus("):QUEUE.index("private static func handleSupportedPluginProgress(")]
        self.assertIn("DownloadNativeDiagnosticLog.clearPluginProgress(", status)
        self.assertIn("attemptGeneration: attemptGeneration(fromPluginTask: task)", status)

    def test_scene_and_actual_configuration_are_observed_without_transport_changes(self):
        refresh = QUEUE[QUEUE.index("private static func refreshForegroundState("):QUEUE.index("/// Scene visibility")]
        self.assertIn('record("application.visibility"', refresh)
        remember = QUEUE[QUEUE.index("private static func rememberDownloadSession("):QUEUE.index("static func acceptsDartOverlayUpdates(")]
        self.assertIn("DownloadNativeDiagnosticLog.recordSessionConfiguration(session)", remember)
        logger = QUEUE[:QUEUE.index("import ObjectiveC")]
        self.assertIn('recordLocked("urlsession.configuration"', logger)
        for private_field in ('"url"', '"headers"', '"displayName"', '"responseBody"',
                              '"sessionIdentifier"', '"Authorization"', '"Cookie"'):
            self.assertNotIn(private_field, logger)
        for mutation in (".resume()", ".cancel()", ".suspend()", "class_addMethod", "method_setImplementation"):
            self.assertNotIn(mutation, logger)

    def test_submission_and_attachment_are_distinct_events(self):
        request = SOURCE.index('recordLifecycle("continued.submit.requested")')
        submit = SOURCE.index("try scheduler.submit(request)", request)
        accepted = SOURCE.index('recordLifecycle("continued.submit.accepted")', submit)
        failed = SOURCE.index('recordLifecycle("continued.submit.failed"', accepted)
        self.assertLess(request, submit)
        self.assertLess(submit, accepted)
        self.assertLess(accepted, failed)
        self.assertIn('recordLifecycle("continued.attached")', SOURCE)
        self.assertIn('"failure": "schedulerSubmission"', SOURCE)
        self.assertIn('"errorCode": (error as NSError).code', SOURCE)

    def test_expiration_is_recorded_before_completion_and_state_clear(self):
        start = SOURCE.index("task.expirationHandler = {")
        end = SOURCE.index('recordLifecycle("continued.attached")', start)
        expiration = SOURCE[start:end]
        event = expiration.index('record("continued.expired"')
        completion = expiration.index("completion.finish { task.setTaskCompleted(success: false) }")
        main_hop = expiration.index("Task { @MainActor")
        clear = expiration.index("self.activeTask = nil")
        self.assertLess(event, completion)
        self.assertLess(completion, main_hop)
        self.assertLess(main_hop, clear)
        self.assertIn("self.activeTask === task", expiration)
        self.assertNotIn("cancellationHandler?", expiration)
        self.assertNotIn('"reason"', expiration)
        self.assertIn('"completedUnits": task.progress.completedUnitCount', expiration)
        self.assertIn('"totalUnits": task.progress.totalUnitCount', expiration)

    def test_completion_uses_verified_success_and_fixed_status_labels(self):
        start = SOURCE.index("let verifiedSuccess = success && snapshotLooksComplete")
        finish = SOURCE.index('recordLifecycle("continued.finished"', start)
        clear = SOURCE.index("activeTask = nil", finish)
        self.assertLess(start, finish)
        self.assertLess(finish, clear)
        self.assertIn('"success": verifiedSuccess', SOURCE[finish:clear])
        self.assertIn('status == "canceled" ? "canceled" : "paused"', SOURCE[finish:clear])
        self.assertIn("completion.finish { task.setTaskCompleted(success: verifiedSuccess) }", SOURCE)

    def test_metadata_excludes_display_text_and_freeform_errors(self):
        helper_start = SOURCE.index("private func recordLifecycle(")
        helper_end = SOURCE.index("\n  func start(", helper_start)
        metadata = SOURCE[helper_start:helper_end]
        for private_field in ("displayName", "url", "headers", "localizedDescription", "responseBody"):
            self.assertNotIn(private_field, metadata)
        self.assertNotIn("error.localizedDescription", SOURCE)
        self.assertNotIn('"reason"', SOURCE)
        expected_keys = {
            "leaseIdentifier", "taskId", "requestAgeMillis", "leaseAgeMillis",
            "progress", "transferredBytes", "totalBytes", "completedCount", "batchTotal",
        }
        self.assertEqual(set(re.findall(r'metadata\["([^"]+)"\]', metadata)), expected_keys)


if __name__ == "__main__":
    unittest.main()
