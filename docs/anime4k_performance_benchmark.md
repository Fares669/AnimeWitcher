# Anime4K Apple Performance Benchmark Evidence

> **PENDING — the final controlled physical-hardware matrix is not complete yet.** Supplementary iPhone validation already confirms that the native Apple Metal route can become active. Do not claim performance completion until the required comparisons below are measured on a physical Apple device and tied to the exact commit that was tested.

This document records the remaining AKP-15 physical color acceptance and AKP-18 final benchmark evidence. CI can prove compilation, shader-corpus validity, routing contracts, native runtime behavior, and telemetry plumbing, but it cannot substitute for visual and sustained-performance acceptance on real Apple hardware.

## Test identity

- Physical Apple device: **PENDING**
- Apple SoC / GPU: **PENDING**
- OS version: **PENDING**
- exact commit: **PENDING**
- App build/configuration: **PENDING**
- Test clip / source: **PENDING**
- Source resolution and FPS: **PENDING**
- Codec / bit depth: **PENDING**
- SDR or HDR: **PENDING**
- Requested Anime4K mode / quality: **PENDING**
- Effective backend: **PENDING**
- effective dimensions: **PENDING**
- Sample duration / warm-up: **PENDING**
- Low Power Mode: **PENDING**
- Starting thermal state: **PENDING**

## Baseline vs optimized runtime evidence

Use the same physical device, clip, playback position, requested mode/quality, display state, and measurement duration for both rows. Record values from native Anime4K telemetry after warm-up rather than estimating them from UI refresh rate.

| Variant | average Anime4K time | p95 Anime4K time | processed frames | skipped duplicate frames | late/dropped frames | effective dimensions | thermal | Low Power Mode |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Baseline | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| Optimized Apple Metal | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |

### Acceptance notes

- Playback smoothness / cadence: **PENDING**
- Sustained thermal behavior: **PENDING**
- Memory / allocation observations: **PENDING**
- Any fallback or backend transition observed: **PENDING**
- Result: **PENDING**

## SDR correctness

Compare the optimized Apple Metal output with the existing mpv GLSL path using the same SDR frames and requested Anime4K mode/quality.

- SDR source identity: **PENDING**
- Reference frame positions: **PENDING**
- Sharpness / denoise / restore comparison: **PENDING**
- Color / range / transfer appearance: **PENDING**
- Unexpected clipping, banding, or geometry changes: **PENDING**
- Result: **PENDING**

## HDR safety / fallback

The native Anime4K Metal path currently fails closed for HDR or unknown transfer metadata. Verify on a real HDR source that playback follows the exact mpv fallback route without double-processing or visible regressions.

- HDR source identity and metadata: **PENDING**
- Native Metal rejected / bypassed for HDR: **PENDING**
- Exact mpv GLSL fallback restored: **PENDING**
- Visual comparison / tone-mapping behavior: **PENDING**
- Result: **PENDING**

## Retired experiments

**Eco/Auto**, **MetalFX**, and the user-facing **Performance log** were experimental validation features and are retired from shipping scope before merge to `main`.

- Eco/Auto is not a shipping setting; manual S/M/L/VL/UL quality remains deterministic.
- MetalFX is not a shipping setting or runtime dependency. The experiment did not establish a sufficient advantage to justify keeping the adapter/toggle in the product.
- The user-facing JSONL Performance log is removed. Native telemetry primitives remain internal for runtime contracts, diagnostics, profiling, and controlled physical benchmark capture.
- Final benchmark rows must compare the actual shipping baseline and optimized Apple Metal path; they must not present Eco/Auto or MetalFX as shipping variants.

## Evidence rules

1. Record the exact physical device, OS, exact commit, source clip, and requested/effective Anime4K configuration.
2. Capture average Anime4K time and p95 Anime4K time from native telemetry after warm-up.
3. Capture processed frames, skipped duplicate frames, and late/dropped frames over the same measurement window.
4. Record effective dimensions, thermal state changes, and Low Power Mode state for each run.
5. Keep SDR correctness, HDR fallback, and performance measurements separate so a frame-time result cannot hide a visual or routing regression.
6. Leave any unmeasured field as **PENDING**. Never replace missing physical-device evidence with simulator, CI-runner, or inferred values.
7. Do not claim performance completion until both the physical color acceptance and controlled baseline-vs-optimized benchmark are recorded.

Until the required PENDING fields are replaced with real measurements and acceptance observations, AKP-15 and the physical benchmark portion of AKP-18 remain incomplete. AKP-17 is retired experimental work rather than pending shipping work.
