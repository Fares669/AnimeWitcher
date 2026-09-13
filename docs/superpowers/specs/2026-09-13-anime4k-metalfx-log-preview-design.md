# Anime4K MetalFX, benchmark log, and preview design

**Date:** 2026-09-13

## Goal

Make the current Apple Anime4K validation UI usable on a physical iPhone by exposing MetalFX directly under Eco/Auto, making the benchmark log compare setting changes inside one session, and repairing the still-image preview.

## Approved behavior

### MetalFX

- Add an Apple-only `MetalFX (experimental)` switch immediately under `Eco / Auto` in the Anime4K dialog.
- MetalFX is independent from Eco. The user may enable MetalFX with Eco either on or off.
- Persist the setting separately from Anime4K enabled/mode/quality/Eco.
- Default is off.
- Enabling/disabling MetalFX reapplies the active Anime4K pipeline immediately.
- Native capability checks remain authoritative. Unsupported MetalFX must fail safely rather than pretending the strategy is active.
- This remains experimental until AKP-17 physical-device performance and visual acceptance are complete.

### Performance log

- Keep one JSONL file for one `Anime4kPerformanceLog` service lifetime; setting changes must not create a new file.
- Add explicit configuration segments. A segment changes when any of these user-controlled values changes: enabled, mode, requested quality, Eco, MetalFX.
- Emit `segmentStart` and `segmentEnd` events with a monotonically increasing `segmentId`.
- Route and snapshot events carry the active `segmentId`.
- `segmentEnd` records duration and the latest available benchmark snapshot (avg/p95 frame time, processed/skipped/dropped counters, dimensions, thermal state, Low Power Mode) so later benchmark extraction does not have to infer boundaries.
- Disabled Anime4K is a real segment, not an absence of logging.

### Sample preview

- Continue using a short-lived mpv renderer rather than rasterizing Flutter's external texture.
- Apply the selected Anime4K GLSL pipeline before capture.
- Capture mpv's processed **video** frame (`screenshot-to-file ... video`) instead of the external output/window. `window` is not reliable with iOS/macOS external textures.
- Cache the resulting bytes and dispose the temporary player immediately after the one-shot capture.
- Keep the friendly UI error, but retain the concrete capture error in debug diagnostics.

## Constraints

- iOS 15.0 and macOS 12.0 minimums do not change.
- Android/Windows/Linux remain on the existing mpv path.
- No double-processing: Metal and mpv Anime4K must never process the same playback frame simultaneously.
- Existing manual S/M/L/VL/UL behavior remains deterministic.
- Do not mark AKP-17 complete until physical-device timing and visual comparison pass.
- TDD: each behavior change gets a failing regression test before production changes.