# Pinned media_kit runtime

This directory contains the runtime, package metadata and MIT license from media_kit 1.2.6 with the local changes below. Screenshots, examples and upstream tests are omitted.

- Source package: https://pub.dev/packages/media_kit/versions/1.2.6
- Upstream repository: https://github.com/media-kit/media-kit
- Published package archive SHA256 (from the original lockfile): ae9e79597500c7ad6083a3c7b7b7544ddabfceacce7ae5c9709b0ec16a5d6643
- Original file checksums: UPSTREAM_SHA256SUMS
- Exact local diff: single-media-open.patch

## Android libraries

`packages/media_kit_libs_android_video` keeps the Java plugin and license from [media_kit_libs_android_video 1.3.8](https://pub.dev/packages/media_kit_libs_android_video/versions/1.3.8). Its Gradle task fetches the [media-kit Android v1.1.11 JARs](https://github.com/media-kit/libmpv-android-video-build/releases/tag/v1.1.11) and verifies their release SHA-256 checksums. All four `libmediakitandroidhelper.so` binaries are byte-identical to v1.1.7, and the new `libmpv.so` binaries retain the previous exports.

## Native single-media open

NativePlayer.open uses its existing loadfile branch for every single Media or one-item Playlist. Previously only fd:// entries used this branch; other opens wrote a temporary playlist with asynchronous filesystem calls while holding the process-wide player lock. Stalled DNS lookups share Dart's I/O workers and could block that temporary file, preventing subsequent players and teardown from progressing.

The existing state reset, current media references, playlist events, URI sanitization, argument-vector command, headers/start/end hooks, play/pause behavior and final playlist index assignment are unchanged. Empty and multiple-item playlists retain the upstream loadlist path.

The app pins this path dependency so tests and every platform build execute the same source. Do not replace it with a build-only cache mutation. On upgrade, verify the upstream implementation, preserve or retire this patch, update provenance, and run the native-open and DNS-starvation regressions.

## Web HLS

The bundled asset is `dist/hls.min.js` from the [HLS.js 1.7.4 npm archive](https://registry.npmjs.org/hls.js/-/hls.js-1.7.4.tgz). The asset's SHA-256 is `cfc70cc9e9fc63d071919e087670abc760c8fd1bc889b88588026e4d22193bbe`. Its upstream license ships beside it as `assets/web/HLS-LICENSE`.

## Apple frameworks

CocoaPods uses the [media-kit Darwin v0.7.3 video bundles](https://github.com/media-kit/libmpv-darwin-build/releases/tag/v0.7.3) through `scripts/media_kit_apple_frameworks.rb`. Both bundles still contain mpv 0.36.0 and the four headers used by the native rendering integration match the vendored copies byte for byte.
