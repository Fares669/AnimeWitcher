# Anime4K iOS Performance Design

## Status

This document describes the final architecture of `feat/anime4k-ios-performance` after implementation and physical-device experimentation. Development-only Eco/Auto, MetalFX, and user-facing benchmark-log experiments are intentionally not part of the shipping design.

## Goal

Reduce Anime4K GPU overhead and duplicated work on Apple platforms while preserving deterministic manual quality, image correctness, safe fallback behavior, and compatibility with the existing non-Apple mpv GLSL path.

## Final product behavior

- Manual S/M/L/VL/UL quality is deterministic and never silently adapted.
- Existing semantic modes A/B/C/A+A/B+B/C+A remain unchanged.
- iOS/macOS may use the native Metal Anime4K backend for supported SDR playback.
- HDR or unknown transfer metadata fails closed to the exact resolved mpv GLSL pipeline until a separately validated native HDR path exists.
- Android/Windows/Linux continue to use mpv GLSL.
- Metal and mpv Anime4K never process the same frame at the same time.
- Native setup, shader compilation, synchronization, or runtime failure never crashes playback and never reports fake success; the controller restores the safe fallback path.
- A saved Anime4K selection applies automatically when an episode opens. On Apple, the controller waits for bounded color-metadata readiness before deciding native Metal vs fallback.
- iOS minimum remains 15.0 and macOS minimum remains 12.0.

## Architecture

### 1. Resolver and shader integrity

Anime4K remains pinned to v4.0.1. The resolver includes the official `Anime4K_AutoDownscalePre_x2.glsl` and `Anime4K_AutoDownscalePre_x4.glsl` stages where appropriate and uses stage-aware CNN quality selection so later high-resolution passes do not accidentally inherit unnecessary cost.

Shader installation is staged into a temporary directory, validates the expected filename/size/SHA-256 manifest, rejects unsafe paths and duplicate normalized names, and atomically replaces the active directory only after validation succeeds. A deterministic ordered pipeline hash feeds the native pipeline cache.

### 2. Native Metal render-path integration

On Apple platforms, the native runtime is integrated into media_kit's produced-frame render path after libmpv creates a new frame and before that frame is published to Flutter. It does not run from a Flutter buffer-copy callback, so display refreshes cannot cause repeated Anime4K processing of the same video frame.

The CocoaPods integration is marker/version checked and fails loudly if upstream `media_kit_video` source structure drifts beyond the supported patch contract.

### 3. GPU synchronization and lifetime

The runtime owns its Metal device/queue, `CVMetalTextureCache`, compiled pipeline cache, reusable intermediate textures, output resources, and bounded in-flight slots.

Input `CVPixelBuffer`/IOSurface resources remain alive until Metal completes its reads. Publication ownership remains bounded until the processed destination is safe to expose/reuse. Steady-state playback does not call `waitUntilCompleted()`, and the integration avoids a blanket per-frame `glFinish()`.

When bounded resources are exhausted, the path follows an explicit non-blocking fallback/publication policy rather than indefinitely blocking the player or UI thread.

### 4. One execution per produced video frame

A produced-frame identity/generation registry prevents Anime4K from running again when Flutter or the display redraws the same source frame. A 24/30 fps source therefore does not multiply processing simply because the display refreshes at 60/120 Hz.

Native telemetry retains processed/skipped/late counters so this behavior remains testable and measurable without exposing a user-facing logging feature.

### 5. Mixed FP16 compute

Safe sampled colors, CNN/intermediate values, and suitable arithmetic use FP16. Coordinates, dimensions, and numerically sensitive operations remain FP32. Apple CI compiles the pinned shader corpus under the supported precision policies and regression tests preserve the translator contract.

### 6. Resolution-aware processing and cache reuse

Processing dimensions follow source aspect ratio and real output/live buffer dimensions rather than allocating unnecessarily large intermediate surfaces. Compiled pipelines and textures are rebuilt only when relevant shader/dimension/precision inputs change.

The active native runtime can retarget to live `CVPixelBuffer` dimensions when player/drawable metadata is stale or changes during playback.

### 7. No-double-processing backend routing

Dart resolves the exact Anime4K GLSL pipeline first. On iOS/macOS, native Metal is configured only when Apple routing is eligible and SDR color metadata is known.

- Native Metal ready: clear mpv `glsl-shaders`, then native Metal owns Anime4K.
- Native unavailable/failed: disable native processing and restore the exact resolved mpv GLSL pipeline.
- HDR/unknown metadata: keep native Metal disabled and use the exact mpv fallback.
- Anime4K disabled: clear/disable both processing paths.

The route never intentionally processes a frame through both Anime4K implementations.

### 8. Color metadata readiness and startup behavior

A new media item can expose `video-params/gamma`/color metadata slightly after `Player.open()` returns. The Apple wrapper therefore performs bounded retries for metadata readiness before making the native/fallback decision.

Known SDR can enter native Metal. Known HDR returns immediately to fallback. Metadata that remains unknown after the bounded window also fails closed. This makes the saved Anime4K mode take effect on episode open without weakening HDR safety.

### 9. Settings preview

The Apple settings preview processes the bundled sample as a one-shot native Metal image and caches the result by mode, quality, effective backend, and shader hash. It does not keep a second playback renderer running continuously.

If native preview processing is unavailable, the existing mpv fallback applies the selected GLSL pipeline and captures the processed `video` frame rather than the external window/Flutter texture. Temporary players are disposed after capture.

### 10. Internal telemetry

Native telemetry is retained as an engineering/runtime contract: average/p95 Anime4K time, processed/skipped/late frames, active dimensions, thermal state, and Low Power Mode can be sampled for tests and controlled physical benchmarks.

It is not an analytics upload and there is no shipping user-facing performance-log UI.

## Retired experiments

### Eco/Auto

An adaptive quality/thermal prototype was implemented and tested during development. It was later removed from the shipping scope. Final manual quality does not change automatically based on thermal state, frame time, or Low Power Mode.

### MetalFX

An optional MetalFX spatial-upscale path was implemented and compared on physical hardware. It did not demonstrate a sufficient advantage for the tested workload to justify product/runtime complexity, so the MetalFX toggle, scaler adapter, and strategy routing were removed before merge.

### User-facing Performance log

The temporary JSONL benchmark/logging surface used during device investigation was removed. Internal native telemetry remains because it is useful for runtime validation and controlled benchmark capture.

## Verification and acceptance

Automated merge gates require:

- `flutter analyze` and the full Flutter test suite.
- Dart↔Metal C API tests.
- native runtime/telemetry/backpressure/publication tests.
- full pinned Anime4K v4.0.1 GLSL→MSL corpus compilation on Apple CI.
- media_kit patch-contract tests.
- Android build.
- unsigned iOS release build plus Anime4K C ABI symbol verification.
- macOS release build plus Anime4K symbol verification.
- no temporary branch-only validation workflows left in the merge candidate.

Physical-device evidence is separate from compilation correctness. Before claiming final performance/color acceptance without a waiver, record representative SDR visual comparison, real HDR fallback behavior, and a controlled baseline-vs-optimized average/p95 benchmark on the exact tested commit. The evidence templates live in `docs/anime4k_apple_color_acceptance.md` and `docs/anime4k_performance_benchmark.md`.
