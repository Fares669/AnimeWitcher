# AnimeWitcher Download Manager Reliability Plan

> **Final source of truth for all download-manager reliability work in PR #231.**
>
> This document is the result of three review-only passes, including a final end-to-end coverage audit. The review commits intentionally change no download logic, perform no refactor, and add no feature. Every implementation item remains unchecked so later Tasks can resume from the first eligible `[ ]` item while using the same branch and PR.

## Review baseline and scope

- Final review baseline: `main` commit `7f25aadf6f18008a93aa95dddf5d7810bdb73279` (tree `8ac644f7dcae67d3326ca71a90de4be918f09d9c`). Main was rechecked before finalizing this plan and still points to this commit.
- Primary Dart orchestration reviewed end-to-end: `download_service.dart`, `persistent_parallel_download.dart`, `download_transport.dart`, `download_range_transfer.dart`, `download_retry_policy.dart`, `download_concurrency.dart`, `download_connection_governor.dart`, `download_host_profile.dart`, `download_job_state.dart`, `download_job_store.dart`, `download_parallel.dart`, `download_plugin_compat.dart`, `download_url_refresh.dart`, `download_continued_processing_service.dart`, `download_diagnostic_log.dart`, `download_telemetry.dart`, and download utilities.
- Persistence/UI/launch integration reviewed: `storage_service.dart`, `downloads_provider.dart`, `download_launcher.dart`, metadata persistence, refresh-descriptor persistence, cleanup/resume utilities, duplicate collapsing, and all user control paths.
- Lifecycle integration reviewed: app initialization in `main.dart`, foreground reconciliation, service reinitialization/disposal, static downloader event bridging, and failure during startup/recovery.
- iOS native/background integration reviewed in depth: `DownloadContinuedProcessingManager.swift`, `DownloadNativeWaitingQueue.swift`, URLSession delegate IMP hooks, native queue snapshots, multipart background promotion, retry replacement, progress bridging, `AppDelegate.swift`, and Dart method-channel ownership.
- Platform policy reviewed: Android WorkManager/UIDT behavior, notification-off combinations, iOS continued processing/background URLSession, macOS download entitlements, and foreground/background concurrency semantics.
- Filesystem safety reviewed: final/partial/staging/manifest locations, assembly, orphan cleanup, path-boundary checks, series-folder cleanup, low-storage behavior, and native temp representations.
- Existing download test suites were reviewed across recovery, relaunch chaos, fault injection, startup reconciliation, range transfer, URL refresh, transport, concurrency, multipart recovery/tail recovery, telemetry, zero-restart invariants, JobStore invariants, UI responsiveness, thermal behavior, and iOS source/bridge guards.
- External dependency review date: **2026-09-10**. The repository lockfile is on `background_downloader 9.6.0`; `9.6.1` is available and adds supported iOS native status/progress callbacks. Any dependency update is an implementation item and is not performed by this review.

## Current architecture and authority map

1. **Source/launch** — `download_launcher.dart` resolves a provider/source, probes metadata/range support, currently persists a refresh descriptor, and invokes `DownloadService.startDownload()`.
2. **Logical orchestration** — `download_service.dart` owns queueing, pause/resume/cancel, source refresh, transport selection, startup/foreground recovery, persistence projection, UI events, and background-session projection.
3. **Single-file native transport** — `download_transport.dart` wraps `background_downloader` Transfer APIs, while plugin DB and native executor state remain separate evidence sources.
4. **Visible-prefix Range fallback** — `download_range_transfer.dart` validates and appends Range responses to visible durable partial files.
5. **Multipart coordinator** — `persistent_parallel_download.dart` owns immutable ranges, slow-start, connection reservations, part attempts, manifests, source validation, recovery timers, disk polling, and final assembly.
6. **Durable logical state** — `DownloadJobStore` is intended to be the logical source of truth, but logical state is still replicated across plugin DB/resume data, metadata Hive, multipart manifests/files, refresh descriptors, iOS UserDefaults queue state, and process-local sets/maps.
7. **Presentation** — `downloads_provider.dart` combines service events + plugin records + metadata and currently still mutates lifecycle persistence and performs destructive cleanup.
8. **iOS native continuation** — Dart exports queue/multipart snapshots; Swift can promote URLSession work while Flutter is suspended and bridges native byte/status evidence back to Dart.
9. **Initialization** — `main.dart` starts `DownloadService.init()` after the first frame without awaiting it; public download controls do not currently share a universal readiness barrier.

## Final-review findings summary

### Confirmed / very high-confidence P0 failure paths

- Multipart `pending-start` can remain reserved forever after an accepted start when no readiness callback arrives, blocking slow-start expansion.
- Native liveness can be hidden by a plugin DB row marked `paused`; persisted status is currently used as a negative liveness filter even though the native worker may still be alive.
- Several JobStore writes synthesize `durableBytes` from `totalSize * progress`. Historical/transport percentage is therefore capable of becoming authoritative byte truth even when no corresponding durable bytes survive.
- JobStore then rejects downward byte correction, so stale synthetic/high-water bytes can remain authoritative after stronger disk evidence proves less data survived.
- Historical `savedProgress > 0` can block restart-from-zero even when no visible bytes and no native resume data remain, creating a permanent resume deadlock.
- Authoritative lifecycle checkpoints are fail-open at important control boundaries: rejected/throwing JobStore writes may be logged and swallowed while ownership/state side effects continue.
- Normal single-file pause can report success after an accepted pause plus timeout without proving that native ownership actually ended.
- Startup recovery can enforce a persisted user pause by attempting native pause, ignore pause failure, then still rewrite the plugin DB row to `paused`, making later liveness inference even more dangerous.
- iOS multipart background promotion has no two-phase Dart<->Swift claim/ack protocol; Swift and Dart can both consider the same current Range generation launchable during a handoff race.
- Multipart exact-size adoption/tail recycling can proceed after failed owner settlement. Exact file length proves bytes exist, not that the previous writer stopped.
- `NativeSingleDownloadTransport.cancel()` detaches/removes Transfer tracking even when native cancel returns `false`. DownloadService also ignores that failure and can proceed to delete DB/JobStore/files, losing ownership evidence while a writer may remain.
- User delete uses an in-memory tombstone and ultimately removes the JobStore row; a process death before native settlement can erase the terminal fact needed to prevent resurrection.
- Public start/pause/resume/cancel controls are not universally gated behind completion of service initialization/recovery. A user can issue a command while startup reconciliation is still running.

### Confirmed / high-confidence P1 failure paths

- Startup and UI inventory remain downloader-DB-first, so JobStore-only/metadata-only/manifest-only recoverable work can disappear from enumeration.
- Logical episode identity and execution `taskId` are mixed across DB lookup, tracking URL, episode URL, file target, native adoption, and Swift `episodeKey` logic.
- Refresh descriptors are lifecycle-critical but currently saved/removed by `DownloadLauncher`. Concurrent starts for the same logical episode can race so one failed/obsolete caller removes a descriptor required by another successful/current generation.
- Generic completion persistence can use the current file's own length as the first positive expected size, weakening independent completion validation.
- The resource fingerprint stores `finalUrl`, but compatibility does not compare it; raw delivery URLs are also unsuitable as stable identity because signed URLs legitimately rotate. Stable resource identity and volatile delivery location are not modeled separately.
- Strong ETag/Last-Modified fields exist in the JobStore fingerprint model, but normal metadata probing does not currently make those validators first-class persisted identity evidence across all paths.
- `downloads_provider.dart` remains a competing lifecycle writer: it rewrites failed/notFound records and performs DB/metadata/artwork/file cleanup independently of DownloadService.
- UI deletion decides whether to issue cancel from `TaskStatus`, even though this audit proves status is not liveness evidence. A failed/notFound/paused-looking row can still have native ownership.
- Range receive processing awaits persistence/plugin DB checkpoints in the response loop, allowing storage latency to become network backpressure.
- Multipart manifests persist child `progress`/`credibleProgress` doubles rather than an explicit durable-byte count; some plugin percentages below the `0.999` sentinel can become credited recovery progress.
- Native/Range/multipart/iOS retries differ for offline state, 401/403/404 refresh, retry exhaustion, and stall handling despite the Transfer API exposing native hold/offline concepts.
- iOS queue snapshots are versionless/best-effort and the Dart bridge swallows queue-persistence failures; stale snapshots can repopulate native work already consumed.
- Multipart assembly may require near another full-file allocation after all parts are downloaded, without explicit storage-headroom policy.
- App-root cleanup boundaries use textual path containment and series-folder cleanup can recursively remove non-video leftovers. Destructive cleanup requires canonical path containment plus explicit app-owned-artifact proof.

### P2 / hardening and compatibility gaps

- Dart logical episode concurrency supports up to 10 while Swift native queue concurrency clamps to 5, creating foreground/background semantic divergence.
- Android downloads always carry `TransferHint.userInitiated`; Android 14+ UIDT is tied to user-visible notification behavior, while the app allows download notifications to be disabled. This needs explicit device-policy testing/fallback.
- Broad iOS URLSession delegate IMP replacement is fragile across plugin versions. `background_downloader 9.6.1` now exposes supported native status/progress callbacks, so the custom hook surface should be reduced after behavior is proven.
- Fixed timing fences remain in callback/restacking paths where generation/acknowledgement should determine correctness.
- Slow transport preparation inside broad serialization can create head-of-line blocking across unrelated downloads.
- `DownloadService.dispose()` starts multiple async teardowns with `unawaited`, immediately closes local controllers, and keeps a static downloader bridge alive; rapid ProviderScope/service recreation can produce ABA-style old-instance/new-instance overlap.
- A meaningful part of the runtime/iOS regression suite checks source strings/structure. These tests are useful guards but cannot establish cross-layer ownership or crash convergence.

## Severity convention

- **P0 / Critical:** can strand work indefinitely, create duplicate writers, lose/corrupt recoverable state, resurrect deleted work, or make a task permanently unresumable.
- **P1 / High:** can produce incorrect lifecycle state, data-integrity risk, serious recovery/background failure, or major throughput/availability degradation.
- **P2 / Medium:** robustness, fairness, compatibility, platform-policy, cleanup-safety, or diagnostic gap that amplifies failures.
- **P3 / Low:** defensive cleanup/hardening with limited normal-user impact.

# Implementation checklist

## Phase 1 — Establish trustworthy ownership, byte truth, and startup ordering

- [x] **DM-01 — Add a generation-bound lease/watchdog for multipart `pending-start` ownership**
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

- [x] **DM-19 — Replace DB-filtered liveness with an independent runtime ownership oracle**
  - **Problem:** `_liveTransferTasks()` can exclude a real worker because the plugin DB row says `paused`.
  - **Root cause:** durable/persisted transport status is incorrectly used as proof that runtime ownership does not exist.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** `download_service.dart`, `download_transport.dart`, platform/native liveness APIs, ownership tests.
  - **Proposed fix:** define `owned / notOwned / settling / unknown` from actual Transfer/native/range/multipart ownership plus acknowledgement. DB status may support a conclusion but can never independently negate a live owner.
  - **Verification/testing:** DB paused + native running; stale DB running + owner gone; Transfer handle exists but executor state unknown; liveness query failure; relaunch; no duplicate resume while unknown.
  - **Dependencies:** None.
  - **Implementation notes (2026-09-11):** Added explicit `owned / notOwned / settling / unknown` runtime ownership semantics with a fail-closed `blocksNewWriter` rule. `_liveTransferTasks()` now consumes the plugin's runtime-active `allTasks(allGroups: true)` result directly instead of removing IDs based on persisted `paused` rows. Range activity is independent positive ownership evidence, successful runtime absence is the negative acknowledgement for `notOwned`, and query failure remains `unknown`. Multipart start/pause paths now consult this oracle so an ambiguous owner cannot cause a second writer.
  - **Confirmed root cause:** `_liveTransferTasks()` took an executor-active result and then removed IDs solely because the persistent database projected them as `paused`, allowing stale DB state to overrule stronger runtime evidence.
  - **Verification passed:** `Guarded DM-19 implementation` run 34537930159 passed patch application, formatting, generation, `download_runtime_ownership_test.dart`, all three targeted multipart/lease regression suites, `flutter analyze --no-fatal-warnings --no-fatal-infos`, diff checks, commit and push. Coverage verifies runtime-active ownership wins regardless of stale persisted pause, successful runtime absence yields `notOwned`, failed liveness with a rehydrated Transfer handle remains `unknown`, `settling` and `unknown` block a writer, and Range activity is authoritative positive evidence.

- [x] **DM-29 — Make durable-byte provenance explicit and ban percentage-derived byte truth**
  - **Problem:** several lifecycle checkpoints persist `durableBytes = totalSize * progress`; multipart recovery also stores/derives credited state from floating-point progress rather than exact byte counts.
  - **Root cause:** presentation/transport percentage and durable byte evidence are represented through overlapping fields, allowing an estimate to become authoritative recovery state.
  - **Severity / priority:** **P0 / Critical because synthetic bytes can combine with monotonic JobStore rules to permanently block recovery.**
  - **Expected files/areas:** `download_service.dart`, `download_job_state.dart`, `download_job_store.dart`, `persistent_parallel_download.dart` manifest schema, native/range byte bridges, migration tests.
  - **Proposed fix:** attach provenance to durable byte evidence. Persist JobStore bytes only from sources with defined durability semantics: exact visible disk bytes, Range writer boundary bytes after flush, verified part files/manifests with explicit byte counters, or native resume/byte evidence only when the executor guarantees it is recoverable. Add exact per-part durable-byte fields to a new manifest schema. Percentage remains presentation/history only.
  - **Verification/testing:** 37% callback + zero surviving bytes; native temp disappears; exact native written bytes vs visible file; old manifest migration/rounding; 0.999 sentinel; crash between byte callback and persistence; no `progress * expected` accepted as durable truth.
  - **Dependencies:** DM-19 defines native ownership/evidence quality.
  - **Implementation status (2026-09-11):** First correctness slice removes percentage-derived JobStore byte writes from startup attachment, interruption, running, pause, and failed-resume lifecycle boundaries. Status/progress may still be projected to UI/metadata, but JobStore now either preserves its previous byte evidence or receives the exact visible `partialBytes` observation on failed resume. A regression guard rejects reintroduction of these `progress * totalSize` durable writes.
  - **Confirmed root cause so far:** lifecycle code reused UI/plugin percentage as if it were a durable-byte measurement; because JobStore is monotonic, one synthetic high-water mark could survive after the underlying native temp bytes disappeared and poison later recovery.
  - **Implementation status (2026-09-11, provenance slice):** JobStore schema v2 now persists `DownloadDurableByteProvenance`. Schema-v1 positive byte counts migrate conservatively to `legacyUnknown`; zero bytes use `none`; exact callers can record `verifiedFinalFile`, `exactDisk`, `rangeFlushed`, `multipartManifest`, or `nativeRecoverable`. Status-only checkpoints preserve provenance, while a changed unqualified byte count is downgraded to `legacyUnknown` instead of inheriting stronger evidence.
  - **Implementation status (2026-09-11, multipart slice):** Multipart manifest schema v5 persists an exact `durableBytes` counter per child. Parent credited bytes now sum those counters rather than `part.size * credibleProgress`; legacy unfinished manifests migrate with zero byte authority and are repaired from visible disk evidence. Native/plugin percentages remain presentation/recovery hints only, while exact disk observations and exact completion update durable byte truth.
  - **Implementation status (2026-09-11, final provenance audit):** Startup/saved-progress reconciliation now reads exact multipart `durableBytesFor()` counters instead of reconstructing bytes from percentage. Positive `legacyUnknown` JobStore bytes are excluded from recovery truth (covering vanished native-temp evidence), Range progress is flushed before checkpoint callbacks and tagged `rangeFlushed`, visible partial seeding is tagged `exactDisk`, and completion records bytes only from a verified visible final file. A schema-v4 behavioral restore test proves a `0.999` legacy child has zero durable authority until disk evidence repairs it.
  - **Verification passed:** guarded RED→GREEN durable-byte contract tests, JobStore provenance/migration tests, multipart schema-v5 plus schema-v4 `0.999` restore behavior, Range transfer/fast-fail suites, pending-start lease and runtime-ownership regressions, and `flutter analyze --no-fatal-warnings --no-fatal-infos` all passed before this item was checked off.

- [x] **DM-20 — Permit authoritative downward byte correction when stronger evidence proves loss**
  - **Problem:** JobStore normally rejects decreasing `durableBytes`, even when exact disk or a valid manifest rollback proves fewer recoverable bytes survived.
  - **Root cause:** normal-attempt monotonicity and recovery reconciliation use the same write semantics.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** JobStore/state model, recovery byte selection, DownloadService, fault-injection tests.
  - **Proposed fix:** retain monotonic writes for ordinary callbacks but add a narrowly scoped reconciliation operation that may lower bytes only with stronger evidence, a generation/fingerprint check, and an auditable provenance/reason.
  - **Verification/testing:** JobStore 70MB vs disk 40MB; JobStore >0 vs zero surviving bytes; truncated partial; manifest rollback; stale callback after correction; incompatible identity.
  - **Dependencies:** DM-29.
  - **Implementation status (2026-09-11):** Added a dedicated serialized `reconcileDurableBytes` path that permits only authoritative downward corrections, validates the active generation and compatible resource fingerprint, persists reconciliation reason/evidence/timestamp, and atomically advances generation to fence stale callbacks. Ordinary `put`, `checkpoint`, and `updateForAttempt` remain monotonic. Startup recovery now uses this path when exact disk/manifest evidence proves fewer bytes survived than JobStore.
  - **Verification passed:** RED→GREEN reconciliation tests prove 700→400 correction, >0→0 survivor loss, generation fencing of stale callbacks, rejection of weak evidence/incompatible fingerprints, persistence of audit reason/evidence, preservation of ordinary monotonic writes, startup recovery integration, existing JobStore/recovery helper regressions, and `flutter analyze --no-fatal-warnings --no-fatal-infos`.

- [x] **DM-21 — Make authoritative lifecycle checkpoints fail closed at control boundaries**
  - **Problem:** start/queue/pause/resume/cancel/completion can continue after JobStore checkpoint rejection or storage exception.
  - **Root cause:** `_checkpointLogicalJob()` returns `void` and swallows rejected/failed writes; some direct store writes also ignore boolean results.
  - **Severity / priority:** **P0 / Critical for ownership/user-intent boundaries.**
  - **Expected files/areas:** `download_service.dart`, JobStore backend, typed control errors/results, persistence failure tests.
  - **Proposed fix:** critical lifecycle checkpoints return an explicit durable result and must succeed before irreversible ownership side effects. Progress snapshots may remain coalesced/best-effort only when boundary flushes are guaranteed.
  - **Verification/testing:** backend reject/throw during start, enqueue, pause, resume, refresh, completion and cancel; kill after each point; state/intent cannot invert after relaunch.
  - **Dependencies:** DM-20.
  - **Implementation status (2026-09-11, control-boundary slice):** `_checkpointLogicalJob` now reports explicit commit/reject/error success instead of swallowing failure as `void`. Queue admission persists `queued` before mutating waiter/metadata/plugin projections; user resume persists `starting` before clearing durable/user-paused projections; user pause persists `pausing` before stopping Range/native ownership. A failed authoritative checkpoint throws before those ownership side effects. Remaining DM-21 work is to audit/fence fresh-start, refresh replacement, completion and cancel/delete boundaries plus direct JobStore writes and add backend reject/throw fault-injection coverage.
  - **Implementation status (2026-09-11, persistence-boundary slice):** Fresh starts now require the initial JobStore record to commit before queue/UI/native projections; Range resume refuses to begin a new attempt if stronger exact-disk byte evidence cannot be persisted; completion commits `completed` plus verified-final-file bytes before metadata is allowed to project 100%. Remaining DM-21 work is cancel/delete and source-refresh boundaries, direct-write audit, and backend reject/throw behavioral coverage.
  - **Implementation status (2026-09-11, cancel-boundary slice):** Active user cancel now persists authoritative `canceled` intent before Range/native/multipart/plugin ownership is stopped or durable state is removed; rejected persistence aborts the irreversible cleanup path. Completed-file deletion remains exempt from rewriting a terminal `completed` record. DM-07 still owns the stronger cleanup-acknowledged durable tombstone lifetime. Remaining DM-21 work is source-refresh boundary ordering, final direct-write audit, and backend reject/throw behavioral coverage.
  - **Implementation status (2026-09-11, source-refresh/final slice):** Source refresh now writes an authoritative `interrupted` checkpoint before either multipart source replacement or single-file plugin-record replacement. A rejected or throwing checkpoint aborts the replacement, so an expired-source recovery cannot install new executor state when durable lifecycle storage is unavailable.
  - **Final direct-write audit:** Critical control-boundary writes are now checked before fresh-start projection, queue admission, user resume, user pause, Range attempt/restart, completion projection, cancel cleanup, and source replacement. Generation-fenced hot progress callbacks remain best-effort because they do not authorize irreversible ownership changes; startup reconciliation writes are recovery convergence rather than user control boundaries. Durable cancel-row removal remains intentionally deferred to DM-07/DM-30 for positive ownership settlement.
  - **Verification passed:** RED source-replacement ordering guard; behavioral `commitAuthoritativeDownloadCheckpoint` coverage for accepted, rejected, and throwing backend writes; lifecycle/persistence/cancel boundary guards; JobStore attempt/provenance/reconciliation tests; recovery/zero-restart/runtime-ownership/multipart regressions; and `flutter analyze --no-fatal-warnings --no-fatal-infos`.

- [x] **DM-32 — Gate every public download control behind initialization/recovery readiness**
  - **Problem:** `main.dart` calls `DownloadService.init()` post-frame without awaiting it, while start/pause/resume/cancel do not universally await the same readiness barrier.
  - **Root cause:** initialization is treated as an app-start side effect rather than a prerequisite shared by every state-mutating command.
  - **Severity / priority:** **P0 / Critical because a fresh command can race persisted-job/native recovery and create duplicate or contradictory ownership.**
  - **Expected files/areas:** `main.dart`, `download_service.dart`, provider lifecycle, startup/relaunch tests.
  - **Proposed fix:** expose one idempotent readiness Future/state. Every public state-changing command joins it. Recovery must reach a defined stable point before a new queue mutation proceeds. Initialization failure must produce a typed recoverable service-unavailable outcome and allow a deliberate retry; foreground reconciliation during initialization must coalesce rather than race.
  - **Verification/testing:** tap download immediately after first frame; resume/pause during startup; foreground event during init; init storage/plugin failure then retry; concurrent callers waiting on same init; no command bypasses recovery.
  - **Dependencies:** DM-21 for startup persistence failures; can be implemented early with conservative blocking.
  - **Implementation notes (2026-09-11):** Added a single `DownloadServiceReadinessBarrier` shared by `init()` and every public state-mutating download command. Concurrent callers receive the same in-flight Future and cannot enter start/pause/resume/cancel/settings mutation until startup recovery has completed. Foreground reconciliation now joins that barrier instead of returning early and losing the event.
  - **Failure/retry semantics:** Initialization failures surface as typed `DownloadServiceUnavailableException(initializationFailed, retryable: true)` and clear only the failed attempt so a later command deliberately retries. Retry cancels any listener installed by a partially completed prior init before attaching a replacement, preventing duplicate event consumers. Post-frame startup explicitly observes the failure instead of leaving an unhandled Future; later controls remain able to retry.
  - **Confirmed root cause:** `init()` itself coalesced only callers that explicitly invoked it; command entry points and foreground reconciliation bypassed that Future, so they could mutate queue/native state while `_recoverPersistedDownloads` was still reconciling persisted ownership.
  - **Verification passed:** readiness unit tests prove exact-Future coalescing and typed fail-then-retry behavior; source guards prove start/pause/resume/cancel and public settings controls await readiness before mutation, foreground reconciliation awaits the same barrier before queue work, and startup observes init failure; download lifecycle/recovery/ownership/multipart regression suites and `flutter analyze --no-fatal-warnings --no-fatal-infos` also pass.

- [x] **DM-02 — Make single-file pause prove that transport ownership actually stopped**
  - **Problem:** accepted native pause + missing callback can become logical/UI paused while the worker is still alive.
  - **Root cause:** the 5-second timeout is treated as success for ordinary single-file tasks; startup enforcement of persisted pause can also ignore pause failure and still write plugin `paused`.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** DownloadService, native transport, startup recovery, pause/resume tests.
  - **Proposed fix:** pause remains `pausing/settling` until a generation-matching callback or DM-19 oracle proves ownership release. Startup user-pause enforcement follows the same rule and may not write a DB state that falsely implies settled ownership.
  - **Verification/testing:** accepted pause/no callback/still-live owner; startup after crash between durable pause intent and native pause; pause enforcement fails on relaunch; late completion; repeated pause/resume; iOS background handoff.
  - **Dependencies:** DM-19, DM-21, DM-32.
  - **Implementation notes (2026-09-11):** Single-file pause now treats native pause acceptance/callback as provisional and requires the DM-19 runtime ownership oracle to prove `notOwned` before projecting a settled pause. The same ownership proof applies to ordinary single-file downloads and multipart children; an owned same-identity worker gets one pause retry without cancellation.
  - **Unsettled ownership behavior:** If ownership remains `owned`, `settling`, or `unknown`, durable user intent remains `pausing` with `userPaused=true`; the service no longer rolls the request back to `running` or publishes a false `paused`. Startup recovery uses the same rule and does not rewrite plugin/UI state to `paused` until release is proven.
  - **Confirmed root cause:** `_pauseTransfer()` waited for pause/final callbacks but only verified runtime ownership for internal multipart children, so an ordinary single-file task could return success after timeout while its worker remained alive. Startup pause enforcement also ignored the pause result and unconditionally persisted `TaskStatus.paused`.
  - **Verification passed:** pre-fix RED regression; pause-settlement guard; runtime-ownership, JobStore, recovery-reconciliation and lifecycle-checkpoint regression suites; generated-source-aware `flutter analyze --no-fatal-warnings --no-fatal-infos`; `git diff --check`.

- [ ] **DM-22 — Introduce a two-phase Dart<->Swift ownership handoff for iOS multipart promotion**
  - **Problem:** Swift can select/start a child from `multipartPlans` while Dart still considers the same generation launchable; stale snapshots can re-add consumed work.
  - **Root cause:** snapshots describe work but do not transfer ownership through a durable claim/ack protocol.
  - **Severity / priority:** **P0 / Critical duplicate-writer risk.**
  - **Expected files/areas:** multipart coordinator, continued-processing bridge, `DownloadNativeWaitingQueue.swift`, `AppDelegate.swift`, iOS tests.
  - **Proposed fix:** export `(parent, child, generation, claimId, lease)`; native atomically claims before launch; Dart treats claimed work unavailable before first byte; snapshot versions cannot reintroduce claimed/consumed work. Recheck foreground and claim validity immediately before native `resume()`.
  - **Verification/testing:** background during selection; foreground before resume; stale snapshot after claim; delayed first byte; duplicate snapshot; suspension; claim expiry/requeue; exactly one writer.
  - **Dependencies:** DM-01, DM-10, DM-15.

- [ ] **DM-23 — Require old-owner settlement before multipart adoption, recycle, assembly, or relaunch**
  - **Problem:** exact-size adoption and tail recovery may ignore failed pause/cancel and continue as if ownership ended.
  - **Root cause:** byte-integrity proof and exclusive-ownership proof are conflated.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** multipart coordinator, DownloadService child pause/cancel seam, native ownership tests.
  - **Proposed fix:** track `bytesVerified` separately from `ownerSettled`. Assembly, delete, backup restore and relaunch require settled ownership; otherwise keep a generation-fenced settling state and reconcile.
  - **Verification/testing:** exact-size child + failed pause + live writer; failed tail cancel; old writer writes after recycle attempt; callback lost; process restart while settling; no part reuse/deletion before settlement.
  - **Dependencies:** DM-19, DM-10.

- [ ] **DM-30 — Preserve ownership evidence until cancel is positively settled**
  - **Problem:** single transport detaches Transfer tracking even when `cancel()` returns false; service and multipart cancellation paths can ignore cancel failure and delete DB records anyway; UI may skip cancellation based on status.
  - **Root cause:** “cancel command sent”, “executor no longer owns task”, and “safe to forget/delete task” are collapsed into one operation.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** `download_transport.dart`, `download_service.dart`, multipart `cancelParts`, downloads provider/delete flow, native liveness tests.
  - **Proposed fix:** cancellation returns a typed settlement such as `canceled`, `alreadyGone`, `stillOwned`, `unknown`. Keep Transfer/native tracking and DB ownership evidence until the oracle proves release. Never decide cancellation necessity from `TaskStatus` alone. Failed/unknown cancel enters durable settling state under tombstone protection.
  - **Verification/testing:** Transfer.cancel false; cancel throws; bulk child cancel false; DB says failed/notFound while native worker live; repeated cancel; cancel during completion; app kill during unknown settlement; no owner is forgotten prematurely.
  - **Dependencies:** DM-19, DM-21; DM-07 consumes this result.

- [ ] **DM-03 — Return explicit typed outcomes for start/resume/pause/cancel**
  - **Problem:** callers receive void/boolean results that cannot distinguish running, attached, queued, settling, missing state, restart required, persistence failure or terminal state.
  - **Root cause:** command APIs expose transport-command acceptance rather than logical operation outcome.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** DownloadService, transport abstraction, downloads provider, launcher, UI tests.
  - **Proposed fix:** define typed outcomes such as `running/attached`, `queued`, `paused`, `settlingOwnership`, `alreadyComplete`, `restartRequired`, `recoverableFailure`, `serviceUnavailable`, `missingState`, `terminal`. UI changes only after a durable service outcome.
  - **Verification/testing:** missing DB; JobStore-only job; failed native resume; failed Range; missing manifest; source refresh failure; queue full; unknown owner; initialization failure; already complete.
  - **Dependencies:** DM-19, DM-21, DM-30; conservative outcomes can land earlier.

- [ ] **DM-04 — Recover from the union of persistence and ownership sources**
  - **Problem:** jobs disappear when plugin DB rows are missing while JobStore, metadata, native ownership, manifest or files survive.
  - **Root cause:** startup/UI inventory is downloader-DB-first.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** DownloadService, JobStore, storage metadata, transport/native ownership, multipart manifests, UI inventory, startup tests.
  - **Proposed fix:** construct one idempotent logical inventory from JobStore + plugin DB + Transfer/native ownership + metadata + manifests + safe app-owned filesystem evidence. Reconstruct missing projections or mark explicit orphan/settling states.
  - **Verification/testing:** remove each source singly and in realistic pairs; user pause; canceled tombstone; native-only owner; manifest-only partials; deterministic FIFO; one logical row/owner.
  - **Dependencies:** DM-19, DM-20, DM-21, DM-24.

## Phase 2 — One logical state, canonical identity, integrity, and terminal deletion

- [ ] **DM-05 — Make `DownloadJobState` the sole logical lifecycle authority**
  - **Problem:** plugin `TaskStatus.paused` currently represents user pause, interruption/failure parking and queue compatibility; side flags in multiple stores disambiguate it.
  - **Root cause:** executor status is also being used as application state.
  - **Severity / priority:** **P1 / High architectural prerequisite.**
  - **Expected files/areas:** JobState/JobStore, DownloadService, concurrency helpers, downloads provider, native snapshot projection.
  - **Proposed fix:** plugin/native statuses become execution evidence only. Persist explicit logical/user/queue state and centralize projection to UI/plugin/native compatibility states.
  - **Verification/testing:** every logical state x plugin status x owner evidence x metadata flags, with reordered events; no user-pause inference from plugin paused alone.
  - **Dependencies:** DM-03, DM-04.

- [ ] **DM-24 — Introduce one canonical logical episode identity separate from execution `taskId`**
  - **Problem:** duplicate detection/adoption uses inconsistent combinations of taskId, tracking URL, episode URL and target file.
  - **Root cause:** execution-attempt identity and logical-download identity are not formally separated.
  - **Severity / priority:** **P1 / High; P0 if duplicate start is reproduced.**
  - **Expected files/areas:** DownloadService, JobStore schema, cleanup identity helpers, downloads provider, Swift `episodeKey`, migration tests.
  - **Proposed fix:** define stable logical download ID/key and map one or more execution task IDs/generations to it. Adoption of a differently named live task atomically moves/aliases all projections.
  - **Verification/testing:** DB lost while native live; same episode new taskId; same filename different episode; source URL rotates; duplicate taps; relaunch during adoption; no cross-episode collapse.
  - **Dependencies:** DM-05.

- [ ] **DM-06 — Strengthen resource identity and final completion verification**
  - **Problem:** current file length may become the expected length; same-size resource replacement can pass size-only checks; fingerprint validator fields are not consistently populated end-to-end.
  - **Root cause:** observed bytes, expected resource size, stable resource identity and volatile signed delivery URL are mixed.
  - **Severity / priority:** **P1 / High (data integrity).**
  - **Expected files/areas:** `getMetadata`, DownloadMetadata, JobStore fingerprint, DownloadService completion/recovery, Range/multipart source checks.
  - **Proposed fix:** distinguish `observedFileBytes`, `expectedResourceBytes`, stable resource identity and delivery URL. Persist strong ETag/Last-Modified when available; preserve provider/source/quality identity; use byte-prefix proof where validators are absent. Never compare a raw signed URL as the sole stable identity, and never complete solely because observed length equals itself.
  - **Verification/testing:** truncated final; wrong-size final; same-size changed resource; signed URL rotates for same resource; validator changes; validators absent; unknown-size source; crash after rename before complete checkpoint.
  - **Dependencies:** DM-05, DM-20, DM-29.

- [ ] **DM-07 — Make delete a durable tombstone-first ownership-settlement transaction**
  - **Problem:** UI can hide a row, time out cancel, delete DB/metadata/files, and lose the terminal fact while a worker is still settling.
  - **Root cause:** terminal intent, cancellation, persistence cleanup and filesystem cleanup are split between service and UI.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** DownloadService, JobStore, downloads provider, native queue, cleanup utilities.
  - **Proposed fix:** persist logical `canceled` tombstone before any ownership mutation; use DM-30 settlement result; perform idempotent cleanup only after ownership is proven gone. Retain/gc tombstones by explicit generation/age policy. UI may hide immediately but does not own destructive cleanup.
  - **Verification/testing:** active/range/multipart/assembly/refresh delete; cancel timeout/false; kill after tombstone; late complete/running callback; repeated delete; failed/notFound-looking row with live owner.
  - **Dependencies:** DM-19, DM-21, DM-30, DM-10.

- [ ] **DM-31 — Make URL-refresh descriptor ownership transactional and generation-aware**
  - **Problem:** `DownloadLauncher` saves a descriptor before `startDownload()` and removes it on a failed result; concurrent/obsolete callers for the same episode can remove the descriptor of a successful/current job.
  - **Root cause:** a lifecycle-critical recovery capability is persisted by the presentation/launch caller outside the logical job transaction.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** `download_launcher.dart`, `download_url_refresh.dart`, DownloadService start/cancel/source replacement, JobStore/logical identity.
  - **Proposed fix:** pass descriptor data into the service and commit/remove it with the logical job generation. Old callers/generations cannot delete a current descriptor. Decide explicitly whether descriptor persistence is required or optional per source; surface failure through typed start outcome.
  - **Verification/testing:** two simultaneous starts same episode; first fails after second succeeds; old cancel vs new generation; descriptor store failure; crash between descriptor/job writes; source/quality change; relaunch with descriptor-only/job-only state.
  - **Dependencies:** DM-21, DM-24, DM-11.

- [ ] **DM-08 — Make source refresh complete and safe for every resumable representation**
  - **Problem:** native-resume-only single downloads cannot safely migrate opaque bytes when signed URLs expire; HTTP refresh handling differs across paths.
  - **Root cause:** no unified capability matrix exists for visible prefix, opaque native resume data, multipart ranges and provider refresh identity.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** DownloadService, transport/compatibility seam, URL refresher/store, multipart refresh, Range validation.
  - **Proposed fix:** same-source native resume first when valid; otherwise migrate/adopt only proven bytes, validate stable resource identity, then Range-resume/restart. Normalize 401/403/404 policy using source/provider evidence. If opaque bytes cannot migrate, return explicit `restartRequired` rather than loop/deadlock.
  - **Verification/testing:** 401/403/404; native resume only; visible partial; changed size/validator/content; descriptor expired; provider unavailable; refresh during crash/relaunch.
  - **Dependencies:** DM-03, DM-06, DM-20, DM-31.

- [ ] **DM-16 — Separate historical presentation progress from recoverable-byte evidence**
  - **Problem:** `savedProgress > 0` currently prevents zero restart even if no bytes or native resume data survive.
  - **Root cause:** a UI high-water mark is treated as evidence of recoverable data.
  - **Severity / priority:** **P1 / High; directly involved in resume deadlocks.**
  - **Expected files/areas:** resume helpers, telemetry, DownloadService, JobState, downloads provider, zero-restart tests.
  - **Proposed fix:** recovery decisions consume only provenance-bearing byte/owner evidence. Historical percentage stays presentation metadata, can reconcile downward, and cannot independently block a safe restart.
  - **Verification/testing:** stale 42% + zero evidence => explicit restart/recovery outcome; visible partial still protected; native opaque resume known/unknown; late regressive callback; 0.999 sentinel; post-DM20 correction.
  - **Dependencies:** DM-20, DM-29, DM-05, DM-06.

## Phase 3 — Deterministic retries, callback fencing, persistence, and concurrency

- [ ] **DM-09 — Introduce one network-interruption/hold policy across all transports**
  - **Problem:** native Transfer, Dart Range, multipart and iOS native retry paths differ for offline periods, transport failures and retry exhaustion.
  - **Root cause:** custom orchestration does not expose one logical network-hold contract; native Transfer hold/offline evidence is not fully projected upward.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** transport, retry policy, Range, multipart, DownloadService, Swift retry bridge, connectivity integration.
  - **Proposed fix:** model `waitingForNetwork` separately from host/server backoff and user pause. Surface native hold reason when available; connectivity restoration triggers fenced reconciliation; avoid double retry loops where the executor already owns waiting/retry.
  - **Verification/testing:** offline->online, Wi-Fi<->cellular, DNS/captive network, long offline, intermittent progress, retry exhaustion, pause/cancel offline, 408/425/429/5xx, multiple tasks recovering together.
  - **Dependencies:** DM-05, DM-03.

- [ ] **DM-10 — Replace time-based correctness fences with generations/acks**
  - **Problem:** late callbacks can cross pause/resume/restack/retry/refresh/cancel boundaries; fixed delays cannot prove causality.
  - **Root cause:** attempt generation exists in some paths but not every logical/native operation.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** JobStore, DownloadService, multipart, Swift snapshot/bridge, control callbacks.
  - **Proposed fix:** every ownership-changing operation carries an operation/generation token; only current-token callbacks mutate logical state, except independently verified safe terminal bytes. Remove correctness dependence on arbitrary suppression windows.
  - **Verification/testing:** callbacks delayed 0.8s/5s/30s; old failure after successful resume; old complete after source change; cancel then running; native background promotion vs foreground recovery.
  - **Dependencies:** DM-01, DM-19, DM-05.

- [ ] **DM-11 — Define crash-safe write ordering and convergence across all replicas**
  - **Problem:** JobStore, plugin DB, metadata, refresh descriptor, manifest/files and native queue can be individually valid yet mutually inconsistent after a crash.
  - **Root cause:** no transaction spans these stores; ordering/reconciliation rules are incomplete.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** DownloadService, JobStore, storage service, URL refresh, multipart manifest, native queue, fault-injection harness.
  - **Proposed fix:** document and enforce each transition's write-ahead intent, executor effect, acknowledgement, projection and cleanup order. Version every correctness-critical replica. Reconciliation must converge after a crash at every boundary.
  - **Verification/testing:** kill after every write/effect in start, queue promotion, pause, resume, refresh, child completion, assembly rename, completion, cancel/tombstone and cleanup.
  - **Dependencies:** DM-04, DM-05, DM-10, DM-21, DM-31.

- [x] **DM-25 — Remove persistence/database backpressure from the Range receive loop**
  - **Problem:** Range `_receive()` awaits `onState`, which can await JobStore/plugin DB writes while network data is flowing.
  - **Root cause:** progress persistence is synchronous with ingestion instead of coalesced behind a bounded ordered writer.
  - **Severity / priority:** **P1 / High under high throughput or slow storage.**
  - **Expected files/areas:** Range transfer, DownloadService checkpointing, JobStore progress writer, throughput tests.
  - **Proposed fix:** maintain exact byte counters in the receive path; coalesce ordered background checkpoints at bounded cadence; synchronously flush/join at pause/failure/complete/source-change/cancel/dispose. Bound pending persistence work.
  - **Verification/testing:** high-speed local stream + slow/failing stores; pause with pending snapshot; crash before/after flush; disk-full persistence error; stable throughput and correct boundary bytes.
  - **Dependencies:** DM-21, DM-29, DM-20.
  - **Implementation notes (2026-09-11):** Range ingestion now separates durable-file flushing from slower JobStore/plugin observers. After each byte/interval threshold the file is flushed, then the newest exact `(written,total)` checkpoint is submitted to a single-flight coalescing writer without awaiting storage in the network receive loop. While one persistence callback is in flight, older pending progress snapshots are replaced by the newest exact durable byte count.
  - **Boundary semantics:** completion and every pause/failure/cancel exit synchronously join the checkpoint writer before publishing their terminal/paused boundary. Persistence callback errors are retained and converted into a parked failure at the boundary, so throughput optimization does not make lifecycle boundaries fail open. Reconnects keep using the exact in-memory/disk offset and do not create parallel persistence writers.
  - **Confirmed root cause:** `_receive()` previously awaited `onState()` immediately after each 512 KiB/250 ms flush. That observer can await Hive/JobStore/plugin database work, so storage latency directly stopped socket consumption even though the exact bytes were already durable on disk.
  - **Verification passed:** RED test proves a blocked progress observer used to stop file ingestion; GREEN coverage proves the file continues to drain while the first observer is blocked, pending snapshots coalesce, and `stop()` retains ownership until the queued checkpoint joins before `onPaused`. Existing Range recovery, durable-byte provenance and lifecycle checkpoint suites plus generated-source-aware `flutter analyze --no-fatal-warnings --no-fatal-infos` and `git diff --check` pass.

- [ ] **DM-13 — Prevent head-of-line blocking and prove fairness across simultaneous downloads**
  - **Problem:** broad serialization can wait on slow probes, range setup or storage while unrelated sessions need promotion.
  - **Root cause:** short state reservation and slow I/O preparation share serialization scope.
  - **Severity / priority:** **P2 / Medium; raise to P1 if profiling reproduces starvation.**
  - **Expected files/areas:** DownloadService queue, multipart pump, concurrency/governor, profiling tests.
  - **Proposed fix:** reserve state/slot quickly, perform slow preparation outside broad locks where safe, then commit with the same generation/lease. Preserve logical FIFO without allowing a dead host to block healthy sessions.
  - **Verification/testing:** fast + stalled hosts; 5/8/16 parts; range probe timeout; rate limiting; queue concurrency 1..10; pause/cancel during promotion; bounded promotion latency.
  - **Dependencies:** DM-01, DM-10, DM-25.

- [ ] **DM-12 — Remove lifecycle persistence and destructive cleanup from presentation code**
  - **Problem:** downloads provider rewrites plugin states and deletes DB/metadata/files while service state evolves concurrently.
  - **Root cause:** UI became a repair/orchestration layer to compensate for transport-state semantics.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** downloads provider, DownloadService logical snapshots/events, cleanup API.
  - **Proposed fix:** presentation sends commands and reads service-owned logical snapshots only. Optimistic UI is tied to accepted operation IDs/outcomes. DB/metadata/file repair belongs to service reconciliation.
  - **Verification/testing:** refresh racing pause/resume/failure/complete/delete; provider recreation; no lifecycle database writes or file deletion from presentation layer.
  - **Dependencies:** DM-03, DM-05, DM-07, DM-31.

## Phase 4 — Filesystem, background-native integration, platform behavior, and lifetime hardening

- [ ] **DM-27 — Add storage-headroom policy for multipart download and assembly**
  - **Problem:** all parts can download successfully but `.assembling` may require another near-full-file allocation and fail at the final stage.
  - **Root cause:** range-size validation is not paired with destination free-space/headroom planning for crash-safe staging.
  - **Severity / priority:** **P1 / High for large files/low-storage devices.**
  - **Expected files/areas:** DownloadService, multipart assembly, storage helpers, typed UI errors.
  - **Proposed fix:** preflight and re-evaluate conservative headroom. Preserve crash-safe staging unless a lower-amplification algorithm is proven safe. Surface `insufficientStorage` and retain proven parts.
  - **Verification/testing:** enough for parts but not staging; disk fills mid-transfer/mid-assembly; cleanup frees space; resume after space available; no proven parts discarded solely because staging is short on space.
  - **Dependencies:** DM-03, DM-06.

- [ ] **DM-14 — Inventory/recover/clean orphan artifacts with canonical path safety**
  - **Problem:** `.parts`, `.assembling`, temp/final files can outlive logical records; current path checks use textual containment/suffix logic and recursive series cleanup can remove unknown non-video content.
  - **Root cause:** recovery/cleanup is target-driven and path ownership is inferred from strings instead of canonical app-root containment + artifact provenance.
  - **Severity / priority:** **P1 / High after final review because a cleanup mistake can cause user data loss.**
  - **Expected files/areas:** `download_cleanup.dart`, DownloadService, multipart, JobStore/metadata inventory, desktop/mobile path tests.
  - **Proposed fix:** canonicalize absolute paths and require path-segment containment under configured AnimeWitcher download roots; reject lookalike roots/traversal/symlink escape. Delete only files/directories whose contents are all known app-owned artifacts or explicitly selected user targets. Adopt provable orphan state; quarantine ambiguous data.
  - **Verification/testing:** `DownloadsBackup` lookalike; `..` traversal; symlink/reparse escape; Windows case/separators; custom desktop root; unknown file inside series folder; missing manifest/DB; stale canceled-generation parts; no external/unknown file deleted.
  - **Dependencies:** DM-04, DM-06, DM-07, DM-11, DM-24.

- [ ] **DM-15 — Make Dart<->iOS queue snapshots versioned, acknowledged, and recoverable**
  - **Problem:** correctness-sensitive queue snapshots use best-effort method-channel semantics and versionless native persistence; stale Dart state can overwrite newer native promotion state.
  - **Root cause:** queue ownership checkpoints share infrastructure with optional presentation updates.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** continued-processing Dart service, Swift queue, AppDelegate, DownloadService snapshot writer.
  - **Proposed fix:** separate overlay updates from queue checkpoints; add monotonic snapshot versions/claims and acknowledgement; reject stale snapshots; evaluate an atomic native journal if UserDefaults durability is insufficient; reconcile unacknowledged writes.
  - **Verification/testing:** method-channel failure; suspend before ack; native promotion then stale Dart snapshot; native completion while Flutter sleeps; duplicate snapshot; native store corruption/reset.
  - **Dependencies:** DM-10, DM-11; DM-22 consumes claim/version semantics.

- [ ] **DM-26 — Reduce/remove fragile URLSession IMP swizzling using supported plugin APIs**
  - **Problem:** AnimeWitcher replaces plugin URLSession delegate implementations, coupling correctness to plugin internals/selector ordering.
  - **Root cause:** custom hooks filled functionality gaps that now partially overlap supported `background_downloader 9.6.1` native iOS status/progress callbacks.
  - **Severity / priority:** **P1 / High compatibility/race reduction; no blind dependency upgrade.**
  - **Expected files/areas:** pubspec/lockfile, AppDelegate, Swift queue/hook, compatibility seam, iOS integration tests.
  - **Proposed fix:** isolate and behaviorally validate 9.6.1 first. Move status/progress observation to supported native callbacks where equivalent. Retain only the smallest hook still required for promotion/completion ordering, version-gated and behavior-tested.
  - **Verification/testing:** foreground/background bytes/status; completion promotion; retry replacement; suspension; hook unavailable; duplicate callback prevention; device/build-preview integration.
  - **Dependencies:** DM-15, DM-22.

- [ ] **DM-28 — Align platform execution-policy and concurrency semantics**
  - **Problem:** Dart allows 1..10 logical episodes while Swift clamps native background queue to 5; Android user-initiated downloads interact with notification-off settings and UIDT/WorkManager rules.
  - **Root cause:** platform safety caps and execution hints evolved separately from user-visible settings.
  - **Severity / priority:** **P2 / Medium; P1 if device tests reproduce stalls/failures.**
  - **Expected files/areas:** concurrency settings, task hints/notifications, Swift queue, Android manifest/config, platform integration tests.
  - **Proposed fix:** define supported foreground/background concurrency per platform and project settings explicitly rather than silently changing semantics. Verify notification-disabled Android fallback and long-running behavior.
  - **Verification/testing:** concurrency 1/5/6/10 on iOS foreground/background; Android 14+ notifications allowed/denied/disabled; >9-minute transfer; process background/termination; no silent setting mismatch.
  - **Dependencies:** DM-09.

- [ ] **DM-17 — Make service/resource teardown joined, generation-safe, and reinitialization-safe**
  - **Problem:** `dispose()` launches multipart/native/continued-processing teardown with `unawaited`, Range disposal is not globally joined, the static downloader bridge survives, and a new service can be created before the old instance has finished teardown.
  - **Root cause:** keep-alive singleton lifetime is assumed while provider/app restart/test/error paths can create ABA-style old/new instance overlap.
  - **Severity / priority:** **P1 / High after final review for reinitialization correctness; memory-only concerns remain P2.**
  - **Expected files/areas:** DownloadService/provider lifecycle, native transport, Range/multipart disposal, continued-processing channel handler, static event bridge, AppDelegate observers.
  - **Proposed fix:** define an async teardown barrier and service-instance generation. Old callbacks/teardown can never mutate or unregister a newer instance. Join all writers/subscriptions that must end before recreation; keep singleton bridges isolated from per-instance resources.
  - **Verification/testing:** rapid dispose->create; dispose during Range write/native transfer/multipart retry; old MethodChannel handler teardown after new handler registration; repeated ProviderScope recreation; hundreds of cycles; no duplicate/lost callbacks or old writer overlap.
  - **Dependencies:** DM-10, DM-32.

## Phase 5 — Prove the system end-to-end

- [ ] **DM-18 — Build a deterministic end-to-end reliability/chaos acceptance matrix**
  - **Problem:** existing tests are broad, but several correctness-critical runtime/iOS tests assert source structure and isolated helpers do not prove convergence across plugin DB, JobStore, filesystem, native executor, multipart scheduler, UI and Swift background ownership.
  - **Root cause:** no single deterministic harness currently controls transport callbacks, liveness ambiguity, persistence failures, crashes and native handoffs together.
  - **Severity / priority:** **P1 / High final release gate; add cases continuously, mark complete only last.**
  - **Expected files/areas:** existing download tests plus fake native/Transfer/Range transport, fake stores/filesystem clock, native handoff harness, selected device integration tests.
  - **Proposed fix:** support dropped/delayed/duplicated/reordered callbacks, explicit ownership states, slow/failing stores, crash injection at every durable boundary, controlled HTTP responses/network changes, and Dart<->Swift claim/snapshot races. Behavioral assertions are required for invariants; source-string tests may remain only as supplementary compatibility guards.
  - **Verification/testing:** mandatory final matrix: fresh start; immediate command during initialization; duplicate concurrent start; pause/resume/repeated pause; pause intent crash; pause failure with live owner; cancel false/throw/timeout; delete tombstone crash; retry/failure; offline/online; stale percentage with zero evidence; synthetic-byte rejection; downward byte correction; missing DB/metadata/JobStore/descriptor; descriptor caller race; 1/2/5/8/16 parts; missing pending-start callback; Dart/Swift same-part handoff race; exact-size part with unsettled owner; 0.999 tail; expired 401/403/404; ignored Range; validator/resource replacement; unknown-size source; simultaneous downloads/fairness; low disk/assembly; orphan/path traversal/lookalike root/unknown user file; iOS suspension/promotion/foreground; plugin-hook migration; Android long transfer notification combinations; dispose/reinit ABA race.
  - **Dependencies:** All prior items. This is the final acceptance gate.

## Dependency / execution order

Existing identifiers remain stable; final-review items are `DM-29` through `DM-32`. Later Tasks should use **file order first** and satisfy explicit dependencies.

1. **DM-01 -> DM-19 -> DM-29 -> DM-20 -> DM-21 -> DM-32 -> DM-02**: establish ownership, exact byte provenance, safe reconciliation, durable control boundaries and startup readiness.
2. **DM-22 -> DM-23 -> DM-30**: eliminate iOS/multipart handoff races and cancellation ownership loss.
3. **DM-03 -> DM-04 -> DM-05 -> DM-24**: expose trustworthy control results, union inventory, one logical state machine and canonical identity.
4. **DM-06 -> DM-07 -> DM-31 -> DM-08 -> DM-16**: protect resource identity/completion, deletion, refresh capability ownership and recovery decisions.
5. **DM-09 -> DM-10 -> DM-11 -> DM-25 -> DM-13 -> DM-12**: normalize retries/callbacks/persistence/concurrency and remove competing UI writers.
6. **DM-27 -> DM-14 -> DM-15 -> DM-26 -> DM-28 -> DM-17**: harden storage/filesystem/native integration/platform policy/lifetime.
7. **DM-18** grows with every implementation item and remains unchecked until the complete supported-platform matrix passes.

## Non-negotiable invariants for every implementation commit

- Exactly one current writer may own a logical file/range. `unknown` or `settling` ownership blocks another writer.
- Plugin DB status, UI state and existence of a Transfer object are evidence; none alone proves native ownership ended.
- Command acceptance is not state completion. Start, pause, resume, cancel, native claim and source replacement require the appropriate durable + ownership acknowledgement.
- Every public state-changing control joins initialization/recovery readiness before mutating queue or ownership.
- User pause/cancel intent is durably established before ownership-changing side effects; if that critical write fails, the new logical state is not claimed.
- `durableBytes` always has a defined provenance. Historical percentage is never converted into authoritative bytes.
- Stronger exact evidence may correct durable bytes downward through the explicit reconciliation path; stale callbacks cannot restore old high-water bytes.
- Explicit user pause and cancel outrank automatic retry/recovery.
- Terminal tombstones remain durable until all possible old owners/callbacks and cleanup are settled.
- A failed/unknown cancel never causes the transport to forget ownership evidence.
- Proven bytes are not discarded merely to repair bookkeeping. Unprovable bytes trigger an explicit safe restart/restart-required decision, never a silent deadlock.
- Final completion requires independent resource-size/identity evidence or an explicitly defined alternative proof; observed file length cannot validate itself.
- Stable logical/resource identity is separate from volatile signed delivery URL.
- Multipart assembly remains crash-safe and never deletes/reuses a part while an old writer may own it.
- Dart<->Swift ownership/snapshot state is versioned/claimed; stale snapshots cannot reintroduce consumed work.
- Queue/global/per-host limits remain bounded under retries, delayed callbacks, background promotion and concurrent sessions.
- Source refresh cannot attach saved bytes to an unverified different resource, and an obsolete caller cannot delete the current job's refresh capability.
- Filesystem cleanup operates only within canonical configured app roots and never recursively deletes unknown/user content merely because it is non-video.
- Restart and foreground reconciliation are idempotent and converge to one logical state/owner.
- Slow persistence does not directly throttle the network stream beyond bounded checkpoint pressure.
- Old service-instance callbacks/teardown cannot affect a newer instance.
- Unsupported/plugin-internal hooks remain isolated, version-gated and behavior-tested until public APIs replace them.

## Checklist protocol for later Tasks

- Read this entire file, current PR state, latest commits and implementation notes before changing code.
- Use the same branch `plan/download-manager-reliability` and PR #231.
- Start from the first unchecked item in file order whose dependencies are complete; finish partially started earlier work first.
- Work on one clear reviewable slice at a time. Add a behavioral regression test first where feasible.
- Do not “fix” a race by merely increasing a timeout. Use ownership evidence, generation, lease, acknowledgement, or explicit state.
- Do not weaken byte/integrity invariants to make resume succeed. Correct the evidence model instead.
- Run the item's targeted tests and inspect the diff before marking it complete.
- Mark `[x]` only when the behavior described under that item is implemented and its required verification passes. Record implementation notes/commits for the next Task.
- DM-18 remains unchecked until the complete end-to-end matrix passes on supported platforms.
- If implementation uncovers a genuinely new root cause, update this document explicitly; do not silently expand code scope.

## Final review exit criteria

This review phase is considered closed only when the plan contains every confirmed failure mode found in the three audit passes; each implementation item has a root cause, proposed correction, verification cases, and dependencies; no checklist item is marked complete; the PR diff remains documentation-only; and implementation begins from this file rather than from ad-hoc fixes.