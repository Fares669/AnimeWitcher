# Download Manager V2 Implementation Plan

> **For agentic workers:** this file is the source of truth for continuation. Use the Superpowers execution/TDD/debugging workflow. Before changing code, read the **Progress Ledger**, inspect the current PR head and CI, and continue from the first incomplete task. Never redo a task marked complete unless verification finds a regression.

**Goal:** Replace AnimeWitcher's custom downloader transport/recovery stack with Download Manager V2 using `background_downloader` as the sole transport authority.

**Architecture:** V2 lives under `lib/core/services/download_v2/`. AnimeWitcher owns logical episode identity, user intent, source refresh, destination metadata, integrity verification, diagnostics, and stale-generation fencing. `background_downloader` owns transfer persistence, pause/resume transport state, retries, native execution, and package-managed chunks. V1 remains only until real-device acceptance proves V2 and Task 14 can safely remove it.

**Tech Stack:** Flutter/Dart 3.13, Riverpod 3, Hive, `background_downloader ^9.6.2`, flutter_test.

**Spec:** `docs/superpowers/specs/2026-09-17-download-manager-v2-design.md`

---

## Progress Ledger

**Update this section on every continuation that materially changes plan state.** A task is counted complete only after its implementation and required verification are actually complete.

**Last reconciled:** 2026-09-17, PR #247, branch `feat/download-manager-v2`, exact verified head: `994f8dea65326f32c66feb9770948ab03affb10b`.

### Overall count

- **Trackable task groups:** 16 total (`Task 1` through `Task 15`, plus explicit `Task 12A` for iOS CI + logging/diagnostics).
- **Complete:** **13 / 16** — Tasks 1-12 plus Task 12A.
- **Remaining:** **3 / 16** — Tasks 13, 14, 15.
- **Currently in progress:** Task 15 automated final review; physical-device acceptance remains the release gate.
- **Blocked by real devices:** Task 13; therefore Task 14 and final merge readiness remain blocked until Task 13 has real-device evidence.

### Status table

| Task | Status | Continuation note |
| --- | --- | --- |
| 1. Dependency + identity + domain model | ✅ Complete | V2 model/identity established and tested. |
| 2. Logical store | ✅ Complete | Dedicated V2 logical persistence implemented. |
| 3. `background_downloader` gateway | ✅ Complete | Package is sole V2 transport boundary; exact task identity used. |
| 4. Start/coalescing/generation fence | ✅ Complete | Duplicate writer prevention and stale callback fencing implemented. |
| 5. Pause/resume/cancel/delete | ✅ Complete | Intent ordering and lifecycle semantics implemented. |
| 6. Startup rehydration | ✅ Complete | Exact-task recovery and deterministic active-missing recovery implemented. |
| 7. Source refresh | ✅ Complete | 401/403 replacement creates fresh byte-zero generation. |
| 8. Integrity gate | ✅ Complete | Logical completion is committed only after final-file verification. |
| 9. Parallel package parent + diagnostics DTO | ✅ Complete | 5-part mode uses one `ParallelDownloadTask` parent; safe allowlisted diagnostics added. |
| 10. Legacy migration policy A | ✅ Complete | Completed legacy preserved; incomplete legacy does not import transport state. |
| 11. Riverpod + production cutover | ✅ Complete | Explicit store/gateway/source/integrity/diagnostics providers, V2 UI routing, and exact-head guard coverage are green. |
| 12. Native authority cleanup + regression matrix | ✅ Complete | All native multipart progress/retry/completion/promotion bridges now require legacy-owned `multipartPlans`; V2 package children remain opaque. |
| 12A. iOS CI + runtime/native diagnostics | ✅ Complete | Production `documents/log` wiring, redaction tests, native logger check, and exact-head iOS build evidence recorded below. |
| 13. Physical-device acceptance | ⛔ Device-gated | Must be executed on real iOS + Android hardware; CI/mocks cannot satisfy it. |
| 14. Remove V1 | ⛔ Blocked by Task 13 | Delete V1 transport only after physical-device gate is complete. |
| 15. Final deep review / merge readiness | 🟡 In progress | Automated cutover review is complete; final readiness remains gated by real-device Task 13 evidence. |

### Known verification context

- `.github/workflows/ci.yml` contains an independent macOS **Build iOS V2 and retain log** job using `flutter build ios --debug --no-codesign` and uploads `ios-v2-build.log` with `if: always()`.
- `.github/workflows/ci.yml` also typechecks the production native download logger on macOS.
- `FileDownloadDiagnosticsV2` writes append-only safe JSONL and accepts only allowlisted diagnostic events; transport URLs, headers, signed query parameters, and free-form exception text must never enter these logs.
- `DownloadManagerV2` records structured V2 lifecycle/integrity/source-refresh diagnostics through the injected `DownloadDiagnosticsV2` sink.
- Existing unrelated full-suite failure involving the missing `ANIME4K_PERFORMANCE_PLAN.md` must not be misreported as a V2 regression. Still inspect every exact-head run because new failures can coexist with that baseline.
- `cancel-in-progress: true` means pushing a new commit may cancel the preceding PR workflow. When a run is needed as evidence, inspect/capture it before pushing the next commit.

---

## Global Constraints

- `background_downloader` is the **only** V2 transport authority.
- No V2 file may import or instantiate `persistent_parallel_download.dart`, `download_range_transfer.dart`, or equivalent V1 executor state.
- No V2 persistence may contain chunk IDs, ranges, resume offsets/bytes, writer ownership, package retry counters, or package hold state.
- Migration policy A: completed legacy downloads remain available; incomplete legacy downloads do not auto-start and restart from byte zero only after explicit user resume/restart.
- Signed URL replacement creates a fresh byte-zero generation.
- Startup matches exact current `taskId`, never URL/filename heuristics.
- `active + missing/nonrecoverable package transfer` creates exactly one fresh generation automatically.
- `paused`, `canceled`, and legacy-incomplete records never auto-start.
- Pause intent is persisted before asking transport to pause.
- Cancel/delete fence the old generation before transport cleanup.
- Package `ParallelDownloadTask` children remain opaque to AnimeWitcher.
- V1 is never a fallback for a V2-owned download.
- Diagnostics are observability only; logging failure must never fail or own a transfer.
- Logs must never contain signed URLs, auth headers/tokens, provider response bodies, cookies, or unbounded exception text.
- Device-only acceptance is not considered complete from CI, simulators, mocks, or unit tests.

## Locked File Structure

**V2 core:**
- `lib/core/services/download_v2/download_v2_models.dart`
- `lib/core/services/download_v2/download_v2_identity.dart`
- `lib/core/services/download_v2/logical_download_store_v2.dart`
- `lib/core/services/download_v2/background_downloader_gateway.dart`
- `lib/core/services/download_v2/download_source_resolver_v2.dart`
- `lib/core/services/download_v2/download_integrity_verifier_v2.dart`
- `lib/core/services/download_v2/download_manager_v2.dart`
- `lib/core/services/download_v2/legacy_download_migration_v2.dart`
- `lib/core/services/download_v2/download_v2_diagnostics.dart`
- `lib/core/services/download_v2/download_v2_provider.dart`

**Production cutover files:**
- `lib/main.dart`
- `lib/features/details/presentation/download_launcher.dart`
- `lib/features/library/presentation/downloads_provider.dart`
- `lib/features/details/presentation/downloaded_file_provider.dart`
- `ios/Runner/AppDelegate.swift`
- existing native continued-processing/download bridge files only where they currently have transport authority.

**Tests:** V2 tests live under `test/core/services/download_v2/`.

---

## Completed Tasks 1-10

These task groups are complete. Do not reimplement them unless a current verification failure proves a regression.

### Task 1: Dependency + Identity + Domain Model — ✅ Complete

Acceptance retained:
- deterministic logical IDs and generation task IDs;
- immutable V2 domain model;
- V2 record JSON contains no custom transport internals;
- `background_downloader ^9.6.2` contract established.

### Task 2: LogicalDownloadStoreV2 — ✅ Complete

Acceptance retained:
- dedicated V2 logical store;
- user intent survives recreation;
- only logical application state is persisted.

### Task 3: BackgroundDownloaderGateway 9.6.2 Contract — ✅ Complete

Acceptance retained:
- gateway is the package transport boundary;
- exact task ID attachment/rehydration;
- single transfer uses package `DownloadTask`;
- `parallelChunks > 1` uses one package `ParallelDownloadTask` parent;
- no package child IDs escape into AnimeWitcher durable state.

### Task 4: Start + Duplicate Coalescing + Generation Fence — ✅ Complete

Acceptance retained:
- duplicate concurrent start creates one writer;
- record/task generation is persisted before callbacks can mutate state;
- late old-generation callbacks cannot affect the current generation.

### Task 5: Pause / Resume / Cancel / Delete — ✅ Complete

Acceptance retained:
- pause intent durable before package pause;
- unsupported/non-resumable pause may cancel transport while preserving paused intent;
- exact paused handle resumes when possible, otherwise a fresh generation is created;
- cancel/delete fence stale callbacks before cleanup.

### Task 6: Startup Rehydration / Relaunch Recovery — ✅ Complete

Acceptance retained:
- rehydrate by exact current task ID;
- never adopt a same-URL unrelated transfer;
- active missing/nonrecoverable state gets exactly one fresh generation;
- paused/canceled records do not auto-start.

### Task 7: Fresh Source Resolver + Signed URL Recovery — ✅ Complete

Acceptance retained:
- source descriptors are application-owned; raw transport URL/headers are resolved only for a fresh generation;
- HTTP 401/403 source expiration triggers at most one serialized replacement for the current generation;
- replacement starts from byte zero and never carries custom ranges/resume bytes.

### Task 8: Final Integrity Gate — ✅ Complete

Acceptance retained:
- package `complete` is insufficient by itself;
- missing, empty, or trustworthy-size mismatch final files are not logically completed;
- only valid final artifact sets `completedAtMillis`;
- stale verification cannot mutate a newer generation.

### Task 9: Package Parallelism + Diagnostics DTO — ✅ Complete

Acceptance retained:
- `parallelChunks: 5` maps to one package parent task whose ID is the V2 generation task ID;
- V2 never persists child IDs;
- diagnostic DTO is allowlisted and cannot serialize signed URLs/query tokens/headers/free-form transport errors.

### Task 10: Legacy Migration Policy A — ✅ Complete

Acceptance retained:
- completed legacy file remains available and migration starts zero transfers;
- incomplete legacy item causes zero network work during migration;
- explicit resume/restart creates a new V2 generation from byte zero;
- never import `PersistentParallelDownload`, `DownloadRangeTransfer`, chunk/range/resume/native ownership state.

---

## Remaining Work

### Task 11: Riverpod Wiring + Production Cutover Guard — 🟡 In progress

**Files:**
- Create/finish: `lib/core/services/download_v2/download_v2_provider.dart`
- Modify: `lib/main.dart`
- Modify: `lib/features/details/presentation/download_launcher.dart`
- Modify: `lib/features/library/presentation/downloads_provider.dart`
- Modify: `lib/features/details/presentation/downloaded_file_provider.dart`
- Create/finish: `test/core/services/download_v2/download_v2_cutover_guard_test.dart`

**Required acceptance:**
- [x] Architectural guard scans V2/production cutover sources and rejects `PersistentParallelDownload`, `DownloadRangeTransfer`, or V1 transport imports on the V2 path.
- [x] One UI download action invokes one V2 manager path, never V1 + V2 simultaneously.
- [x] Production downloads list no longer reconciles `FileDownloader().database` directly; it projects V2 logical records/snapshots.
- [x] `download_v2_provider.dart` wires concrete logical store, package gateway, source resolver, integrity verifier, and diagnostics as keep-alive production dependencies.
- [x] `download_launcher.dart` keeps existing source-selection/confirmation UX but creates `DownloadStartRequestV2` and calls V2.
- [x] `downloads_provider.dart` projects V2 state and routes pause/resume/cancel/delete to V2 logical IDs.
- [x] `downloaded_file_provider.dart` resolves both migrated completed legacy files and V2 completed records without reintroducing V1 transport ownership.
- [x] V2 initializes once from application/provider lifecycle.
- [x] Persisted transport policy survives process recreation: `allowPause`, retry policy, and especially user-selected `parallelChunks` must not silently revert to 1 after restart.
- [x] Source resolver adapter may reuse V1 provider/source-selection knowledge, but not V1 transfer state or executor ownership.
- [x] Focused V2 tests green.
- [x] Analyzer has no V2/cutover errors.
- [x] Full-suite result inspected and V2 regressions separated from known unrelated baseline failures.

**Run:**
```bash
flutter test test/core/services/download_v2
flutter analyze --no-fatal-warnings --no-fatal-infos
flutter test --dart-define=ANIMEWITCHER_FIREBASE_API_KEY=test-api-key
```

**Commit target:** `refactor(downloads): route production downloads through v2`

---

### Task 12: Native Authority Cleanup + Automated Regression Matrix — ⬜ Remaining

**Files:**
- Modify: `ios/Runner/AppDelegate.swift`
- Modify: existing iOS continued-processing/native bridge files only where they independently enqueue/split/retry/resume/cancel.
- Modify/create V2 tests.

**Required acceptance:**
- [x] Automated matrix covers start, duplicate start, pause, resume, pause + manager recreation, active + missing recovery, offline/held projection, 403 refresh, cancel/delete stale callback, integrity failure, five-chunk parent mapping, multiple episodes, completed legacy preserve, incomplete legacy restart.
- [x] Remove independent native transport ownership from the V2 path. Native code may keep OS integration, completion delivery, diagnostics, Live Activity/presentation, and telemetry only.
- [x] No native V2 code independently chooses chunk/range ownership, creates a second retry engine, adopts URL matches, or promotes multipart files outside `background_downloader` ownership.
- [x] Review `AppDelegate` background-session handling against `background_downloader` requirements and keep only callbacks needed for package/OS lifecycle integration.
- [x] Run focused V2 tests, analyzer, native typecheck, and iOS build job.

**Commit target:** `refactor(downloads): remove native transport authority from v2`

---

### Task 12A: iOS CI + Download Diagnostics/Logs — ✅ Complete

This is an explicit task so a future worker cannot lose the iOS verification/logging requirement.

**Purpose:** make iOS-specific failures reproducible and leave enough safe evidence to diagnose background lifecycle issues without leaking signed download credentials.

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `lib/core/services/download_v2/download_v2_diagnostics.dart`
- Modify: `lib/core/services/download_v2/download_manager_v2.dart`
- Modify/finish: `lib/core/services/download_v2/download_v2_provider.dart`
- Modify as needed: `ios/Runner/DownloadNativeWaitingQueue.swift` / native diagnostics bridge.
- Create/modify tests under `test/core/services/download_v2/`.

**Already present at the last reconciliation:**
- independent macOS `ios-v2-build` CI job;
- `flutter build ios --debug --no-codesign` with output captured to `ios-v2-build.log`;
- `actions/upload-artifact` executes with `if: always()` so failed builds retain logs;
- macOS native logger typecheck job;
- safe `DownloadDiagnosticEventV2` allowlist;
- append-only `FileDownloadDiagnosticsV2` JSONL sink;
- manager lifecycle/source-refresh/integrity diagnostic recording hooks.

**Verified acceptance:**
- [x] Wire `FileDownloadDiagnosticsV2` through the **production** V2 provider, honoring the existing/user-facing download logging preference if one exists; disabled logging must create no file.
- [x] Store runtime V2 log under the app's dedicated `log` directory (or the existing canonical download-log directory) with serialized writes.
- [x] Add/keep tests proving logging never contains raw URL, query token, auth header/cookie, provider body, or free-form exception text.
- [x] Ensure logging I/O failure is swallowed/isolated and cannot fail start/pause/resume/cancel/completion.
- [x] Native diagnostics must use allowlisted identifiers/status/reason categories only; never dump `URLSessionTask.originalRequest`, headers, cookies, or signed URL strings.
- [x] Keep a CI artifact for iOS build logs on both success and failure.
- [x] Record exact successful iOS workflow run ID + head SHA here after the production cutover head is stable.
- [x] If iOS CI fails, inspect the retained artifact and fix the root cause; do not bypass the job.
- [x] Compare iOS background wake/resume/completion behavior with V1 as a **behavioral reference only**. Never restore V1 transport ownership to make the test pass.

**Evidence field:**
- Stable exact-head CI: head `994f8dea65326f32c66feb9770948ab03affb10b`, workflow run `35228229194` (#2311, attempt 2); Analyze succeeded, iOS build succeeded, and native logger typecheck succeeded.
- Full-suite result: V2/cutover/native guards and telemetry passed; the only remaining failure is the unrelated missing `ANIME4K_PERFORMANCE_PLAN.md` baseline.
- Runtime V2 log path: application documents `log/`, wired through `FileDownloadDiagnosticsV2` and the user download-diagnostics preference.
- Native logger verification: workflow job `Typecheck native download logger` succeeded on the exact head.

**Commit target:** `test(downloads): harden ios v2 diagnostics and build evidence`

---

### Task 13: Physical-Device Acceptance Gate — ⛔ Device-gated

**This task cannot be checked from CI/mocks/simulator alone.**

- [ ] iOS real device: new complete download.
- [ ] Android real device: new complete download.
- [ ] Pause/resume on both platforms.
- [ ] Pause -> force kill -> reopen -> remains paused -> explicit resume.
- [ ] Active download -> process termination -> relaunch recovery.
- [ ] Network loss -> recovery.
- [ ] 401/403 -> one fresh byte-zero generation.
- [ ] Five-chunk package parallel download.
- [ ] Multiple simultaneous episodes.
- [ ] Cancel and delete.
- [ ] Disk failure / unwritable destination behavior.
- [ ] Integrity failure behavior.
- [ ] Stale old-generation callback has no effect.
- [ ] Completed legacy playback remains available.
- [ ] Incomplete legacy item restarts from byte zero only after explicit user action.
- [ ] Record exact app build SHA, device/OS, action, expected result, observed result, and relevant safe log excerpt/artifact reference.

**Evidence field:** `PENDING REAL DEVICES`

**Commit target:** `test(downloads): record v2 device acceptance`

---

### Task 14: Remove V1 Only After Device Gate — ⛔ Blocked by Task 13

**Prerequisite:** every required Task 13 scenario has real-device evidence.

- [ ] Add architecture guard proving production no longer references V1 executor types.
- [ ] Delete obsolete V1 executor files including `lib/core/services/persistent_parallel_download.dart`, `lib/core/services/download_range_transfer.dart`, and transport-only ownership/reconciliation code proven unreachable.
- [ ] Reduce/remove `lib/core/services/download_service.dart` only after remaining non-V1 responsibilities are moved or proven unused.
- [ ] Delete obsolete V1-only transport tests.
- [ ] Retain legacy completed-download presentation metadata reading only as long as needed for migrated completed files.
- [ ] Run focused V2 tests, full analyzer, full tests, iOS build/log job, and exact PR-head CI.

**Commit target:** `refactor(downloads): remove legacy downloader transport`

---

### Task 15: Final Deep Review / Merge Readiness — ⬜ Remaining

- [ ] Compare final diff against every acceptance criterion in the design spec and this plan.
- [ ] Re-check duplicate writers, pause ordering, persisted transport policy, generation fence, relaunch, exact task adoption, 403 loop prevention, integrity gate, migration policy A, diagnostics redaction, native authority, and absence of V1 fallback.
- [ ] Run `flutter analyze --no-fatal-warnings --no-fatal-infos` and full tests from the exact final head SHA.
- [ ] Inspect PR CI for that exact SHA, including iOS build/log and native logger checks.
- [ ] Fix every discovered V2 issue and rerun affected checks.
- [ ] Update the Progress Ledger counts/statuses and record Task 13 evidence.
- [ ] Mark PR ready only when automated **and** physical-device gates are actually satisfied.
- [ ] Do not merge unless explicitly requested.

---

## Continuation Protocol

A new worker continuing this branch must:

1. Read this plan and the design spec.
2. Fetch PR #247 current head and latest CI; do not assume the head recorded above is still current.
3. Reconcile the Progress Ledger only from code/tests/CI evidence, not chat history.
4. Start at the first incomplete prerequisite-sensitive task (currently Task 11).
5. Use RED -> GREEN for new behavior; diagnose root causes before fixes.
6. While a CI run is executing, work on an independent next item locally/in review, but do not push a commit that cancels evidence you still need from the current run.
7. Use V1 code only as a behavioral/reference source for UI metadata, source selection, and platform lifecycle knowledge. Never copy its custom transport ownership into V2.
8. Keep iOS Task 12A and its logging/evidence requirements visible until marked complete with exact-head evidence.
9. Never mark Task 13 complete without real-device results, and never start destructive V1 removal before Task 13 is complete.
10. After every meaningful milestone, update **Complete / Remaining / In progress** counts in the Progress Ledger so the next worker can resume without reconstructing history.
