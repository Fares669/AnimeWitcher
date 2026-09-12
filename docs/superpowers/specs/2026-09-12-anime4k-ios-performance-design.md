# Anime4K iOS Performance Design

## Goal

Reduce Anime4K GPU load, heat, battery use, and dropped frames on iOS while preserving image quality, keeping manual S/M/L/VL/UL choices deterministic, and adding a separate Apple Eco/Auto mode that may adapt work to runtime conditions.

## Current State

AnimeWitcher currently resolves Anime4K v4.0.1 GLSL pipelines in Dart and applies them through mpv `glsl-shaders`. iOS uses media_kit's libmpv OpenGL ES renderer, which renders into Metal-compatible BGRA `CVPixelBuffer`s. The repository already contains an Anime4K GLSL-to-MSL translator derived from Anime4KMetal, but it does not yet execute a native Metal runtime in the playback path.

## Non-Negotiable Behavior

- Manual quality S/M/L/VL/UL remains fixed. Eco/Auto never silently changes a manual non-Eco selection.
- Apple Eco/Auto is a separate setting available on iOS/macOS only.
- Eco/Auto may reduce work but never change the semantic mode A/B/C/A+A/B+B/C+A; it adapts quality tier, expensive late passes, and processing resolution only.
- Android/Windows/Linux remain on the existing mpv GLSL path unless a later dedicated plan changes them.
- If native Metal setup, shader compilation, synchronization, color correctness, or runtime processing fails, playback must continue using mpv GLSL or unmodified video rather than crash or claim Anime4K is active when it is not.
- Metal and mpv Anime4K must never process the same frame simultaneously.
- iOS minimum remains 15.0 and macOS minimum remains 12.0.

## Performance Strategy

### 1. Correct the shader pipeline before optimizing the backend

Anime4K's own optimized configurations insert `Anime4K_AutoDownscalePre_x2.glsl` and `Anime4K_AutoDownscalePre_x4.glsl` between upscale stages so work is not wasted at a resolution larger than the actual output needs. AnimeWitcher's current resolver omits those passes. The resolver will add them where the official v4.0.1 optimized pipelines use them.

Repeated CNN stages will become stage-aware: later passes after an x2 upscale use a lower network size intentionally instead of only choosing another unused filename. The manual selected quality remains the first-stage ceiling.

### 2. Baseline and observability first

Before changing native rendering, add deterministic performance telemetry interfaces for:

- backend (`mpv-glsl`, `metal`, `metal-eco`)
- requested mode and quality
- effective quality
- input and processing dimensions
- average and p95 Anime4K frame time
- processed frame count and skipped duplicate frame count
- dropped/late frame count when available
- thermal state
- Low Power Mode state

Telemetry is debug/diagnostic state, not analytics upload.

### 3. Execute native Metal in the render path

The native Metal runtime will be called as part of media_kit's Apple render path after libmpv has rendered a new frame and before that frame is published as ready to Flutter. It will not run from `copyPixelBuffer()` because Flutter may request the same current buffer multiple times. This guarantees at most one Anime4K execution per produced video frame.

The integration remains marker/version checked. If the upstream `media_kit_video` source structure changes, CocoaPods setup fails loudly rather than silently producing an unprocessed image.

### 4. Asynchronous GPU pipeline, no per-frame blocking wait

Do not use `waitUntilCompleted()` in the steady-state render loop. Maintain a bounded ring of output buffers and command buffers. Each frame may be in flight until its completion handler marks its resources reusable. If no output slot is available, skip Anime4K for that frame or keep the most recent completed processed frame according to the render contract; never block the UI/main thread indefinitely.

### 5. GL ES to Metal synchronization and lifetime safety

Input `CVPixelBuffer`s are Metal-compatible IOSurfaces. The runtime creates Metal textures with `CVMetalTextureCache`, preserves the source buffer until Metal has finished reading it, and preserves output buffers until Flutter is done with the published frame. Synchronization must be proven without adding a blanket `glFinish()` to every frame. Buffer ownership is explicit so media_kit cannot recycle a surface still in use by Metal.

### 6. Mixed FP16 compute

The existing translator emits float32 vectors and sampled textures. Add a precision policy that uses `half`/`half2`/`half3`/`half4` for CNN weights, sampled colors, and safe intermediate math while retaining float32 for coordinates, size calculations, and numerically sensitive accumulations. The exact output must be compared against float32 within a defined tolerance before enabling FP16 by default.

### 7. Reuse textures and compiled pipelines

Intermediate textures are allocated per pipeline/dimension configuration, not per frame. Recompile only when shader list or relevant dimensions change. Cache `MTLComputePipelineState` objects and use a stable cache key derived from shader content hashes plus precision mode. Explore `MTLBinaryArchive` only after the primary runtime is correct; it is an optimization, not a dependency.

### 8. Resolution-aware processing

Never run Anime4K at a resolution materially above the player output when the extra pixels will immediately be downscaled. Processing dimensions derive from source aspect ratio and actual drawable/video output size. Manual mode keeps its selected quality but avoids pointless oversized intermediate work. Eco/Auto may be more aggressive about capping processing dimensions.

### 9. Apple Eco/Auto policy

Eco/Auto uses the manual selected mode and selected quality as intent. It may step down the effective quality and late-stage work using hysteresis based on:

- rolling Anime4K GPU/frame time relative to the video frame budget
- `ProcessInfo.thermalState`
- Low Power Mode
- sustained dropped/late frames

Suggested initial policy:

- nominal thermal, sufficient headroom: requested quality
- pressure or fair thermal: one tier lower
- serious thermal or repeated misses: S and reduced late-stage work
- critical thermal: temporarily bypass Anime4K until recovery
- Low Power Mode: cap at S in Eco/Auto

Transitions require sustained evidence and cooldown windows to prevent oscillation.

### 10. Frame deduplication

Anime4K runs only for a newly produced video frame. Display refreshes at 60/120 Hz must not re-run Anime4K for a 24/30 fps source. Use render production identity/timestamp or buffer generation identity, not wall-clock guessing.

### 11. Color and HDR correctness

The Metal backend must preserve SDR color and must not silently damage HDR. Add representative image tests where possible and device-level validation for SDR/HDR. If HDR correctness cannot be guaranteed on the native path, fall back to mpv GLSL for HDR content until a correct path is implemented.

### 12. Preview optimization

The settings preview currently creates a second media_kit player and keeps a still image active. Replace that on Apple with a one-shot processed image cache where practical so opening settings does not continuously consume decode/render resources. The preview must use the same effective pipeline logic as playback.

### 13. Shader library integrity

Keep Anime4K pinned to v4.0.1. Download into a temporary directory, verify the expected manifest/content hashes, then atomically replace the active shader directory. Cache a manifest of filenames and hashes so pipeline resolution and Metal cache keys do not repeatedly scan the filesystem.

### 14. MetalFX experiment

After the native Metal Anime4K path is stable, benchmark an optional Eco variant that uses Anime4K restore/denoise followed by MetalFX spatial scaling instead of all Anime4K upscale passes. Keep it experimental until objective quality and frame-time measurements show a benefit.

### 15. Verification

Every implementation item follows TDD where testable. Required automated gates before completion:

- focused Anime4K Dart tests
- full Flutter test suite
- `flutter analyze`
- native Swift translator/runtime tests
- full v4.0.1 shader corpus translation/Metal compilation checks on Apple CI
- Android build unchanged and green
- iOS unsigned release build green
- macOS release build green

Physical-device acceptance on at least one iPhone/iPad is required for claiming performance improvement. Report baseline vs optimized average/p95 processing time, dropped frames, thermal behavior, and effective processing resolution. CI build success alone is not performance proof.
