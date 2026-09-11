# Anime4K Apple Metal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a real Metal compute Anime4K backend on iOS/macOS while preserving mpv playback and GLSL fallback.

**Architecture:** Keep libmpv/media_kit as the renderer, patch `media_kit_video`'s Apple `TextureHW.copyPixelBuffer()` at CocoaPods install time, and run a shared Metal post-process runtime on the returned Metal-compatible `CVPixelBuffer`. Configure it per mpv instance through `user-data/anime4k-metal-*`; clear mpv GLSL while Metal is active and fall back to GLSL on any native failure.

**Tech Stack:** Flutter/Dart, media_kit 1.2.6, media_kit_video 2.0.1, Swift 5, CoreVideo, Metal/MetalKit, CocoaPods, libmpv user-data properties.

**Spec:** `docs/superpowers/specs/2026-09-11-anime4k-apple-metal-design.md`

## Global Constraints

- iOS minimum stays 15.0; macOS minimum stays 12.0.
- Android/Windows/Linux keep the existing mpv GLSL pipeline.
- Apple Metal and mpv `glsl-shaders` must never run simultaneously.
- Native failure returns the unmodified video frame and triggers Dart fallback to GLSL.
- CocoaPods patching must be idempotent and fail loudly if media_kit source markers change.
- Preserve Apache-2.0 attribution for code derived from Anime4KMetal.

---

### Task 1: Backend routing contract

**Files:**
- Modify: `test/features/player/anime4k_mobile_gpu_test.dart`
- Modify: `lib/features/player/data/anime4k.dart`

**Interfaces:**
- Consumes: existing platform/backend availability helpers.
- Produces: Apple-aware renderer selection helpers used by the controller.

- [ ] **Step 1: Write the failing test**

Add assertions that the renderer capability accepts the explicit native Metal marker and that Apple-native playback is eligible while adaptive playback remains ineligible.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/player/anime4k_mobile_gpu_test.dart`
Expected: assertion failure because `anime4kGpuRendererSupportsShaders('metal')` is currently false.

- [ ] **Step 3: Write minimal implementation**

Teach the renderer capability helper about the native Metal marker without changing non-Apple GLSL semantics.

- [ ] **Step 4: Run test to verify it passes**

Run the focused test, then `flutter test test/features/player/anime4k_test.dart`.

- [ ] **Step 5: Commit**

Commit message: `test: define Anime4K Metal backend contract`

### Task 2: Native Metal runtime source

**Files:**
- Create: `native/anime4k_metal/Anime4KMetalRuntime.swift`
- Create: `native/anime4k_metal/NOTICE`
- Create: `native/anime4k_metal/README.md`

**Interfaces:**
- Consumes: a `CVPixelBuffer`, mpv handle, ordered shader path list, output dimensions.
- Produces: `process(pixelBuffer:handle:) -> Unmanaged<CVPixelBuffer>?` semantics for the patched texture layer plus status/error values through mpv user-data.

- [ ] **Step 1: Add parser-focused failing verification fixture**

Add a deterministic debug/self-test entry in the runtime that parses representative Anime4K directives (`DESC`, `HOOK`, `BIND`, `SAVE`, `WIDTH`, `HEIGHT`, `WHEN`) and returns an error for malformed directives.

- [ ] **Step 2: Verify RED through an Apple compile/test workflow**

Use the PR's Apple build workflow before implementation; expected failure is missing runtime symbols referenced by the test harness/patch fixture.

- [ ] **Step 3: Implement minimal runtime**

Port Anime4KMetal's parser/GLSL-to-MSL translation and compute execution with Apache-2.0 attribution. Use `CVMetalTextureCache`, `MTLCommandQueue`, `MTLComputePipelineState`, reusable output buffers, and synchronous command-buffer completion before returning a processed pixel buffer.

- [ ] **Step 4: Add runtime safety**

Cache pipelines by ordered shader paths/dimensions; stop retrying after a failure until configuration changes; write `user-data/anime4k-metal-status` and `user-data/anime4k-metal-error`; return the original buffer when disabled or failed.

- [ ] **Step 5: Verify GREEN**

Compile iOS and macOS plugin-patched builds. Confirm no Swift warnings/errors introduced by the runtime.

### Task 3: CocoaPods media_kit_video patch integration

**Files:**
- Create: `ios/anime4k_metal_patch.rb`
- Create: `macos/anime4k_metal_patch.rb`
- Modify: `ios/Podfile`
- Modify: `macos/Podfile`

**Interfaces:**
- Consumes: upstream `TextureHW.swift` from media_kit_video 2.0.1 and canonical runtime source.
- Produces: patched `copyPixelBuffer()` that invokes `Anime4KMetalRuntime` on iOS/macOS.

- [ ] **Step 1: Write marker assertions first**

Patch scripts must verify the exact `copyPixelBuffer()` source marker and a custom idempotency marker before editing. A changed upstream file raises an actionable CocoaPods error.

- [ ] **Step 2: Verify RED**

Run `pod install`/Apple build before adding the integration call; expected compile failure is unresolved runtime invocation in the deliberately patched test state.

- [ ] **Step 3: Implement patch**

Copy/append the canonical runtime Swift source into the plugin source file and replace the return path so the original `CVPixelBuffer` is passed through `Anime4KMetalRuntime.shared.process(pixelBuffer:handle:)`.

- [ ] **Step 4: Verify idempotence**

Run pod installation twice in CI/build setup. The second application must detect the marker and make no duplicate edits.

- [ ] **Step 5: Verify platform isolation**

Android build must not consume the Apple patch/runtime files.

### Task 4: Dart controller configuration and fallback

**Files:**
- Modify: `lib/features/player/presentation/player_controller.dart`
- Modify: `test/features/player/anime4k_mobile_gpu_wiring_test.dart`

**Interfaces:**
- Consumes: `Anime4kPipeline.files/value`, mpv platform property API, platform detection.
- Produces: Apple Metal request/fallback logic and non-Apple GLSL behavior.

- [ ] **Step 1: Write failing wiring tests**

Assert that Apple configuration writes `user-data/anime4k-metal-enabled=yes`, sends ordered absolute shader paths, clears `glsl-shaders`, and that a native `failed` status causes Metal disable plus GLSL re-application. Assert Android keeps GLSL without Metal properties.

- [ ] **Step 2: Run test to verify RED**

Run: `flutter test test/features/player/anime4k_mobile_gpu_wiring_test.dart`
Expected: failure because Apple Metal user-data wiring is absent.

- [ ] **Step 3: Implement minimal controller routing**

On iOS/macOS, configure Metal user-data before clearing GLSL. Poll/read native status after configuration/apply points; on `failed`, clear Metal properties and apply the original GLSL chain. `off` clears both backends. Other platforms retain the existing GLSL renderer validation.

- [ ] **Step 4: Verify GREEN**

Run both Anime4K focused test files and existing player tests.

### Task 5: CI/build verification and PR cleanup

**Files:**
- Modify: `.github/workflows/anime4k-platform-build.yml` only if needed for stable verification.
- Modify: PR #232 description.

**Interfaces:**
- Consumes: completed branch.
- Produces: verified draft/ready PR with accurate test evidence.

- [ ] **Step 1: Run static/test verification**

Run `flutter analyze` and full `flutter test` through Actions or existing CI.

- [ ] **Step 2: Run platform builds**

Build Android, iOS unsigned, and macOS. Inspect failed job logs and fix root causes with a new failing regression test where applicable.

- [ ] **Step 3: Review diff**

Check that Apple-only code is isolated, license notices are present, patch markers match media_kit_video 2.0.1, and no workflow/debug artifacts remain.

- [ ] **Step 4: Update PR**

Document Metal architecture, fallback behavior, licensing, and exact verification results. Keep Draft if any required automated check is not green; otherwise mark ready for review.