# Download Manager V2 Design

Date: 2026-09-17
Status: Proposed architecture approved in chat; written specification pending final review
Branch: `feat/download-manager-v2`

## 1. Purpose

Rebuild AnimeWitcher's download manager around `background_downloader` as the single transport authority. The new manager must remove the custom transport/recovery machinery that made the current downloader difficult to reason about while preserving the user-visible download experience.

The redesign is correctness-first. It deliberately gives up migration of legacy partial-transfer state and some bandwidth-preserving recovery optimizations in exchange for a small, deterministic lifecycle with one owner for network transfer state.

## 2. User decision: legacy migration policy

The selected migration policy is **A**:

- Existing completed legacy downloads remain available and are not redownloaded.
- Existing incomplete legacy downloads do **not** migrate chunk state, range offsets, resume data, native ownership, or partial transport state into V2.
- An incomplete legacy download remains visible as restart-required/paused until the user resumes it.
- When the user resumes an incomplete legacy download after V2 cutover, V2 cleans up the old incomplete transport artifacts and starts a fresh V2 transfer from byte zero using a freshly resolved source URL.
- Migration never silently starts network work merely because the app was upgraded.

This policy is a hard architectural constraint. No later implementation task may reintroduce legacy chunk/range-state migration without a new design review.

## 3. Core invariant: one transport authority

`background_downloader` owns all transport state for V2 downloads.

AnimeWitcher owns only application/domain concerns:

- logical anime/episode identity;
- source/provider information required to resolve a fresh media URL;
- destination naming and presentation metadata;
- user intent: active, paused, canceled/deleted;
- logical episode queue/priority policy;
- final-file validation/integrity checks;
- diagnostic logging and UI projection;
- generation fencing so stale callbacks cannot mutate a replacement download.

AnimeWitcher must **not** implement or persist:

- manual HTTP Range splitting;
- custom chunk task IDs or chunk lifecycle state;
- byte offsets used to resume a transport;
- custom multipart assembly state;
- custom transport retry state machines;
- native writer ownership discovery;
- `owned / notOwned / unknown / settling` transport ownership states;
- hand-built reconciliation between a custom JobStore and native transport state;
- custom iOS multipart scheduling;
- direct manipulation of `background_downloader` resume data;
- a fallback downloader for fresh V2 transfers.

For every V2 logical episode, there is one current package task identity. If package-managed parallel downloading is used, all internal chunk ownership remains an implementation detail of `background_downloader`.

## 4. Dependency baseline

V2 targets `background_downloader ^9.6.2` or newer only after compatibility verification.

The implementation will use the modern Transfer API introduced in 9.6:

- `FileDownloader().start(autoCleanDatabase: true)` during downloader startup;
- `FileDownloader().transfers.start(...)` for a new transfer;
- `FileDownloader().transfers.getOrStart(...)` when attaching to a known task;
- `FileDownloader().transfers.rehydrateFromDatabase(...)` at startup;
- `Transfer.pause()`, `Transfer.resume()`, and `Transfer.cancel()` for lifecycle commands;
- Transfer notifiers/streams for status, progress, speed, remaining time, hold reason, and exceptions;
- the package database only as the transport package's persistence layer, never as an AnimeWitcher-owned transport database.

Version 9.6.2 is preferred over the current `^9.6.1` baseline because it fixes update-stream suppression when Transfer tracking is enabled.

## 5. High-level architecture

```text
UI / Riverpod presentation
          |
          v
   DownloadManagerV2
      /    |      \
     /     |       \
    v      v        v
Logical   Source   Integrity
Store     Resolver Verifier
    \       |        /
     \      |       /
      v     v      v
 BackgroundDownloaderGateway
              |
              v
      background_downloader
```

The V2 implementation is built beside the current manager until acceptance gates pass. The old manager is not used as a fallback for a V2-owned logical download.

## 6. Components

### 6.1 `DownloadManagerV2`

The application coordinator. It exposes the small lifecycle surface consumed by the rest of the app:

- initialize;
- start/download episode;
- pause;
- resume;
- cancel;
- delete;
- retry/restart;
- observe current logical downloads;
- query completed download availability.

It coordinates domain metadata and the gateway but does not perform HTTP transport itself.

### 6.2 `BackgroundDownloaderGateway`

A narrow adapter around public `background_downloader` APIs. Responsibilities:

- initialize/start the package;
- create and start package tasks;
- rehydrate package Transfer handles;
- expose normalized transfer snapshots/events to `DownloadManagerV2`;
- call package pause/resume/cancel operations;
- query or remove package task records where lifecycle cleanup requires it;
- configure package concurrency/notifications/platform behavior.

No UI, provider/source resolution, anime identity, or legacy migration rules belong here.

The gateway must be mockable. Unit tests for `DownloadManagerV2` must not require native downloader execution.

### 6.3 `LogicalDownloadStoreV2`

Stores only AnimeWitcher-owned durable metadata. It is not a second transport database.

A V2 logical record contains at most:

- schema version;
- stable logical download ID;
- anime and episode identity needed by the app;
- current package `taskId`;
- current generation number;
- destination descriptor/path metadata;
- provider/source descriptor needed to obtain a fresh URL;
- explicit user intent (`active`, `paused`, or `canceled`);
- final completion metadata when the file is complete;
- last user-visible failure category/details when useful;
- timestamps and presentation metadata required by existing UI/library behavior.

It must not contain package chunk IDs, range offsets, resume bytes, package retry counters, package hold state, or a mirror of every package transport status.

### 6.4 `DownloadSourceResolver`

Owns provider/source refresh. It accepts stable source/provider metadata and returns a fresh downloadable URL plus headers and any resource identity evidence available from the source.

It is invoked:

- before every new V2 generation;
- when restarting an old incomplete legacy job;
- when a transfer fails because the source URL is expired/unauthorized;
- when the application explicitly retries a source-related failure.

### 6.5 `DownloadIntegrityVerifier`

Validates the final downloaded file before V2 marks the logical episode complete.

Minimum checks:

- final file exists;
- final file is non-empty;
- expected size is respected when trustworthy size information is available;
- any stronger provider/resource validator already available to AnimeWitcher is checked when practical.

A transport `complete` event is evidence that transport finished; logical completion is committed only after final-file validation.

### 6.6 `LegacyDownloadMigration`

Implements migration policy A only.

- completed legacy files/metadata are preserved;
- incomplete legacy records are mapped to `restartRequired` presentation state, not to V2 transport state;
- old partial files/chunk/temp/package records are cleaned only when the user chooses resume/restart or during a specifically tested safe cleanup pass;
- resume of a legacy-incomplete item resolves a fresh source and starts a new V2 task from byte zero.

No code in this component may attempt to reconstruct a legacy `PersistentParallelDownload`, Range transfer, child ownership graph, or resume offset.

## 7. Identity and stale-event fencing

Each logical episode has a stable `logicalDownloadId` and a monotonically increasing `generation`.

Each new transport generation receives a distinct package `taskId` derived from the logical identity plus generation. The exact task-ID encoding must be deterministic and package-safe.

Example conceptually:

```text
logical episode E42
  generation 1 -> V2 task A
  generation 2 -> V2 task B
```

Only events for the current task ID/generation may mutate the logical record or UI projection. Events from canceled/replaced generations are ignored.

This generation fence replaces the large legacy ownership/tombstone machinery. It protects against late native/package callbacks without requiring AnimeWitcher to determine whether an obsolete transport still owns a byte range.

## 8. Parallel downloads

AnimeWitcher may preserve its user-visible parallel/chunk preference by mapping it to the package's `ParallelDownloadTask` when package/platform acceptance tests pass.

Rules:

- AnimeWitcher creates only the parent package task.
- AnimeWitcher never persists package-generated child chunk task IDs.
- AnimeWitcher never manually assembles chunk files.
- AnimeWitcher never starts custom Range writers alongside a package parallel task.
- UI progress is based on the parent Transfer/package aggregate view, not a custom child-progress database.
- If a platform/package combination fails acceptance for package parallel downloads, the safe fallback is a package-managed single `DownloadTask`, not the legacy downloader.

The implementation preserves existing supported user settings where they fit package-supported bounds; any change to visible limits must be made explicitly and tested.

## 9. Lifecycle semantics

### 9.1 Start

1. Validate there is no current completed file that already satisfies the logical request.
2. Persist/update the logical record with user intent `active`.
3. Resolve a fresh source URL and headers.
4. Allocate a new generation and unique package task ID.
5. Create a package `DownloadTask` or `ParallelDownloadTask` with pause support, retries, metadata, destination, priority, and package updates enabled through the Transfer API.
6. Start it through `BackgroundDownloaderGateway`.
7. Bind its Transfer events to the current logical generation.

Duplicate start calls for the same logical episode must coalesce onto the current generation instead of creating a second writer.

### 9.2 Pause

1. Persist user intent `paused` first so the pause survives process death.
2. Ask the current Transfer to pause.
3. If package pause succeeds, keep the current generation.
4. If package pause is unsupported or fails to establish a resumable state, cancel the transport while retaining logical intent `paused`. Resume later starts a fresh generation from byte zero.

The user-visible guarantee is stronger than byte preservation: after a successful pause command, V2 must not silently restart the download on relaunch.

### 9.3 Resume

If user intent is paused:

- if the current package Transfer is still resumable, call `Transfer.resume()`;
- if the Transfer is missing/final/non-resumable, resolve a fresh source and start a new generation from byte zero;
- set intent back to `active` only as part of the accepted resume command.

V2 does not reconstruct byte ranges itself.

### 9.4 Failure

Failures are classified at the application boundary:

- offline/held: project the package hold/offline state; do not create a custom network retry state machine;
- transient transport failure: let package retries/resume policy operate;
- expired/unauthorized source (for example provider-specific 401/403): stop the failed generation, resolve a fresh source, and restart from byte zero as a new generation;
- filesystem/disk failure: surface a durable user-visible failure and do not spin retries;
- integrity failure: remove/quarantine the invalid final artifact and require a clean retry generation;
- unknown final failure: expose retry, with retry creating or reusing transport only according to public package semantics.

Correctness is prioritized over preserving partial bytes across a changed signed URL. V2 phase one does **not** transplant resume bytes to a replacement URL.

### 9.5 Cancel

1. Persist canceled intent / advance the generation fence before transport cleanup.
2. Cancel the current Transfer if present.
3. Ignore all late events from the old generation.
4. Remove obsolete package tracking/database records when safe.
5. Remove partial artifacts according to package/public file APIs.

Cancel is terminal until the user starts the episode again, which creates a new generation.

### 9.6 Delete

Delete performs cancel fencing first, then removes the final file, partial artifacts owned by the current package task, and AnimeWitcher logical metadata. A missing file is treated as already deleted, not as a reason to resurrect a task.

## 10. Startup / relaunch behavior

Startup must be short and deterministic:

1. Initialize `background_downloader` with persistent tracking.
2. Rehydrate package Transfers from its database.
3. Load V2 logical records.
4. Attach each current logical task ID to its Transfer if present.
5. Apply explicit user intent:
   - `paused`: never auto-resume;
   - `canceled`: never recreate;
   - `active`: attach to the package transfer if it exists;
   - `active` with no recoverable package transfer: mark restart-needed and start a fresh generation only according to the defined auto-recovery policy, never by reconstructing custom transport state.
6. Validate completed logical entries against final file existence.
7. Expose the projected state to UI.

There is no scan of custom chunk owners, Range writers, native child tasks, or multiple transport databases.

For an app process killed and relaunched, package persistence is the transport source of truth; V2 logical storage supplies identity and user intent only.

## 11. State projection

V2 avoids persisting a second full transport state machine.

The UI-facing logical state is derived from:

- durable AnimeWitcher intent/final metadata;
- the current package Transfer status;
- package hold reason/offline state;
- temporary app-owned source-refresh or integrity-verification operations.

The presentation model may expose states such as:

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

These are projections, not a custom transport executor state graph.

## 12. Signed URL policy

Signed/provider URLs are application concerns because the package cannot know how AnimeWitcher obtains a replacement source.

V2 rules:

- resolve fresh URL before a new generation;
- package retries may continue while the URL remains valid;
- on an authentication/expiry failure, do not repeatedly retry the expired URL at the application layer;
- resolve a new URL and start a new generation;
- phase one always restarts from byte zero when the URL is replaced;
- no custom byte-prefix verification or Range adoption is required for the core V2 cutover.

A future optimization may preserve compatible partial bytes across refreshed URLs only through documented package APIs and a separate design/acceptance gate.

## 13. Queueing and concurrency

AnimeWitcher owns logical priority and the user's configured concurrency preference; `background_downloader` owns actual transfer execution.

V2 must prefer package queue/holding/concurrency facilities over custom Future chains, semaphores, or child schedulers. App-level code may decide which logical episodes are eligible/priority-ordered, but must not implement its own network writer pool.

Multiple episodes may download concurrently, but each logical episode has exactly one current package generation.

## 14. Network handling

V2 does not pause/resume writers merely because `connectivity_plus` emits a state change.

Package Transfer hold/offline state is the primary transport signal. AnimeWitcher may observe connectivity for UI hints or source resolution, but must not run a second transport retry controller.

When connectivity returns, package behavior handles held/resumable transport. App intervention is reserved for a terminal/source-related failure that requires a fresh URL or generation.

## 15. iOS and Android platform responsibilities

### iOS

`background_downloader`/URLSession remains the transport owner. Existing custom native multipart scheduling or chunk ownership bridges are removed from the V2 path.

Native status/progress observation may remain only for presentation features such as Live Activities/WidgetKit while Dart is suspended. Native observers must never enqueue, split, retry, resume, or cancel independently of the package lifecycle.

### Android

Use package-supported WorkManager/UIDT behavior, pause resilience, notifications, priority, Wi-Fi constraints, and large-file hints as documented by the package. V2 must not create an independent Android transport service.

### Desktop

Use the same gateway/task model where supported. Platform-specific differences are contained in gateway configuration and tests, not in domain lifecycle branching.

## 16. Diagnostics

Keep diagnostics, but simplify them around one authority.

Every significant event should include:

- logical download ID;
- generation;
- package task ID;
- action/event name;
- package status/hold reason when relevant;
- progress/bytes/speed when available;
- source refresh reason without logging sensitive signed URLs/tokens;
- integrity result;
- final failure category.

Logs must make it possible to answer "what did the package report and what logical intent did AnimeWitcher have?" without reconstructing multiple writer systems.

## 17. Rollout strategy

The rewrite uses a strangler/cutover approach:

1. Build V2 in new files/modules beside V1.
2. Add tests around V2 without routing production downloads to it yet.
3. Add an internal cutover seam so a logical download is owned by exactly one manager.
4. Route new downloads to V2 only after automated acceptance gates pass.
5. Apply migration policy A to existing incomplete legacy jobs.
6. Run physical-device acceptance on iOS and Android, including relaunch and background/termination scenarios.
7. Make V2 the only production path.
8. Remove V1 transport code, custom range/multipart machinery, obsolete JobStore ownership logic, and native multipart bridges.
9. Remove compatibility flags only after the old path is unreachable and tests prove the new path.

At no point may V1 and V2 write the same logical destination concurrently.

## 18. Test strategy

### Unit tests

Required focused tests include:

- deterministic logical ID/task generation;
- stale generation events are ignored;
- duplicate start coalesces;
- pause intent survives manager recreation;
- pause failure falls back to stopped transport without auto-resume;
- resume uses package resume when available;
- resume recreates a fresh generation when package state is unavailable;
- cancel/delete fence late callbacks;
- source 401/403 creates exactly one refreshed generation and does not loop the expired URL;
- integrity failure never commits completion;
- completed file projection survives package database cleanup;
- legacy completed migration preserves files;
- legacy incomplete migration never imports old chunk/range/resume state;
- legacy incomplete resume starts V2 from byte zero;
- missing/ambiguous package state never creates two writers.

### Gateway/contract tests

- package task construction for single and parallel downloads;
- package Transfer lifecycle mapping;
- rehydration behavior;
- retries/hold/offline mapping;
- database cleanup/removal behavior;
- current package API compilation against the pinned dependency.

### End-to-end/device acceptance

At minimum on iOS and Android:

1. new download completes;
2. pause -> resume;
3. pause -> kill app -> relaunch -> remains paused -> resume;
4. running -> app process terminated/backgrounded -> relaunch and recover/reattach;
5. transient network loss and recovery;
6. expired signed URL / 401 or 403 -> fresh source -> clean restart;
7. package parallel download with the existing user-relevant chunk settings, including 5 chunks;
8. multiple episodes concurrently;
9. cancel during transfer;
10. delete during/after transfer;
11. insufficient disk space;
12. final-file integrity failure;
13. late callback from replaced/canceled generation;
14. completed legacy download remains playable;
15. incomplete legacy download resumes as a fresh V2 download from byte zero.

No device-only behavior is marked complete from mocks or CI alone.

## 19. Acceptance criteria for cutover

V2 may replace V1 only when all of the following are true:

- all new transport work goes through `BackgroundDownloaderGateway`;
- no V2 path imports `persistent_parallel_download.dart` or `download_range_transfer.dart`;
- no V2 record persists custom chunk/range ownership state;
- startup rehydration uses package persistence/Transfer API;
- user pause survives relaunch;
- failed/missing package state can recover without duplicate writers;
- cancel/delete cannot be undone by stale callbacks;
- signed URL expiry recovers through a fresh generation without corrupting a partial file;
- completed legacy files remain available;
- incomplete legacy jobs restart cleanly under V2;
- automated tests are green;
- required iOS and Android physical-device acceptance evidence is recorded.

## 20. Explicit non-goals for the first V2 cutover

The initial V2 does not attempt to:

- preserve partial bytes from legacy incomplete downloads;
- migrate custom multipart or Range state;
- preserve partial bytes across a refreshed signed URL by custom manipulation;
- maintain a custom transport ownership model in parallel with the package;
- optimize every transport edge case before the core lifecycle is proven;
- delete the V1 implementation before V2 acceptance is complete.

These exclusions are intentional safeguards against recreating the current manager's complexity.

## 21. Planned implementation sequence

The detailed executable plan will be written after this specification is reviewed. It will follow this dependency order:

1. dependency/package API baseline and V2 module skeleton;
2. domain identities, logical records, and generation fencing;
3. mockable `BackgroundDownloaderGateway`;
4. core start/pause/resume/cancel/delete lifecycle;
5. startup rehydration and restart behavior;
6. source refresh and failure classification;
7. final integrity verification;
8. package-managed parallel download and concurrency mapping;
9. legacy migration policy A;
10. Riverpod/UI compatibility adapter and diagnostics;
11. platform notification/native-observation cleanup;
12. automated regression/contract test expansion;
13. controlled V2 cutover;
14. iOS/Android device acceptance;
15. removal of V1 transport, Range, multipart, ownership, and obsolete persistence code;
16. final full-suite/CI verification and code review.
