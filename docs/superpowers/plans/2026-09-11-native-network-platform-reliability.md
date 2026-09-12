# Native, Network, Platform Reliability Implementation Plan

> **For Agent:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

`DOWNLOAD_MANAGER_PLAN.md` remains the sole source of truth for scope, dependency status, acceptance criteria, and checkbox state. This document only records Agent 3 execution sequencing and TDD targets. Never mark a DM complete from this file.

## Scope and dependency gate

Agent 3 owns only DM-22, DM-23, DM-09, DM-13, DM-27, DM-14, DM-15, DM-26, DM-28, and DM-18.

Before every task:

1. Refresh `plan/download-manager-reliability` and reread the owned DM plus every listed dependency in `DOWNLOAD_MANAGER_PLAN.md`.
2. Confirm dependencies are present in the actual base branch, not merely open in another PR.
3. If a dependency is missing, do not recreate it and do not add a compatibility workaround. Move to the next eligible owned DM.
4. For every bug/race: reproduce -> confirm root cause -> add a failing behavioral regression -> make the smallest fix -> run the focused test -> run related regression tests -> run platform verification when applicable.
5. Update only Agent 3 DMs in `DOWNLOAD_MANAGER_PLAN.md`, and only after fresh verification evidence exists.

Current gate captured on 2026-09-11:

- DM-22: blocked by DM-10 and DM-15.
- DM-23: blocked by DM-10.
- DM-09: blocked by DM-05.
- DM-13: blocked by DM-10.
- DM-27: blocked by DM-06.
- DM-14: blocked by DM-04, DM-06, DM-07, DM-11, DM-24.
- DM-15: blocked by DM-10 and DM-11.
- DM-26: blocked by DM-15 and DM-22.
- DM-28: blocked by DM-09.
- DM-18: final gate; blocked until every preceding DM in the master plan is complete and merged.

## Primary implementation surfaces

Dart download core:

- `lib/core/services/download_service.dart`
- `lib/core/services/download_concurrency.dart`
- `lib/core/services/download_connection_governor.dart`
- `lib/core/services/download_continued_processing_service.dart`
- `lib/core/services/download_job_state.dart`
- `lib/core/services/download_job_store.dart`
- `lib/core/services/download_range_transfer.dart`
- `lib/core/services/download_retry_policy.dart`
- `lib/core/services/download_transport.dart`
- `lib/core/services/persistent_parallel_download.dart`
- `lib/core/utils/download_cleanup.dart`
- `lib/core/storage/storage_service.dart`

Native iOS:

- `ios/Runner/AppDelegate.swift`
- `ios/Runner/DownloadContinuedProcessingManager.swift`
- `ios/Runner/DownloadNativeWaitingQueue.swift`
- `ios/Runner/Info.plist`

Platform policy/configuration:

- `android/app/src/main/AndroidManifest.xml`
- Android runner/service sources selected by the current implementation after dependency refresh.
- `pubspec.yaml` / lockfile only when DM-26 behavioral evidence proves a dependency change is required.

Existing regression suites to extend rather than replace include:

- `test/core/services/download_concurrency_test.dart`
- `test/core/services/download_connection_governor_test.dart`
- `test/core/services/download_range_transfer_test.dart`
- `test/core/services/download_retry_policy_test.dart`
- `test/core/services/download_recovery_fault_injection_test.dart`
- `test/core/services/download_relaunch_chaos_test.dart`
- `test/core/services/download_runtime_ownership_test.dart`
- `test/core/services/download_service_queue_test.dart`
- `test/core/services/persistent_parallel_download_test.dart`
- `test/core/services/persistent_parallel_download_recovery_snapshot_test.dart`
- `test/core/services/ios_continued_processing_expiration_test.dart`
- `test/core/services/ios_download_url_session_selector_test.dart`
- `test/core/services/ios_multipart_native_bridge_source_test.dart`

## Task 1: DM-09 network interruption state machine

**Dependency:** DM-05 + DM-03 must be present on base.

**Tests to add/extend:**

- Create `test/core/services/download_network_interruption_behavior_test.dart`.
- Extend `test/core/services/download_retry_policy_test.dart` and `download_range_transfer_test.dart` only where policy boundaries already live there.

**RED cases:** offline before start; loss after first byte; Wi-Fi/cellular transition; DNS failure; captive-style connection failure; 408/425/429/5xx; server Retry-After; retry exhaustion; user pause while offline; duplicate reconnect notifications. Assert `waitingForNetwork` is distinct from server backoff, user pause, and terminal exhaustion.

**Minimal implementation:** introduce one canonical interruption classification/state transition shared by plugin transport, Dart ranges, multipart, and iOS continuation adapters. Do not reinterpret user pause as network wait and do not burn server retry budget while offline.

**Focused verification:**

`flutter test test/core/services/download_network_interruption_behavior_test.dart test/core/services/download_retry_policy_test.dart test/core/services/download_range_transfer_test.dart`

## Task 2: DM-13 remove cross-host head-of-line blocking

**Dependency:** DM-10 + DM-01 + DM-25.

**Tests to add/extend:**

- Create `test/core/services/download_promotion_fairness_test.dart`.
- Extend `test/core/services/download_concurrency_test.dart` and `download_connection_governor_test.dart`.

**RED cases:** one host stalls during probe/promotion while another host is healthy; 1/5/8/16-part jobs; queue concurrency 1..10; pause/cancel during promotion; host backoff isolated to that host. Assert bounded promotion latency for healthy work.

**Minimal implementation:** remove awaits under global promotion/queue critical sections; keep reservation/commit atomic while moving slow host/network work outside global serialization.

## Task 3: DM-27 storage headroom and resumable insufficientStorage

**Dependency:** DM-06 + DM-03.

**Tests to add:**

- `test/core/services/download_storage_headroom_test.dart`

**RED cases:** parts fit but final staging/assembly does not; disk pressure appears during transfer; disk pressure appears before assembly; valid parts survive; typed `insufficientStorage`; retry succeeds after capacity is restored.

**Minimal implementation:** compute required headroom across remaining parts + staging/assembly overhead according to the current artifact strategy. Never delete verified parts merely to convert a storage failure into a restart.

## Task 4: DM-14 canonical, ownership-proven orphan cleanup

**Dependencies:** DM-04, DM-06, DM-07, DM-11, DM-24.

**Tests to add/extend:**

- Create `test/core/utils/download_cleanup_containment_test.dart`.
- Extend manifest/inventory tests only for app-ownership proof.

**RED cases:** `..`; symlink escape; root lookalikes; mixed separators; Windows case behavior; custom download root; unknown user file; orphan manifest; orphan part; path normalizes outside root. Assert unknown/unproven files are retained.

**Minimal implementation:** canonicalize the configured root and candidate, verify filesystem containment and app-owned provenance before deletion, and fail closed when ownership cannot be proven.

## Task 5: DM-15 versioned, acknowledged iOS queue snapshots

**Dependencies:** DM-10 + DM-11.

**Tests to add:**

- `test/core/services/ios_queue_snapshot_protocol_test.dart`

**Native behavioral coverage:** add/extend XCTest target if present after dependency refresh; otherwise introduce a small protocol model that can be behaviorally exercised from Dart and compile/typecheck the Swift integration.

**RED cases:** stale snapshot after newer ack; duplicate snapshot; method-channel send failure; suspension before ack; native completion while Flutter sleeps; persistence failure/corruption; overlay update racing ownership checkpoint. Assert UI overlay data cannot advance ownership epoch.

**Minimal implementation:** snapshot version/epoch + ack protocol with persisted last-applied/last-acked state and idempotent duplicate handling. Keep presentation overlay events separate from ownership checkpoint messages.

## Task 6: DM-22 explicit Dart <-> Swift multipart ownership fencing

**Dependencies:** DM-10 + DM-15 + DM-01.

**Tests to add:**

- `test/core/services/ios_multipart_claim_fencing_test.dart`

**Protocol:** parent, child, generation, claimId, lease expiry, owner/requestedOwner, ack epoch and part path as specified by the master plan.

**RED cases:** background during owner selection; foreground before resume; stale snapshot; claim expiration; suspension; duplicate snapshot; delayed first byte; Dart tries to resume while Swift claim is live; Swift tries to claim the current Dart generation. Assert never more than one writer for `(parent, child, generation)`.

**Minimal implementation:** make claims durable before execution, require acknowledgement at ownership transfer boundaries, reject stale generation/claimId, and fence late callbacks/writes after ownership changes.

## Task 7: DM-23 bytesVerified is not ownerSettled

**Dependency:** DM-10 + DM-19.

**Tests to add:**

- `test/core/services/download_owner_settlement_test.dart`

**RED cases:** full-sized part while old writer remains active; failed pause/cancel; retiring owner sends late bytes; restart while settlement is unresolved; assembly/delete/recycle/relaunch attempted before settlement. Assert bytes can be verified while reuse remains forbidden.

**Minimal implementation:** explicit settlement state (`absent` / `activeOwner` / `retiring` / `settled` / `provenDead` or exact contract from base) and gates for destructive/reuse operations.

## Task 8: DM-26 behavior-first background_downloader 9.6.1 integration review

**Dependencies:** DM-15 + DM-22.

**Tests to add:**

- `test/core/services/background_downloader_behavior_test.dart`

**RED/characterization cases first:** foreground/background status and bytes; retry replacement; suspension/resume; duplicated callback; missing callback; stale task callback; plugin callback vs custom URLSession hook ordering.

Only after characterization, map official package callbacks/APIs used by 9.6.1 against the custom swizzle surface. Remove a custom hook only if behavioral coverage proves the official path preserves all required semantics. Do not update the package merely to simplify code.

**iOS verification:**

`xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build`

## Task 9: DM-28 explicit platform execution projection

**Dependency:** DM-09.

**Tests to add:**

- `test/core/services/download_platform_execution_policy_test.dart`

**iOS cases:** logical setting 1/5/6/10 in foreground and background; explicit effective cap/projection when native runtime differs.

**Android 14+ cases:** notifications allowed; notifications denied; notifications disabled in-app; long-running transfer; foreground/UIDT/WorkManager fallback as supported by project/platform. Assert a user-facing logical setting is never silently projected to a lower platform cap.

**Android verification:** compile the configured app variant and inspect manifest/service requirements after implementation. Use the repository's Gradle wrapper and actual module/task names resolved from base before running.

## Task 10: DM-18 deterministic chaos/reliability release gate

**Dependency:** every earlier DM in `DOWNLOAD_MANAGER_PLAN.md` must be complete and merged. This task is always last.

**Tests to add:**

- `test/core/services/download_deterministic_chaos_matrix_test.dart`
- Add native/platform integration tests where Dart cannot exercise the behavior directly.

Use a deterministic fake scheduler/clock and callback injector to control dropped, delayed, duplicated, and reordered callbacks; runtime ownership ambiguity; persistence failure; crash injection; network changes; HTTP status behavior; Dart/Swift handoff races; resume after relaunch; multipart 1/5/8/16; queue concurrency changes.

Source-string assertions are allowed only as supplemental configuration guards. DM-18 does not pass from source-string checks alone.

## Final verification before marking any release gate ready

Run fresh evidence from the final head:

1. Focused tests for every changed subsystem.
2. Related download-manager regression suites.
3. `flutter test`
4. `flutter analyze --no-fatal-warnings --no-fatal-infos`
5. iOS simulator build/typecheck for Swift-sensitive changes.
6. Android compile/config verification for DM-28 changes.
7. Confirm `DOWNLOAD_MANAGER_PLAN.md` checkboxes/notes match only verified, merged prerequisites and verified Agent 3 work.
8. Recompare this branch against latest `plan/download-manager-reliability` before declaring the PR ready.

Do not mark a DM `[x]` if required platform behavior could not be exercised; record the limitation/blocker instead.
