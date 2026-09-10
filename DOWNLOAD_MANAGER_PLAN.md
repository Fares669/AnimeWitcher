# AnimeWitcher Download Manager Reliability Plan

> **Source of truth for all download-manager reliability work in PR #231.**
>
> This document is the result of two review-only passes. The review commits intentionally change no download logic, perform no refactor, and add no feature. Every implementation item remains unchecked so later Tasks can resume from the first eligible `[ ]` item while using the same branch and PR.

## Review baseline and scope

- Reviewed against `main` commit `7f25aadf6f18008a93aa95dddf5d7810bdb73279` (tree `8ac644f7dcae67d3326ca71a90de4be918f09d9c`).
- Primary Dart orchestration reviewed end-to-end: `download_service.dart`, `persistent_parallel_download.dart`, `download_transport.dart`, `download_range_transfer.dart`, `download_retry_policy.dart`, `download_concurrency.dart`, `download_connection_governor.dart`, `download_host_profile.dart`, `download_job_state.dart`, `download_job_store.dart`, `download_parallel.dart`, `download_plugin_compat.dart`, `download_url_refresh.dart`, `download_telemetry.dart`, and download utilities.
- Persistence/UI integration reviewed: `storage_service.dart`, `downloads_provider.dart`, `download_launcher.dart`, download cleanup/resume utilities, database/metadata projections, and user control paths.
- iOS native/background integration reviewed in depth: `DownloadContinuedProcessingManager.swift`, `DownloadNativeWaitingQueue.swift`, its URLSession delegate IMP hooks, `AppDelegate.swift`, native queue snapshots, multipart promotion, background retry, and the Dart bridge.
- Platform policy reviewed: Android UIDT/background requirements, macOS download entitlements, iOS continued-processing/background URLSession behavior, and cross-platform concurrency assumptions.
- Recent download-manager commit history was reviewed because many iOS/multipart/progress/thermal fixes landed close together; interaction regressions are therefore explicitly part of this plan.
- Existing download tests were reviewed, including recovery, relaunch chaos, fault injection, startup reconciliation, range transfer, URL refresh, transport, concurrency, multipart recovery/tail recovery, telemetry, zero-restart invariants, JobStore invariants, and iOS bridge/source tests.
- External dependency review date: **2026-09-10**. `pubspec.lock` is on `background_downloader 9.6.0`; `9.6.1` is available and adds supported iOS native status/progress callbacks. Any dependency change is an implementation item, not part of this review commit.

## Current architecture and lifecycle

### Main components

1. **Launch/source resolution** — `download_launcher.dart` resolves a provider/source, probes metadata/range capability, persists a URL-refresh descriptor, and calls `DownloadService.startDownload()`.
2. **Logical queue/orchestration** — `download_service.dart` owns user-facing lifecycle, queue slots, pause/resume/cancel, source refresh, native transport rehydration, restart recovery, and state projection.
3. **Single-file native transport** — `download_transport.dart` uses the `background_downloader` Transfer API for normal one-file downloads.
4. **Visible-prefix fallback** — `download_range_transfer.dart` performs validated Range continuation when durable bytes are visible to Dart.
5. **Multipart coordinator** — `persistent_parallel_download.dart` owns immutable ranges, attempt generations, manifests, slow start, connection reservations, retries, disk polling, source validation, and final assembly.
6. **Durable logical state** — `DownloadJobStore` is intended to be logical authority, but state is still replicated across plugin DB/resume data, Hive metadata, manifests/files, refresh descriptors, iOS UserDefaults queue state, and process-local sets/maps.
7. **UI projection** — `downloads_provider.dart` combines plugin records, metadata, and service events and currently performs some persistence normalization/deletion itself.
8. **iOS background continuity** — Dart exports queue/multipart plans to Swift; Swift can promote URLSession tasks while Flutter is suspended and sends native byte/status evidence back when Flutter is available.

### Lifecycle traces

- **Fresh download:** source resolve -> metadata/range probe -> refresh descriptor -> logical JobStore/metadata state -> queue reservation -> single native transport or multipart coordinator -> progress/status -> final verification -> completion persistence.
- **Pause:** record user intent -> stop/join Dart range writer if active -> pause native/multipart ownership -> reconcile transport ownership -> project paused logical state.
- **Resume:** reconcile ownership -> clear user-pause intent -> reconstruct task/bytes -> possibly refresh source -> native resume, visible-prefix Range continuation, multipart restore, or safe restart -> establish queue/transport ownership -> project accepted result.
- **Failure/retry:** classify HTTP/network/storage failure -> retry/backoff/refresh/reconcile or park -> preserve durable bytes -> eventually re-enter normal fenced start/resume path.
- **App restart/crash:** restore JobStore + metadata + plugin DB/native ownership + manifests/files -> derive one logical inventory -> preserve user intent -> rebuild queue -> reconcile again on foreground.
- **Network interruption:** currently split between Transfer behavior, Dart Range retries, multipart child recovery, and custom iOS URLSession retries; this must converge onto one logical policy.
- **Cancel/delete:** durable cancel intent/tombstone should precede ownership settlement; destructive DB/file cleanup must happen only when stale writers cannot return.

## Deep-review findings summary

### Confirmed / very high-confidence P0 paths

- Multipart slow-start can strand a child indefinitely after `startPart()` reports success if no running/progress/status callback arrives. The child remains in `currentBatchPendingIds`; there is no pending-start lease.
- The current native-liveness helper filters `FileDownloader().allTasks()` using plugin DB rows marked `paused`. A real URLSession worker can therefore be hidden precisely after a pause-state race, causing later reconciliation/resume to conclude there is no owner and potentially create a second writer.
- Resume/start controls do not expose one authoritative accepted/failed outcome to callers; UI can remain `enqueued` after a silent no-op.
- Startup inventory is downloader-DB-first. JobStore-only or metadata/filesystem-only recoverable jobs are not independently enumerated.
- JobStore deliberately rejects decreasing `durableBytes`, but stronger disk evidence can legitimately prove that fewer bytes survived. Recovery attempts to write corrected lower bytes through `put()`, which rejects the update, and some callers do not inspect the rejection.
- `savedProgress > 0` is currently treated as sufficient reason to forbid restart-from-zero even when no visible bytes and no native resume data exist. Combined with stale JobStore/high-water progress, this can create a permanent resume deadlock.
- `_checkpointLogicalJob()` is fail-open for control boundaries: rejected/throwing JobStore writes are logged and swallowed, while pause/resume/queue/cancel orchestration may continue as if the authoritative intent was durable.
- iOS native multipart promotion is not a two-phase ownership handoff. Swift can select/start an unlaunched child from a persisted plan while Dart still considers that same generation unlaunched; a foreground/background race or stale Dart snapshot can therefore produce two current owners for the same immutable Range.
- Multipart exact-size adoption and tail recycling prove byte length but do not always prove that the old native owner stopped. Some pause/cancel failures are intentionally ignored before the coordinator releases ownership or schedules another attempt.
- User deletion uses an in-memory `_terminalJobIds` tombstone and later removes the JobStore row. A crash after logical deletion but before all native effects settle can therefore lose durable terminal knowledge needed to reject resurrection.

### Confirmed / high-confidence P1 paths

- Logical episode identity and execution `taskId` are not the same concept, but several runtime paths are DB/taskId-first while other paths match by `trackingUrl` or file key. Attaching to a live task with a different taskId can split metadata/job state across identities instead of atomically adopting one owner.
- Generic completion persistence can use the current file's own length as the first positive expected size, weakening independent completion verification.
- `downloads_provider.dart` is still a competing writer of lifecycle DB state and destructive cleanup.
- The Range receive loop awaits durable/plugin checkpoint work from `onState` while receiving the response stream. At high throughput, frequent JobStore + plugin DB writes can become storage backpressure on the network loop itself.
- Range/native/multipart/iOS retry paths differ on offline, 404/expired-source, retry budgets, and stall handling. The Transfer API already exposes offline hold information, but the custom transport abstraction does not surface it.
- iOS native queue snapshots are versionless and written to UserDefaults; Dart->native bridge errors are swallowed. A stale Dart snapshot can also repopulate multipart waiters already consumed natively.
- The custom iOS implementation replaces Objective-C IMPs on the plugin URLSession delegate. `background_downloader 9.6.1` now exposes supported native status/progress callbacks; keeping a broad swizzle after supported hooks exist increases compatibility and ordering risk.
- Multipart assembly requires substantial extra storage while all part files still exist. No explicit headroom/reservation policy prevents an episode from reaching the tail and then repeatedly failing during `.assembling` creation/truncation.

### Important P2 / hardening gaps

- Dart allows up to 10 simultaneous logical episodes while the Swift native queue clamps its concurrency value to 5, so foreground/background execution semantics diverge for settings above 5.
- `TransferHint.userInitiated` is applied to downloads, while Android 14+ UIDT requires user-visible notification behavior. The app allows download notifications to be disabled, so this combination needs an explicit tested fallback policy.
- Time-based callback suppression/restacking windows remain where generation/ack fences should decide correctness.
- Resume preparation can hold serialized scheduler paths and create head-of-line blocking under slow probes/storage.
- Orphan `.parts`, `.assembling`, partial and final files are not comprehensively inventoried when logical records disappear.
- Range-transfer disposal cancels operations but does not join every operation before the service can be recreated; static/native subscriptions and process-lifetime maps also deserve lifecycle stress tests.
- Several iOS/runtime tests verify that source strings contain a guard rather than behaviorally exercising the race. Those tests protect structure but cannot prove cross-layer convergence.

## Severity convention

- **P0 / Critical:** can strand active work indefinitely, create duplicate writers, resurrect deleted work, or make a resumable task unrecoverable without an explicit safe decision.
- **P1 / High:** can create incorrect lifecycle state, data-integrity risk, serious background/recovery failure, or major throughput/availability degradation.
- **P2 / Medium:** robustness, fairness, platform-policy, compatibility, or diagnostic gap that amplifies failures.
- **P3 / Low:** defensive resource/lifecycle hardening with limited normal-user impact.

# Implementation checklist

## Phase 1 — Eliminate ambiguous ownership and permanent resume deadlocks

- [ ] **DM-01 — Add a generation-bound lease/watchdog for multipart `pending-start` ownership**
  - **Problem:** `startPart()` can return `true` and the child can remain forever in `currentBatchPendingIds` if no readiness callback arrives, blocking slow-start expansion.
  - **Root cause:** reservation occurs before enqueue correctly, but there is no deadline that turns an accepted command into verified ownership or rollback.
  - **Severity / priority:** **P0 / Critical. First implementation item.**
  - **Expected files/areas:** `lib/core/services/persistent_parallel_download.dart`, `download_service.dart` liveness seam, multipart behavioral tests.
  - **Proposed fix:** attach a lease to the exact child attempt generation. At expiry reconcile real owner + durable bytes. Adopt a proven owner; otherwise roll back only that reservation and schedule recovery. Delayed callbacks must be fenced by generation/lease identity.
  - **Verification/testing:** accepted start with no callback; callback after lease; pause/cancel during lease; reconciliation during lease; 1/2/5/8/16 parts; global budget contention; no duplicate launch.
  - **Dependencies:** None.

- [ ] **DM-19 — Replace DB-filtered native liveness with an independent runtime ownership oracle**
  - **Problem:** `_liveTransferTasks()` excludes tasks whose plugin DB row is `paused`, even though DB state is not proof that URLSession/WorkManager ownership ended.
  - **Root cause:** persisted transport status is being used as a negative liveness signal. This can hide the exact still-live worker produced by an accepted-pause/missing-callback race.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** `download_service.dart`, `download_transport.dart`, platform/native liveness APIs, ownership reconciliation tests.
  - **Proposed fix:** define a liveness oracle from actual Transfer/native/range/multipart ownership and explicit acknowledgement. Never remove an owner from the live set merely because a DB row says paused. Represent `unknown/settling` separately from `not owned`.
  - **Verification/testing:** DB paused + native running; Transfer handle paused but URLSession still live; stale DB running + no native owner; app restart; liveness query failure; ensure resume never creates a second writer while ownership is unknown.
  - **Dependencies:** None; DM-02 must consume this oracle.

- [ ] **DM-20 — Permit authoritative downward correction of durable bytes when stronger evidence proves byte loss**
  - **Problem:** JobStore's monotonic `durableBytes` invariant rejects a lower byte count even when exact disk evidence proves that the old checkpoint was stale or the partial file was lost/truncated.
  - **Root cause:** normal callback monotonicity and recovery reconciliation use the same `put()` semantics. Recovery has no privileged, evidence-tagged correction operation; rejected corrections can be ignored.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** `download_job_store.dart`, `download_job_state.dart`, `download_service.dart`, recovery byte-selection tests, fault-injection tests.
  - **Proposed fix:** keep monotonic writes for ordinary attempts, but add a narrow reconciliation operation that can lower bytes only when a stronger evidence source (exact disk inventory or verified final/manifest rollback) proves the correction. Fence it by generation/fingerprint and record the reason/source.
  - **Verification/testing:** JobStore 70 MB vs disk 40 MB; JobStore progress vs zero surviving bytes; truncated partial after crash; manifest rollback; stale callback after correction; incompatible fingerprint. Assert stale high-water bytes cannot return.
  - **Dependencies:** DM-19 recommended for correct native-only evidence classification.

- [ ] **DM-21 — Make authoritative lifecycle checkpoints fail closed at control boundaries**
  - **Problem:** pause/resume/queue/start/cancel can continue after `_checkpointLogicalJob()` rejects or throws, so the action visible to native/UI may not survive a crash.
  - **Root cause:** `_checkpointLogicalJob()` returns `Future<void>` and swallows both rejected checkpoints and backend exceptions; some direct `_jobStore.put()` results are also not checked.
  - **Severity / priority:** **P0 / Critical for user-intent boundaries; progress checkpoints may remain best-effort.**
  - **Expected files/areas:** `download_service.dart`, `download_job_store.dart`, storage error modeling, control-result tests.
  - **Proposed fix:** return a typed durable-checkpoint result. Require a successful write-ahead checkpoint before transitions that change ownership or user intent. If persistence is unavailable, do not claim the new state; preserve the safest current ownership and expose a recoverable storage/state error. Keep telemetry/progress persistence separately coalesced/best-effort.
  - **Verification/testing:** backend write throws/returns false during fresh start, queueing, pause, resume, source refresh, cancel and completion. Kill immediately after each failure and verify intent/state cannot invert.
  - **Dependencies:** DM-20 for evidence-correction semantics.

- [ ] **DM-02 — Make single-file pause prove that transport ownership actually stopped**
  - **Problem:** a single-file task can be presented as paused after an accepted pause and a 5-second callback timeout even if native ownership remains.
  - **Root cause:** normal single-file pause lacks the post-command ownership proof already attempted for internal multipart children; timeout is treated as success instead of unknown.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** `download_service.dart`, `download_transport.dart`, pause/resume behavioral tests.
  - **Proposed fix:** an accepted pause command is not a paused state. Require generation-matching paused/final evidence or the DM-19 liveness oracle to prove release. Otherwise remain `pausing/interrupted/settling` and reconcile; never enqueue another writer.
  - **Verification/testing:** accepted pause + missing callback + still-live owner; delayed callback; completion race; repeated pause/resume; app background/foreground; liveness query failure.
  - **Dependencies:** DM-19, DM-21.

- [ ] **DM-22 — Introduce a two-phase Dart<->Swift ownership handoff for iOS multipart promotion**
  - **Problem:** Swift can start an unlaunched multipart child from `multipartPlans` while Dart still considers the same child/generation launchable. A stale Dart snapshot can also repopulate waiters Swift already consumed.
  - **Root cause:** exported multipart plans are snapshots, not claims. Swift removes a selected waiter then starts it outside the state lock, without a durable claim token acknowledged by Dart; foreground can change between selection and launch.
  - **Severity / priority:** **P0 / Critical duplicate-writer risk.**
  - **Expected files/areas:** `persistent_parallel_download.dart`, `download_continued_processing_service.dart`, `DownloadNativeWaitingQueue.swift`, `AppDelegate.swift`, iOS multipart handoff tests.
  - **Proposed fix:** give each exported child `(parent, child, generation, lease/claimId)` ownership state. Native must atomically claim before launch; Dart must treat claimed children as unavailable even before progress. Snapshots carry a monotonic version and cannot re-add a consumed/claimed child. Re-check foreground/claim validity immediately before `resume()`, and requeue/expire an unstarted claim safely.
  - **Verification/testing:** background transition during selection; foreground transition before `resume()`; stale Dart snapshot after native claim; delayed first byte; duplicate `persistNativeQueue`; process suspension; claim expiration; verify exactly one URLSession/FileDownloader writer per Range.
  - **Dependencies:** DM-01 attempt lease model, DM-10 generation fencing, DM-15 versioned snapshots.

- [ ] **DM-23 — Require old-owner settlement before multipart exact-size adoption, recycle, or relaunch**
  - **Problem:** `_adoptExactSizePart()` can catch/ignore pause failure and still mark a part complete; tail recycle can ignore cancellation failure and later schedule another attempt. Exact byte length proves content availability, not exclusive ownership.
  - **Root cause:** byte-integrity proof and ownership-settlement proof are conflated. Generation filtering prevents stale callbacks from mutating state but cannot stop an old native writer from continuing to write/delete/move files.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** `persistent_parallel_download.dart`, `download_service.dart` child pause/cancel seam, native ownership tests.
  - **Proposed fix:** separate `bytesVerified` from `ownerSettled`. Before assembly, deletion, backup restore, or relaunch, prove native/range ownership ended or quarantine the part in `settling` until reconciliation can prove it. Never free a connection slot as launchable merely because callback ownership is fenced.
  - **Verification/testing:** exact-size child + pause failure + still-live owner; tail cancel failure; late native write after recycle; completion callback lost; app restart while settling; ensure no concurrent writers and no part deletion while owner remains.
  - **Dependencies:** DM-19 and DM-10.

- [ ] **DM-03 — Return an explicit start/resume outcome and eliminate silent control no-ops**
  - **Problem:** UI can optimistically show `enqueued` while resume returns no actionable success/failure result; existing-row `startDownload()` can also report success without established ownership.
  - **Root cause:** command APIs collapse queued, attached, running, already-complete, missing-state, source-refresh failure and recoverable failure into `void`/boolean paths.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** `download_service.dart`, `downloads_provider.dart`, `download_launcher.dart`, control/UI tests.
  - **Proposed fix:** define a typed outcome such as `running/attached`, `queued`, `alreadyComplete`, `paused`, `settlingOwnership`, `restartRequired`, `recoverableFailure`, `missingState`, `terminal`. UI state changes only after the service durably accepts the transition.
  - **Verification/testing:** missing DB row, JobStore-only task, failed native resume, failed range fallback, manifest missing, source refresh failure, queue full, ownership unknown, already-complete file.
  - **Dependencies:** DM-19 through DM-23 provide reliable evidence; implementation can start earlier with conservative outcomes.

- [ ] **DM-04 — Recover from the union of persistence/ownership sources, not downloader DB rows only**
  - **Problem:** valid logical jobs can disappear from recovery/UI when the plugin DB row is missing while JobStore, metadata, native ownership, manifest or files survive.
  - **Root cause:** startup/UI inventory begins from `FileDownloader().database.allRecords()` and joins stronger evidence only after a row is known.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** `download_service.dart`, `download_job_store.dart`, `storage_service.dart`, `downloads_provider.dart`, filesystem/manifest inventory, startup tests.
  - **Proposed fix:** construct one idempotent logical inventory from the union of JobStore, plugin DB/Transfer handles, native ownership, metadata, multipart manifests and safe app-owned filesystem evidence. Reconstruct missing projections or mark explicit orphan/settling states.
  - **Verification/testing:** remove each source singly and in pairs; preserve user pause; recover proven bytes; do not resurrect terminal jobs; deterministic FIFO; no duplicate logical rows.
  - **Dependencies:** DM-19, DM-20, DM-21; DM-24 provides canonical identity.

## Phase 2 — Establish one logical truth, canonical identity, and durable integrity

- [ ] **DM-05 — Make `DownloadJobState` the sole logical lifecycle authority**
  - **Problem:** `TaskStatus.paused` currently means user pause, interrupted/failure parking and sometimes queue compatibility state, with intent scattered through metadata and memory sets.
  - **Root cause:** plugin transport status and application lifecycle state are mixed.
  - **Severity / priority:** **P1 / High; architectural prerequisite.**
  - **Expected files/areas:** `download_job_state.dart`, `download_job_store.dart`, `download_service.dart`, `download_concurrency.dart`, `downloads_provider.dart`, iOS snapshot projection.
  - **Proposed fix:** plugin status becomes transport evidence only. Persist explicit logical state/user intent/queue intent and centralize logical -> UI/native compatibility projection. Never infer user pause solely from plugin `paused`.
  - **Verification/testing:** full logical-state x plugin-status x native-ownership x metadata matrix, with event-order permutations.
  - **Dependencies:** DM-03/DM-04.

- [ ] **DM-24 — Introduce one canonical logical episode identity across changing taskIds**
  - **Problem:** runtime duplicate detection is DB/taskId-first, while other paths match `trackingUrl` or file target. A live task with a different taskId can be attached to while metadata/JobStore remain split, or a new task can be created when the old DB row vanished but native ownership remains.
  - **Root cause:** `taskId` is being used both as execution-attempt identity and logical episode identity.
  - **Severity / priority:** **P1 / High; raise to P0 if duplicate runtime start is reproduced.**
  - **Expected files/areas:** `download_service.dart`, `download_job_store.dart`, `download_cleanup.dart` identity helpers, `downloads_provider.dart`, Swift `episodeKey`, duplicate-start tests.
  - **Proposed fix:** define a stable logical download key (tracking episode identity plus safe target/resource context) and separate it from execution taskId/generation. Adoption of a differently named live owner must atomically move/alias all logical projections rather than partially copying metadata.
  - **Verification/testing:** DB row lost while native task live; same episode different taskId; same filename different episode; source URL changes; duplicate taps; app restart during taskId adoption; ensure one logical row and one owner.
  - **Dependencies:** DM-05; used by DM-04 final inventory.

- [ ] **DM-06 — Strengthen final-file completion verification with independent expected-resource evidence**
  - **Problem:** a nonzero file can be checkpointed complete using its current length as the first positive expected size; same-size wrong-resource cases can also evade size-only checks.
  - **Root cause:** observed file bytes, expected resource bytes and resource identity are not consistently distinguished at the generic completion boundary.
  - **Severity / priority:** **P1 / High (data integrity).**
  - **Expected files/areas:** `download_service.dart`, `download_resume.dart`, JobStore fingerprint model, completion/relaunch tests.
  - **Proposed fix:** require independent expected size or an explicit alternative integrity proof. Capture/use strong ETag/Last-Modified where available; preserve prefix validation for partials. Unknown integrity enters `verifying/interrupted`, not `completed`.
  - **Verification/testing:** truncated final with stale complete row; wrong-size file; same-size changed resource; unknown-size source; crash after rename before checkpoint; multipart final target conflict.
  - **Dependencies:** DM-05, DM-20.

- [ ] **DM-07 — Make cancel/delete a durable tombstone-first ownership-settlement transaction**
  - **Problem:** UI can time out cancellation and delete DB/metadata/files while ownership still settles; the service's terminal tombstone is process-local and the JobStore row is ultimately removed.
  - **Root cause:** terminal intent is not retained durably through the entire native-settlement/cleanup window, and destructive cleanup is split across service/UI.
  - **Severity / priority:** **P0 / Critical after deeper review.**
  - **Expected files/areas:** `download_service.dart`, `downloads_provider.dart`, `download_job_store.dart`, cleanup utilities, native queue cleanup.
  - **Proposed fix:** persist `canceled` tombstone before any ownership mutation. UI may hide immediately, but DB/files/metadata are cleaned by an idempotent service transaction only after ownership is settled. Retain tombstone long enough to reject late native/plugin callbacks, then garbage-collect by explicit policy.
  - **Verification/testing:** cancel during native/range/multipart transfer, pause, assembly and refresh; cancel API timeout; kill after tombstone before native ack; late running/complete callback; reinstall/reinit cleanup.
  - **Dependencies:** DM-19, DM-21, DM-10.

- [ ] **DM-08 — Make source refresh safe and complete for all resumable representations**
  - **Problem:** native-resume-only single downloads cannot safely migrate opaque resume data across an expired signed URL; HTTP 404 refresh semantics also differ between range/multipart paths.
  - **Root cause:** source refresh lacks one capability matrix for visible bytes, opaque native resume data, multipart parts and provider-specific expired-link statuses.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** `download_service.dart`, `download_transport.dart`, `download_plugin_compat.dart`, `download_url_refresh.dart`, multipart refresh callbacks/tests.
  - **Proposed fix:** define a platform-safe decision tree: try valid same-source native resume; migrate/adopt visible verified prefix when possible; validate refreshed resource identity; range-resume or restart only when evidence permits. Normalize 401/403/404 handling using descriptor/provider evidence instead of inconsistent hard-coded paths. Expose `restartRequired` when opaque bytes cannot be migrated.
  - **Verification/testing:** 401/403/404 expired source, native resume data only, visible partial, changed size/validator, descriptor expired, provider unavailable, refresh during app restart.
  - **Dependencies:** DM-03, DM-06, DM-20.

- [ ] **DM-16 — Separate historical presentation progress from recoverable byte evidence**
  - **Problem:** current helpers intentionally prevent restart when `savedProgress > 0`, even when no visible bytes and no native resume data survive. A stale percentage can therefore block every safe continuation path.
  - **Root cause:** UI high-water progress is treated as proof that durable bytes exist. The zero-restart test currently codifies that assumption.
  - **Severity / priority:** **P1 / High; directly involved in resume deadlocks.**
  - **Expected files/areas:** `download_resume.dart`, `download_telemetry.dart`, `download_service.dart`, `download_job_state.dart`, `downloads_provider.dart`, zero-restart/recovery tests.
  - **Proposed fix:** recovery decisions accept only evidence-bearing inputs: verified native resume ownership/data, exact disk bytes, current-generation manifest/JobStore bytes after DM-20 reconciliation. Historical percentage remains presentation metadata only and may reconcile downward after proven byte loss.
  - **Verification/testing:** stale 42% + zero bytes + no native resume must yield a deliberate restart/recoverable outcome; visible partial still blocks destructive restart; late regressive callback; 0.999 sentinel; restart after corrected JobStore.
  - **Dependencies:** DM-20, DM-05, DM-06.

## Phase 3 — Deterministic retries, concurrency, and I/O behavior

- [ ] **DM-09 — Introduce one network-interruption/hold policy across all transports**
  - **Problem:** native Transfer, Dart Range, multipart recovery and iOS native retries react differently to offline/online transitions, stalls and retry exhaustion.
  - **Root cause:** custom `DownloadTransport` does not expose Transfer hold reason/stall state, while custom layers each implement their own retry semantics.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** `download_transport.dart`, `download_retry_policy.dart`, `download_range_transfer.dart`, `persistent_parallel_download.dart`, `download_service.dart`, Swift background retry.
  - **Proposed fix:** model `waitingForNetwork` separately from server backoff and user pause. Surface Transfer `holdReason` where supported, use connectivity restoration as a trigger, and define progress-reset retry budgets/circuit behavior consistently. Evaluate `stallTimeout` rather than duplicating an inferior watchdog for native single transfers.
  - **Verification/testing:** offline->online, Wi-Fi<->cellular, DNS/captive network, long offline period, intermittent progress, retry exhaustion, pause/cancel while offline, simultaneous recovery, 408/425/429/5xx.
  - **Dependencies:** DM-05, DM-03.

- [ ] **DM-10 — Replace time-based correctness fences with generations/acks**
  - **Problem:** late callbacks after pause/resume/restacking/retry/source replacement/cancel can mutate newer state; fixed 800ms/other timing windows cannot prove causality.
  - **Root cause:** generation fencing exists only in portions of the stack and does not cover every logical/native operation.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** JobStore, `download_service.dart`, multipart coordinator, Swift queue/bridge payloads.
  - **Proposed fix:** every ownership-changing operation carries a durable generation/operation token. Accept only current-token callbacks, except independently verified safe terminal bytes. Replace arbitrary callback-suppression windows with ack/settlement state.
  - **Verification/testing:** callbacks delayed 0.8s/5s/30s; stale complete after source change; stale failure after successful resume; cancel then running; background promotion vs foreground recovery.
  - **Dependencies:** DM-01, DM-19, DM-05.

- [ ] **DM-11 — Define crash-safe write ordering and convergence for all replicas**
  - **Problem:** JobStore, plugin DB, metadata, manifest, filesystem, URL-refresh store and native queue can each be individually valid while mutually inconsistent after a crash.
  - **Root cause:** no cross-store transaction exists; correctness requires explicit write-ahead rules and idempotent reconciliation.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** `download_service.dart`, JobStore, storage service, multipart manifest, native queue store/bridge, fault-injection harness.
  - **Proposed fix:** document per-transition write ordering with JobStore intent first for control boundaries, then executor effects, then projections. Add generation/version fields where missing. Reconciliation must tolerate crash after every write and converge without discarding stronger evidence.
  - **Verification/testing:** inject death after every write in start, queue promotion, pause, resume, URL refresh, child completion, assembly rename, final completion, cancel/tombstone/cleanup.
  - **Dependencies:** DM-04, DM-05, DM-10, DM-21.

- [ ] **DM-25 — Remove persistence/database backpressure from the Range receive loop**
  - **Problem:** `_receive()` awaits `onState` while consuming the network stream; `onState` can await JobStore and plugin DB writes every 512 KiB/250 ms threshold.
  - **Root cause:** durable checkpointing is synchronous with data ingestion instead of coalesced behind an ordered writer.
  - **Severity / priority:** **P1 / High when throughput/storage latency is high.**
  - **Expected files/areas:** `download_range_transfer.dart`, `download_service.dart`, JobStore progress checkpoints, range throughput tests.
  - **Proposed fix:** keep exact in-memory/disk byte counters on the receive path, enqueue/coalesce ordered persistence snapshots at a bounded cadence, and synchronously flush/join only at pause, failure, completion, source change, cancel and dispose boundaries. Backpressure must be bounded so a slow store cannot grow an unbounded queue.
  - **Verification/testing:** high-speed local stream + deliberately slow JobStore/plugin DB; pause during pending checkpoint; crash after last unflushed progress; disk-full persistence error; assert throughput remains stable and boundary bytes are durable.
  - **Dependencies:** DM-21 defines critical vs best-effort writes; DM-20 handles recovery correction.

- [ ] **DM-13 — Prevent head-of-line blocking and prove fairness across simultaneous downloads**
  - **Problem:** serialized queue/session paths can await slow resume probes/range setup/storage while unrelated downloads need promotion.
  - **Root cause:** invariant protection and slow transport preparation share the same serialization scope.
  - **Severity / priority:** **P2 / Medium; P1 if profiling reproduces starvation.**
  - **Expected files/areas:** `persistent_parallel_download.dart`, `download_service.dart`, `download_concurrency.dart`, connection governor.
  - **Proposed fix:** reserve state/slot quickly, perform slow preparation outside broad scheduler locks where safe, then commit only with the same generation/lease. Preserve logical FIFO without letting a dead host block healthy sessions.
  - **Verification/testing:** fast + stalled hosts; 5/8/16 parts; probe timeout; rate-limit on one host; queue concurrency 1..10; pause/cancel during promotion; bounded promotion latency.
  - **Dependencies:** DM-01, DM-10, DM-25.

- [ ] **DM-12 — Remove lifecycle persistence writes from the presentation layer**
  - **Problem:** `downloads_provider.dart` rewrites failed/not-found rows and performs destructive cleanup while DownloadService/JobStore simultaneously own lifecycle.
  - **Root cause:** UI became a repair layer to translate plugin statuses.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** `downloads_provider.dart`, `download_service.dart`, state snapshot/projection helpers.
  - **Proposed fix:** UI reads a service-owned logical snapshot and sends commands only. Optimistic visuals require an accepted service operation token/outcome; DB/metadata/file cleanup belongs to service reconciliation.
  - **Verification/testing:** UI refresh racing failure/pause/resume/completion/delete; provider recreation; ensure no lifecycle DB writes originate from presentation code.
  - **Dependencies:** DM-03, DM-05, DM-07.

## Phase 4 — Filesystem, background, dependency, and platform hardening

- [ ] **DM-27 — Add storage-headroom policy for multipart download + assembly**
  - **Problem:** multipart can successfully download all ranges yet fail at the tail because `.assembling` needs another near-full-file allocation while all part files remain. Repeated resume can repeat the same failure without a clear reason.
  - **Root cause:** source-size validation is not paired with destination free-space/headroom planning; assembly's crash-safe staging temporarily amplifies storage use.
  - **Severity / priority:** **P1 / High for large files/low-storage devices.**
  - **Expected files/areas:** `download_service.dart`, `persistent_parallel_download.dart`, cleanup/storage helpers, UI error outcome, disk-space tests.
  - **Proposed fix:** preflight and periodically re-evaluate required free space using a conservative platform-aware headroom model. Preserve crash-safe assembly; if a lower-amplification assembly algorithm is introduced, prove crash recovery before using it. Surface explicit `insufficientStorage` instead of generic paused/failed.
  - **Verification/testing:** just enough for parts but not staging; disk fills mid-download/mid-assembly; sparse/allocation behavior; cleanup frees space; resume after space becomes available; never delete proven parts solely because assembly lacks headroom.
  - **Dependencies:** DM-03 outcome model, DM-06 integrity.

- [ ] **DM-14 — Inventory and safely recover/clean orphan download artifacts**
  - **Problem:** `.parts`, `.assembling`, `.part/.tmp/.download` or final files can survive while logical DB/metadata rows disappear.
  - **Root cause:** cleanup/recovery is target-driven rather than a complete, app-root-scoped inventory.
  - **Severity / priority:** **P2 / Medium; P1 combined with persistence loss.**
  - **Expected files/areas:** cleanup utilities, multipart coordinator, DownloadService, JobStore/metadata reconciliation.
  - **Proposed fix:** scan only app-owned download roots; correlate artifacts with canonical logical identity/generation; adopt provable state, quarantine ambiguous targets, delete only artifacts proven obsolete by durable tombstones/age policy.
  - **Verification/testing:** crash during assembly stages; missing manifest; `.tmp` newer than canonical manifest; final conflict; missing DB/metadata; canceled-generation leftovers; external files untouched.
  - **Dependencies:** DM-04, DM-06, DM-07, DM-11, DM-24.

- [ ] **DM-15 — Make Dart<->iOS queue snapshots versioned, acknowledged, and recoverable**
  - **Problem:** queue snapshot bridge calls swallow platform failures; native queue state is stored as a versionless UserDefaults blob; stale Dart snapshots can overwrite newer native consumption/promotion state.
  - **Root cause:** correctness-sensitive queue checkpoints use best-effort semantics designed for optional UI updates.
  - **Severity / priority:** **P1 / High after deeper review.**
  - **Expected files/areas:** `download_continued_processing_service.dart`, `DownloadNativeWaitingQueue.swift`, `AppDelegate.swift`, DownloadService snapshot writer.
  - **Proposed fix:** separate overlay calls from queue-state checkpoints. Add monotonically increasing snapshot/version/claim generations and acknowledgement. Reject stale snapshots. Evaluate an atomic native journal/file if UserDefaults durability is insufficient for ownership claims. Reconcile unacknowledged writes on foreground/background handoff.
  - **Verification/testing:** method-channel failure; process suspended after Dart send but before ack; native promotion then stale Dart snapshot; native completion while Flutter sleeps; repeated identical snapshot; corrupted/native store reset.
  - **Dependencies:** DM-10, DM-11; DM-22 consumes the version/claim model.

- [ ] **DM-26 — Reduce/remove fragile URLSession delegate IMP swizzling using supported plugin APIs**
  - **Problem:** AnimeWitcher replaces implementations on `background_downloader`'s `UrlSessionDelegate` selectors for completion/progress/promotion. Plugin internals or selector ordering can change across versions, and failure to hook is currently mostly diagnostic.
  - **Root cause:** older plugin versions lacked native host callbacks needed while Dart was suspended. `background_downloader 9.6.1` now exposes supported iOS native status/progress closures, while the project lockfile remains on 9.6.0.
  - **Severity / priority:** **P1 / High compatibility/race reduction; do not perform a blind upgrade.**
  - **Expected files/areas:** `pubspec.yaml`, `pubspec.lock`, `AppDelegate.swift`, `DownloadNativeWaitingQueue.swift`, `download_plugin_compat.dart`, iOS integration/source tests.
  - **Proposed fix:** first isolate and verify 9.6.1 behavior. Move status/progress observation to official callbacks where behavior matches. Retain only the smallest native hook still required for queue promotion/completion ordering, if any, and guard unsupported compatibility APIs by version. Remove source-string assumptions once behavioral coverage exists.
  - **Verification/testing:** foreground/background status/progress, completion promotion, retry replacement, app suspension, plugin update compatibility, hook unavailable, duplicate callback prevention, build preview/device integration.
  - **Dependencies:** DM-22/DM-15 define required handoff semantics before removing hooks.

- [ ] **DM-28 — Align platform execution-policy and concurrency semantics**
  - **Problem:** Dart logical concurrency allows 1..10 while Swift clamps native queue concurrency to 5. Android downloads always carry `userInitiated`, but Android 14+ UIDT requires notification-visible execution while users can disable download notifications.
  - **Root cause:** platform-specific safety caps/hints evolved separately from the user-facing queue/notification settings.
  - **Severity / priority:** **P2 / Medium; P1 if device tests show failed/background-stalled transfers.**
  - **Expected files/areas:** `download_concurrency.dart`, task creation/notification configuration, `DownloadNativeWaitingQueue.swift`, Android manifest/config, platform tests.
  - **Proposed fix:** explicitly define supported foreground/background concurrency per platform and project settings accordingly rather than silently clamping. On Android, test notification-off behavior and choose a documented WorkManager/UIDT/foreground-service fallback that remains valid. Keep macOS entitlement requirements covered by build checks.
  - **Verification/testing:** concurrency 1/5/6/10 across iOS foreground/background; Android 14+ notifications allowed/denied/disabled; long >9-minute task; process background/termination; no hidden setting mismatch.
  - **Dependencies:** DM-09 network/transport policy; otherwise independent.

- [ ] **DM-17 — Audit and harden resource/subscription lifetime across reinitialization**
  - **Problem:** the stack contains static/shared plugin event bridges, timers, Transfer handles, range operations, native observers and process-lifetime maps. `DownloadRangeTransfer.dispose()` cancels operations but does not itself join every operation before service teardown continues.
  - **Root cause:** normal production assumes a keep-alive singleton, while tests/recreated scopes/hot restart and error recovery can exercise reinitialization.
  - **Severity / priority:** **P2 / Medium after deeper review.**
  - **Expected files/areas:** `download_service.dart`, `download_transport.dart`, `download_range_transfer.dart`, multipart coordinator, AppDelegate observers/native state.
  - **Proposed fix:** document owner/lifetime for every controller/subscription/timer/native handle. Make dispose asynchronous where joining is required; prevent a second service instance from receiving old-operation callbacks or starting while old writers are settling.
  - **Verification/testing:** repeated init/dispose; provider recreation; dispose during Range write/multipart retry; hundreds of complete/cancel cycles; memory/file-handle inspection; no duplicate subscriptions.
  - **Dependencies:** DM-10 makes late delivery safe.

## Phase 5 — Prove behavior, not source shape

- [ ] **DM-18 — Build an end-to-end deterministic reliability/chaos acceptance matrix**
  - **Problem:** many existing tests are valuable, but some correctness-critical iOS/runtime tests assert source strings and some unit invariants encode assumptions that the deeper review identified as unsafe.
  - **Root cause:** the manager spans plugin DB, JobStore/Hive, filesystem, native executor, multipart scheduler, UI projection and Swift background state; isolated helper tests cannot prove convergence under lost/reordered callbacks and crashes.
  - **Severity / priority:** **P1 / High as final release gate; grow incrementally with every earlier fix.**
  - **Expected files/areas:** existing `test/core/services/*download*` suites plus deterministic fake transport/store/native-handoff harnesses and platform integration tests where executable native tests are practical.
  - **Proposed fix:** support dropped/delayed/duplicated/reordered callbacks, liveness ambiguity, slow/failing stores, crash injection at every durable boundary, native claim/snapshot races and controlled network/server behavior. Prefer behavioral assertions over source-string presence for invariants.
  - **Verification/testing:** mandatory matrix includes fresh download; pause/resume; accepted pause with live owner; retry/failure; zero surviving bytes with stale progress; JobStore byte rollback; JobStore write failure; process kill/restart; missing DB/metadata/job; 1/2/5/8/16 parts; missing start callback; native/Dart same-part race; exact-size part with unsettled owner; 0.999 tail; expired 401/403/404 source; ignored Range; validator/resource change; offline/online; multiple downloads; queue full; cancel/tombstone races; low disk/assembly failure; iOS suspension/native promotion/foreground; Android long UIDT/notification-off cases; service dispose/reinit.
  - **Dependencies:** All prior items. Final item remains unchecked until the complete matrix passes on supported platforms.

## Dependency / execution order

Later Tasks should follow **file order first**, then dependencies. Existing DM identifiers were intentionally preserved when this deeper review added DM-19..DM-28.

Recommended implementation sequence:

1. **DM-01 -> DM-19 -> DM-20 -> DM-21 -> DM-02**: eliminate ambiguous start/pause ownership and stale-byte deadlocks.
2. **DM-22 -> DM-23**: eliminate iOS/multipart duplicate-writer and unsettled-owner paths before broader state refactors.
3. **DM-03 -> DM-04 -> DM-05 -> DM-24**: establish explicit control outcomes, complete inventory, one logical state machine, and canonical identity.
4. **DM-06 -> DM-07 -> DM-08 -> DM-16**: protect final integrity, terminal deletion, source refresh, and recovery-byte truth.
5. **DM-09 -> DM-10 -> DM-11 -> DM-25 -> DM-13 -> DM-12**: normalize retry/race/write ordering, remove hot-path persistence pressure, then simplify UI ownership.
6. **DM-27 -> DM-14 -> DM-15 -> DM-26 -> DM-28 -> DM-17**: harden storage, orphan recovery, native snapshots/plugin integration, platform policy, and resource lifetime.
7. **DM-18** grows alongside every item but remains the final unchecked acceptance gate until the complete matrix passes.

## Invariants every implementation commit must preserve

- Never start a second writer for the same logical episode/range while an earlier owner is live **or ownership is unknown**.
- A DB status is never proof of native non-ownership.
- Command acceptance is never equivalent to state completion: `pause`, `resume`, `cancel`, `enqueue`, native claim and source replacement require the appropriate durable/ownership acknowledgement.
- Control-boundary user intent must be durable before ownership-changing side effects; progress telemetry may be best-effort only when boundary flushes remain correct.
- Exact disk bytes outrank historical progress and may legitimately force a recovery-byte correction downward.
- Historical percentage alone is never evidence that bytes still exist.
- Explicit user pause and cancel outrank automatic retry/recovery.
- Terminal tombstones survive long enough to reject late native callbacks and finish cleanup after a crash.
- Proven bytes are never discarded merely to repair bookkeeping; when bytes cannot be proven, the system makes an explicit safe restart/restart-required decision instead of deadlocking.
- A final file is never marked complete solely by comparing its length with itself; completion requires independent expected-resource evidence or an explicit alternative proof.
- Multipart assembly remains staging/crash-safe and never deletes/reuses a part until prior writer ownership is settled.
- Dart and Swift ownership snapshots are monotonic/versioned; stale snapshots cannot reintroduce consumed native work.
- Queue/global/per-host connection limits remain bounded under retries, delayed callbacks, native background promotion and concurrent sessions.
- Source refresh never appends old bytes to an unverified different resource.
- Restart/foreground reconciliation is idempotent: repeated reconciliation converges to the same logical state without duplicate tasks.
- Slow persistence must not directly throttle the network receive loop beyond bounded checkpoint pressure.
- Unsupported/plugin-internal hooks stay isolated, version-gated, and covered by behavior tests until replaced by public APIs.

## Checklist protocol for later Tasks

- Read this file completely before changing code.
- Read the current PR/branch state and the latest implementation notes before selecting work.
- Start from the first unchecked item in file order whose dependencies are complete.
- If an earlier item is partially implemented, finish it before opening another.
- Implement one clear, reviewable slice at a time and add the behavioral regression test first where feasible.
- Do not replace a behavioral failure with a longer arbitrary timeout; establish an acknowledgement, lease, generation, or evidence-based rule.
- Re-read the diff and run the item's targeted verification before checking it.
- Mark `[x]` only when the item's described behavioral verification passes; record implementation notes/commits under the item for the next Task.
- Keep using branch `plan/download-manager-reliability` and PR #231 until DM-18 is complete.
- If a newly discovered root cause invalidates an item, update this source-of-truth document explicitly rather than silently changing scope.
