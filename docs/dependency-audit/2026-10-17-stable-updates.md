# Stable dependency audit, 2026-10-17

## Scope and result

Application baseline: `4ed993d` (existing UI work preserved). Flutter 3.47.1 / Dart 3.13.1 are unchanged. Versions were checked against the official pub.dev package API, package archives/changelogs, and official native release documentation on 2026-10-17.

- Dart lock graph: 247 → 240 packages (56 direct application, 8 direct development, 176 transitive).
- 96 version upgrades, 9 additions, 16 removals: 121 graph changes. Thirty direct dependencies were upgraded; `custom_lint` was removed during the supported Riverpod analyzer-plugin migration.
- Every selected direct dependency uses a stable release. The stable Riverpod generator/lint releases themselves require the exact prerelease-named development utility `riverpod_analyzer_utils 1.0.0-dev.12`; its upstream requirement was retained without overrides (previously dev.8).
- The official Pub audit reported zero advisory-affected and zero retracted resolved packages. This is a registry snapshot, not a comprehensive security audit. Four discontinued legacy screen-retriever platform packages remain required by the current window-manager release; see below.

Complete old/new/latest versions, including unchanged packages, are in [direct-dependencies.csv](direct-dependencies.csv) and [dart-dependencies.csv](dart-dependencies.csv). [pub-registry-snapshot.json](pub-registry-snapshot.json) records all 240 queried packages, their latest/resolvable versions and advisory/retraction/discontinuation flags.

## Major application upgrades and migrations

| Library | Old lock | New stable |
| --- | --- | --- |
| flutter_riverpod / hooks_riverpod | 3.1.0 | 3.4.3 |
| riverpod_annotation | 4.0.0 | 4.0.7 |
| riverpod_generator | 4.0.0+1 | 4.0.9 |
| riverpod_lint | 3.1.0 | 3.1.9 |
| go_router / go_router_builder | 17.3.0 / 4.4.0 | 18.1.0 / 4.5.0 |
| dio | 5.11.0 | 5.11.1 |
| google_fonts | 8.2.1 | 9.0.0 |
| cached_network_image | 3.4.1 | 4.0.4 |
| connectivity_plus | 6.1.5 | 7.3.2 |
| file_picker | 12.0.0-beta.7 | 13.1.0 |
| flutter_secure_storage | 10.3.1 | 11.2.0 |
| dpad | 2.0.2 | 3.1.1 |
| dynamic_color | 1.8.1 | 2.1.0 |
| lucide_icons_flutter | 3.1.19 | 4.0.0 |
| image / archive | 4.8.0 / 4.0.9 | 4.12.0 / 4.5.2 |
| shimmer | 3.0.0 | 4.0.0 |
| build_runner | 2.15.1 | 2.16.2 (compatible hold) |

Migration details:

- File selection uses stable `pickFile()` and `PlatformFile.readAsBytes()` for a single profile image; cancellation, invalid images and the existing 20 MB validation remain. Custom font selection uses the returned single file path. Directory and log-export APIs remain compatible.
- Lucide's 200-weight icons use the new `lucide_icons_200.dart` / `LucideIcons200` API, retaining each icon and weight.
- Two D-pad focus builders now consume `DpadFocusState.focused` and supply a reusable child. Remote activation and touch selection are covered by widget tests.
- Riverpod uses its supported analysis-server plugin instead of the obsolete `custom_lint` integration. Providers/routes were regenerated, including the tracked notifier `runBuild()` return contract.
- `dynamic_color` now returns `material_ui.ColorScheme`, a different type from the app's Flutter Material scheme. The app's existing fixed-accent theme factories already ignore device-color input. They continue receiving null, preserving their actual appearance and avoiding an unnecessary application-wide Material migration.
- Generated native registration follows the resolved plugin graph: the Darwin picker import changes to `file_picker_darwin`, and obsolete `flutter_js` Linux registration is removed. No app code uses that removed plugin.

### Secure-storage release caveat

[Version 11 removes legacy cipher/EncryptedSharedPreferences migration](https://pub.dev/packages/flutter_secure_storage/changelog). Users jumping directly from an app using pre-v10 storage may need to sign in again because old encrypted credentials can become unreadable; users whose data has already migrated through v10 retain compatible current ciphers. This upgrade was explicitly approved after that caveat was explained.

The app stores its account session (including Firebase ID/refresh tokens) and cached profile in this secure backend, not downloaded episodes or ordinary settings. A production-storage-wrapper test simulates a native read/decryption failure, verifies startup returns signed out promptly, and verifies unrelated local sentinels remain intact. No broad reset or biometric/security-option change was added.

## Downloader and native player

- `background_downloader 9.6.4` is already [latest stable](https://pub.dev/packages/background_downloader/changelog). It stays exactly pinned because custom native completion/resume hooks are validated against that version. Its constraint permits connectivity_plus `>=6.1.3 <8.0.0`; the old 6.x-only comment was corrected. Resume/callback hooks were retained.
- `media_kit 1.2.6`, `media_kit_video 2.0.1` and `media_kit_libs_video 1.0.7` are already latest stable. The local media-kit override and single-item native-open/DNS-starvation fix remain intact, with existing provenance and patch manifests.
- Vendored `video_view 1.3.1 → 1.3.3` was three-way merged against both published archives. Headers, DRM, external subtitle payloads, live/seekable metadata, orientation, cleanup and retries remain. The upstream disposed/stale-callback guards and UTF-8 Windows path fix were integrated. Unrelated upstream example-project changes were omitted. See [fork provenance](../../packages/video_view/UPSTREAM.md).
- Its Media3 range was replaced by exact stable `1.11.1`. Comparing 38 used API classes from official 1.10.1/1.11.1 Maven artifacts found no called member removed. All eight audited AARs retain minSdk 23 / minCompileSdk 36. No Kotlin runtime migration was necessary. See [API/manifest/hash audit](media3-1.11.1-compatibility.md) and [raw public API delta](media3-public-api-diff.txt). The audit distinguishes an unchanged, pre-existing external-subtitle decoder concern from this version bump.

### Upstream-owned embedded runtimes retained

Latest media-kit packages still ship upstream-selected older binaries/assets: web HLS.js 1.4.10 and internal ffi 1.2.1, mpv 0.36.0 headers, Apple libmpv-darwin-build v0.6.0, Windows 2023-09-24 binary packaging, and Linux mimalloc 2.1.2. These were not independently replaced. Doing so would be a separate player-fork/native-runtime migration and could invalidate the tightly checked Anime4K render/pacing/header integrations. This update does not claim that every embedded upstream binary is globally newest.

## Android native libraries and build tooling

| Component | Old | Selected | Reason |
| --- | --- | --- | --- |
| Media3 | floating [1.10,1.11) | 1.11.1 | Latest stable; targeted API and manifest audit |
| AndroidX tvprovider | 1.0.0 | 1.1.0 | Latest stable; existing channel APIs retained |
| Android Gradle Plugin | 8.13.0 | 9.1.1 | Existing compileSdk 37 requires AGP ≥9.1.1 |
| Gradle | 8.14 | 9.3.1 | Required by AGP 9.1 and matches Flutter 3.47.1's known/tested version |
| Kotlin Gradle plugin | 2.2.20 | 2.4.21 | Latest stable within the documented Gradle/AGP compatibility range |
| desugar_jdk_libs | 2.1.5 | 2.1.5 | Already latest documented stable |

Global AGP 9.4.0 / Gradle 9.8.1 were not selected: they go beyond this Flutter SDK's known/tested toolchain; Gradle 9.7+ also changes embedded Kotlin used while compiling Flutter's included build. The minimal API-37-compatible stack avoids that additional unvalidated migration. Existing `android.builtInKotlin=false` and `android.newDsl=false` remain, as required by Flutter's supported AGP-9 legacy compatibility and the project's legacy extension configuration.

No supported-device OS minimum was raised. App Android minSdk remains Flutter's 24; compileSdk 37 and targetSdk 36 remain. Java target 17 and Flutter-owned NDK 28.2.13676358 remain. The local video plugin keeps iOS 15 / macOS 12 / Swift 5 minima.

Sources: [API/AGP compatibility](https://developer.android.com/build/releases/about-agp), [AGP 9.1 requirements](https://developer.android.com/build/releases/agp-9-1-0-release-notes), [Flutter AGP-9 migration](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin), [Kotlin compatibility](https://kotlinlang.org/docs/gradle-configure-project.html), [tvprovider releases](https://developer.android.com/jetpack/androidx/releases/tvprovider), [desugaring changelog](https://github.com/google/desugar_jdk_libs/blob/master/CHANGELOG.md).

## Exact Dart compatibility holds

The final solver reports no newer upgradable or resolvable versions. Nine packages have a newer stable version outside the complete graph's constraints:

| Package | Selected / latest | Actual limiting requirement |
| --- | --- | --- |
| build_runner | 2.16.2 / 2.17.1 | 2.17.1 requires build ≥5; go_router_builder 4.5.0, riverpod_generator 4.0.9 and mockito 5.8.1 require build <5. Version 2.17.0 is retracted. |
| build | 4.0.11 / 5.0.0 | Same three latest stable builders require ≥3 <5. |
| build_config | 1.3.3 / 1.4.0 | build_runner 2.16.2 requires ≥1.3.2 <1.4.0. |
| cross_file | 0.3.5+5 / 0.4.0 | file_picker 13.1.0 and its platform packages require ^0.3.5+4; share_plus 13.3.1 requires ^0.3.5+2. |
| material_color_utilities | 0.13.0 / 0.13.1 | Flutter SDK pins exactly 0.13.0. |
| protobuf | 3.1.0 / 6.1.0 | Latest flutter_avif_platform_interface 3.1.0 requires ^3.1.0. |
| screen_retriever | 0.2.2 / 0.3.0 | Latest window_manager 0.5.2 requires ^0.2.2. |
| test_api | 0.7.12 / 0.7.15 | Flutter SDK flutter_test pins exactly 0.7.12. |
| xml | 7.0.1 / 7.1.0 | Latest vector_graphics_compiler 1.3.2 requires ≥6.3.0 ≤7.0.1. |

The screen-retriever 0.2 graph retains discontinued `screen_retriever_linux`, `screen_retriever_macos`, `screen_retriever_windows` and `screen_retriever_platform_interface` 0.2.2. Its parent 0.3 release consolidates platform code, but current window_manager does not permit it. No unsupported override or additional vendored maintenance fork was introduced.

## Verification and platform limits

- `flutter pub upgrade`: passed; `flutter pub outdated --json --show-all`: all 240 packages audited, no newer upgradable/resolvable versions.
- `dart run build_runner build --delete-conflicting-outputs`: passed, 81 generated outputs. The new runner reports that the old flag is ignored; generation itself succeeds.
- `flutter analyze --no-pub --no-fatal-warnings --no-fatal-infos`: passed with zero errors, 3 warnings and 474 infos. Nonfatal diagnostics remain visible rather than being suppressed.
- Focused Dart/widget/native-player tests: 64 passed, plus 10 picker/theme tests passed.
- Complete Flutter suite: **2813 passed, 1 intentionally skipped live-network suite, 0 failures**, in 5m24s. Command: `CI=true BOT=true flutter test --no-pub --concurrency=2 --dart-define=ANIMEWITCHER_FIREBASE_API_KEY=test-api-key`. The existing skip is `test/features/skip/live_probe_test.dart`, which explicitly requires opt-in live-network execution.
- Ruby Anime4K media-kit patch, pacing patch and telemetry-install contracts passed. Downloader compatibility-version test: 1 test / 7 assertions passed.
- Python continued-processing diagnostics: 7 passed; DM26 static guards: 2 passed; range-experiment checks: 15 passed. Retry-metadata and iOS-diagnostics production-source extraction passed, with Swift execution explicitly skipped. CryptoKit/Security native checks skipped on non-macOS. Continued-processing lifecycle and range-handoff behavior tests cannot run without a Swift compiler (exit 1 for that environment prerequisite).
- Official Gradle 9.3.1 distribution SHA-256 verified, recorded in the wrapper, and `--version` ran on Java 21. Project `gradle help` could not resolve the Flutter SDK's `org.gradle.kotlin.kotlin-dsl:6.4.2` marker/plugin from Plugin Portal, before evaluating the application. A second proxy-configured attempt had the same blocker. An official Python HTTP read of the marker POM succeeded, so this is an unresolved local Gradle retrieval/configuration limit, not proof of Android source compatibility or incompatibility.
- No Android SDK, Swift compiler, Apple runtime/Xcode or Windows compiler is installed here. No Android/iOS/macOS/Windows app build or device playback smoke test is claimed. No iOS build or CI workflow was run or dispatched.

### Apple lock handling

The tracked `macos/Podfile.lock` was left byte-for-byte unchanged; its existing graph still lists removed `flutter_js` and does not represent all current plugins. CocoaPods versions in plugin podspecs are not necessarily Dart package versions. It must be regenerated and verified by CocoaPods on an Apple environment before claiming the native macOS graph is current. Checksums were not hand-edited. The repository intentionally ignores `ios/Podfile.lock`, so there is no tracked iOS lock to update. CocoaPods 1.16.2 in the macOS lock records the generating tool, not an enforced pin; 1.17.0 is latest stable. OrderedSet 6.0.3 is already current. Apple dependency resolution and native builds remain unverified.

Unrelated automatic localization regeneration was restored to the baseline after the final Flutter invocation. No ARB translation source or supported app locale changed.
