# Anime4K Performance Improvement Plan

> **Source of truth for the final state of this branch.** A checked item means the implementation decision for that item is complete and its automated verification is present. Physical-device acceptance remains explicitly unchecked where it is still required.

**Branch:** `feat/anime4k-ios-performance`  
**Primary platform:** iOS / Apple GPU  
**Architecture:** `docs/superpowers/specs/2026-09-12-anime4k-ios-performance-design.md`

## Final shipping scope

- Manual S/M/L/VL/UL choices remain deterministic and are never silently changed.
- Semantic modes A/B/C/A+A/B+B/C+A remain unchanged.
- iOS/macOS use the native Metal Anime4K path only when supported and color routing is safe.
- HDR or unknown transfer metadata fails closed to the exact resolved mpv GLSL fallback until a separately validated HDR-native path exists.
- Android/Windows/Linux stay on the mpv GLSL path.
- Metal and mpv Anime4K must never process the same frame simultaneously.
- Native setup/runtime failure must fall back safely; no crash and no fake/no-op success state.
- Saved Anime4K mode/quality is reapplied automatically when a new episode opens; Apple waits for bounded color-metadata readiness before choosing native Metal vs fallback.
- The settings preview is one-shot/cached on Apple and falls back safely when the native preview path is unavailable.
- iOS minimum remains 15.0; macOS minimum remains 12.0.
- TDD/regression coverage is required for testable behavior.

## Retired from shipping scope

The following experiments were useful during validation but are intentionally absent from the final product surface/runtime:

- **Eco/Auto** — evaluated as an adaptive Apple policy, then removed. Manual quality is the shipping behavior.
- **MetalFX** — evaluated experimentally on physical hardware, did not establish a sufficient performance advantage, and its setting/scaler/runtime strategy were removed.
- User-facing **Performance log** — removed with the validation UI. Internal native telemetry remains available for runtime contracts, diagnostics, and controlled benchmarks.

Historical commits/tests may refer to those experiments as development evidence; they are not current product requirements.

---

- [x] **AKP-00 — Audit and architecture definition**
  - Reviewed resolver, downloader/library, player wiring, Apple `media_kit_video` render path, GLSL→MSL translator, buffer ownership, preview path, and CI.
  - Defined the native Metal integration and fail-closed routing architecture.

- [x] **AKP-01 — Telemetry and performance contracts**
  - Added internal backend/performance telemetry contracts used for tests and profiling.
  - Final shipping backend surface is mpv GLSL vs native Metal; retired adaptive-policy UI is not part of the product.

- [x] **AKP-02 — Official AutoDownscale stages**
  - Added the official v4.0.1 AutoDownscale stages and ordering used by supported optimized pipelines.

- [x] **AKP-03 — Stage-aware CNN quality selection**
  - Later CNN stages use deliberate lower-cost tiers after upscaling while respecting the requested manual quality ceiling.

- [x] **AKP-04 — Shader manifest and deterministic cache key**
  - Stable ordered pipeline hashing and cached manifest metadata avoid repeated directory scanning and provide deterministic Metal cache keys.

- [x] **AKP-05 — Atomic and integrity-checked shader download**
  - v4.0.1 extraction is staged, path-safe, duplicate-safe, hash/size checked, and atomically activated with rollback behavior.

- [x] **AKP-06 — Full v4.0.1 GLSL→MSL compatibility verification**
  - Apple CI validates the pinned shader corpus through translation and Metal compilation, including CRLF parser regression coverage.

- [x] **AKP-07 — Native Metal runtime core**
  - Runtime owns Metal device/queue, texture cache, reusable intermediates, output buffers, compiled pipeline cache, and explicit status/error behavior.
  - Steady-state playback has no unconditional `waitUntilCompleted()`.

- [x] **AKP-08 — media_kit Apple render-path integration**
  - Anime4K executes in the produced-frame render path, not Flutter buffer-copy callbacks.
  - CocoaPods patching is marker/version checked and platform-isolated.

- [x] **AKP-09 — Synchronization and buffer lifetime**
  - Source/output surfaces live until GPU/publication completion, with bounded non-blocking in-flight behavior and no blanket per-frame `glFinish()`.

- [x] **AKP-10 — Mixed FP16 Metal path**
  - Safe sampled/CNN/intermediate math uses FP16 while coordinates/dimensions/sensitive operations remain FP32.
  - Both precision policies are corpus-compiled in Apple CI.

- [x] **AKP-11 — Resolution-aware processing and texture reuse**
  - Processing targets respect actual video/output dimensions and avoid unnecessary oversized intermediates.
  - Runtime retargeting follows live CVPixelBuffer dimensions and reuses configuration resources.

- [x] **AKP-12 — Apple backend routing and no-double-processing fallback**
  - Native Metal owns SDR processing only when ready; mpv shaders are cleared while Metal is active.
  - Failure/unavailability/HDR/unknown metadata restores the exact resolved mpv GLSL path.
  - Turning Anime4K off clears both paths.

- [x] **AKP-13 — Adaptive Eco prototype evaluated and retired**
  - Thermal/Low Power/frame-time adaptation was implemented and tested during development.
  - The experiment was removed before shipping; there is no Eco/Auto setting, governor, bypass API, or adaptive product behavior in the final scope.

- [x] **AKP-14 — Frame deduplication**
  - Produced-frame identity prevents 60/120 Hz display refreshes from multiplying Anime4K work for lower-FPS sources.
  - Native counters cover processed/skipped duplicate frames.

- [ ] **AKP-15 — SDR/HDR physical color correctness acceptance**
  - Automated conservative color classification/routing is implemented and covered by tests.
  - Startup waits through transient unknown metadata before applying saved Anime4K settings, while persistent unknown/HDR remains fail-closed.
  - **Remaining gate:** physical SDR visual comparison plus real HDR fallback/tone-mapping comparison documented in `docs/anime4k_apple_color_acceptance.md` / benchmark evidence.

- [x] **AKP-16 — Settings preview one-shot processing**
  - Apple uses a cached native one-shot preview using the same Metal runtime architecture.
  - mpv processed-video capture remains the fallback.
  - ByteData copying is bounded to the actual asset view.

- [x] **AKP-17 — MetalFX experiment evaluated and retired**
  - Physical-device comparison did not demonstrate a sufficient shipping benefit; 1080p→1080p workloads in particular provided no useful spatial-upscale opportunity.
  - The experimental setting, scaler adapter, strategy routing, and related user-facing validation plumbing were removed.
  - MetalFX is not a merge prerequisite or shipping dependency.

- [ ] **AKP-18 — CI modernization and final physical benchmark evidence**
  - CI gates cover Flutter analyze/full tests, native Swift/C API/runtime contracts, shader corpus compilation, Android build, unsigned iOS release build, and macOS release build.
  - Obsolete/temporary branch-specific workflows must not remain in the merge candidate.
  - **Remaining gate:** controlled physical baseline-vs-optimized evidence for average/p95 Anime4K time, processed/skipped/late frames, effective dimensions, thermal state, and Low Power Mode in `docs/anime4k_performance_benchmark.md`.

- [ ] **AKP-19 — Final audit and PR readiness**
  - Review all changed files against this final shipping scope.
  - Confirm Apache/MIT notices and Anime4K attribution remain intact.
  - Confirm no temporary workflows/debug hacks remain.
  - Run/fetch final exact-HEAD CI and resolve every failure.
  - Complete or explicitly waive the remaining physical AKP-15/AKP-18 acceptance before declaring the PR ready to merge.

## Automated merge gate

The exact PR head must pass:

- Flutter analyze and full Flutter tests.
- Native logger/typecheck contracts.
- Dart↔Metal C API tests.
- Full pinned Anime4K v4.0.1 shader corpus translation/Metal compilation.
- Native Metal runtime, telemetry, publication/backpressure, and media_kit patch contracts.
- Android build.
- macOS release build and Anime4K symbol verification.
- unsigned iOS release build and Anime4K C ABI symbol verification.
- repository cleanup contracts, including absence of the temporary one-shot preview workflow.

## Remaining manual gate

Before AKP-19 can be checked without a waiver:

1. Physical SDR visual comparison against the mpv reference path.
2. Physical HDR playback confirming exact safe fallback and acceptable tone mapping/color behavior.
3. Controlled same-device/same-clip baseline-vs-optimized performance capture tied to the exact tested commit.

**Current execution order:** `AKP-15 → AKP-18 physical evidence → AKP-19`.
