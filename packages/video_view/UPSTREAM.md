# Vendored video_view

Based on the published [video_view 1.3.3](https://pub.dev/packages/video_view/versions/1.3.3)
release, upgraded from 1.3.1 on 2026-10-17. Source and license remain upstream's.

Official archive provenance (SHA-256):

- [1.3.1 archive](https://pub.dev/api/archives/video_view-1.3.1.tar.gz):
  `29a839b531651fca7297fff73b4a39a2ff10938c39ade282f83890fdd2903639`
- [1.3.3 archive](https://pub.dev/api/archives/video_view-1.3.3.tar.gz):
  `b04f0cb9fc41a34692dbf35eae054ee34c02ed1529905b35eb8f89ca5dd9a108`

## Upgrade method

Three-way compared published 1.3.1, the existing vendored tree, and published
1.3.3, normalizing CRLF only while comparing text. Applied upstream changes to
runtime sources, package metadata, and documentation. Unrelated upstream
example-project changes were omitted. Preserved
local file omissions, ignore files, line endings, example CocoaPods includes,
and the example web plugin's relative symlink. The example remains on the
existing project configuration.

## AnimeWitcher customizations retained

- Dart API: request headers, ClearKey parameters, external subtitle configuration,
  live/seekable metadata, updated live durations, and observable orientation.
- Dart lifecycle: cancel native events before disposing property notifiers.
- Android: authenticated media requests, ClearKey and subtitle media sources,
  playback buffering/retry behavior, and live/seekable timeline metadata.
- Apple: authenticated requests, native buffering/retries, live/seekable metadata,
  background playback, and teardown cleanup. External subtitle merging remains
  unsupported by the Apple backend, as before.
- Windows: authenticated requests, network retries and exception handling,
  live/seekable metadata, live-range position normalization and buffer updates.
- Linux: live/seekable metadata and the existing `openWithSubtitles` dispatch alias.
- Native widget: orientation notifications retain their existing API and behavior.

Two overlapping upstream changes were merged explicitly:

1. Wrapped the entire customized Dart native event handler in upstream's
   `!disposed` check, preserving its existing payload handling.
2. Combined Windows playback-state checks with local retries, exception handling,
   and live buffering. Retained the local guarded `loadEnd()` implementation and
   its live-duration metadata. The stale `MediaFailed` check runs before retry
   dispatch, leaving local `sendError()` usable by caught load and manifest
   failures. Added upstream's UTF-8 local/asset path decoding.

## Compatibility boundaries

The plugin still requires Dart >=3.10 and Flutter >=3.38; Java 17; iOS 15 and
macOS 12. Media3 is pinned to stable `1.11.1`; public API descriptors for the plugin-used
classes were compared against `1.10.1` and no called API was removed. The SwiftPM
manifest now declares upstream's local FlutterFramework dependency; the app's
existing CocoaPods-only configuration is unchanged.

For future upgrades, repeat the three-way comparison rather than replacing this
directory with an unpatched upstream archive. Review destruction/seek callbacks,
headers/DRM/subtitle payloads, live duration and seek ranges, and platform retries.
Native platform builds and playback smoke tests are still required to validate
platform behavior; source comparison alone cannot establish runtime correctness.
