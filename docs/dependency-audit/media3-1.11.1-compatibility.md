# Media3 1.11.1 plugin compatibility audit

Date: 2026-10-17 (UTC)

## Recommendation

Pin `packages/video_view/android/build.gradle.kts` to `val media3Version = "1.11.1"`. No Kotlin source migration is required by the audited 1.10.1 → 1.11.1 change. Retain the existing local DRM, headers, external-subtitle, live and seeking patches. The upstream `[1.10,1.11)` range is a version constraint, not evidence of a plugin API incompatibility.

[Official release notes](https://developer.android.com/jetpack/androidx/releases/media3#1.11.1) identify 1.11.1 as the latest stable release, dated September 10, 2026.

## Evidence and scope

Downloaded official Google Maven AARs for versions 1.10.1 and 1.11.1, extracted `classes.jar`, and compared public/protected member names, JVM descriptors, generic signatures, access flags, superclasses and interfaces for the 38 plugin-used API classes listed below. The comparison reads class files directly and does not require an Android SDK. It is a static surface audit, not an Android compilation or runtime playback test.

Across that class set the only removed members are:

- `androidx.media3.common.C.generateAudioSessionIdV21(android.content.Context)`
- `androidx.media3.exoplayer.ExoPlayer.Builder.experimentalAvoidLoadingWhileEnded(boolean)`

Neither name occurs in the local plugin. No other existing public/protected member in the checked classes disappears or changes its checked signature. This covers the plugin’s HTTP headers/timeouts, ClearKey session construction, load control, source creation, track selection, live timeline, playback speed, seeking, surface callbacks, cue delivery and subtitle painting.

The official 1.11 release-note removals concerning metadata retrievers, media extractors, motion-photo metadata, dummy extractor outputs and audio-session generation are not used by this plugin. Audio-sink signature changes also do not apply because the plugin does not implement or subclass an audio sink.

All eight inspected artifacts have the same manifest `minSdk=23` and AAR `minCompileSdk=36` in both versions, including all five directly declared modules. The repository’s `android/build.gradle.kts` sets compileSdk 37, above that requirement. The updated app Kotlin plugin 2.4.21 is above the upstream 1.11 library build’s Kotlin 2.2.0 level. This does not substitute for a complete Gradle build.

## External-subtitle behavior: pre-existing risk, separate scope

There is no newly introduced legacy-subtitle default incompatibility in 1.11.1:

- `SingleSampleMediaSource.java` from both official source archives is byte-identical. SHA-256: `7c1800b20460ca49e3128327a51ee75e20ccd78c5d4caa112076b019478daef4`.
- Both versions initialize `TextRenderer.legacyDecodingEnabled` to false and retain the same `assertLegacyDecodingEnabledIfRequired` check.
- Both default renderer factories create a normal `TextRenderer`; the plugin supplies no custom renderer factory or legacy-decoding opt-in.
- The plugin manually creates `SingleSampleMediaSource` for external subtitle tracks. The class’s existing deprecation warning describes why selecting ordinary external subtitle formats through that legacy route can fail. This is a pre-existing concern in 1.10.1 and is not a reason to defer the 1.11.1 pin.

1.11.1 does modify internal subtitle read-ahead handling (limiting reads to about one second ahead). Therefore the two libraries are not claimed to be behavior-identical; specifically, the legacy-subtitle default and guard are unchanged. A separate playback test or issue should track the existing external-subtitle risk. No subtitle modernization is included in this recommendation.

Official exact-version source references:

- [1.10.1 SingleSampleMediaSource](https://github.com/androidx/media/blob/1.10.1/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/source/SingleSampleMediaSource.java)
- [1.11.1 SingleSampleMediaSource](https://github.com/androidx/media/blob/1.11.1/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/source/SingleSampleMediaSource.java)
- [1.10.1 TextRenderer](https://github.com/androidx/media/blob/1.10.1/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/text/TextRenderer.java)
- [1.11.1 TextRenderer](https://github.com/androidx/media/blob/1.11.1/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/text/TextRenderer.java)
- [1.10.1 DefaultRenderersFactory](https://github.com/androidx/media/blob/1.10.1/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/DefaultRenderersFactory.java)
- [1.11.1 DefaultRenderersFactory](https://github.com/androidx/media/blob/1.11.1/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/DefaultRenderersFactory.java)

## API classes compared

The following names are relative to `androidx.media3`. Nested class names use JVM `$` notation.

- `common.util.UnstableApi`
- `common.text.Cue$TextSizeType`
- `common.C`
- `common.MimeTypes`
- `common.Format`
- `common.MediaItem`
- `common.MediaItem$Builder`
- `common.MediaItem$DrmConfiguration$Builder`
- `common.MediaItem$SubtitleConfiguration$Builder`
- `common.PlaybackException`
- `common.Player`
- `common.Player$Listener`
- `common.TrackSelectionOverride`
- `common.TrackSelectionParameters`
- `common.TrackSelectionParameters$Builder`
- `common.Timeline`
- `common.Timeline$Window`
- `common.VideoSize`
- `common.text.Cue`
- `common.text.Cue$Builder`
- `common.text.CueGroup`
- `common.util.Log`
- `common.Tracks`
- `common.Tracks$Group`
- `common.PlaybackParameters`
- `exoplayer.ExoPlayer`
- `exoplayer.ExoPlayer$Builder`
- `exoplayer.DefaultLoadControl$Builder`
- `exoplayer.SeekParameters`
- `exoplayer.source.DefaultMediaSourceFactory`
- `exoplayer.source.MergingMediaSource`
- `exoplayer.source.SingleSampleMediaSource$Factory`
- `exoplayer.drm.DefaultDrmSessionManager$Builder`
- `exoplayer.drm.FrameworkMediaDrm`
- `exoplayer.drm.LocalMediaDrmCallback`
- `datasource.DefaultHttpDataSource$Factory`
- `ui.CaptionStyleCompat`
- `ui.SubtitleView`

## Archive provenance and SHA-256

All downloads came directly from Google Maven. Each archive link below identifies the exact bytes inspected.

- [media3-common-1.10.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-common/1.10.1/media3-common-1.10.1.aar)
  - SHA-256: `39686f54ff6baf8cbc841199afd55619533eaef2ab6cd0efc32b8a3c55dd88c3`
- [media3-common-1.11.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-common/1.11.1/media3-common-1.11.1.aar)
  - SHA-256: `50813cf219c7c93ed8a32a750891ca6d1280729ecf7a90c49567adacd67ef31b`
- [media3-datasource-1.10.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-datasource/1.10.1/media3-datasource-1.10.1.aar)
  - SHA-256: `e22f9f779047ce951152c793af094593e7cbb52475a82d56fa4f869fd319e700`
- [media3-datasource-1.11.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-datasource/1.11.1/media3-datasource-1.11.1.aar)
  - SHA-256: `490fd23c7562a6a1183d63bf854b291ae3a77dce5a151450aa1937148c80c60b`
- [media3-exoplayer-1.10.1-sources.jar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer/1.10.1/media3-exoplayer-1.10.1-sources.jar)
  - SHA-256: `68378d00a9c979bdf2a0e3141be6138928a570543d23fc815ba92dadba174e7c`
- [media3-exoplayer-1.10.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer/1.10.1/media3-exoplayer-1.10.1.aar)
  - SHA-256: `19090f829afbbb595d67618f59c212f72b433ac01dc72b47594cf42552c8ed61`
- [media3-exoplayer-1.11.1-sources.jar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer/1.11.1/media3-exoplayer-1.11.1-sources.jar)
  - SHA-256: `a13b3e52cf278f147020d9b98f29ebd5a19e1dc0798f02595c6849291eb33233`
- [media3-exoplayer-1.11.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer/1.11.1/media3-exoplayer-1.11.1.aar)
  - SHA-256: `588592baec110837c33ce0c82bb76464203e6b0621177bbe5d88779001a6f1ed`
- [media3-exoplayer-dash-1.10.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer-dash/1.10.1/media3-exoplayer-dash-1.10.1.aar)
  - SHA-256: `03cc493dd75c7bf6ab920b1963688b950807e127d7f69d4dc3052765de4d6cfb`
- [media3-exoplayer-dash-1.11.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer-dash/1.11.1/media3-exoplayer-dash-1.11.1.aar)
  - SHA-256: `eda5ca5879d1016b2f6cb7a79fd8bef864017a3e62e8ece8c25b3a595373920c`
- [media3-exoplayer-hls-1.10.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer-hls/1.10.1/media3-exoplayer-hls-1.10.1.aar)
  - SHA-256: `01546472ff7a73004e4251fd6dcd2ca2ab5ffe55d294e845f7084f9743ae95b4`
- [media3-exoplayer-hls-1.11.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer-hls/1.11.1/media3-exoplayer-hls-1.11.1.aar)
  - SHA-256: `bd7aeac8dc60b3ee926eddbe05e29f27dc53c81514cae3271b2edab693f34262`
- [media3-exoplayer-smoothstreaming-1.10.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer-smoothstreaming/1.10.1/media3-exoplayer-smoothstreaming-1.10.1.aar)
  - SHA-256: `78fd704f9da836405ac7bc33cbb6df760f000a5178ba94b39c5f258818bc08cd`
- [media3-exoplayer-smoothstreaming-1.11.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-exoplayer-smoothstreaming/1.11.1/media3-exoplayer-smoothstreaming-1.11.1.aar)
  - SHA-256: `00e9716fed7b43d30024c32b79e08e12a5a73e66eb8b236eafd3d5c293fa44e9`
- [media3-extractor-1.10.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-extractor/1.10.1/media3-extractor-1.10.1.aar)
  - SHA-256: `3c823279356b64f4215a8c6cb1e6bfa60c533351a651786ad6fa69ad001ef1b1`
- [media3-extractor-1.11.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-extractor/1.11.1/media3-extractor-1.11.1.aar)
  - SHA-256: `6b2d58d23a0c53425249d8b7c945600019d61a8b404c8fb8cd9ca860c5738508`
- [media3-ui-1.10.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-ui/1.10.1/media3-ui-1.10.1.aar)
  - SHA-256: `ceb6df6e096df142865760d06439baa878aa0dead4eaa7b5fb5e4c30d1589392`
- [media3-ui-1.11.1.aar](https://dl.google.com/dl/android/maven2/androidx/media3/media3-ui/1.11.1/media3-ui-1.11.1.aar)
  - SHA-256: `bbd94f6d0e504931235d87275c3c5bf4f0a48e0008d8d12efc79f96fc8a3011f`

## Verification limitations

No Android SDK is installed in the audit environment. No Android/iOS build, device playback test, CI workflow, GitHub action or Gradle dependency-resolution task was run. The report establishes a targeted source/API compatibility basis for the stable-version pin, not complete build or playback validation.
