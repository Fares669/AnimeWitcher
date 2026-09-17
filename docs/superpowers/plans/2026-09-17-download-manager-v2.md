# Download Manager V2 Implementation Plan

> **For agentic workers:** this file is the source of truth for continuation. Before changing code, inspect the current PR head and CI, then continue from the first incomplete acceptance item. Use TDD/systematic debugging for every regression found by review. Do not mark a task complete from isolated unit coverage when the production path is not wired.

**Goal:** Replace AnimeWitcher's custom downloader transport/recovery stack with Download Manager V2 using `background_downloader` as the single transport authority.

**Architecture:** AnimeWitcher owns logical identity, user intent, source refresh, destination/presentation metadata, integrity validation, diagnostics, priority/concurrency preferences, and stale-generation fencing. `background_downloader` owns network transfer, transport persistence, pause/resume data, retries, background native execution, and package-managed chunks. V1 remains only as a legacy strangler path until real-device acceptance allows Task 14 to delete it; V1 must never own or retry a V2 task.

**Spec:** `docs/superpowers/specs/2026-09-17-download-manager-v2-design.md`

---

## Progress Ledger

**Last deep review:** 2026-09-17, PR #247, branch `feat/download-manager-v2`, reviewed head `4cc87d75d6e89bb69c547e3f82941e91ef9b7ae9`.

### Overall count

- **Trackable task groups:** 16 total (`Task 1` through `Task 15`, plus explicit `Task 12A`).
- **Complete:** **10 / 16** — Tasks 1-9 plus Task 12A.
- **Remaining:** **6 / 16** — Tasks 10, 11, 12, 13, 14, 15.
- **Reopened by deep review:** Tasks 10, 11, and 12. Earlier isolated tests/guards were insufficient to prove the production integration.
- **Device-gated:** Task 13; therefore Task 14 and final merge readiness remain blocked until real iOS + Android evidence exists.

### Status table

| Task | Status | Continuation note |
| --- | --- | --- |
| 1. Dependency + identity + domain model | ✅ Complete | Stable logical/task identities and V2 DTOs are established. |
| 2. Logical store | ✅ Complete | Dedicated V2 application-owned persistence exists. |
| 3. `background_downloader` gateway | ✅ Complete | Transfer API is the V2 package boundary; exact task identity is used. |
| 4. Start/coalescing/generation fence | ✅ Complete | Duplicate same-logical start and stale callbacks are covered. |
| 5. Pause/resume/cancel/delete | ✅ Complete | Core intent ordering and lifecycle commands are implemented. |
| 6. Startup rehydration | ✅ Complete | Exact-task recovery and active-missing fresh generation are implemented. |
| 7. Source refresh | ✅ Complete | 401/403 replacement resolves a fresh source and starts byte zero. |
| 8. Integrity gate | ✅ Complete | Runtime completion requires final-file verification. Additional relaunch/cleanup gaps are tracked under Task 12. |
| 9. Package parallelism + diagnostics DTO | ✅ Complete | One package parent represents parallel work; child IDs remain opaque. |
| 10. Legacy migration policy A | 🟡 Reopened | Migration class/tests exist, but incomplete legacy is not wired into the production presentation/startup path and legacy playback can accept an incomplete file. |
| 11. Riverpod + production cutover | 🟡 Reopened | Main/UI are largely V2, but Settings can still instantiate V1; presentation metadata has a crash window; destination identity can admit two writers. |
| 12. Native authority cleanup + regression matrix | 🟡 Reopened | iOS legacy hook can still retry/settle V2 full-file tasks; additional startup/integrity/replacement tests are missing. |
| 12A. iOS CI + runtime/native diagnostics | ✅ Complete | Dedicated iOS build log artifact, native typecheck, production V2 log sink, and redaction protections exist. Re-capture exact-head evidence after Tasks 10-12 stabilize. |
| 13. Physical-device acceptance | ⛔ Device-gated | Must run on real iOS + Android hardware; CI/simulator/mocks do not satisfy it. |
| 14. Remove V1 | ⛔ Blocked by Task 13 | Delete V1 transport/native ownership only after device acceptance. |
| 15. Final deep review / merge readiness | 🟡 In progress | This review reopened concrete blockers. Re-run after Tasks 10-14. |

### Verification baseline before reopened fixes

- Reviewed head: `4cc87d75d6e89bb69c547e3f82941e91ef9b7ae9`.
- Workflow run: `35229854291` (`Flutter Checks`, run #2312).
- Analyzer: success with the existing no-fatal warning/info policy.
- `Build iOS V2 and retain log`: success.
- `Typecheck native download logger`: success.
- Full Flutter test suite: **1502 passed, 1 failed, 1 skipped**. The sole failure is the unrelated missing `ANIME4K_PERFORMANCE_PLAN.md` baseline. New V2 failures must not be hidden behind that baseline.
- `cancel-in-progress: true` means preserve exact-head evidence before pushing another commit when that evidence is required.

---

## Global Constraints

- `background_downloader` is the **only** transport/retry/pause-resume authority for V2.
- No V2 production path may instantiate or call `DownloadService`, `PersistentParallelDownload`, `DownloadRangeTransfer`, legacy JobStore ownership, or native retry/promotion logic.
- V1 may remain temporarily only for pre-cutover legacy work and must explicitly ignore every V2 task.
- No V2 persistence may contain custom chunk IDs, ranges, resume offsets/bytes, package retry counters, package hold state, or native writer ownership.
- Migration policy A: completed legacy files remain usable only when completion is proven; incomplete legacy work stays visible but performs zero network work until explicit user resume/restart, then starts V2 from byte zero.
- Startup attaches only by the current exact package `taskId`, never URL/filename matching.
- `active + missing/nonrecoverable transfer` creates one fresh generation; paused/canceled/legacy-incomplete never auto-start.
- Pause intent is durable before transport pause. Cancel/delete fence stale callbacks before cleanup.
- Every logical/destination artifact has one active writer. Different source/server selections must not create independent writers for the same destination.
- Package parallel children remain opaque; UI uses parent aggregate progress.
- Completed state is only valid while the final artifact still passes integrity validation.
- Invalid final artifacts are removed/quarantined before clean retry.
- Diagnostics are observability only and never own transport. Logs must not contain signed URLs, auth headers/tokens, cookies, provider bodies, or free-form exception dumps.
- Device-only acceptance is never inferred from CI, simulator, mocks, or unit tests.

---

## Completed foundation: Tasks 1-9

Tasks 1-9 are retained as complete unless a new regression specifically invalidates their acceptance. Do not reimplement them speculatively.

---

## Task 10: Legacy Migration Policy A — 🟡 Reopened

**Root cause found by deep review:** `LegacyDownloadMigrationV2` is implemented and unit-tested but not wired into production startup/presentation. `downloads_provider` only retains verified legacy-complete rows, so incomplete legacy work disappears instead of remaining restart-required/paused. `downloaded_file_provider` also accepts an existing legacy file without first proving stored completion, which can expose a partial file as playable.

**Required acceptance:**
- [ ] Add a production migration seam that consumes legacy presentation metadata without importing V1 transport/range/chunk/resume/native ownership state.
- [ ] Completed legacy entries migrate/present only when stored completion and final-file validity are both proven.
- [ ] Incomplete legacy entries remain visible as paused/restart-required and cause zero automatic network work after upgrade/relaunch.
- [ ] Explicit resume/restart of an incomplete legacy entry creates a fresh V2 generation from byte zero using stable provider/source metadata.
- [ ] Legacy partial files are never returned by `DownloadedFiles.resolveFile()` as completed media.
- [ ] Migration is idempotent and never overwrites a newer V2-owned logical record.
- [ ] Add production-level tests in addition to the existing isolated migration tests.

---

## Task 11: Production Cutover / Presentation / Settings — 🟡 Reopened

**Root causes found by deep review:**
- `general_settings_provider.dart` still imports/uses `downloadServiceProvider` for concurrency and notification settings, which can construct V1 after cutover.
- `DownloadLauncher` starts V2 before presentation metadata is durably saved. Process death in that window leaves a real V2 transfer/record that `downloads_provider` cannot render because it drops records without legacy presentation metadata.
- `variantKey` includes server/source while the destination filename/path may not; two logical IDs can therefore target the same file concurrently.
- progress projection is still keyed by tracking URL in places, allowing variants to collide in presentation.
- Android non-transport preflight behavior from V1 (storage access/battery optimization and offline skip-segment preparation) must be preserved outside V1 or proven obsolete before device acceptance.

**Required acceptance:**
- [ ] Extend the production cutover guard to include settings and every production download entry point; no V1 service/provider imports or calls remain reachable from normal V2 UI/settings.
- [ ] Move concurrency and notification configuration to V2/package-safe configuration without constructing V1.
- [ ] Make presentation metadata crash-safe: a V2 record must contain enough app-owned presentation metadata to rehydrate UI after process death, or equivalent metadata must be durably committed before a writer can start.
- [ ] Add a regression test for process death between accepted start and legacy presentation-metadata persistence.
- [ ] Enforce one writer per canonical destination/logical episode across alternate source/server selections.
- [ ] Define semantic variant identity explicitly (for example quality/dub-sub) and keep transient server/source selection in the source descriptor rather than using it to create unsafe independent destination owners.
- [ ] Key presentation/control state by logical/task identity rather than tracking URL where collisions are possible.
- [ ] Preserve required Android storage/battery/offline preparation through V2-safe helpers; do not call V1 to get this behavior.
- [ ] Remove progress DTO/formatter duplication and the `core -> feature` transitive export dependency introduced during cutover.
- [ ] Focused V2/cutover tests green, analyzer green, and full suite inspected with only documented unrelated baseline failures.

---

## Task 12: Native Authority Cleanup + Reliability Regression Matrix — 🟡 Reopened

**Root causes found by deep review:**
- iOS installs the legacy `DownloadNativeWaitingQueue` URLSession hook globally.
- `retryBackgroundTransferIfNeeded()` can recreate a normal V2 full-file `URLSessionDownloadTask`, becoming a second retry engine and suppressing `background_downloader`'s own completion/failure path.
- legacy full-file completion handling can still park/promote queue state for V2 tasks.
- `_startFreshGeneration()` publishes the next durable generation before proving the obsolete writer stopped; failed cancel can leave a durable missing generation while the old writer remains active.
- startup trusts `completedAtMillis` without revalidating the final artifact.
- runtime integrity failure records a failure but does not remove/quarantine an invalid final artifact.

**Required acceptance:**
- [ ] Add RED source/behavior guards proving every `aw_v2_` native task bypasses legacy native retry, queue ownership, promotion, pause/cancel/resume, and completion settlement. Diagnostics/presentation observation may remain.
- [ ] Preserve legacy hook behavior only for explicitly legacy-owned tasks until Task 14; V2 must pass through to `background_downloader` unchanged.
- [ ] Prevent replacement generation publication/start until the obsolete non-final writer is safely settled; failed cancel must leave a recoverable, truthful durable state and never create a second writer.
- [ ] Add a regression test for obsolete-cancel failure during restart/source refresh.
- [ ] On startup, revalidate every logically completed final file; missing/empty/size-invalid files must not project as completed.
- [ ] Remove/quarantine invalid final artifacts after integrity failure before clean retry.
- [ ] Extend tests for completed+missing relaunch, corrupt completion cleanup, and stale completion around generation transition.
- [ ] Retain the existing matrix: start, duplicate start, pause, resume, pause+recreation, active+missing, held/offline projection, 403 refresh, cancel/delete stale callback, five-chunk package parent, multiple episodes, completed legacy preserve, incomplete legacy restart.
- [ ] Re-run focused V2 tests, analyzer, native typecheck, and exact-head iOS build/log artifact.

---

## Task 12A: iOS CI + Download Diagnostics/Logs — ✅ Complete

Feature acceptance retained:
- independent macOS iOS V2 build job captures `ios-v2-build.log` and uploads it with `if: always()`;
- native download logger typechecks on macOS;
- production `FileDownloadDiagnosticsV2` writes serialized allowlisted JSONL under application documents `log/` and honors the user setting;
- disabled/failing logging cannot fail transport actions;
- diagnostics never serialize raw transport URL/query token/auth header/cookie/provider body/free-form transport exception text.

**Continuation rule:** after Tasks 10-12 stabilize, replace the stale evidence field with the final exact head + workflow run whose analyzer, iOS build, native logger check, and focused V2 tests were inspected.

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
- one transport authority and one writer per destination;
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
7. Stop automatic implementation only at the real-device gate if no device evidence is available; report exactly what remains blocked.