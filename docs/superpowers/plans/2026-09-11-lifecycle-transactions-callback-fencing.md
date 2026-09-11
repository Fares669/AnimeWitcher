# Lifecycle Transactions / Callback Fencing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement only DM-10, DM-07, DM-31, DM-11, DM-08, DM-12, and DM-17 after their declared dependencies are complete, with generation/acknowledgement correctness instead of timing fences and with crash-safe lifecycle ownership centralized in `DownloadService`.

**Architecture:** `DOWNLOAD_MANAGER_PLAN.md` remains the sole source of truth. This file is execution preparation only: it records dependency gates, confirmed seams, and the behavioral RED tests to run once the shared branch contains the prerequisite DM-04/DM-05/DM-24/DM-06 work. No prerequisite is reimplemented here.

**Tech Stack:** Flutter/Dart, Riverpod, Hive, `background_downloader`, `flutter_test`, native iOS MethodChannel/URLSession bridge.

**Spec:** `DOWNLOAD_MANAGER_PLAN.md`

## Global Constraints

- Owned items only: DM-10, DM-07, DM-31, DM-11, DM-08, DM-12, DM-17.
- Never treat command acceptance as ownership settlement.
- `owned`, `settling`, and `unknown` ownership block destructive cleanup and a replacement writer.
- No arbitrary delay may provide correctness.
- Old callbacks may not mutate a newer job generation, operation, refresh descriptor, or service instance.
- `DOWNLOAD_MANAGER_PLAN.md` is updated to `[x]` only when every acceptance criterion and required verification for that item passes.
- Before implementation, rebase/merge the latest `plan/download-manager-reliability` and re-read dependency checkboxes. Do not copy or substitute another agent's DM-04/DM-05/DM-24/DM-06 implementation.

---

## Current dependency gate (2026-09-11)

At base `ac477d7c6c313c2d586e8e93e045a4b5c9814e28`, the plan still has DM-04, DM-05, DM-24, and DM-06 unchecked.

Consequences:

- DM-10 is blocked by DM-05.
- DM-07 is blocked by DM-10.
- DM-31 is blocked by DM-24 and participates in the documented DM-31 <-> DM-11 dependency cycle.
- DM-11 is blocked by DM-04, DM-05, DM-10, and DM-31.
- DM-08 is blocked by DM-06 and DM-31.
- DM-12 is blocked by DM-05, DM-07, and DM-31.
- DM-17 is blocked by DM-10.

No owned DM is eligible on this base. Implementation must not start until at least DM-05 is checked, then proceed only as each owned item's full dependency set becomes satisfied.

## Confirmed seams/root causes to preserve in RED coverage

1. **DM-10:** `DownloadService.cancelDownload()` still drops `_cancellingUrls` through `Future.delayed(const Duration(milliseconds: 500), ...)`. A fixed 500 ms suppression window cannot prove that a callback belongs to the canceled operation or that an old callback is no longer in flight.
2. **DM-07:** `cancelDownload()` persists `canceled` before ownership mutation, but after `notOwned` it deletes the plugin row, metadata, JobStore row, and refresh descriptor. The durable terminal fact therefore does not survive as a retained/GC'd tombstone.
3. **DM-31:** `DownloadLauncher` still writes `DownloadUrlRefreshDescriptor` before `startDownloadOutcome()` and removes it when that caller receives a non-accepted result. `DownloadUrlRefreshDescriptor` has no logical ID or generation, and `DownloadUrlRefreshStore.remove()` is keyed only by tracking URL. An obsolete caller can therefore delete the current caller's capability.
4. **DM-12:** `DownloadsNotifier` still rewrites legacy plugin rows and directly performs DB, metadata, artwork, and file cleanup in `removeDownloads()`. Presentation is therefore still a lifecycle/destructive writer.
5. **DM-17:** `DownloadService.dispose()` is synchronous, starts `_parallel.dispose()`, `_nativeTransport.dispose()`, and `_continuedProcessing.dispose()` with `unawaited`, does not join the FileDownloader bridge, and can close per-instance resources before old async teardown/callbacks settle.
6. **DM-11:** lifecycle state is persisted across JobStore, plugin DB, metadata, refresh descriptors, multipart state/files, and native queue without one enforced write-ahead/effect/ack/projection/cleanup transaction ordering for every transition.
7. **DM-08:** refresh capability remains split from logical job ownership and source replacement. Safe restart vs resume cannot be made complete until DM-06 resource identity and DM-31 descriptor ownership are present.

---

### Task 1: Dependency rebase and eligibility check

**Files:**
- Read: `DOWNLOAD_MANAGER_PLAN.md`
- Read: `lib/core/services/download_job_state.dart`
- Read: `lib/core/services/download_job_store.dart`
- Read: `lib/core/services/download_service.dart`
- Read: `lib/core/services/download_logical_identity.dart`

**Interfaces:**
- Consumes: merged DM-04/DM-05/DM-24/DM-06 contracts from the shared plan branch.
- Produces: no code; an explicit eligibility decision for each owned DM.

- [ ] Rebase or merge the latest `plan/download-manager-reliability` into this branch.
- [ ] Re-read the complete plan and confirm the actual `[x]` state for DM-04/05/24/06.
- [ ] Inspect any migrations/contracts introduced by those items before designing tokens or descriptor keys.
- [ ] If DM-05 is still unchecked, stop implementation and keep this PR preparation-only.

### Task 2: DM-10 generation + operation acknowledgement fencing

**Files:**
- Modify: `lib/core/services/download_job_state.dart`
- Modify: `lib/core/services/download_job_store.dart`
- Modify: `lib/core/services/download_service.dart`
- Modify when required by current shared contracts: `lib/core/services/persistent_parallel_download.dart`
- Test: `test/core/services/download_callback_generation_test.dart`
- Extend: `test/core/services/download_job_store_test.dart`

**Interfaces:**
- Consumes: DM-05 authoritative logical state and existing `DownloadAttemptToken`/`DownloadJobStore.beginAttempt()` generation fencing.
- Produces: operation-scoped tokens/acks that let callback handling prove the current operation rather than infer freshness from elapsed time.

- [ ] Add a RED behavioral test: pause -> resume -> delayed pause/failure callback from the old operation must not change the resumed logical state.
- [ ] Add a RED behavioral test: cancel -> delayed `running` callback must not resurrect a canceled/tombstoned job.
- [ ] Add a RED behavioral test: source refresh/new generation -> old `complete` callback must not complete the replacement generation.
- [ ] Add a RED behavioral test: retry/new generation -> old-generation `failed` callback must not park the new attempt.
- [ ] Run those tests and confirm they fail for stale-callback acceptance, not for setup/compile errors.
- [ ] Implement the smallest operation-token/ack contract that composes with the merged DM-05 logical state. Reuse durable generation where it represents execution generation; add a distinct operation token only where multiple ownership-changing operations can occur inside one execution generation.
- [ ] Remove `_cancellingUrls` correctness dependence on the 500 ms delayed clear. Any remaining delay may be telemetry/UI-only and must not determine callback acceptance.
- [ ] Run the four focused tests plus JobStore generation tests and adjacent pause/resume/cancel/source-refresh tests.

### Task 3: DM-07 durable tombstone delete transaction

**Files:**
- Modify: `lib/core/services/download_job_state.dart`
- Modify: `lib/core/services/download_job_store.dart`
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/features/library/presentation/downloads_provider.dart`
- Test: `test/core/services/download_delete_transaction_test.dart`

**Interfaces:**
- Consumes: DM-10 callback fencing, DM-30 cancel settlement, DM-05 logical authority.
- Produces: durable canceled tombstone + settlement/cleanup/GC transaction owned by `DownloadService`.

- [ ] RED: kill/recreate immediately after tombstone persistence but before cancel settlement; recovery must preserve terminal delete intent and must not resurrect the row.
- [ ] RED: cancel returns/settles `owned`, `settling`, or `unknown`; no DB, metadata, descriptor, manifest, part, final, or native ownership evidence may be destructively removed.
- [ ] RED: late complete/running callbacks for the deleted generation are fenced by tombstone generation.
- [ ] RED: repeated delete is idempotent and eventually cleans once ownership is `notOwned`.
- [ ] Implement service-owned phases: durable tombstone -> owner settlement -> idempotent cleanup -> tombstone retention/GC.
- [ ] Define a deterministic GC predicate using settled ownership + generation/age policy; never remove a tombstone solely because UI stopped displaying it.
- [ ] Move delete-side destructive operations out of `DownloadsNotifier` as part of the service transaction boundary; DM-12 completes the remaining presentation cleanup.

### Task 4: DM-31 and DM-11 coupled refresh/crash transaction

**Files:**
- Modify: `lib/core/services/download_url_refresh.dart`
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/features/details/presentation/download_launcher.dart`
- Modify as needed after DM-24: `lib/core/services/download_logical_identity.dart`
- Test: `test/core/services/download_refresh_descriptor_transaction_test.dart`
- Test: `test/core/services/download_lifecycle_crash_convergence_test.dart`

**Interfaces:**
- Consumes: DM-24 canonical logical identity, DM-10 generations/operations, DM-21 fail-closed checkpoints.
- Produces: generation-aware descriptor lifecycle owned by the service and an explicit write-ahead/effect/ack/projection/cleanup ordering used by crash reconciliation.

- [ ] RED: caller A saves/starts, caller B supersedes successfully, then A fails; A must be unable to delete B's descriptor.
- [ ] RED: old cancel/cleanup generation cannot remove the descriptor for a newer generation of the same logical episode.
- [ ] RED: descriptor-store failure at required-source start returns a typed failure before executor ownership is launched.
- [ ] RED crash boundaries for start/refresh: after logical intent, after descriptor commit, after executor effect, after ack, after projections; restart must converge to one logical state/owner/capability.
- [ ] Resolve the plan's DM-31 <-> DM-11 cycle as one coherent transaction change: define the actual ordering first, then implement descriptor version/generation and crash convergence together without weakening either acceptance criterion.
- [ ] Launcher passes descriptor data to `DownloadService`; it no longer writes/removes lifecycle descriptors directly.

### Task 5: DM-08 unified source replacement capability matrix

**Files:**
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/core/services/download_url_refresh.dart`
- Modify: `lib/core/services/download_transport.dart`
- Modify: `lib/core/services/download_range_transfer.dart`
- Modify: `lib/core/services/persistent_parallel_download.dart`
- Test: `test/core/services/download_source_replacement_matrix_test.dart`

**Interfaces:**
- Consumes: DM-06 resource identity, DM-31 service-owned descriptor, DM-10 fencing, DM-20 byte reconciliation.
- Produces: one typed source-replacement decision across native opaque resume, visible Range prefix, multipart parts, and signed-URL HTTP expiration.

- [ ] RED matrix for HTTP 401/403/404 across native, Range, and multipart representations.
- [ ] RED: native opaque resume evidence with unprovable compatibility returns `restartRequired`; it must not loop or silently attach bytes to a refreshed resource.
- [ ] RED: verified visible prefix + compatible refreshed identity resumes without discarding proven bytes.
- [ ] RED: validator/size/content mismatch does not reuse old bytes.
- [ ] RED: crash during source replacement converges through the DM-11 transaction ordering.
- [ ] Implement the smallest shared decision layer and keep representation-specific mechanics behind transport/range/multipart seams.

### Task 6: DM-12 presentation becomes command/snapshot-only

**Files:**
- Modify: `lib/features/library/presentation/downloads_provider.dart`
- Modify: `lib/core/services/download_service.dart`
- Test: `test/features/library/presentation/downloads_provider_lifecycle_boundary_test.dart`

**Interfaces:**
- Consumes: DM-05 logical snapshots, DM-07 delete transaction, DM-31 lifecycle descriptor ownership.
- Produces: provider that issues service commands and renders service-owned outcomes/snapshots without lifecycle persistence or destructive cleanup.

- [ ] RED/source guard: `downloads_provider.dart` must not call `FileDownloader().database.updateRecord/deleteRecordWithId`, metadata removal, or downloaded-file deletion for lifecycle repair/delete.
- [ ] RED behavior: provider recreation during pause/resume/failure/complete/delete does not alter durable lifecycle state except via service commands.
- [ ] Move remaining cleanup/reconciliation into `DownloadService`; keep UI optimistic state only when tied to accepted operation/outcome IDs.
- [ ] Run provider authority/logical identity/UI responsiveness regressions.

### Task 7: DM-17 joined teardown and service-instance generation

**Files:**
- Modify: `lib/core/services/download_service.dart`
- Modify: `lib/core/services/download_transport.dart`
- Modify: `lib/core/services/download_range_transfer.dart`
- Modify: `lib/core/services/persistent_parallel_download.dart`
- Modify: `lib/core/services/download_continued_processing_service.dart`
- Test: `test/core/services/download_service_reinitialization_test.dart`

**Interfaces:**
- Consumes: DM-10 generation fencing and DM-32 readiness barrier.
- Produces: async teardown barrier + service-instance generation that prevents old instance callbacks/teardown from mutating or unregistering a newer instance.

- [ ] RED: rapid dispose -> create while old Range/multipart/native work is settling; old instance callbacks cannot reach new state.
- [ ] RED: old MethodChannel handler teardown occurring after new handler registration cannot unregister the new handler.
- [ ] RED: repeated ProviderScope recreation does not duplicate/loss callbacks from the static FileDownloader bridge.
- [ ] Replace synchronous fire-and-forget teardown with a joined async barrier for writers/subscriptions whose lifetime must end before recreation.
- [ ] Fence bridge/handler ownership with a monotonically increasing service-instance generation.
- [ ] Run dispose/reinit focused tests plus pause/cancel/recovery callback regressions.

## Final verification gate

Only after eligible implementation is complete:

```text
flutter analyze --no-fatal-warnings --no-fatal-infos
flutter test test/core/services/download_job_store_test.dart
flutter test test/core/services/download_runtime_ownership_test.dart
flutter test test/core/services/download_callback_generation_test.dart
flutter test test/core/services/download_delete_transaction_test.dart
flutter test test/core/services/download_refresh_descriptor_transaction_test.dart
flutter test test/core/services/download_lifecycle_crash_convergence_test.dart
flutter test test/core/services/download_source_replacement_matrix_test.dart
flutter test test/features/library/presentation/downloads_provider_lifecycle_boundary_test.dart
flutter test test/core/services/download_service_reinitialization_test.dart
```

Also run existing adjacent pause/resume/cancel, URL refresh, recovery/relaunch, source replacement, provider/UI lifecycle, Range, multipart, and lifecycle-checkpoint suites. Run the full Flutter suite when practical before any owned DM is marked complete.
