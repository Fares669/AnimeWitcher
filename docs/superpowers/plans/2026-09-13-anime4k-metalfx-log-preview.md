# Anime4K MetalFX, Log, and Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose an independent Apple MetalFX experiment toggle, produce segment-aware benchmark logs, and restore the one-shot sample preview on iOS/macOS.

**Architecture:** Extend `PlayerSettings` with one persisted MetalFX boolean and use it as the sole Dart request for the native upscale strategy while leaving native capability gating intact. Extend the existing JSONL logger with configuration-segment state so routes/snapshots are attributable without creating multiple files. Keep preview rendering through short-lived mpv, but capture the processed `video` frame instead of the external output `window`.

**Tech Stack:** Flutter/Dart, Riverpod, media_kit/libmpv, Swift/Metal/MetalFX, JSONL, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-13-anime4k-metalfx-log-preview-design.md`

## Global Constraints

- MetalFX is Apple-only in the UI, independent of Eco, persisted separately, and defaults off.
- Native MetalFX capability checks remain authoritative.
- One logger service lifetime produces one JSONL session file.
- Segment boundaries follow enabled/mode/quality/Eco/MetalFX changes.
- Preview capture must use mpv processed video, not Flutter texture rasterization or mpv `window` capture.
- TDD for every behavior change.
- Do not mark AKP-17 complete from implementation alone.

---

### Task 1: Independent MetalFX setting and runtime routing

**Files:**
- Modify: `test/features/settings/presentation/anime4k_eco_settings_test.dart`
- Modify: `test/features/player/anime4k_metalfx_experiment_contract_test.dart`
- Modify: `lib/features/settings/presentation/player_settings_provider.dart`
- Modify: `lib/features/settings/presentation/widgets/anime4k_dialog.dart`
- Modify: `lib/features/player/presentation/player_controller_base.dart`
- Modify: `lib/features/player/presentation/player_controller.dart`

**Interfaces:**
- Produces: `PlayerSettings.anime4kMetalFxEnabled`, `PlayerSettingsNotifier.setAnime4kMetalFxEnabled(bool)`.
- Consumes: native strategy strings `fullAnime4K` and `restoreDenoiseMetalFXSpatial` already supported by the Apple C API/runtime.

- [ ] **Step 1: Write failing settings/runtime contract tests**

Add assertions that `PlayerSettings` defaults MetalFX off, `copyWith` preserves Eco independence, the repository key is `player_anime4k_metalfx_enabled`, the dialog places `MetalFX (experimental)` after Eco, and both controllers read `settings?.anime4kMetalFxEnabled` without `ANIME4K_METALFX_EXPERIMENT` or an Eco predicate.

- [ ] **Step 2: Run the focused tests and confirm RED**

Run: `flutter test test/features/settings/presentation/anime4k_eco_settings_test.dart test/features/player/anime4k_metalfx_experiment_contract_test.dart`
Expected: FAIL because `anime4kMetalFxEnabled` and its persisted/UI/runtime wiring do not exist yet.

- [ ] **Step 3: Implement the minimal persisted setting and switch**

Add:
```dart
final bool anime4kMetalFxEnabled;
```
with constructor/copyWith/load/write support and:
```dart
Future<void> setAnime4kMetalFxEnabled(bool val)
```
using `player_anime4k_metalfx_enabled`. Add an Apple-only `SwitchListTile` immediately after Eco. Runtime strategy selection becomes:
```dart
final useMetalFx = settings?.anime4kMetalFxEnabled ?? false;
final upscaleStrategy = useMetalFx
    ? 'restoreDenoiseMetalFXSpatial'
    : 'fullAnime4K';
```
Include the new flag in `_anime4kSettingsChanged` and logging.

- [ ] **Step 4: Run focused tests and confirm GREEN**

Run the same focused Flutter tests and require both to pass.

- [ ] **Step 5: Commit**

Commit message: `feat: expose independent Anime4K MetalFX toggle`

### Task 2: Segment-aware benchmark log

**Files:**
- Modify: `test/features/player/anime4k_performance_log_contract_test.dart`
- Modify: `lib/features/player/data/anime4k_performance_log.dart`
- Modify: `lib/features/player/presentation/player_controller.dart`

**Interfaces:**
- Produces: `Anime4kPerformanceLog.recordConfiguration(...)`.
- Route/snapshot events continue through existing `recordRoute` and `recordSnapshot` APIs but gain `segmentId`.

- [ ] **Step 1: Write failing log tests**

Add a real temp-directory test that records configuration A, route/snapshot A, changes only MetalFX, records route/snapshot B, then asserts one log file contains ordered `segmentStart`, `segmentEnd`, second `segmentStart`, and that route/snapshot entries reference the correct segment IDs. Add a disabled configuration assertion.

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `flutter test test/features/player/anime4k_performance_log_contract_test.dart`
Expected: FAIL because `recordConfiguration`, `segmentStart`, `segmentEnd`, and `segmentId` do not exist.

- [ ] **Step 3: Implement minimal segment state**

Maintain an in-memory active key containing enabled/mode/quality/Eco/MetalFX, incrementing `segmentId`, start timestamp, and latest snapshot. On key change, append a `segmentEnd` summary before the next `segmentStart`. Repeated identical configuration is a no-op. Route/snapshot appends include active `segmentId`. Call `recordConfiguration` from the player before post-apply route classification so disabled Anime4K is represented.

- [ ] **Step 4: Run focused test and confirm GREEN**

Run the performance log contract test and require all assertions to pass.

- [ ] **Step 5: Commit**

Commit message: `fix: segment Anime4K benchmark logs`

### Task 3: iOS/macOS sample preview capture

**Files:**
- Modify: `test/features/player/anime4k_sample_preview_test.dart`
- Modify: `lib/features/player/presentation/widgets/anime4k_sample_preview.dart`

**Interfaces:**
- Keeps existing `Anime4kPreviewCacheKey` and process cache.
- Uses libmpv `screenshot-to-file <path> video` for the processed still.

- [ ] **Step 1: Write failing preview regression test**

Change the capture contract to require `'video'` and explicitly reject `'window'` in the mpv fallback path.

- [ ] **Step 2: Run focused test and confirm RED**

Run: `flutter test test/features/player/anime4k_sample_preview_test.dart`
Expected: FAIL because current capture requests `'window'`.

- [ ] **Step 3: Implement minimal capture fix**

Change only the screenshot target from `window` to `video`, retain first-frame wait, shader acceptance checks, bounded file wait, cache, and immediate player disposal. Preserve the friendly localized error and add the concrete `_error` text only under debug diagnostics.

- [ ] **Step 4: Run focused test and confirm GREEN**

Run the preview test and require it to pass.

- [ ] **Step 5: Commit**

Commit message: `fix: capture Anime4K preview from processed video`

### Task 4: Plan alignment and exact-head verification

**Files:**
- Modify: `ANIME4K_PERFORMANCE_PLAN.md`
- Modify only if needed: `docs/anime4k_performance_benchmark.md`

**Interfaces:**
- AKP-17 remains unchecked.

- [ ] **Step 1: Update AKP-17 wording**

Record the approved change from hidden Eco-only compile-time toggle to an Apple-only user-visible independent experimental toggle. Keep the promotion/benchmark acceptance criteria unchanged.

- [ ] **Step 2: Run verification**

Require Flutter analyze, the full Flutter test suite, native logger typecheck, Anime4K platform/native contracts, and unsigned iOS release build on the exact PR head.

- [ ] **Step 3: Inspect CI evidence**

Fetch workflow jobs/logs for exact head, resolve any failures, and do not claim completion until green.

- [ ] **Step 4: Produce a fresh iOS Preview IPA**

Run the existing one-shot preview workflow on exact head and verify the final IPA still contains all required Anime4K Metal C symbols.

- [ ] **Step 5: Report physical-device test instructions**

Ask for same-clip comparisons with MetalFX off/on (Eco optional), and use the new segment IDs in the returned log. Do not check AKP-17 until performance plus visual acceptance is demonstrated.