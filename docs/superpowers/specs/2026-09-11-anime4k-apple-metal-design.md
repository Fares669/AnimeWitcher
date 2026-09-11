# Anime4K Apple Metal Backend Design

## Goal

Run Anime4K through native Metal compute on iOS and macOS while keeping `media_kit`/libmpv as the playback engine and preserving the existing GLSL path as a safe fallback.

## Constraints

- Keep PR #232 and branch `feat/anime4k-mobile-gpu` as the integration branch.
- Do not replace mpv with AVPlayer; playback formats, network behavior, audio, subtitles, seeking, and player state stay owned by `media_kit`/libmpv.
- Android/Windows/Linux continue using mpv GLSL.
- iOS 15+ and macOS 12+ may use Metal.
- Never run Metal Anime4K and mpv `glsl-shaders` at the same time.
- If Metal setup, shader parsing, compilation, or per-frame processing fails, clear the Metal request and fall back to the existing mpv GLSL chain rather than presenting a no-op state.
- Preserve Apache-2.0 notices for code derived from `imxieyi/Anime4KMetal`; Anime4K GLSL files remain user-downloaded assets and are not bundled.

## Architecture

`media_kit_video` owns the Apple Flutter texture. Its iOS and macOS `TextureHW` implementations render libmpv into a Metal-compatible `CVPixelBuffer` before Flutter asks for that buffer through `copyPixelBuffer()`. AnimeWitcher will patch that exact native source during CocoaPods installation, following the repository's existing controlled plugin-patch pattern, so the patch is version-checked and fails installation if upstream source markers move.

The patch calls a shared `Anime4KMetalRuntime` immediately before the pixel buffer is returned to Flutter. The runtime converts the input `CVPixelBuffer` to an `MTLTexture`, executes Anime4K compute passes, writes to a second Metal-compatible `CVPixelBuffer`, waits for GPU completion for correctness, and returns the processed buffer. A small ring/pool avoids allocating a fresh output buffer every frame.

Dart communicates the requested shader chain to the native code through mpv `user-data/anime4k-metal-*` properties on the same player handle already held by `TextureHW`. This avoids introducing a second global Flutter method channel and keeps configuration scoped to the exact mpv instance being rendered.

## Shader compatibility

The Metal runtime ports the parser/translator concepts from Anime4KMetal's `MPVShader.swift` and execution model from `Anime4K.swift`: `HOOK`, `BIND`, `SAVE`, `WIDTH`, `HEIGHT`, `WHEN`, texture bindings, sampler selection, and multi-pass compute pipelines. It reads the same absolute `.glsl` file paths already resolved by `Anime4kShaderLibrary`, so the existing mode/quality/fallback selection remains the source of truth.

The runtime caches compiled pipelines by ordered shader path list and recompiles only when the selected chain or relevant dimensions change. Invalid or unsupported shader syntax produces a native failure flag that Dart can observe and use to fall back to mpv GLSL.

## Data flow

1. Dart resolves the Anime4K chain as today.
2. On iOS/macOS, Dart writes the ordered paths into `user-data/anime4k-metal-shaders` and enables `user-data/anime4k-metal-enabled`.
3. Dart clears `glsl-shaders` so the frame is not processed twice.
4. libmpv decodes and renders normally into media_kit's `CVPixelBuffer`.
5. Patched `TextureHW.copyPixelBuffer()` invokes `Anime4KMetalRuntime` with its private mpv handle and the rendered buffer.
6. Metal executes the Anime4K chain and returns a processed `CVPixelBuffer` to Flutter.
7. If native Metal processing reports failure, Dart disables Metal and reapplies the original GLSL chain through mpv.

## Failure handling

The CocoaPods patch is marker-checked and idempotent. Native runtime errors never crash playback: they return the original buffer, publish a failure/error string through mpv user-data, and stop attempting Metal until Dart explicitly reconfigures it. Dart checks native status after configuration and on subsequent apply calls; unavailable Metal falls back to GLSL. Turning Anime4K off clears both native Metal configuration and `glsl-shaders`.

## Verification

- Dart tests cover Apple backend preference, desktop/mobile availability, fallback behavior, and prevention of double-processing configuration.
- Swift parser/runtime tests cover representative Anime4K directives and Metal source translation where possible without a live GPU.
- `flutter analyze` and the full Flutter test suite must pass.
- Android build must remain green to prove the Apple-specific integration did not regress GLSL mobile support.
- iOS unsigned and macOS release/debug builds must compile the patched `media_kit_video` source and Metal runtime.
- PR remains draft until all available automated verification is green; real-device performance is still required to quantify frame time and thermal behavior.