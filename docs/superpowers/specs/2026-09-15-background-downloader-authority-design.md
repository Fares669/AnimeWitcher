# Background Downloader Authority Design

## Status

Approved architectural direction for `refactor/background-downloader-authority`.

This design starts from `main` after PR #231 (`fix(downloads): download manager reliability hardening`) and deliberately treats that merged implementation as the compatibility baseline. Migration work must preserve its user-visible reliability guarantees while reducing duplicated transport machinery.

## Problem

AnimeWitcher currently uses `background_downloader 9.6.2`, but transport ownership is split across several layers:

- `FileDownloader` / `Transfer` for native single-file execution.
- `PersistentParallelDownload` for multipart scheduling, recovery, manifests, connection slots, retry, progress aggregation, and assembly.
- `DownloadRangeTransfer` for direct Dio Range writes, source replacement, resume validation, and reconnect.
- `DownloadJobStore` for durable logical state, execution generations, durable-byte provenance, replica transactions, and recovery intent.
- custom Swift queue / multipart promotion / continued-processing integration on iOS.
- AnimeWitcher logical queueing, URL refresh, resource identity, UI projection, notifications, and cleanup.

This creates multiple partially overlapping sources of truth for one logical download. Bugs fixed in PR #231 repeatedly came from disagreement between persisted plugin rows, real native ownership, custom multipart ownership, custom retry state, JobStore state, and UI state.

The target is not to delete AnimeWitcher-specific reliability policy. The target is to stop implementing generic download transport twice.

## Goal

Make `background_downloader` the authoritative transport executor for ordinary and parallel downloads wherever its pinned public API can meet AnimeWitcher's invariants, while AnimeWitcher remains authoritative for logical episode intent, provider/source refresh, resource identity, episode-level queue policy, cleanup policy, and presentation.

## Non-goals

- Do not replace the provider/source resolution system.
- Do not remove stable logical episode identity.
- Do not weaken resource identity checks for refreshed signed URLs.
- Do not restart valid partial downloads from byte zero merely to simplify migration.
- Do not make `HoldingQueue` the logical episode queue unless characterization proves parent/chunk accounting matches AnimeWitcher's user-facing concurrency semantics.
- Do not remove iOS continued-processing UI. Reduce it to presentation/lifecycle support rather than a second transport scheduler.
- Do not blindly upgrade `background_downloader`; the migration targets the currently pinned `^9.6.2` public contract. Any later dependency upgrade remains a separate, evidence-driven change.

## External capability baseline

The pinned 9.6 line already provides the following public capabilities that AnimeWitcher should prefer over duplicate implementations:

1. `FileDownloader().transfers` with first-class `Transfer` handles.
2. Transfer status, progress, network speed, ETA, hold reason, exception and notification-tap notifiers/updates.
3. Transfer pause, resume and cancel controls.
4. `rehydrateFromDatabase` for reconnecting to persisted transfers after process recreation.
5. `FileDownloader.start()` startup processing, including background-update replay and killed-task rescheduling when `doRescheduleKilledTasks` is enabled.
6. `ParallelDownloadTask` and native parallel implementations on supported platforms, including parent/chunk status coordination and final assembly.
7. task `stallTimeout` support.
8. persistent task database and database update stream.
9. native platform scheduling through URLSession / Android background execution.
10. `HoldingQueue` controls for total, host, and group concurrency.

Important capability gates remain:

- AnimeWitcher must characterize manual pause/resume and failure-resume semantics for `ParallelDownloadTask` on each supported platform before deleting custom multipart recovery.
- The plugin does not know how to refresh AnimeWitcher provider URLs.
- A changed signed URL may invalidate native resume data that embeds an older URL, especially on iOS. Verified source replacement therefore remains an AnimeWitcher responsibility until a public plugin contract proves equivalent safety.
- AnimeWitcher's setting represents concurrent logical episodes. Plugin queue accounting may include parallel child tasks, so episode-level queue policy remains above the transport initially.
- Android user-initiated execution policy and `ParallelDownloadTask` must be device-tested before selecting one universal Android path.

## Architectural principles

### 1. One transport authority

For a task handed to `background_downloader`, AnimeWitcher must not independently schedule child network writers for the same byte ranges.

The plugin owns:

- URLSession / WorkManager/native task creation.
- parallel chunk creation and chunk lifecycle when using `ParallelDownloadTask`.
- native pause/resume state and resume data.
- transport progress/speed/ETA.
- transport retry/stall behavior that does not require provider URL replacement.
- final parallel assembly.

AnimeWitcher may observe and project those states but must not mirror them into a second transport state machine.

### 2. AnimeWitcher owns logical intent

AnimeWitcher remains authoritative for:

- logical episode identity.
- anime/episode metadata.
- provider id, source, quality, tracking URL and refresh descriptor.
- user pause/delete intent.
- logical episode queue ordering and user-facing episode concurrency.
- target library location and safe cleanup.
- signed-URL refresh decisions.
- resource fingerprint compatibility.
- presentation and diagnostics.

### 3. Runtime ownership is not database status

A plugin database record is persistence evidence, not proof that a native writer is currently alive.

The transport adapter must expose runtime ownership using supported `Transfer`/plugin runtime state. Unknown ownership fails closed: no second writer starts until ownership becomes positively absent.

### 4. No duplicate retry loops

For plugin-authoritative tasks, generic connection retry/stall/reconnect belongs to `background_downloader`.

AnimeWitcher retry policy is retained only for application-level actions the plugin cannot perform, principally:

- refresh signed provider URL.
- resource identity reconciliation.
- explicit wait-for-network/user-intent transitions where needed by logical policy.
- storage/full-disk/user-visible parking policy.

### 5. Durable bytes are never inferred from presentation progress

Plugin progress and speed are presentation/runtime telemetry. Any decision that can discard or reuse bytes must still use exact plugin resume capability, a verified file, or explicit resource identity evidence.

### 6. Migration is reversible

Every transport replacement ships behind an internal policy selector until its acceptance matrix passes. The old custom path is removed only after the plugin path has passed equivalent tests on the supported platform set.

No feature flag may create two writers for the same task.

## Target components

### `BackgroundDownloaderTransport`

Replace the single-only intent of `NativeSingleDownloadTransport` with one adapter around public `background_downloader` APIs.

Responsibilities:

- start/reconnect `DownloadTask` and `ParallelDownloadTask`.
- retain/rehydrate `Transfer` handles.
- expose typed command outcomes.
- expose `Transfer` updates and telemetry.
- report runtime ownership separately from persisted records.
- surface final HTTP/status failures to the application policy layer.

It must not implement provider URL refresh or custom byte-range writing.

### `DownloadTransportPolicy`

A small pure policy selects transport shape:

- one connection -> `DownloadTask`.
- N connections -> `ParallelDownloadTask(chunks: N)` when plugin parallel is enabled and platform capability is accepted.
- legacy custom multipart -> temporary fallback only while migration gates remain incomplete.
- verified Range recovery -> exceptional fallback for refreshed-source partial bytes only while needed.

The policy is deterministic and unit-testable.

### Logical episode queue

Keep AnimeWitcher's logical episode queue initially.

A queue slot means one episode handed to the transport, regardless of how many plugin chunks that episode uses. The plugin may schedule chunk internals; AnimeWitcher does not count those chunks as additional user-visible episodes.

After the migration stabilizes, `HoldingQueue` may be evaluated as an additional native safety cap, but it is not the initial source of logical queue truth.

### `DownloadJobStore` -> intent/compatibility store

The existing store remains during migration so old rows can be adopted safely.

Its long-term responsibilities shrink to:

- stable logical identity.
- task/execution identity needed for migration/adoption.
- user intent and delete tombstone.
- queue position/intent if required.
- provider/source/quality refresh metadata linkage.
- resource fingerprint.
- compatibility/migration metadata.

Fields that duplicate plugin transport state become deprecated and then removed after migration:

- child transport ownership.
- custom multipart durable-byte bookkeeping.
- generic transport retry phase.
- custom child launch/lease state.
- assembly phase owned by plugin parallel execution.

### URL refresh and resource identity

`DownloadUrlRefreshStore`, `DownloadUrlRefresher`, and `DownloadResourceFingerprint` remain AnimeWitcher-owned.

On 401/403/eligible 404:

1. park the current plugin transfer without inventing a fresh writer.
2. obtain refreshed provider URL/headers.
3. prove resource compatibility using available fingerprint evidence.
4. attempt the safest supported plugin resume/replacement path.
5. if native resume data cannot safely follow a changed URL but valid partial bytes exist, route only this exceptional case through the verified Range recovery seam.
6. once the exceptional fallback is no longer required on a platform, remove it there.

This keeps `DownloadRangeTransfer` from being the normal transport while preserving the hardest signed-URL invariant.

### Telemetry

For plugin-authoritative transfers:

- progress comes from `Transfer`/task updates.
- network speed comes from plugin transfer telemetry.
- ETA comes from plugin transfer telemetry.
- AnimeWitcher may sample/smooth for UI cadence only.
- AnimeWitcher must not recalculate a competing byte clock for the same transfer.

Custom telemetry remains only for the temporary legacy/fallback path.

### iOS native layer

The target iOS layer does not create a second multipart scheduler.

Keep:

- iOS 26 continued-processing session/overlay.
- supported plugin callbacks needed for live presentation.
- minimal compatibility/version gate where a public callback is unavailable.
- diagnostic logging.

Remove after plugin-path acceptance:

- custom multipart plan/claim scheduling.
- custom native child promotion.
- custom child connection ownership snapshots used only by `PersistentParallelDownload`.
- custom speed bridge that duplicates plugin transfer telemetry.
- any URLSession delegate interception no longer required by a documented gap.

### Android policy

Android must be selected by measured behavior, not by symmetry with iOS.

Acceptance compares:

- `DownloadTask` with user-initiated/large-file hints.
- `ParallelDownloadTask` for user-selected multiple connections.
- notification enabled vs disabled.
- foreground/background/kill/relaunch behavior.

If plugin parallel cannot provide required Android lifecycle guarantees, Android may temporarily keep a different transport shape while still sharing the same adapter and logical policy.

## State ownership matrix

| Concern | Authoritative owner after migration |
| --- | --- |
| Logical episode id | AnimeWitcher |
| Provider/source/quality | AnimeWitcher |
| Signed URL refresh | AnimeWitcher |
| Resource fingerprint | AnimeWitcher |
| User pause/delete intent | AnimeWitcher |
| Logical episode queue | AnimeWitcher initially |
| Native task lifecycle | `background_downloader` |
| Parallel chunks | `background_downloader` |
| Chunk retry/stall | `background_downloader` |
| Resume data | `background_downloader` |
| Runtime progress | `background_downloader` |
| Runtime speed/ETA | `background_downloader` |
| Parallel assembly | `background_downloader` |
| Final library cleanup rules | AnimeWitcher |
| iOS continued-processing UI | AnimeWitcher presentation layer |
| Exceptional changed-URL partial recovery | AnimeWitcher fallback until proven removable |

## Compatibility strategy

The branch must read all persisted state produced by PR #231.

Migration rules:

1. Existing completed files remain untouched.
2. User-paused downloads remain paused after upgrade.
3. A live native plugin task is adopted, never duplicated.
4. Existing custom multipart manifests are not deleted merely because the new path prefers plugin parallel.
5. A legacy active multipart session continues on the legacy engine until it reaches a stable boundary, unless a dedicated adoption test proves byte-exact conversion.
6. New downloads may use the plugin-authoritative path once the feature gate for their platform is enabled.
7. Old `.part` data is garbage-collected only after explicit ownership and recoverability checks.

The first migration therefore supports mixed inventory: legacy custom multipart rows and new plugin-authoritative parallel rows may coexist, but one logical download may use only one executor at a time.

## Acceptance invariants

Every implementation phase must maintain all of these:

1. At most one current writer owns a logical file/range.
2. User pause survives process restart.
3. User delete cannot be resurrected by delayed native callbacks.
4. Valid partial bytes do not silently reset to zero.
5. Completed files are never overwritten by recovery guesses.
6. A killed app can reopen and converge without a permanent `running`/0 B/s ghost state.
7. Speed is non-zero while fresh transport bytes are reported and becomes stale/zero only when transport progress is actually stale.
8. Signed URL refresh cannot attach old bytes to a different resource.
9. Episode concurrency means episodes, not plugin child count.
10. No duplicate user notification is emitted for internal parallel chunks.
11. Unknown runtime ownership blocks a second writer.
12. Migration can be rolled back without deleting user data.

## Characterization and acceptance matrix

Before removing any legacy path, automated or device tests must cover:

- 1, 2, 4, 8 and 16 requested connections where supported.
- server with correct HTTP 206 ranges.
- server ignoring Range and returning 200.
- content length missing/incorrect.
- strong ETag stable and changed.
- Last-Modified fallback.
- 401/403 signed URL expiry and successful provider refresh.
- 416 reconciliation.
- 429 / Retry-After.
- transient 5xx.
- socket loss and network offline/online.
- stall with no bytes.
- pause at early/mid/late progress.
- resume after pause.
- process kill at early/mid/late progress.
- relaunch while native task survived.
- relaunch when native task was killed and only resume state survived.
- cancel/delete during active transfer.
- low disk / assembly failure.
- one, three and ten logical episodes queued.
- notification on/off.
- iOS foreground/background/continued-processing expiration.
- Android foreground/background and supported user-initiated path.
- no duplicate writer and no restart-from-zero without explicit evidence.

## Removal criteria

### Remove normal-use `PersistentParallelDownload` only when

- plugin parallel passes the supported-platform characterization matrix.
- manual pause/resume behavior is proven.
- kill/relaunch behavior is proven.
- progress/speed/ETA are trustworthy enough to replace aggregate custom telemetry.
- logical episode queue remains correct with plugin internal chunks.
- signed URL expiry has a safe handoff path.

### Remove normal-use `DownloadRangeTransfer` only when

- fresh and ordinary resumed transfers use only plugin transport.
- changed signed URLs with existing partial bytes have an equally safe public-plugin path, or the file-specific verified recovery fallback is isolated to a smaller replacement component.

### Remove custom iOS multipart scheduling only when

- plugin parallel continues correctly while Flutter is suspended.
- native completion and progress callbacks are sufficient for continued-processing presentation.
- no custom claim/promotion path is needed for queue advancement.

## Delivery strategy

The implementation is intentionally staged:

1. characterization and contracts.
2. generalized plugin transport adapter.
3. plugin telemetry authority.
4. startup recovery authority.
5. parallel plugin path behind policy gate.
6. signed-URL/fallback integration.
7. platform acceptance and default enablement.
8. remove duplicate custom multipart/range machinery.
9. shrink iOS native bridge.
10. simplify JobStore and finalize migration cleanup.

Each stage must be independently testable and committed. No cleanup stage may precede successful replacement-stage acceptance.