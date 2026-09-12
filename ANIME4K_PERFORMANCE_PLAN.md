# Anime4K Performance Improvement Plan

> **Source of truth for this branch.** Implement in dependency order. A top-level item changes from `[ ]` to `[x]` only after its implementation and required verification pass. Do not mark partial work complete.

**Branch:** `feat/anime4k-ios-performance`  
**Primary platform:** iOS / Apple GPU  
**Spec:** `docs/superpowers/specs/2026-09-12-anime4k-ios-performance-design.md`

## Global constraints

- Manual S/M/L/VL/UL choices remain deterministic and are never silently changed.
- Apple Eco/Auto is a separate Apple-only mode.
- Eco/Auto may reduce effective quality/work but never changes semantic mode A/B/C/A+A/B+B/C+A.
- Android/Windows/Linux stay on the mpv GLSL path.
- Metal and mpv Anime4K must never process the same frame simultaneously.
- Native failure must fall back safely; no crash and no fake/no-op success state.
- iOS minimum remains 15.0; macOS minimum remains 12.0.
- TDD for testable behavior; regression tests for every bug found.
- Every completed item must leave focused tests green before `[x]` is set.

---

- [x] **AKP-00 — Final audit and architecture definition**
  - Reviewed current Anime4K resolver, shader downloader/library, settings, preview, player wiring, existing GLSL→MSL translator, iOS `media_kit_video` render path, and Apple buffer ownership model.
  - Identified missing official `Anime4K_AutoDownscalePre_x2.glsl` / `Anime4K_AutoDownscalePre_x4.glsl` stages, need for stage-aware CNN sizing, render-path Metal integration, asynchronous GPU buffering, FP16, color/HDR validation, frame deduplication, preview optimization, manifest integrity, and CI cleanup.
  - Design committed at `docs/superpowers/specs/2026-09-12-anime4k-ios-performance-design.md`.

- [x] **AKP-01 — Performance policy and telemetry contract**
  - Files:
    - Create `lib/features/player/data/anime4k_performance.dart`
    - Create `test/features/player/anime4k_performance_test.dart`
  - Add pure Dart types:
    - `Anime4kBackend { mpvGlsl, metal, metalEco }`
    - `Anime4kThermalLevel { nominal, fair, serious, critical }`
    - immutable `Anime4kPerformanceSnapshot`
    - immutable `Anime4kEffectivePlan`
  - Add a pure policy function that takes requested quality/mode, thermal level, Low Power Mode, rolling frame time, and video frame budget and returns an effective quality/work level.
  - Manual/non-Eco mode must return requested quality unchanged.
  - Eco policy uses hysteresis-friendly inputs and never raises above requested quality.
  - RED: tests fail before the new policy exists.
  - GREEN: focused performance-policy tests pass.
  - Verification: Flutter Checks run `34678445629` passed Analyze, full Test, and native logger typecheck on commit `2337a6a`.

- [x] **AKP-02 — Official AutoDownscale stages in the resolver**
  - Files:
    - Modify `lib/features/player/data/anime4k.dart`
    - Modify `test/features/player/anime4k_test.dart`
  - Add `_Family.autoDownscalePreX2` and `_Family.autoDownscalePreX4` mapped to the exact v4.0.1 filenames.
  - Match Anime4K's optimized pipeline ordering for A/B/C and doubled modes where applicable.
  - AutoDownscale stages are optional degradation-safe steps: if absent, the resolver reports them distinctly but does not destroy an otherwise usable pipeline.
  - RED: tests assert official fast pipeline ordering and fail first.
  - GREEN: all existing resolver tests plus new ordering tests pass.
  - Verification: Flutter Checks run `34679101325` passed Analyze, full Test, and native logger typecheck on commit `af0557f7`.

- [x] **AKP-03 — Stage-aware CNN quality selection**
  - Files:
    - Modify `lib/features/player/data/anime4k.dart`
    - Modify `test/features/player/anime4k_test.dart`
  - Replace the current collision-driven repeated-pass quality choice with explicit stage-cost selection.
  - The first CNN stage uses requested quality when present.
  - CNN stages after an x2 upscale intentionally step down by up to two quality tiers, bounded by S and available files.
  - Manual quality remains the ceiling; no stage may use a quality above the requested one merely because that file exists.
  - Preserve the one-use-per-shader rule.
  - RED/GREEN tests cover S/M/L/VL/UL for A, A+A, B+B, C+A.
  - RED evidence: Flutter Checks run `34679670753` passed Analyze/native typecheck and failed 17 focused stage-quality assertions before implementation.
  - GREEN verification: Flutter Checks run `34680067875` passed Analyze, full Test, and native logger typecheck on commit `83c5c1a`.

- [x] **AKP-04 — Shader manifest and deterministic cache key**
  - Files:
    - Create `lib/features/player/data/anime4k_shader_manifest.dart`
    - Modify `lib/features/player/data/anime4k_shader_library.dart`
    - Create `test/features/player/anime4k_shader_manifest_test.dart`
  - Build a manifest of shader filename + file size + SHA-256.
  - Cache manifest by directory metadata and invalidate when the directory changes.
  - Pipeline resolution consumes the manifest instead of rescanning the directory for every apply/preview.
  - Expose a stable ordered pipeline hash for Metal pipeline-cache keys.
  - RED/GREEN tests cover stable hashes, changed content invalidation, missing directory, and deterministic ordering.
  - Verification: Flutter Checks run `34680484820` passed Analyze, full Test, and native typecheck.

- [x] **AKP-05 — Atomic and integrity-checked Anime4K download**
  - Files:
    - Modify `lib/features/player/data/anime4k_download.dart`
    - Modify/create downloader tests under `test/features/player/`
  - Download/extract into a temporary sibling directory.
  - Preserve safe basename flattening/path rejection and change duplicate normalized filenames from silent first-wins behavior to a hard integrity failure.
  - Validate the expected v4.0.1 shader manifest before activation.
  - Atomically replace the active shader folder only after validation succeeds.
  - A failed/cancelled update leaves the previous shader set untouched.
  - RED/GREEN tests cover corrupt archive, partial archive, duplicate entry, and successful atomic swap.
  - Verification: RED run `34680785075`; GREEN Flutter Checks `34680909065`. Real release verification later corrected three pinned entries to the actual official ZIP bytes and verified all 23 files.

- [x] **AKP-06 — Full v4.0.1 GLSL→MSL compatibility verification**
  - Files:
    - Extend `native/anime4k_metal/Anime4KMetalShaderTests.swift`
    - Add a CI helper script under `scripts/`
  - Test every Anime4K shader family used by AnimeWitcher, not only the current synthetic fixture.
  - Parse actual downloaded/pinned v4.0.1 shader text and compile generated MSL with Metal on Apple CI.
  - Fail closed on unsupported directives/syntax.
  - Keep Apache-2.0 NOTICE intact.
  - Regression: official release AutoDownscale shaders use CRLF; parser now splits with Foundation newline semantics instead of Swift `Character` `\n` splitting.
  - Verification: platform run `34682216965` passed the corpus gate: 23/23 pinned files, 265 generated Metal passes, all 265 compiled by Apple's Metal compiler.

- [x] **AKP-07 — Native Metal runtime core**
  - Files:
    - Create `native/anime4k_metal/Anime4KMetalRuntime.swift`
    - Create native runtime tests/fixtures
  - Runtime owns `MTLDevice`, `MTLCommandQueue`, `CVMetalTextureCache`, compiled pipeline cache, reusable intermediate textures, and output buffer pool.
  - Consume an ordered shader-path/hash configuration plus source/output dimensions.
  - Compile only when pipeline/hash/dimensions/precision change.
  - Return original frame on disabled/failure and publish explicit native status/error.
  - No `waitUntilCompleted()` in steady-state playback.
  - Preserve shader-file boundaries so each mpv shader file feeds its final output as `MAIN` to the next file rather than flattening A+A/B+B semantics.
  - Verification: native runtime contract step passed on platform run `34682216965` after the 265-pass corpus gate.

- [x] **AKP-08 — media_kit Apple render-path integration**
  - Files:
    - Create marker-checked CocoaPods patch integration for iOS/macOS
    - Modify `ios/Podfile`
    - Modify `macos/Podfile`
  - Patch `TextureHW.render()` rather than `copyPixelBuffer()` so one produced video frame receives at most one Anime4K pass.
  - Keep upstream three-buffer ownership semantics.
  - Patch is idempotent and version/marker checked; source drift fails CocoaPods setup loudly.
  - Android build must remain isolated from Apple patch sources.
  - Verification: exact-HEAD platform run `34691927403` passed Android, macOS release, iOS unsigned release, and `media_kit Anime4K render patch contract`.

- [x] **AKP-09 — GL ES/OpenGL ↔ Metal synchronization and buffer lifetime**
  - Files:
    - Modify `Anime4KMetalRuntime.swift`
    - Modify Apple integration patch
  - Retain input `CVPixelBuffer`/IOSurface until Metal finishes reading it.
  - Retain output buffers until Flutter has consumed/published the completed frame.
  - Use completion handlers and bounded in-flight slots.
  - Do not add unconditional per-frame `glFinish()`.
  - When all output slots are busy, use an explicit non-blocking fallback policy instead of stalling indefinitely.
  - Native stress tests exercise rapid resize/configuration changes and pool reuse.
  - Verification: exact-HEAD platform run `34691927403` passed the native runtime contract and media_kit bridge backpressure contract.

- [x] **AKP-10 — Mixed FP16 Metal path**
  - Files:
    - Modify `native/anime4k_metal/Anime4KMetalShader.swift`
    - Extend Swift tests
  - Introduce a precision policy: FP16 for safe sampled color/CNN/intermediate operations; FP32 for coordinates, dimensions, and sensitive accumulations.
  - Keep a debug FP32 reference path.
  - Compare FP16 output against FP32 with defined numerical tolerance before enabling FP16 by default.
  - Compile both policies across the actual supported shader corpus.
  - Verification: exact-HEAD platform run `34691927403` passed the full shader corpus/precision gate for both precision policies.

- [x] **AKP-11 — Resolution-aware processing and texture reuse**
  - Files:
    - Modify Metal runtime and Dart configuration/wiring
  - Determine target processing dimensions from source aspect ratio and actual player output/drawable size.
  - Never allocate 4K intermediates when the visible output is materially smaller.
  - Rebuild reusable textures only when dimensions/pipeline change.
  - Preserve aspect ratio and avoid repeated resize oscillation caused by transient layout values.
  - Tests cover 480p/720p/1080p source to common iPhone/iPad output sizes.
  - Regression: media_kit now retargets the active Metal runtime to the live `CVPixelBuffer` dimensions rather than trusting stale mpv drawable dimensions, and native telemetry carries those live dimensions back to Eco/Dart.
  - Verification: exact-HEAD Flutter Checks `34695838534` passed Analyze/full Test/native logger typecheck, and platform run `34695837180` passed C API, 530-pass corpus, runtime/bridge contracts, and Android/macOS/iOS builds on commit `2e511e93`.

- [x] **AKP-12 — Dart Apple backend routing and no-double-processing fallback**
  - Files:
    - Modify `lib/features/player/presentation/player_controller.dart`
    - Modify player wiring tests
  - Configure Metal through the native per-player contract on iOS/macOS.
  - While Metal is active, clear `glsl-shaders`.
  - If Metal reports failed/unavailable/unsupported-HDR, disable Metal and restore the exact resolved GLSL pipeline.
  - Turning Anime4K off clears both paths.
  - Android/Windows/Linux behavior remains unchanged.
  - Verification: exact-HEAD Flutter Checks `34695838534` passed routing/wiring regressions in the full suite, and platform run `34695837180` passed Android/macOS/iOS builds plus native Metal/C API contracts on commit `2e511e93`.

- [ ] **AKP-13 — Apple Eco/Auto user setting and adaptive policy**
  - Files:
    - Modify `player_settings_provider.dart`
    - Modify Anime4K dialog/settings UI
    - Modify `anime4k_performance.dart`
    - Add settings/policy tests
  - Add a separate Apple-only Eco/Auto toggle/mode.
  - Manual quality remains stored as the user's ceiling.
  - Eco observes rolling Anime4K frame time, frame budget, `ProcessInfo.thermalState`, Low Power Mode, and sustained late/dropped frames.
  - Add hysteresis/cooldown so effective quality does not flap.
  - Critical thermal temporarily bypasses Anime4K; recovery restores progressively.
  - UI shows requested quality and effective quality/backend in diagnostics without misleading the user.

- [ ] **AKP-14 — Frame deduplication**
  - Files:
    - Modify native render integration/runtime
    - Add native tests/counters
  - Assign a produced-frame generation/timestamp identity.
  - Anime4K runs once for a newly produced video frame, not once per Flutter/display refresh.
  - 24/30 fps sources on 60/120 Hz displays must not multiply Anime4K executions.
  - Expose processed/skipped-duplicate counters in the performance snapshot.

- [ ] **AKP-15 — SDR/HDR color correctness gate**
  - Files:
    - Modify native runtime/backend routing
    - Add representative test fixtures and documented device checks
  - Preserve BGRA/color metadata correctly for SDR.
  - Detect HDR/extended-range content conservatively.
  - Until a tested HDR Metal path is proven, route HDR to mpv GLSL rather than silently tone-shifting/clipping it.
  - Device acceptance compares representative SDR and HDR frames against the mpv reference path.

- [ ] **AKP-16 — Settings preview one-shot processing**
  - Files:
    - Modify `anime4k_sample_preview.dart`
    - Add preview behavior tests where practical
  - On Apple Metal-capable path, process the sample as a one-shot/cached image rather than keeping a second video renderer active continuously.
  - Invalidate cache only when mode/quality/effective backend/shader hash changes.
  - Keep existing mpv preview as fallback for unsupported platforms/backend failures.

- [ ] **AKP-17 — MetalFX Eco experiment**
  - Files:
    - Add isolated MetalFX scaler adapter in native Apple runtime
    - Add benchmark toggle hidden behind experimental/debug capability until proven
  - Compare Anime4K full upscale vs Anime4K restore/denoise + MetalFX Spatial.
  - Measure frame time and visual output; do not make default solely because it compiles.
  - Promote only if performance improves without unacceptable image degradation.

- [ ] **AKP-18 — CI modernization and benchmark evidence**
  - Files:
    - Replace/update `.github/workflows/anime4k-platform-build.yml`
    - Add benchmark documentation/results file
  - Remove branch-specific dead trigger tied to `feat/anime4k-mobile-gpu`.
  - CI gates: analyze, full Flutter tests, Swift tests, shader corpus compile, Android build, iOS unsigned release, macOS release.
  - Final physical-device benchmark records baseline vs optimized average/p95 Anime4K time, processed frames, dropped/late frames, effective dimensions, thermal transitions, and Low Power Mode behavior.
  - No claim of performance completion without physical Apple-device evidence.

- [ ] **AKP-19 — Final audit and PR readiness**
  - Review all changes against the spec and this plan.
  - Confirm every completed item has evidence and no item is checked prematurely.
  - Confirm Apache/MIT notices and Anime4K attribution are preserved.
  - Confirm no temporary workflows/debug hacks remain.
  - Run/fetch final CI on the exact PR HEAD and resolve all failures before marking ready.

## Current execution order

`AKP-01 → AKP-02 → AKP-03 → AKP-04 → AKP-05 → AKP-06 → AKP-07 → AKP-08 → AKP-09 → AKP-10 → AKP-11 → AKP-12 → AKP-13 → AKP-14 → AKP-15 → AKP-16 → AKP-17 → AKP-18 → AKP-19`
