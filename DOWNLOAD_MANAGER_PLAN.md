# AnimeWitcher Download Manager Reliability Plan

> **Source of truth for the download-manager reliability work.**
>
> This document was created from a review-only pass. The review commit intentionally changes no download logic, performs no refactor, and adds no feature. Every implementation item remains unchecked so a later task can start from the first `[ ]` item and use this same PR/branch for all follow-up work.

## Review baseline and scope

- Reviewed against `main` commit `7f25aadf6f18008a93aa95dddf5d7810bdb73279` (tree `8ac644f7dcae67d3326ca71a90de4be918f09d9c`).
- Primary Dart orchestration reviewed: `download_service.dart`, `persistent_parallel_download.dart`, `download_transport.dart`, `download_range_transfer.dart`, `download_retry_policy.dart`, `download_concurrency.dart`, `download_connection_governor.dart`, `download_host_profile.dart`, `download_job_state.dart`, `download_job_store.dart`, `download_parallel.dart`, `download_plugin_compat.dart`, `download_url_refresh.dart`, `download_telemetry.dart`, and download utilities.
- Persistence/UI integration reviewed: `storage_service.dart`, `downloads_provider.dart`, `download_launcher.dart`, download cleanup/resume utilities, and the surrounding downloads UI flow.
- iOS background/continued-processing integration reviewed: `DownloadContinuedProcessingManager.swift`, `DownloadNativeWaitingQueue.swift`, `AppDelegate.swift` integration, and the Dart continued-processing bridge.
- Existing download tests were reviewed, including recovery, relaunch chaos, fault injection, startup reconciliation, range transfer, URL refresh, transport, concurrency, multipart recovery/tail recovery, telemetry, and iOS bridge tests.

## Current architecture and lifecycle

### Main components

1. **Launch/source resolution** — `download_launcher.dart` resolves a provider/source, verifies metadata/range capability, persists a URL-refresh descriptor, and calls `DownloadService.startDownload()`.
2. **Logical queue/orchestration** — `download_service.dart` owns user-facing task lifecycle, queue slots, pause/resume/cancel, state projection, source refresh, native transport rehydration, restart recovery, and coordination with persistence.
3. **Single-file transport** — `download_transport.dart` delegates normal one-file transfers to `background_downloader`, while `download_range_transfer.dart` provides a validated byte-range continuation fallback when a visible partial file exists.
4. **Multipart transport** — `persistent_parallel_download.dart` owns immutable byte ranges, per-part attempts, manifests, global connection reservations, slow-start/ramp behavior, recovery timers, source validation, and final staging/assembly.
5. **Durable state** — download state is distributed across `DownloadJobStore` (Hive), `background_downloader` records/resume data, download metadata (Hive), multipart manifests/part files, URL-refresh descriptors, iOS native queue state, and process-local sets/maps.
6. **UI projection** — `downloads_provider.dart` combines downloader records + metadata + live service events and currently also performs some persistence normalization itself.
7. **iOS background continuity** — the Dart service exports queue snapshots/multipart plans to Swift so URLSession work can continue and promote waiters while Flutter is suspended.

### Lifecycle traces

- **Download:** source resolve -> metadata probe -> metadata/refresh descriptor -> logical task/job checkpoint -> queue -> single native transfer or multipart coordinator -> progress/status projection -> completion persistence -> downloaded file.
- **Pause:** durable pause intent is written -> range writer is stopped/joined where applicable -> single native or multipart transport is asked to pause -> logical/plugin/UI paused state is projected.
- **Resume:** logical queue serializes resume -> user-pause intent is cleared -> task/bytes are reconstructed -> URL may be refreshed -> native resume, visible-partial range continuation, multipart restore, or safe fresh restart is attempted.
- **Failure/retry:** native/range failures are classified; multipart children may retry independently; logical failures are generally parked as a recoverable paused/interrupted row; authorization/not-found failures may trigger source refresh.
- **App restart/crash:** `DownloadService.init()` restores logical intent, rehydrates native transfers, walks persisted downloader records, restores multipart manifests, reconciles ownership, rebuilds the queue, and `onAppForegrounded()` runs another reconciliation when the app resumes.
- **Network interruption:** native plugin retry behavior, Dart range retry policy, multipart child recovery, and iOS URLSession retry logic currently have different retry/parking semantics; there is no single download-level waiting-for-network state.
- **Cancel/delete:** logical cancellation attempts to stop native/range/multipart ownership and tombstone state; the UI then removes downloader records/metadata/files on a best-effort basis.

## Findings summary

### Confirmed / high-confidence defects

- Multipart slow-start can strand a child indefinitely after `startPart()` reports success if no subsequent running/progress/status callback arrives. The child remains in `currentBatchPendingIds`, blocking the next ramp batch, and no pending-start lease/watchdog exists.
- Startup recovery enumerates `background_downloader` database records and joins `DownloadJobStore`; a valid authoritative JobStore entry with a missing downloader DB row is not itself enumerated/reconstructed. The downloads UI has the same DB-first visibility problem.
- Single-file pause treats an accepted native pause as successful after a 5-second callback timeout without verifying that the ordinary task left the live native set. Multipart children do perform this ownership verification; ordinary single-file tasks do not.
- Resume is exposed as `Future<void>` to the UI. Several failure/no-task paths can return without throwing or without an explicit failure outcome, while the UI has already optimistically switched the row to `enqueued`.
- `startDownload()` can find an existing recoverable row, call the resume path, and return success even when the resume attempt did not actually establish transport ownership.
- Completion persistence can choose the current on-disk file length as the first positive “known” expected size. This makes the completion boundary weaker than it appears because an independently known expected size is not always required before `completed` is checkpointed.
- `TaskStatus.paused` carries multiple meanings (explicit user pause, queue/failure parking, interrupted transfer), and separate metadata/in-memory flags are required to disambiguate it. At least one iOS native snapshot path can infer `userPaused` from a paused downloader row when it is not a queue waiter.
- `downloads_provider.dart` rewrites failed/not-found downloader records to paused directly, outside `DownloadService`/`DownloadJobStore`, creating another writer of lifecycle state and another race surface.
- The downloads UI can time out waiting for cancellation and then independently delete downloader DB/metadata/files while cancellation is still settling, leaving a race with native ownership.
- A refreshed signed URL cannot safely reuse native-only resume data for a single-file transfer when no visible partial prefix exists, so an expired URL can leave preserved bytes that cannot be migrated to the refreshed source automatically.

### Important risks / design gaps

- Multiple durable authorities are updated independently and often best-effort/unawaited; crash windows can produce valid but conflicting snapshots that current reconciliation does not cover exhaustively.
- Fixed-duration fences (for example waiter restacking/callback suppression windows) are time-based rather than acknowledgement/generation-based and are vulnerable to unusually late native callbacks.
- Range, native, multipart, and iOS background retry paths react differently to offline/online transitions; a task can look `running` at 0 B/s or park until manual action instead of entering a consistent network-wait state.
- Resume of a partial range may hold a serialized scheduler path while performing probes/range setup, producing head-of-line blocking between concurrent logical downloads under adverse network conditions.
- Display progress is intentionally monotonic, but exact recoverable bytes can be lower after corruption/loss. Without a distinct durable-byte projection the UI can temporarily claim progress that cannot actually be resumed.
- Orphan `.parts` directories, `.assembling` files, and partial files are recoverable when their logical records still exist, but there is no complete filesystem-inventory recovery path when the DB/metadata side disappears.
- The Dart->iOS continued-processing bridge swallows platform invocation failures by design. A failed native queue snapshot is therefore not visible to the logical state machine and can leave Dart/native background views diverged.
- Static/native subscriptions and process-lifetime maps are mostly cleaned for the keep-alive singleton path, but lifecycle ownership should be explicitly stress-tested to prevent duplicate subscriptions or retained state across reinitialization/hot-restart/test scenarios.

## Severity convention

- **P0 / Critical:** can permanently strand active work or make a resumable task unrecoverable without clear user action.
- **P1 / High:** can create wrong lifecycle state, duplicate ownership, data-integrity risk, or unreliable recovery in realistic conditions.
- **P2 / Medium:** robustness/fairness/diagnostic gap that amplifies failures or makes edge cases harder to recover from.
- **P3 / Low:** defensive lifecycle cleanup/hardening with limited normal-user impact.

# Implementation checklist

## Phase 1 — Stop the known “stuck forever” paths

- [ ] **DM-01 — Add a lease/watchdog for multipart `pending-start` ownership**
  - **Problem:** A multipart child whose enqueue/start call returns `true` can remain forever in `currentBatchPendingIds` if native never emits the callback that marks it ready. The next slow-start batch is blocked and a multi-part episode can sit at 0 B/s with untouched parts.
  - **Root cause:** Reservation is made before enqueue (correctly closing the enqueue/running race), but the reservation has no expiration/ownership confirmation deadline. `_pumpSession()` treats a non-empty pending set as a successful wait condition, so coordinator recovery is not armed for this state.
  - **Severity / priority:** **P0 / Critical. First implementation item.**
  - **Expected files/areas:** `lib/core/services/persistent_parallel_download.dart`; possibly `download_service.dart` for live-owner verification; multipart auto-recovery tests.
  - **Proposed fix:** Give each pending-start attempt a generation-bound lease. On expiry, query/confirm native/range ownership and durable bytes. If ownership is real, adopt it and release the slow-start gate; if not, roll back only that reservation and schedule normal child recovery. Never launch a duplicate while ownership is ambiguous.
  - **Verification/testing:** Add a deterministic behavioral test where `startPart()` returns `true` but no callback ever arrives; verify the coordinator recovers and later ranges start. Add variants for delayed callback after lease expiry, pause during the lease, app reconciliation during the lease, 5/8/16 configured parts, and global-budget contention.
  - **Dependencies:** None. Later DM-10 generation fencing should reuse the same lease token model.

- [ ] **DM-02 — Make single-file pause prove that transport ownership actually stopped**
  - **Problem:** The logical/UI state can become paused after an accepted native pause even if the ordinary single-file worker is still live after the 5-second callback timeout.
  - **Root cause:** `_pauseTransfer()` verifies post-pause liveness for internal multipart chunks, but not for normal single-file native tasks. Timeout is currently interpreted as success rather than “state unknown”.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** `lib/core/services/download_service.dart`, `lib/core/services/download_transport.dart`, pause/resume behavioral tests.
  - **Proposed fix:** Use the same explicit ownership-settlement invariant for normal tasks: an accepted command is not a completed pause. Confirm the task is no longer live or receive a generation-matching paused/final callback; otherwise keep an interrupted/pausing state and reconcile rather than claiming paused. Do not discard resume data or cancel as a substitute for pause.
  - **Verification/testing:** Simulate accepted pause + missing callback + still-live owner; accepted pause + delayed callback; pause racing completion; repeated pause/resume; and iOS background owner handoff. Assert no duplicate resume starts and no hidden live transfer under a paused card.
  - **Dependencies:** None; DM-05 will simplify the final state representation.

- [ ] **DM-03 — Return an explicit resume/start outcome and eliminate silent resume no-ops**
  - **Problem:** UI marks a row `enqueued` optimistically, while `resumeDownload()` returns no success/failure value and missing-task/failed-resume paths can return silently. `startDownload()` can also report success for an existing paused row even if its resume failed.
  - **Root cause:** The control API models resume as a command-only `Future<void>` even though downstream operations have meaningful boolean/ownership results. Task lookup, state restoration, URL refresh, native resume, range fallback, and multipart restore do not converge on one externally visible outcome.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** `download_service.dart`, `downloads_provider.dart`, `download_launcher.dart`, related control/UI tests.
  - **Proposed fix:** Introduce a small typed control result (for example started/running, queued, alreadyComplete, userPaused, recoverableFailure, missingState/terminal) and require `startDownload()`/resume flows to return it consistently. Only project optimistic UI state that the service has durably accepted; on recoverable failure publish the authoritative state/event immediately.
  - **Verification/testing:** Tests for missing downloader DB row, missing metadata, failed native resume, failed range fallback, multipart manifest missing, expired URL refresh failure, queue-full resume, and already-complete file. Assert UI cannot remain `enqueued` without queued or active ownership.
  - **Dependencies:** DM-04 for full recovery of JobStore-only tasks; can be implemented before it with an explicit `missingState` outcome.

- [ ] **DM-04 — Recover from the union of authoritative persistence sources, not downloader DB rows only**
  - **Problem:** On restart, a job can survive in `DownloadJobStore` (and/or metadata/partial files) while its `background_downloader` row is missing. It is not enumerated by current startup recovery and can also disappear from the downloads UI.
  - **Root cause:** `_recoverPersistedDownloads()` and `_refreshList()` start from `FileDownloader().database.allRecords()`. `DownloadJobStore` is consulted only after a downloader row is already known, so it is not a true inventory source.
  - **Severity / priority:** **P0 / Critical.**
  - **Expected files/areas:** `download_service.dart`, `download_job_store.dart`, `storage_service.dart`, `downloads_provider.dart`, startup reconciliation tests, relaunch/fault-injection tests.
  - **Proposed fix:** Build an idempotent startup inventory keyed by logical task/tracking identity from the union of JobStore, downloader DB/rehydrated transfers, metadata, multipart manifests, and safe filesystem evidence. Define reconstruction rules for missing representations and explicit orphan rules when reconstruction is impossible. Keep the JobStore as logical authority rather than merely a join.
  - **Verification/testing:** Fault-inject loss of each persistence source one at a time and in realistic pairs; verify resumable bytes remain visible/recoverable, terminal jobs are never resurrected, user pause survives, queue order is deterministic, and duplicate logical rows are not created.
  - **Dependencies:** DM-03 strongly recommended; DM-05 defines cleaner state precedence used by the final reconciliation matrix.

## Phase 2 — Establish one lifecycle truth and protect data integrity

- [ ] **DM-05 — Stop encoding multiple logical meanings as `TaskStatus.paused`**
  - **Problem:** User pause, interrupted/failure parking, and queue-related states can collapse to the same downloader status, with truth spread across `_userPausedIds`, `_queueWaitingIds`, Hive metadata, JobStore, and iOS snapshot inference.
  - **Root cause:** Plugin status is being used both as transport state and logical application state. Side flags compensate, but those flags live in different stores and are updated on different schedules.
  - **Severity / priority:** **P1 / High; architectural prerequisite for later reconciliation hardening.**
  - **Expected files/areas:** `download_job_state.dart`, `download_job_store.dart`, `download_service.dart`, `download_concurrency.dart`, `downloads_provider.dart`, continued-processing snapshot code/tests.
  - **Proposed fix:** Make `DownloadJobState` the sole logical lifecycle authority and treat plugin status as transport evidence only. Centralize projection from logical state -> UI/native compatibility status. Persist explicit user intent and queue intent; never infer user pause solely from plugin `paused`.
  - **Verification/testing:** Expand the startup/reconciliation matrix for every logical state x plugin status x native ownership x metadata flags. Verify the same logical state is produced regardless of event ordering.
  - **Dependencies:** DM-03/DM-04 should feed the new outcome/inventory model. DM-11, DM-12, and DM-15 depend on this.

- [ ] **DM-06 — Strengthen final-file completion verification with independent expected-resource evidence**
  - **Problem:** A nonzero file can be checkpointed as completed using its own current length as the first positive “known size”, and complete downloader rows can bypass meaningful revalidation during startup. A truncated/wrong resource therefore has a weaker integrity boundary than intended.
  - **Root cause:** `_persistCompletedFilePath()` asks `knownDownloadSize()` with `fileBytes` before independently known sizes. `knownDownloadSize()` returns the first positive candidate. Length equality is strong in multipart assembly, but the generic logical completion path does not always require an independent expected size/fingerprint.
  - **Severity / priority:** **P1 / High (data integrity).**
  - **Expected files/areas:** `download_service.dart`, `download_resume.dart`, `download_job_state.dart`/fingerprint handling, completion/relaunch tests.
  - **Proposed fix:** Separate `observedFileBytes` from `expectedResourceBytes`. Complete only when an independent expected size is known and matches, or when a deliberately defined alternative integrity proof is available. Preserve strong ETag/Last-Modified/resource identity where possible. On uncertainty, enter verifying/interrupted rather than completed.
  - **Verification/testing:** Truncated final file with stale complete DB row; wrong-size file; same-size resource replacement with validator change; complete multipart staging; unknown-size source; crash between rename and completion checkpoint. Assert no corrupt/truncated file becomes logical `completed`.
  - **Dependencies:** DM-05 for clean `verifying/interrupted` projection; DM-04 for restart inventory.

- [ ] **DM-07 — Make cancel/delete a single ownership-settlement transaction from the UI’s perspective**
  - **Problem:** The downloads UI may time out waiting for `cancelDownload()` and then delete DB metadata/files while native cancellation is still settling. A late native worker can still own/write the target after its logical records disappear.
  - **Root cause:** Presentation code independently performs downloader DB, metadata, artwork, and filesystem deletion after a fixed timeout. Cancellation ownership/tombstone authority is split between service and UI.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** `downloads_provider.dart`, `download_service.dart`, cleanup utilities, JobStore, cancel/relaunch tests.
  - **Proposed fix:** Move logical deletion into one service-owned idempotent operation with durable tombstone-first ordering. UI can hide the row immediately, but destructive file/record cleanup must occur only after ownership is settled or be represented as pending cleanup that restart reconciliation can finish safely.
  - **Verification/testing:** Cancel while active, cancel during native pause, cancel during range append, cancel during multipart assembly, cancellation API timeout, app kill immediately after user delete, and late callback after tombstone. Verify no resurrected row and no writer survives against a deleted/reused path.
  - **Dependencies:** DM-05; DM-10 generation fencing should protect late callbacks.

- [ ] **DM-08 — Make URL refresh recover native-resume-only single downloads safely**
  - **Problem:** If a single-file transfer has durable bytes only inside native resume data and its signed URL expires, the service deliberately avoids replacing that URL because the native resume blob embeds the old source. The task can become unrecoverable without restarting or losing progress.
  - **Root cause:** There is no portable migration from opaque native resume data to a verified visible byte prefix before refreshing the source URL.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** `download_service.dart`, `download_transport.dart`, `download_plugin_compat.dart`, `download_url_refresh.dart`, iOS native queue where applicable, URL-refresh integrity tests.
  - **Proposed fix:** Define a platform-safe migration decision tree: first attempt valid native resume; if URL is expired, extract/adopt a verifiable partial file/prefix when the platform exposes one; validate new source identity/size/validator; then range-resume. If bytes cannot be proven/migrated, expose an explicit recoverable “restart required” outcome rather than looping or silently remaining paused.
  - **Verification/testing:** Expired signed URL with native resume data only, visible partial + expired URL, changed resource same URL, provider unavailable, descriptor expired, refresh returns different size/quality, and app restart between refresh and resumed write.
  - **Dependencies:** DM-03 outcome model and DM-06 resource identity rules.

## Phase 3 — Make retries, races, and concurrent downloads deterministic

- [ ] **DM-09 — Introduce a consistent network-interruption state and recovery trigger**
  - **Problem:** Offline transitions are handled differently by native single transfers, Dart range transfers, multipart child recovery, and iOS background URLSession. Some paths park; others keep retrying/backing off while the parent appears running at 0 B/s.
  - **Root cause:** Retry policy classifies transport/HTTP failures but the logical download state machine has no shared “waiting for connectivity / interrupted by network” contract or connectivity-restored trigger.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** `download_retry_policy.dart`, `download_range_transfer.dart`, `persistent_parallel_download.dart`, `download_service.dart`, platform/native background bridge as needed, network fault tests.
  - **Proposed fix:** Normalize network-loss classification into a logical interrupted/waiting state without consuming destructive retry budget while known-offline. On connectivity restoration or foreground reconciliation, revalidate ownership/source and resume through the normal fenced path. Keep server overload/backoff distinct from device offline.
  - **Verification/testing:** Wi-Fi->offline->online, Wi-Fi<->cellular/IP change, DNS failure, connection reset, captive/no-internet network, long offline period, pause while offline, cancel while offline, and multiple queued episodes recovering together.
  - **Dependencies:** DM-05; DM-03 for user-visible outcomes.

- [ ] **DM-10 — Replace time-based callback suppression with generation/acknowledgement fences**
  - **Problem:** Late callbacks can arrive after pause, resume, restacking, retry, source replacement, or cancellation. Some paths already use attempt generations, but other protections rely on fixed delays such as waiter-restacking windows.
  - **Root cause:** Attempt identity is strong inside portions of multipart/range handling but is not uniformly carried through every logical/native transition.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** `download_job_store.dart`, `download_service.dart`, `persistent_parallel_download.dart`, `DownloadNativeWaitingQueue.swift`, native bridge payloads, race tests.
  - **Proposed fix:** Attach a durable/logical generation or operation token to every transition that can receive a late callback. Accept a callback only if it belongs to the current generation or is a safe terminal completion with independently verified bytes. Remove correctness dependence on arbitrary millisecond fences.
  - **Verification/testing:** Inject callbacks after 0.8s/5s/30s, stale completion after new source generation, old failure after successful resume, cancel then stale running, and native background promotion racing Flutter foreground restore.
  - **Dependencies:** Reuse DM-01 lease generations; DM-05 logical authority.

- [ ] **DM-11 — Define crash-safe write ordering and reconciliation for all persistence replicas**
  - **Problem:** JobStore, plugin DB, metadata, multipart manifest, refresh descriptor, native iOS queue, and filesystem checkpoints can be written independently/best-effort. A crash between writes can leave mutually inconsistent but individually valid state.
  - **Root cause:** No single transaction can span Hive, plugin DB, filesystem, and native URLSession; several writes are intentionally `unawaited`, so correctness depends on reconciliation but current reconciliation is not exhaustive.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** `download_service.dart`, `download_job_store.dart`, `storage_service.dart`, `persistent_parallel_download.dart`, continued-processing bridge/native store, relaunch/fault-injection tests.
  - **Proposed fix:** Document and implement strict write-ahead ordering around `DownloadJobStore` logical intent plus idempotent projections to secondary stores. Add version/generation markers where missing. Every restart path must tolerate a crash after each individual write and converge without losing proven bytes or resurrecting terminal work.
  - **Verification/testing:** Fault-inject a process death after every state-write boundary in start, queue promotion, pause, resume, source refresh, part completion, assembly rename, completion, and cancel. Reopen stores and assert invariant convergence.
  - **Dependencies:** DM-04 inventory and DM-05 authority are prerequisites; DM-10 protects stale callbacks during convergence.

- [ ] **DM-12 — Remove lifecycle-state writes from the presentation layer**
  - **Problem:** `downloads_provider.dart` mutates downloader persistence (for example failed/not-found -> paused) and independently cleans records, while DownloadService/JobStore are simultaneously managing the same lifecycle.
  - **Root cause:** UI refresh code evolved into a repair layer because plugin statuses do not map directly to desired presentation states.
  - **Severity / priority:** **P1 / High.**
  - **Expected files/areas:** `downloads_provider.dart`, `download_service.dart`, state projection helpers/tests.
  - **Proposed fix:** Make UI read a service-owned logical snapshot/event stream and send commands only. Put all persistence reconciliation/normalization inside DownloadService. Keep optimistic visuals only when tied to a service-issued accepted operation token/outcome.
  - **Verification/testing:** Race UI refresh against native failure, pause, resume, completion and cancel; recreate provider while transfers run; verify no DB writes originate from presentation lifecycle normalization and visible state always converges to service state.
  - **Dependencies:** DM-03 and DM-05; DM-07 moves deletion ownership first.

- [ ] **DM-13 — Prevent head-of-line blocking and verify fairness across simultaneous downloads**
  - **Problem:** Multiple logical downloads share a serialized pump/global connection budget. A resumed partial child can perform resume capability probes or range setup while the scheduler is awaiting it, potentially delaying promotion/pumping of unrelated sessions on a bad host/network.
  - **Root cause:** Scheduler serialization protects invariants but some awaited transport preparation is comparatively slow and happens inside the serialized coordination path.
  - **Severity / priority:** **P2 / Medium (raise to P1 if profiling reproduces user-visible starvation).**
  - **Expected files/areas:** `persistent_parallel_download.dart`, `download_service.dart`, `download_concurrency.dart`, connection governor, concurrency/fairness tests.
  - **Proposed fix:** Measure first. If reproduced, split short state reservation from slow transport preparation, retain generation/slot ownership, and let other sessions progress without exceeding the global connection budget. Preserve FIFO at logical episode level where intended.
  - **Verification/testing:** Concurrent episodes on fast + stalled hosts, 5/8/16 parts, partial resume probe timeout, one server rate-limiting while another is healthy, queue concurrency 1..max, and cancellation/pause during promotion. Assert bounded promotion latency and no budget oversubscription.
  - **Dependencies:** DM-01 and DM-10 so async preparation cannot create duplicate ownership.

## Phase 4 — Recovery/cleanup/background hardening

- [ ] **DM-14 — Inventory and safely recover or clean orphan partial/manifests/staging files**
  - **Problem:** `.parts`, `.assembling`, `.part/.tmp/.download`, or final files can survive a crash while one or more logical DB/metadata records disappear. Current recovery is strongest when the logical parent record still exists.
  - **Root cause:** Cleanup utilities are target-driven; startup does not build a complete safe filesystem inventory under AnimeWitcher’s download root and correlate it with logical jobs/manifests.
  - **Severity / priority:** **P2 / Medium; P1 when combined with DM-04 persistence loss.**
  - **Expected files/areas:** `download_cleanup.dart`, `persistent_parallel_download.dart`, `download_service.dart`, JobStore/metadata reconciliation, fault-injection tests.
  - **Proposed fix:** Add a narrowly scoped scanner for app-owned download paths only. Adopt exact, identity-linked staging/final/part state where provable; quarantine/leave ambiguous user-visible files untouched; clean only artifacts proven obsolete by terminal tombstones/generations and an age/safety policy.
  - **Verification/testing:** Crash during each assembly phase, missing manifest with parts, manifest temp newer than canonical, final target conflict, missing DB row, canceled-generation leftovers, low disk/full disk, and files outside the app download root (must never be touched).
  - **Dependencies:** DM-04, DM-06, DM-11.

- [ ] **DM-15 — Make Dart<->iOS background queue snapshot failures observable and reconcilable**
  - **Problem:** Continued-processing bridge invocation catches/swallow platform errors, so Dart can believe a native queue snapshot was exported even when Swift never accepted it. Flutter suspension can then leave native queue ownership stale.
  - **Root cause:** The bridge is intentionally best-effort for compatibility, but correctness-sensitive queue persistence uses the same fire-and-forget error semantics as noncritical presentation updates.
  - **Severity / priority:** **P2 / Medium; P1 for reproducible iOS background stalls.**
  - **Expected files/areas:** `download_continued_processing_service.dart`, `DownloadNativeWaitingQueue.swift`, `DownloadContinuedProcessingManager.swift`, `download_service.dart`, iOS source/behavior tests.
  - **Proposed fix:** Distinguish optional UI-overlay calls from queue-state checkpoint calls. Queue persistence should return an acknowledgement/version when supported. On failure, record it durably/diagnostically and force reconciliation on foreground/background handoff without duplicating native ownership.
  - **Verification/testing:** Method channel failure, plugin unavailable, app suspended immediately after queue change, native completion while Dart sleeps, multipart native promotion, foreground restore, and stale snapshot version rejection.
  - **Dependencies:** DM-05 logical authority, DM-10 generation/version fencing, DM-11 write ordering.

- [ ] **DM-16 — Separate durable recoverable bytes from monotonic presentation progress**
  - **Problem:** UI progress intentionally avoids regressions, but after partial-file loss/correction the amount of provable resumable data can be lower. Treating both as one number creates misleading state and complicates recovery decisions.
  - **Root cause:** Telemetry/presentation high-water marks and recovery byte truth serve different purposes but are persisted/projected through overlapping record fields.
  - **Severity / priority:** **P2 / Medium.**
  - **Expected files/areas:** `download_telemetry.dart`, `download_service.dart`, `download_job_state.dart`, `downloads_provider.dart`, multipart progress tests.
  - **Proposed fix:** Keep durable bytes authoritative for recovery/integrity and a separate ephemeral/presentation progress stream for smooth UI. On restart/recovery, display must be able to reconcile downward only when proven necessary and explain/represent recovery rather than silently claiming unavailable bytes.
  - **Verification/testing:** Lost partial file with stale progress, 0.999 sentinel, late regressive callback, manifest rollback to last durable checkpoint, app restart, and resumed download after source replacement.
  - **Dependencies:** DM-05 and DM-06.

- [ ] **DM-17 — Audit and harden resource/subscription lifetime across reinitialization**
  - **Problem:** Most session timers/controllers/part resources are explicitly canceled, but the download stack also has static/shared downloader subscriptions and process-lifetime maps. They are safe only if singleton/reinit assumptions always hold.
  - **Root cause:** The app uses a keep-alive service plus static plugin event bridging; tests/hot restart/recreated provider scopes can exercise lifetime patterns different from normal production startup.
  - **Severity / priority:** **P3 / Low unless profiling shows retained sessions.**
  - **Expected files/areas:** `download_service.dart`, `download_transport.dart`, `persistent_parallel_download.dart`, diagnostic log/native bridge disposal, lifecycle tests.
  - **Proposed fix:** Define ownership for every stream subscription, controller, timer, native transfer handle, recovery timer, telemetry entry, and static bridge. Make init/dispose idempotent; ensure a second service initialization does not duplicate delivery or retain old session state.
  - **Verification/testing:** Repeated init/dispose loops, provider scope recreation, hundreds of completed/canceled downloads, multipart pause/resume cycles, and memory/handle-count inspection where platform tooling permits.
  - **Dependencies:** DM-10 makes duplicate/late delivery safer; otherwise independent.

## Phase 5 — Prove the whole system, not just individual helpers

- [ ] **DM-18 — Build an end-to-end deterministic reliability/chaos acceptance matrix**
  - **Problem:** Existing tests cover many important helpers and prior regressions, but several “runtime stability” checks assert source-code structure, and the uncovered pending-start/recovery-inventory/control-result races require behavioral orchestration tests.
  - **Root cause:** The download manager spans plugin DB, Hive, filesystem, native transport, multipart scheduler, UI projection, and iOS background state; unit tests for each layer do not prove cross-layer convergence under reordered/lost callbacks and crashes.
  - **Severity / priority:** **P1 / High as the release gate; implement incrementally alongside each preceding fix, finalize last.**
  - **Expected files/areas:** existing `test/core/services/*download*` suites plus new focused orchestration/fault-injection harnesses; iOS source/native integration tests where executable native tests are unavailable.
  - **Proposed fix:** Add deterministic fake transport/persistence clocks capable of dropping, delaying, duplicating, and reordering callbacks; fault injection at durable-write boundaries; and scenario matrices for single + multipart. Prefer behavior assertions over source-string assertions for correctness-critical invariants.
  - **Verification/testing:** Mandatory final matrix: fresh download; pause/resume; repeated pause/resume; failure/retry; process kill/restart; crash during checkpoint; offline/online; expired URL refresh; missing plugin DB; missing metadata; partial-file loss; 1/2/5/8/16 parts; one missing child callback; 0.999 tail; server ignores Range; server changes validator; simultaneous downloads; queue full; cancel/delete races; low disk; assembly crash; iOS background suspend/promotion/foreground. Run targeted tests after each item and the complete download suite before marking this final item complete.
  - **Dependencies:** All prior items. This is the final acceptance gate, not a substitute for per-item tests.

## Dependency / execution order

Recommended order for later tasks:

1. DM-01 -> DM-02 -> DM-03 -> DM-04 to eliminate the currently strongest stuck/resume/restart failure paths.
2. DM-05 establishes the logical state authority used by subsequent work.
3. DM-06 and DM-07 close integrity and ownership-deletion boundaries.
4. DM-08 and DM-09 normalize expired-source and network recovery.
5. DM-10 and DM-11 harden races/crash consistency across all stores/transports.
6. DM-12 removes competing UI writers once the service contract is stable.
7. DM-13 through DM-17 handle fairness, orphan recovery, iOS snapshot reliability, byte/progress separation, and resource lifetime.
8. DM-18 is developed continuously as regression coverage but remains unchecked until the full final matrix passes.

## Invariants every implementation PR commit must preserve

- Never start a second writer for the same logical task/range while ownership of an earlier generation is unknown.
- Never claim `paused`, `running`, `queued`, or `completed` solely because a command was accepted; require logical intent plus transport/durable evidence appropriate to that state.
- Explicit user pause and explicit user cancel always outrank automatic retry/recovery.
- Proven on-disk bytes are never discarded merely to repair state bookkeeping.
- A final file is never overwritten during automatic recovery when its identity/expected size is uncertain.
- Multipart assembly remains staging-based and validates every part boundary before atomic final promotion.
- Terminal tombstones must prevent late native callbacks from resurrecting deleted/canceled work.
- Queue/global connection limits must remain bounded under retries, delayed callbacks, and concurrent sessions.
- Source refresh must never append bytes from an unverified different resource.
- Restart reconciliation must be idempotent: running it multiple times converges to the same logical state without duplicate tasks.

## Checklist protocol for later Tasks

- Read this file before changing code.
- Start from the first unchecked item whose dependencies are complete.
- Implement only a reviewable slice of that item at a time, with its regression test first where feasible.
- Re-read the diff and run the targeted verification before checking an item.
- Mark `[x]` only when the item’s described behavioral verification passes and update the item with any implementation notes that future Tasks need.
- Keep using the same branch and PR until DM-18 is complete.
- If a newly discovered root cause invalidates an item, update this document explicitly rather than silently changing scope.
