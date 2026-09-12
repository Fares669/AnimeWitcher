# Anime4K Apple Performance Benchmark Evidence

> **PENDING — physical hardware evidence has not been collected yet.** Do not claim performance completion until every required comparison below has been measured on a Physical Apple device and recorded against the exact commit that was tested.

This document is the reproducible evidence record for AKP-15, AKP-17, and AKP-18. CI can prove compilation, shader-corpus validity, routing contracts, and telemetry plumbing, but it cannot substitute for visual and performance acceptance on real Apple hardware.

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

Use the same device, clip, playback position, requested mode/quality, display state, and measurement duration for both rows. Record values from the native Anime4K telemetry rather than estimating them from UI refresh rate.

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

The native Anime4K Metal path currently fails closed for HDR or unknown transfer metadata. Verify that real HDR playback follows the exact fallback route without double-processing or visible regressions.

- HDR source identity and metadata: **PENDING**
- Native route rejected as unsupported HDR: **PENDING**
- Exact mpv GLSL fallback restored: **PENDING**
- Visual comparison / tone-mapping behavior: **PENDING**
- Result: **PENDING**

## MetalFX hidden experiment

MetalFX is an experimental Eco-only benchmark strategy and is not the default. Compare it with the full Anime4K Apple Metal strategy on the same physical device and clip. The experiment must not be promoted based on CI or simulator results alone.

| Variant | average Anime4K time | p95 Anime4K time | processed frames | skipped duplicate frames | late/dropped frames | effective dimensions | thermal | Low Power Mode | Visual result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Full Anime4K | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |
| MetalFX experiment | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING | PENDING |

- MetalFX capability supported on tested hardware: **PENDING**
- MetalFX performance delta: **PENDING**
- MetalFX visual delta: **PENDING**
- Recommendation: **PENDING**

## Evidence rules

1. Record the exact device, OS, exact commit, source clip, and requested/effective Anime4K configuration.
2. Capture average Anime4K time and p95 Anime4K time from native telemetry after warm-up.
3. Capture processed frames, skipped duplicate frames, and late/dropped frames over the same measurement window.
4. Record effective dimensions, thermal state changes, and Low Power Mode state for each run.
5. Keep SDR correctness, HDR fallback, and MetalFX comparisons separate so a performance gain cannot hide a visual or routing regression.
6. Leave any unmeasured field as **PENDING**. Never replace missing physical-device evidence with simulator, CI-runner, or inferred values.

Until the PENDING fields required by the plan are replaced with real measurements and acceptance observations, AKP-15, AKP-17, and the physical benchmark portion of AKP-18 remain incomplete.
