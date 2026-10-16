# Pinned media_kit runtime

This directory contains the unchanged runtime, required web asset, package metadata and MIT license from media_kit 1.2.6, except for the small patch below. Screenshots, examples and upstream tests are omitted.

- Source package: https://pub.dev/packages/media_kit/versions/1.2.6
- Upstream repository: https://github.com/media-kit/media-kit
- Published package archive SHA256 (from the original lockfile): ae9e79597500c7ad6083a3c7b7b7544ddabfceacce7ae5c9709b0ec16a5d6643
- Original file checksums: UPSTREAM_SHA256SUMS
- Exact local diff: single-media-open.patch

## Local change

NativePlayer.open uses its existing loadfile branch for every single Media or one-item Playlist. Previously only fd:// entries used this branch; other opens wrote a temporary playlist with asynchronous filesystem calls while holding the process-wide player lock. Stalled DNS lookups share Dart's I/O workers and could block that temporary file, preventing subsequent players and teardown from progressing.

The existing state reset, current media references, playlist events, URI sanitization, argument-vector command, headers/start/end hooks, play/pause behavior and final playlist index assignment are unchanged. Empty and multiple-item playlists retain the upstream loadlist path.

The app pins this path dependency so tests and every platform build execute the same source. Do not replace it with a build-only cache mutation. On upgrade, verify the upstream implementation, preserve or retire this patch, update provenance, and run the native-open and DNS-starvation regressions.
