# Download Manager V2 Design

Date: 2026-09-17  
Status: Architecture approved; written spec ready for review  
Branch: `feat/download-manager-v2`

## 1. Goal

Rebuild AnimeWitcher's download manager around `background_downloader` as the **single transport authority**.

The current manager accumulated custom Range transfer, multipart/chunk state, JobStore lifecycle state, native ownership reconciliation, custom retry/recovery, and platform-specific handoff logic. V2 removes those transport responsibilities from AnimeWitcher instead of reimplementing them in a different form.

The design is correctness-first. Reliable pause/resume/relaunch behavior and one-writer guarantees are more important than preserving every partial byte in unusual recovery cases.

## 2. Legacy migration decision: policy A

The selected migration policy is **A**:

- Completed legacy downloads remain available and are not redownloaded.
- Incomplete legacy downloads do **not** migrate chunk state, Range offsets, resume data, native ownership, or partial transport state into V2.
- An incomplete legacy item remains visible as restart-required/paused until the user resumes it.
- On resume, old incomplete transport artifacts are cleaned safely, a fresh source is resolved, and V2 starts from byte zero.
- Upgrading the app never silently starts an old incomplete download.

This is a hard architectural constraint. Reintroducing legacy partial-state migration requires a new design review.

## 3. Single-authority rule

`background_downloader` owns:

- actual network transfer;
- package task persistence;
- pause/resume transport data;
- retries and resumable transport behavior;
- package-managed parallel chunks;
- native transport execution while the app is backgrounded/suspended;
- transport progress/status/hold state.

AnimeWitcher owns only:

- logical anime/episode identity;
- provider/source information needed to resolve a fresh URL;
- destination/presentation metadata;
- explicit user intent: active, paused, canceled;
- logical priority/concurrency preference;
- final-file integrity validation;
- diagnostics and UI projection;
- generation fencing against stale callbacks.

AnimeWitcher V2 must **not** persist or implement:

- manual HTTP Range splitting;
- custom chunk IDs or chunk lifecycle;
- byte offsets/resume bytes;
- multipart assembly state;
- custom transport retry state machines;
- native writer ownership discovery;
- `owned / notOwned / unknown / settling` transport ownership states;
- custom reconciliation between app JobStore and native writers;
- custom iOS multipart scheduling;
- direct manipulation of package resume data;
- legacy transport fallback for a fresh V2 download.

For every logical episode there is exactly one current V2 package task generation.

## 4. Package baseline

V2 targets `background_downloader ^9.6.2` after compatibility checks.

Use the modern Transfer API:

- `FileDownloader().start(autoCleanDatabase: true)` on startup;
- `FileDownloader().transfers.start(...)` for new tasks;
- `FileDownloader().transfers.rehydrateFromDatabase(...)` on relaunch;
- exact-task lookup/attachment by current `taskId`;
- `Transfer.pause()`, `Transfer.resume()`, `Transfer.cancel()`;
- Transfer status/progress/speed/time/hold/exception signals for presentation;
- the package database only as the package's transport persistence.

`9.6.2` is required over the current `^9.6.1` baseline because it fixes update-stream suppression when Transfer tracking is enabled.

## 5. Architecture

```text
UI / Riverpod
     |
     v
DownloadManagerV2
  |      |       |
  v      v       v
Logical  Source  Integrity
Store    Resolver Verifier
   \       |      /
    \      |     /
     v     v    v
BackgroundDownloaderGateway
            |
            v
 background_downloader
```

V2 is built beside V1 until cutover gates pass. V1 is never a fallback for a V2-owned logical download.

## 6. Components

### 6.1 `DownloadManagerV2`

Application coordinator with a deliberately small public surface:

- initialize;
- start/download episode;
- pause;
- resume;
- cancel;
- delete;
- retry/restart;
- observe logical downloads;
- query completed availability.

It coordinates domain metadata and the gateway but performs no HTTP transport.

### 6.2 `BackgroundDownloaderGateway`

Narrow, mockable adapter around public `background_downloader` APIs.

Responsibilities:

- initialize package tracking;
- create/start package tasks;
- rehydrate Transfer handles;
- attach by exact current `taskId`;
- normalize package events/snapshots;
- pause/resume/cancel package transfers;
- remove obsolete package records when safe;
- configure package notifications, parallelism, queueing, priorities, hints, and platform behavior.

It contains no anime/provider logic and no legacy migration rules.

### 6.3 `LogicalDownloadStoreV2`

Stores only AnimeWitcher-owned durable metadata, not a second transport database.

A logical record may contain:

- schema version;
- stable logical download ID;
- anime/episode identity;
- current package `taskId`;
- monotonically increasing generation;
- destination descriptor;
- provider/source descriptor required to resolve a new URL;
- explicit intent: `active`, `paused`, `canceled`;
- final completion metadata;
- last useful user-visible failure category;
- timestamps/presentation metadata needed by existing UI/library behavior.

It must not contain package child task IDs, Range offsets, resume bytes, package retry counters, package hold state, or a mirrored running-state machine.

### 6.4 `DownloadSourceResolver`

Returns a fresh URL, headers, and available stable resource identity from provider metadata.

Used before:

- every fresh generation;
- restart of a legacy-incomplete item;
- restart after signed URL/auth expiry;
- explicit retry when source renewal is required.

### 6.5 `DownloadIntegrityVerifier`

A package `complete` status is transport completion, not automatically logical completion.

Before committing logical completion, verify at minimum:

- final file exists;
- file is non-empty;
- trustworthy expected size matches when available;
- stronger provider/resource validators already available to the app are respected where practical.

### 6.6 `LegacyDownloadMigration`

Implements policy A only:

- completed legacy files stay available;
- incomplete legacy entries become restart-required presentation state;
- no legacy chunk/Range/resume state is imported;
- old partial artifacts are cleaned only through tested cleanup code;
- user resume starts a new V2 generation from byte zero.

## 7. Identity and stale-event fencing

Each logical episode has:

- stable `logicalDownloadId`;
- monotonically increasing `generation`;
- exactly one current package `taskId`.

Every fresh/replacement transport receives a new generation and a distinct deterministic package-safe task ID.

Only events matching the logical record's **current task ID and generation** may update UI or metadata. Late events from a canceled/replaced generation are ignored.

This fence replaces the legacy ownership/tombstone graph without attempting to determine which obsolete native writer owns a byte range.

## 8. Parallel download rule

Preserve the existing user-visible parallel/chunk preference by mapping it to `ParallelDownloadTask` where package/platform acceptance passes.

Rules:

- AnimeWitcher creates the parent task only.
- Package-created child chunks are never persisted by AnimeWitcher.
- AnimeWitcher never assembles chunks manually.
- No custom Range writer may run alongside a package parallel task.
- UI uses parent/package aggregate progress.
- If package parallel mode fails acceptance on a platform, fallback is a package-managed single `DownloadTask`, never V1.

Existing visible parallel settings are preserved when within package-supported behavior; changes to visible limits require explicit tests.

## 9. Lifecycle semantics

### 9.1 Start

1. Check whether a valid completed file already satisfies the logical request.
2. Coalesce duplicate start commands for the same logical episode.
3. Persist intent `active`.
4. Resolve a fresh source URL/headers.
5. Allocate a new generation/task ID.
6. Create `DownloadTask` or package-managed `ParallelDownloadTask` with package pause/retry/update options.
7. Start through `BackgroundDownloaderGateway`.
8. Bind events only to the current generation.

No second writer is created for the same logical episode.

### 9.2 Pause

1. Persist intent `paused` **before** transport action so pause survives process death.
2. Call `Transfer.pause()`.
3. If resumable pause succeeds, retain the generation.
4. If package pause cannot establish a resumable state, cancel the transport but retain intent `paused`.
5. Later resume starts a fresh generation from byte zero if package resume is unavailable.

The user guarantee is that paused means no automatic restart on relaunch. Preserving partial bytes is secondary.

### 9.3 Resume

For a paused logical record:

- if the exact current Transfer exists and package resume succeeds, continue it;
- otherwise resolve a fresh source and start a new generation from byte zero;
- return intent to `active` as part of the accepted resume operation.

AnimeWitcher never reconstructs byte ranges itself.

### 9.4 Failure

Classify failures at the application boundary:

- **offline/held:** project package hold/offline state; no custom network retry machine;
- **transient transport:** package retry/resume policy owns it;
- **expired/unauthorized source (provider-specific 401/403):** terminate/settle the failed generation, resolve a fresh source, create a new generation, restart from byte zero;
- **filesystem/disk:** durable failure; do not spin transport retries;
- **integrity:** remove/quarantine invalid final artifact and require clean retry;
- **other terminal failure:** expose retry using documented package semantics.

V2 phase one never transplants partial bytes to a replacement signed URL.

### 9.5 Cancel

1. Persist canceled intent and advance/fence the current generation before cleanup.
2. Cancel exact current Transfer if present.
3. Ignore every late event from the old generation.
4. Remove obsolete package tracking/database records when safe.
5. Remove package-owned partial artifacts through supported APIs/known paths.

Cancel is terminal until the user explicitly starts the episode again.

### 9.6 Delete

Fence/cancel first, then remove final/partial artifacts and AnimeWitcher logical metadata. Missing files count as already deleted and must never cause task resurrection.

## 10. Startup and relaunch

Startup is deterministic:

1. Call `FileDownloader().start(autoCleanDatabase: true)`.
2. Rehydrate package Transfers from the package database.
3. Load V2 logical records.
4. Match each logical record **only by its exact current `taskId`**. Do not recover by URL matching.
5. Apply intent:
   - `paused`: never auto-resume;
   - `canceled`: never recreate;
   - `active` + exact live/recoverable Transfer: attach;
   - `active` + no recoverable package Transfer: automatically resolve a fresh source and start a new generation from byte zero;
   - completed logical metadata: validate final-file existence and expose completed state.
6. Expose the projected state to UI.

Automatic restart for `active` is allowed because the user already requested continuing work. It does **not** apply to legacy-incomplete migration entries, paused records, or canceled records.

There is no scan of custom chunk owners, Range writers, native child ownership, or multiple transport databases.

## 11. State projection

V2 does not persist a second full transport state graph.

UI state is derived from:

- durable AnimeWitcher intent/final metadata;
- current exact Transfer status;
- package hold reason/offline state;
- temporary app-owned source-refresh/integrity operations.

Presentation may expose:

- queued;
- running;
- pausedByUser;
- waitingForNetwork;
- refreshingSource;
- verifying;
- completed;
- failed;
- restartRequired;
- canceled.

These are projections, not transport executor states stored and reconciled separately.

## 12. Signed URL policy

Signed URL renewal remains an app responsibility.

Rules:

- resolve fresh URL before every new generation;
- let package retries operate while the source remains valid;
- do not create an application retry loop around an expired URL;
- on confirmed auth/expiry terminal failure, settle old generation, resolve new URL, and start a new generation;
- replacement-URL recovery starts from byte zero in V2 phase one;
- no custom prefix verification/Range adoption is part of the initial cutover.

Safe partial-byte preservation across changed URLs may be designed later only using documented package APIs and its own acceptance gate.

## 13. Queueing and concurrency

AnimeWitcher owns logical priority and the user's desired concurrency; `background_downloader` owns actual transport execution.

Prefer package queue/holding/concurrency facilities over custom Future chains, semaphores, or writer pools. App code may decide which logical episodes are eligible or prioritized, but must not implement its own network executor.

Each logical episode always has one current package generation.

## 14. Network handling

Do not pause/resume writers merely because `connectivity_plus` emits a change.

Package Transfer hold/offline state is the primary transport signal. Connectivity observation may remain for UI/source-resolution hints but not as a second retry controller.

## 15. Platform responsibilities

### iOS

`background_downloader`/URLSession owns transport. V2 removes custom native multipart scheduling and chunk ownership bridges from the transport path.

Native status/progress observation may remain for presentation features such as Live Activities while Dart is suspended, but observers must never independently enqueue, split, retry, resume, or cancel transport.

### Android

Use package WorkManager/UIDT, pause resilience, notifications, priority, Wi-Fi constraints, and large-file behavior. Do not create an independent Android downloader service.

### Desktop

Use the same gateway/task model where supported. Platform differences stay inside gateway configuration/tests.

## 16. Diagnostics

Keep diagnostics around the single authority. Log:

- logical ID;
- generation;
- package task ID;
- action/event;
- package status/hold reason;
- progress/bytes/speed when available;
- source-refresh reason without signed URL/token leakage;
- integrity result;
- terminal failure category.

The log should answer: **what did the package report, and what was AnimeWitcher's user intent?**

## 17. Rollout

Use a controlled strangler/cutover:

1. Build V2 in isolated files beside V1.
2. Test V2 without routing production downloads to it.
3. Add a single cutover seam that guarantees one manager per logical episode.
4. Route new downloads to V2 after automated gates pass.
5. Apply legacy migration policy A.
6. Run physical-device acceptance on iOS and Android.
7. Make V2 the only production path.
8. Remove V1 transport, custom Range/multipart code, ownership logic, obsolete JobStore transport state, and native multipart bridges.
9. Remove compatibility flags only after V1 is unreachable and tests prove the cutover.

V1 and V2 must never write the same logical destination concurrently.

## 18. Tests

### Unit tests

Required cases:

- deterministic logical ID/task generation;
- stale generation event ignored;
- duplicate start coalesced;
- pause intent survives manager recreation;
- pause failure leaves logical item paused and stopped;
- resume uses package resume when possible;
- resume creates fresh generation when package state is unavailable;
- cancel/delete fence late callbacks;
- active relaunch with missing package state creates exactly one fresh generation;
- paused/canceled relaunch never creates transport;
- 401/403 creates exactly one refreshed generation and no expired-URL loop;
- integrity failure never commits completion;
- completion survives package DB cleanup through logical final metadata/file validation;
- legacy completed files are preserved;
- legacy incomplete state never imports Range/chunk/resume data;
- legacy incomplete resume starts V2 from byte zero;
- ambiguous/missing package state cannot create two writers.

### Gateway/contract tests

- single task construction;
- parallel parent task construction;
- Transfer lifecycle mapping;
- exact-ID rehydration/attachment;
- hold/offline mapping;
- retry/final status mapping;
- package database cleanup/removal behavior;
- compile/API contract against pinned `background_downloader`.

### Device acceptance: iOS and Android

At minimum:

1. new download completes;
2. pause -> resume;
3. pause -> kill/relaunch -> stays paused -> resume;
4. running -> background/process termination -> relaunch -> reattach/recover;
5. network loss/recovery;
6. expired signed URL/401/403 -> fresh source -> clean restart;
7. package parallel mode including 5 chunks;
8. multiple episodes concurrently;
9. cancel during transfer;
10. delete during/after transfer;
11. insufficient disk;
12. integrity failure;
13. late callback from replaced generation;
14. completed legacy file remains playable;
15. incomplete legacy item resumes as fresh V2 byte-zero transfer.

Device-only behavior is never marked complete from mocks/CI alone.

## 19. Cutover acceptance criteria

V2 replaces V1 only when:

- all new transport goes through `BackgroundDownloaderGateway`;
- no V2 path imports `persistent_parallel_download.dart` or `download_range_transfer.dart`;
- V2 persists no custom chunk/range ownership state;
- startup uses package persistence/Transfer API and exact task IDs;
- user pause survives relaunch;
- active missing package state recovers without duplicate writers;
- cancel/delete cannot be undone by stale callbacks;
- signed URL expiry restarts cleanly without mixing old partial bytes;
- completed legacy files remain available;
- incomplete legacy jobs restart cleanly under V2;
- automated verification is green;
- required iOS and Android physical-device evidence exists.

## 20. Explicit non-goals for first cutover

V2 phase one does not:

- preserve partial bytes from legacy incomplete downloads;
- migrate custom multipart/Range state;
- preserve partial bytes across refreshed signed URLs by custom manipulation;
- maintain a second transport ownership model;
- optimize every transport edge case before core lifecycle correctness is proven;
- delete V1 before V2 acceptance.

## 21. Implementation order

The executable implementation plan will be written after this spec is reviewed. Dependency order:

1. package/API baseline and V2 skeleton;
2. logical identity/store/generation fencing;
3. mockable `BackgroundDownloaderGateway`;
4. start/pause/resume/cancel/delete;
5. startup rehydration and active auto-recovery;
6. source refresh/failure classification;
7. final integrity verification;
8. package-managed parallel/concurrency mapping;
9. legacy migration policy A;
10. Riverpod/UI compatibility adapter and diagnostics;
11. platform notification/native-observation cleanup;
12. automated regression/contract coverage;
13. controlled cutover;
14. iOS/Android device acceptance;
15. remove V1 transport/Range/multipart/ownership/obsolete persistence;
16. full CI verification and final code review.
