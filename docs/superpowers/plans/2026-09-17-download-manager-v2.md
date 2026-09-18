# Download Manager V2 Implementation Plan

> **For agentic workers:** this file is the source of truth for continuation. Before changing code, inspect the current PR head and CI, then continue from the first incomplete acceptance item. Use TDD/systematic debugging for every regression found by review. Do not mark a task complete from isolated unit coverage when the production path is not wired.

**Goal:** Replace AnimeWitcher's custom downloader transport/recovery stack with Download Manager V2 using `background_downloader` as the single transport authority.

**Architecture:** AnimeWitcher owns logical identity, user intent, source refresh, destination/presentation metadata, integrity validation, diagnostics, priority/concurrency preferences, and stale-generation fencing. `background_downloader` owns network transfer, transport persistence, pause/resume data, retries, background native execution, and package-managed chunks. V1 remains only as a dormant/legacy strangler path until real-device acceptance allows Task 14 to delete it; V1 must never own or retry a V2 task.

**Spec:** `docs/superpowers/specs/2026-09-17-download-manager-v2-design.md`

---

## Progress Ledger

**Last deep review:** 2026-09-17, PR #247, branch `feat/download-manager-v2`, deep-review base head `4cc87d75d6e89bb69c547e3f82941e91ef9b7ae9`.

**Latest reconciliation:** 2026-09-17, code head `d389ed349b7d2717e1310b62bdbe460c3d0ea7c7`. The review-fix batch now closes the production acceptance items for Tasks 10-12, and exact-head CI evidence is recorded below. Only the real-device gate and its downstream V1-removal/final-readiness work remain.

### Overall count

- **Trackable task groups:** 17 total (`Task 1` through `Task 15`, plus explicit `Task 12A` and `Task 12B`).
- **Complete:** **11 / 17** — Tasks 1-4, 6-10, 12, and 12A.
- **Remaining:** **6 / 17** — reopened Tasks 5 and 11, new Task 12B, and Tasks 13-15.
- **Reopened by deep review:** Tasks 10, 11, and 12 were closed by the follow-up production-path fixes and exact-head verification in this reconciliation.
- **Device-gated:** Task 13; therefore Task 14 and final merge readiness remain blocked until real iOS + Android evidence exists.

### Status table

| Task | Status | Continuation note |
| --- | --- | --- |
| 1. Dependency + identity + domain model | ✅ Complete | Stable logical/task identities and V2 DTOs are established. |
| 2. Logical store | ✅ Complete | Dedicated V2 application-owned persistence exists. |
| 3. `background_downloader` gateway | ✅ Complete | Transfer API is the V2 package boundary; exact task identity is used. |
| 4. Start/coalescing/generation fence | ✅ Complete | Duplicate same-logical start and stale callbacks are covered. |
| 5. Pause/resume/cancel/delete | 🟡 Reopened | Real-iOS evidence shows pause → resume can replace the paused generation with a fresh generation that stays queued at 0%; fixed behavior must be proven before device acceptance. |
| 6. Startup rehydration | ✅ Complete | Exact-task recovery and active-missing fresh generation are implemented. |
| 7. Source refresh | ✅ Complete | 401/403 replacement resolves a fresh source and starts byte zero. |
| 8. Integrity gate | ✅ Complete | Runtime completion requires final-file verification; relaunch/cleanup regressions found later are being closed under Task 12. |
| 9. Package parallelism + diagnostics DTO | ✅ Complete | One package parent represents parallel work; child IDs remain opaque. |
| 10. Legacy migration policy A | ✅ Complete | Production migration preserves incomplete/restart-required rows, keeps startup network-free, and routes explicit restart through safe source reconstruction with malformed-row coverage. |
| 11. Riverpod + production cutover | 🟡 Reopened | Device/review comparison found concurrency and notification settings are persisted but not fully applied by the V2 runtime/package gateway. |
| 12. Native authority cleanup + regression matrix | ✅ Complete | Native remains observation-only, replacement and integrity fences are covered, stale generations cannot resurrect completion, and the retained regression matrix was re-audited. |
| 12A. iOS CI + runtime/native diagnostics | ✅ Complete | Dedicated iOS build log artifact, native typecheck, production V2 log sink, and redaction protections exist; exact-head evidence is current at `d389ed3…`. |
| 12B. Device-preflight regressions + platform parity | 🟡 In progress | Real iOS log exposed resume-to-zero/queued stall and missing speed/iOS continued-processing presentation; SkyStream comparison also exposed runtime concurrency/notification/platform configuration gaps. |
| 13. Physical-device acceptance | ⛔ Device-gated | Must run on real iOS + Android hardware; CI/simulator/mocks do not satisfy it. |
| 14. Remove V1 | ⛔ Blocked by Task 13 | Delete V1 transport/native ownership only after device acceptance. |
| 15. Final deep review / merge readiness | 🟡 In progress | Deep review produced concrete blockers; rerun the review after Tasks 10-14 are closed. |

### Latest exact-head verification (`d389ed349b7d2717e1310b62bdbe460c3d0ea7c7`)

Workflow run: `35268324678` (`Flutter Checks`, run #2347).

- `Analyze`: ✅ success.
- `Focused V2 tests`: ✅ success (`69 tests passed`).
- `Build iOS V2 and retain log`: ✅ success; artifact upload also succeeded.
- `Typecheck native download logger`: ✅ success.
- Full `Test` step: ❌ `1517 tests passed, 1 failed, 1 skipped.` The sole failure is `test/features/player/anime4k_platform_ci_contract_test.dart`, which attempts to read the missing `ANIME4K_PERFORMANCE_PLAN.md` at repository root. This is an unrelated pre-existing Anime4K contract failure, not a Download Manager V2 failure.
- Overall workflow conclusion is failure only because of that unrelated repository-baseline failure; all V2-focused, analyzer, native, and iOS gates are green.

This exact-head evidence is the basis for closing Tasks 10-12; Task 13 still requires physical iOS + Android evidence.

---

## Global Constraints

- `background_downloader` is the **only** transport/retry/pause-resume authority for V2.
- No V2 production path may instantiate or call `DownloadService`, `PersistentParallelDownload`, `DownloadRangeTransfer`, legacy JobStore ownership, or native retry/promotion logic.
- V1 source may remain temporarily only for legacy compatibility/removal staging and must explicitly never own a V2 task.
- No V2 persistence may contain custom chunk IDs, ranges, resume offsets/bytes, package retry counters, package hold state, or native writer ownership.
- Migration policy A: completed legacy files remain usable only when completion is proven; incomplete legacy work stays visible but performs zero network work until explicit user resume/restart, then starts V2 from byte zero.
- Startup attaches only by the current exact package `taskId`, never URL/filename matching.
- `active + missing/nonrecoverable transfer` creates one fresh generation; paused/canceled/legacy-incomplete never auto-start.
- Pause intent is durable before transport pause. Cancel/delete fence stale callbacks before cleanup.
- Every canonical destination artifact has one active writer. Different source/server selections must not create independent writers for the same destination.
- Package parallel children remain opaque; UI uses parent aggregate progress.
- Completed state is valid only while the final artifact still passes integrity validation.
- Invalid final artifacts are removed/quarantined before clean retry.
- Diagnostics are observability only and never own transport. Logs must not contain signed URLs, auth headers/tokens, cookies, provider bodies, or free-form exception dumps.
- Device-only acceptance is never inferred from CI, simulator, mocks, or unit tests.

---

## Completed foundation: Tasks 1-9

Tasks 1-9 are retained as complete unless a new regression specifically invalidates their acceptance. Do not reimplement them speculatively.

---

## Task 10: Legacy Migration Policy A — 🟡 In progress

**Deep-review root cause:** `LegacyDownloadMigrationV2` originally existed only in isolation. Production startup did not invoke it, incomplete legacy work disappeared, and legacy playback could accept a partial file.

**Review-fix batch now present:** production migration runs before package transport initialization; migrated rows are patched with canonical `logicalId`; completed legacy migration requires stored completion plus file validity; incomplete rows remain visible as paused/restart-required even without a refresh descriptor; explicit restart reconstructs a safe descriptor when the stored provider/source metadata is sufficient; malformed and ambiguous rows fail closed without transport work; migration does not overwrite a newer V2 record.

**Required acceptance:**
- [x] Add a production migration seam that consumes legacy presentation metadata without importing V1 transport/range/chunk/resume/native ownership state.
- [x] Completed legacy entries migrate/present only when stored completion and final-file validity are both proven.
- [x] Incomplete legacy entries remain visible as paused/restart-required and cause zero automatic network work after upgrade/relaunch, including rows without a usable refresh descriptor.
- [x] Explicit resume/restart of every visible incomplete legacy entry creates a fresh V2 generation from byte zero using stable provider/source metadata; production-path behavior covers descriptor reconstruction and fails closed when re-selection is required.
- [x] Legacy partial files are never returned by `DownloadedFiles.resolveFile()` as completed media.
- [x] Migration is idempotent and never overwrites a newer V2-owned logical record.
- [x] Add production-level behavioral tests covering startup presentation + explicit restart, including the no-refresh-descriptor case and malformed legacy rows.

**Result:** restart-required presentation, safe descriptor reconstruction, malformed-row handling, and explicit V2 restart are wired and covered. No further automatic implementation is required here; Task 13 is the next gate.

---

## Task 11: Production Cutover / Presentation / Settings — 🟡 In progress

**Deep-review root causes:** Settings could construct V1; metadata was written after transport start; source/server identity could create unsafe logical variants; progress used tracking URL aliases; Android preflight/offline preparation was missing; progress DTO/formatter layering became duplicated/inverted.

**Review-fix batch now present:** Settings no longer imports/calls `downloadServiceProvider`; the cutover guard includes Settings; presentation metadata is durably written before `DownloadManagerV2.start()` with cleanup on start failure; semantic variant identity no longer contains transient source/server; progress primary key is logical ID; V2-safe Android permission/battery/offline preflight exists; progress DTO/formatting is centralized in core without a `core -> feature` export; canonical destination admission serializes ownership and rejects alternate logical writers for the same artifact.

**Required acceptance:**
- [x] Extend the production cutover guard to include Settings and normal production download entry points; no V1 service/provider imports or calls remain reachable from normal V2 UI/settings.
- [x] Move concurrency and notification configuration to V2/package-safe persistence/configuration without constructing V1.
- [x] Make presentation metadata crash-safe by durably committing it before a writer can start.
- [x] Add a regression guard proving metadata persistence precedes `downloadManager.start()` and failed start removes the staged metadata.
- [x] Enforce one writer per **canonical destination** across alternate source/server and semantic-variant selections. Logical-ID coalescing is supplemented by destination-level admission/fencing.
- [x] Define semantic variant identity explicitly (audio/dub-sub + quality) and keep transient server/source selection in the source descriptor.
- [x] Key V2 presentation/control state primarily by logical identity. Temporary read-only tracking aliases are allowed only when unambiguous and must never become ownership keys.
- [x] Preserve required Android storage/battery/offline preparation through V2-safe helpers; do not call V1 to get this behavior.
- [x] Remove progress DTO/formatter duplication and the `core -> feature` transitive export dependency introduced during cutover.
- [x] Re-inspect the exact-head full-suite failure and record focused V2 + analyzer + native typecheck + iOS build/log + full-suite status; only the explicitly proven unrelated Anime4K baseline failure remains.

**Result:** the RED duplicate-canonical-destination regression is green with destination-level admission/fencing. Exact-head CI evidence is recorded above; no further automated cutover work remains.

---

## Task 12: Native Authority Cleanup + Reliability Regression Matrix — 🟡 In progress

**Deep-review root causes:** the iOS compatibility hook could become a second retry/queue authority; replacement generation was published before the obsolete writer was safely stopped; startup trusted `completedAtMillis` without file validation; integrity failure left corrupt output behind.

**Review-fix batch now present:** `DownloadHookInstallation` defaults `transportOwnershipEnabled` to false and repeated installs preserve observation-only ownership; legacy native retry/promotion functions are fenced behind `nativePromotionAvailable`; source guards assert that transport ownership stays disabled for the V2 cutover; `_startFreshGeneration()` cancels a non-final obsolete handle before publishing the replacement; failed obsolete cancel keeps the prior durable generation; completed records are revalidated at startup; invalid artifacts are deleted on startup/runtime integrity failure; focused regression tests cover these review findings, including stale completion after a generation restart.

**Required acceptance:**
- [x] Add RED/source guards proving the installed compatibility hook is observation-only after cutover and cannot claim V2 retry/queue/completion ownership.
- [x] Keep native retry/promotion dormant for V2. Dormant legacy source may remain until Task 14, but `background_downloader` stays the only active V2 transport authority.
- [x] Prevent replacement generation publication/start until an obsolete non-final writer is safely settled; failed cancel leaves the old durable generation truthful and starts no second writer.
- [x] Add a regression test for obsolete-cancel failure during replacement.
- [x] On startup, revalidate logically completed final files; missing/empty/size-invalid files no longer project as completed.
- [x] Remove invalid final artifacts after integrity failure before clean retry.
- [x] Verify stale completion callbacks around generation transitions cannot resurrect completion after restart/source refresh/cancel; the focused generation regression proves the durable replacement remains incomplete after an old-generation completion callback.
- [x] Re-audit the retained regression matrix end to end: start, duplicate start, pause, resume, pause+recreation, active+missing, held/offline projection, 403 refresh, cancel/delete stale callback, five-chunk package parent, multiple episodes, completed legacy preserve, incomplete legacy restart.
- [x] Re-inspect the exact-head full-suite failure and record final exact-head analyzer + focused V2 + native typecheck + iOS build/log + full-suite evidence after Tasks 10/11 fixes landed.

---

## Task 12A: iOS CI + Download Diagnostics/Logs — ✅ Complete

Feature acceptance retained:
- independent macOS iOS V2 build job captures `ios-v2-build.log` and uploads it with `if: always()`;
- native download logger typechecks on macOS;
- production `FileDownloadDiagnosticsV2` writes serialized allowlisted JSONL under application documents `log/` and honors the user setting;
- disabled/failing logging cannot fail transport actions;
- diagnostics never serialize raw transport URL/query token/auth header/cookie/provider body/free-form transport exception text.

**Latest exact-head evidence:** at `d389ed349b7d2717e1310b62bdbe460c3d0ea7c7`, run `35268324678` has a successful iOS V2 build/log upload and successful native logger typecheck; the focused V2 suite and analyzer also pass. The full-suite red is isolated to the missing Anime4K plan file documented above.
---

## Task 12B: Device-Preflight Regressions + Platform Parity — 🟡 In progress

**Trigger:** first real-iOS V2 run on 2026-09-18 plus comparison against SkyStream's current downloader integration.

**Observed device evidence (`download_v2.jsonl` supplied from the real iOS run):**
- Generation 1 started normally and progressed to `0.0227567795` (~2.28%) before explicit pause.
- The first explicit resume did **not** continue generation 1. It created generation 2 at byte zero; generation 2 remained `queued` and never emitted `running` before being paused ~13 seconds later.
- Subsequent generations 3-7 repeatedly remained at 0% in queued/paused/canceled states, confirming a real replacement/resume transport stall rather than a presentation-only issue.
- The V2 diagnostic schema currently omits throughput/ETA, so the screenshot's persistent “calculating” speed cannot be root-caused from the existing JSONL alone.
- The iOS 26 continued-processing/Dynamic-Island code still exists natively, but normal V2 production flow no longer drives the Dart continued-processing bridge; it must remain observation-only and never regain retry/queue transport ownership.

**Required acceptance — device bugs:**
- [ ] RED regression: a paused package transfer whose direct package resume cannot recover must not publish/start a replacement until the obsolete transfer is demonstrably settled; replacement then reaches a runnable package state rather than remaining a zero-progress queued zombie.
- [ ] Resume success keeps the exact generation/task and preserves package resume bytes; fallback-to-fresh-generation starts from byte zero only when package resume is unavailable.
- [ ] V2 snapshots expose package throughput + ETA reliably on iOS/parallel parent transfers; add credential-safe diagnostic fields for transferred/total bytes, speed, and ETA so the next device log can prove the signal path.
- [ ] A real iOS Preview shows non-placeholder speed once package progress contains throughput and pause → resume continues or cleanly restarts without a permanent 0% queue stall.

**Required acceptance — parity items requested from the SkyStream comparison:**
- [ ] **1. Runtime concurrency:** the persisted 1-10 episode limit is actually enforced by V2 without counting package-managed parallel children as independent episodes and without a holding-queue/chunk deadlock.
- [ ] **2. Package/platform configuration:** V2 applies notification preferences at runtime, configures appropriate Android long-download behavior using supported `background_downloader 9.6.2` facilities, and restores iOS download-file cloud-backup exclusion. Do not reintroduce a second transport scheduler.
- [ ] **3. iOS 26 Continued Processing:** reconnect V2 progress/session presentation to the native continued-processing bridge as **observation/UI only**. Expiration/cancellation of the system overlay must not pause, retry, promote, or cancel the package-owned URLSession transfer.
- [ ] **4. Notification permission timing:** request download notification permission on the first real download/action that needs it rather than unconditionally at app launch; older/no-notification flows continue without transport failure.
- [ ] Add focused automated guards for all four parity items and rerun analyzer + focused V2 + iOS build/native typecheck before returning to Task 13.

**Scope rule:** keep `background_downloader` as the single transport/pause-resume/retry authority. Reuse Transfer API/notifiers/configuration instead of reviving V1 Range, JobStore, native promotion, or custom chunk state.


---

## Task 13: Physical-Device Acceptance Gate — ⛔ Device-gated

This task requires real iOS and Android hardware. Minimum matrix:
- fresh start and multiple simultaneous episodes;
- 5-part/package-parallel mode where supported;
- pause/resume foreground;
- pause -> process kill -> relaunch -> stays paused;
- active -> process kill/suspension -> background continuation/relaunch recovery;
- connectivity loss/restore without a second app retry engine;
- signed URL expiry/403 fresh-generation recovery;
- cancel/delete with late native/package callbacks;
- completed playback after relaunch;
- upgrade with legacy completed + legacy incomplete rows;
- Android fresh-install storage/background behavior;
- iOS background URLSession wake/complete behavior;
- diagnostics enabled/disabled and credential redaction.

Record device/OS/build/head/log evidence in this file. Do not mark complete from simulator/CI.

---

## Task 14: Remove V1 — ⛔ Blocked by Task 13

After Task 13 passes on both platforms:
- delete `DownloadService` transport execution, custom range/multipart writers, legacy JobStore transport ownership/retry/reconciliation, and obsolete iOS native queue/promotion/retry bridge;
- keep only reusable non-transport helpers that are still intentionally used by V2;
- remove compatibility flags/providers/tests that exist solely for V1;
- prove no production import/reference can instantiate V1;
- run full analyzer/tests + iOS build and repeat a smoke device check after deletion.

---

## Task 15: Final Deep Review / Merge Readiness — 🟡 In progress

Do not mark complete until Tasks 10-14 are complete. Final review must compare the exact branch head against the design spec and verify:
- one transport authority and one writer per canonical destination;
- no V1 fallback/reachability;
- exact-ID lifecycle semantics and generation fencing;
- migration policy A end-to-end;
- restart/crash windows;
- source refresh/integrity behavior;
- package-managed parallelism only;
- safe diagnostics;
- UI/settings behavior and platform parity;
- final exact-head CI and real-device evidence.

---

## Continuation Protocol

1. Fetch PR #247 head and current CI before every batch; the branch may move concurrently.
2. Start with the first unchecked acceptance item above; do not redo completed foundation work.
3. For every bug: write a focused failing test/guard first, verify RED, implement the smallest root-cause fix, then verify GREEN.
4. Do not idle on CI; work on an independent item while jobs run, but capture exact-head evidence before the next push when needed.
5. Update this ledger whenever a task genuinely changes state. Never use a passing isolated unit test to claim production integration.
6. V1 is behavioral reference only. Never restore V1 transport ownership to make V2 pass.
7. Prefer production-behavior tests over source-shape guards when the behavior can be exercised directly; keep source guards only for architectural reachability/ownership constraints that are otherwise difficult to observe.
8. Stop automatic implementation only at the real-device gate if no device evidence is available; report exactly what remains blocked.
