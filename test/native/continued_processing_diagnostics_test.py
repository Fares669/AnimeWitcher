"""Supplementary lifecycle/privacy wiring guards; Apple runtime tests still apply."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "ios/Runner/DownloadContinuedProcessingManager.swift").read_text()


class ContinuedProcessingDiagnosticsTests(unittest.TestCase):
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
