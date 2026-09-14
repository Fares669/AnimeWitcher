# mpv runtime provenance

AnimeWitcher targets mpv `v0.41.0` with explicit `gpu-next` as the normal renderer and explicit `gpu` as the fallback/A-B path. This document records what each media_kit native package actually supplies today and the smallest boundary AnimeWitcher will replace. A header-only change never counts as a runtime upgrade.

## ios

- Current package boundary: `media_kit_libs_ios_video`.
- Current runtime source: `media-kit/libmpv-darwin-build` release `v0.6.0`.
- Current underlying mpv: `v0.36.0`.
- Evidence: media_kit's iOS video Makefile downloads `libmpv-xcframeworks_v0.6.0_ios-universal-video-default.tar.gz` and verifies its SHA-256; the current `libmpv-darwin-build` dependency lock still pins mpv `0.36.0`.
- Replacement strategy: `runtime-overlay` at the resolved `media_kit_libs_ios_video/ios/Makefile` archive URL/checksum boundary.
- Target: an immutable iOS XCFramework archive built from mpv `v0.41.0`, verified before CocoaPods consumes it, followed atomically by activation of the vendored v0.41.0 libmpv headers.
- Reason for not forking media_kit: its Dart/native API can stay unchanged; only the native binary source needs replacement.

## macos

- Current package boundary: `media_kit_libs_macos_video`.
- Current runtime source: `media-kit/libmpv-darwin-build` release `v0.6.0`.
- Current underlying mpv: `v0.36.0`.
- Evidence: media_kit's macOS video Makefile downloads the v0.6.0 universal video XCFramework and verifies its SHA-256; the Darwin build lock pins mpv `0.36.0`.
- Replacement strategy: `runtime-overlay` at the resolved `media_kit_libs_macos_video/macos/Makefile` archive URL/checksum boundary.
- Target: an immutable macOS XCFramework archive built from mpv `v0.41.0`, with matching v0.41.0 headers and the existing Anime4K/media_kit patch contract preserved.

## android

- Current package boundary: `media_kit_libs_android_video/android/build.gradle`.
- Current runtime source: `media-kit/libmpv-android-video-build` release `v1.1.7`.
- Current underlying mpv: commit `78d43740f52db817d98bcf24fb30a76ab6fa13ff` from that build's `buildscripts/include/depinfo.sh`.
- Evidence: media_kit downloads four architecture JARs (`arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86`) from release v1.1.7 and validates their MD5 values before copying them into the plugin output.
- Replacement strategy: `runtime-overlay` at that JAR URL/hash list. Keep the existing Java/Flutter package API and replace only the native JAR artifacts with reproducibly pinned mpv v0.41.0 builds.
- Compatibility requirement: retain the Android-specific `mpv_lavc_set_java_vm` integration expected by media_kit or update the native helper in the same platform commit if mpv 0.41 requires a different patch.

## windows

- Current package boundary: `media_kit_libs_windows_video/windows/CMakeLists.txt`.
- Current runtime source: media_kit's `libmpv-win32-video-cmake` snapshot `20241021`.
- Current underlying mpv: commit `0f7858451817c5fd5ebdb74a807a7c997662c390` (archive names abbreviate it as `0f78584`).
- Evidence: the package CMake file selects x64/arm64 archives, validates their MD5, extracts them into `libmpv`, and bundles `libmpv-2.dll` from that directory.
- Replacement strategy: `runtime-overlay` at the `LIBMPV` archive URL/hash boundary. Preserve ANGLE and the media_kit CMake API; replace only the libmpv archive with a stable v0.41.0 build and verify the bundled DLL before declaring Windows upgraded.

## Upgrade rule

Every platform remains `pending` until the package or binary that is actually bundled reports/proves mpv `v0.41.0`. The `third_party/mpv/v0.41.0` headers are staged and integrity-checked now, but Apple continues to use the v0.36 headers until the Darwin runtime switch occurs atomically. Renderer rollout is similarly explicit: `gpu-next` is the target normal path under mpv 0.41, while `gpu` remains available for rollback and comparison rather than being silently selected.
