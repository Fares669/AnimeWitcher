from pathlib import Path

path = Path('DOWNLOAD_MANAGER_PLAN.md')
text = path.read_text()
old = """- [ ] **DM-01 — Add a generation-bound lease/watchdog for multipart `pending-start` ownership**
  - **Problem:** `startPart()` can return `true` while no running/progress/final callback ever arrives, leaving the child in `currentBatchPendingIds` and blocking subsequent slow-start batches.
  - **Root cause:** reservation-before-enqueue correctly closes one race, but accepted start has no deadline that converts it into verified ownership or rollback.
  - **Severity / priority:** **P0 / Critical. First implementation item.**
  - **Expected files/areas:** `persistent_parallel_download.dart`, DownloadService liveness seam, multipart auto-recovery tests.
  - **Proposed fix:** attach a lease to `(parent, child, attemptGeneration)`. On lease expiry, query real ownership and durable bytes. Adopt proven ownership; otherwise roll back only that reservation and schedule fenced recovery. Never launch while ownership remains unknown.
  - **Verification/testing:** accepted start/no callback; callback after lease expiry; pause/cancel during lease; app reconciliation during lease; 1/2/5/8/16 parts; global-budget contention; exactly one writer.
  - **Dependencies:** None.
"""
new = """- [x] **DM-01 — Add a generation-bound lease/watchdog for multipart `pending-start` ownership**
  - **Problem:** `startPart()` can return `true` while no running/progress/final callback ever arrives, leaving the child in `currentBatchPendingIds` and blocking subsequent slow-start batches.
  - **Root cause:** reservation-before-enqueue correctly closes one race, but accepted start has no deadline that converts it into verified ownership or rollback.
  - **Severity / priority:** **P0 / Critical. First implementation item.**
  - **Expected files/areas:** `persistent_parallel_download.dart`, DownloadService liveness seam, multipart auto-recovery tests.
  - **Proposed fix:** attach a lease to `(parent, child, attemptGeneration)`. On lease expiry, query real ownership and durable bytes. Adopt proven ownership; otherwise roll back only that reservation and schedule fenced recovery. Never launch while ownership remains unknown.
  - **Verification/testing:** accepted start/no callback; callback after lease expiry; pause/cancel during lease; app reconciliation during lease; 1/2/5/8/16 parts; global-budget contention; exactly one writer.
  - **Dependencies:** None.
  - **Implementation notes (2026-09-11):** Added a generation-bound pending-start lease to each multipart child reservation. Lease expiry rechecks runtime liveness, adopts proven exact-size durable bytes, preserves the reservation while ownership is unknown, and otherwise rolls back only that child before fenced recovery. Lease timers are canceled on readiness, release, recovery, pause/reset, and disposal; reconciliation converts proven live pending children to ready ownership without duplicate launch.
  - **Confirmed root cause:** accepted native enqueue previously had no post-acceptance deadline, so a missing readiness callback could reserve the slow-start slot indefinitely.
  - **Verification passed:** regression coverage includes accepted start/no callback retry with a new attempt generation, proven runtime ownership without duplicate writer, unknown-liveness fail-closed behavior, reconciliation during the lease, and pause during the lease. `Flutter Checks` completed successfully for commit `6250ca886205472fbdeaaaad71a269f5e162915b` after the final test correction; the later head-only check had `action_required` with no jobs after verifier cleanup and is not a test failure.
"""
if text.count(old) != 1:
    raise SystemExit(f'Expected exactly one DM-01 block, found {text.count(old)}')
path.write_text(text.replace(old, new, 1))
