# AnimeRift PR #280 — native parity audit (2026-11-06)

This is a validation record for the AnimeWitcher
`feat/animerift-multi-provider` work in PR #280. It distinguishes observed
APK contracts, passing mocked tests, and features still unverified on the
real server. It must not be interpreted as full official-client parity.

## Native APK and verified protocol

- Official source artifact: `app-release-3.13.13.apk`, whose Android manifest
  actually reports package `com.riftapps.animerift` and version **3.13.5**.
  Flutter ARM64 `libapp.so` and restored AOT assembly/constant pool were
  examined locally; no signing credentials or user tokens are recorded here.
- `POST /comment/create`: query includes `animeId` (and `episodeId` when
  applicable); JSON body has **`text`** and nullable **`_parent`**. The
  native assembler loads the `text` field at `0xab6130` and `_parent` at
  `0xab6174`; its target map at `0xab61e4–0xab62bc` is passed to the network
  wrapper as query parameters. Native success branch expects HTTP **201**.
- `PUT /comment/react/{commentId}`: body has `reaction_type: thumbsUp`, plus
  the actual `animeId`/`episodeId` context when present. Native handler
  `0xab87a0–0xab88b0` builds the map and invokes the PUT wrapper. Native
  success branch expects HTTP **202**. A bare comment ID or POST was wrong.
- Comment rights (`termsAndConditionsAccepted`, `replyAllowed`,
  `canReplyToNext`) were found at the top level of native response data.
- The local requests do not retry 403, 406 or 429 simply to test access.

## Other bugs fixed with regression tests

- Cloud favorites: readback must use the actual `anime` / `_anime` catalog
  reference, rather than a distinct membership record `_id`. Tests cover
  add/remove acknowledgements and account isolation.
- Video source picker: the short-lived source catalog is scoped by the
  linked account and episode, not just episode URL. Guest → restored-account
  initial requests may be re-fetched **once on successful transition**;
  A → B account switches during an in-flight response fail closed.
- Home: ignore late news completion after disposal or provider-generation
  change before accessing Riverpod state. Tests cover success, failure and
  disposal races.
- Download V2 artwork audit: close its background persistence worker before
  deleting the test-specific temporary directory to prevent a late metadata
  flush from failing after the test.
- Download V2 deep-race assertions wait for the complete renewal/admission
  transition, not just its earlier source-replacement acknowledgement.
- Linux secure storage: a valid account credential shared in the system
  keyring is **not deleted** merely because a different XDG profile has a
  different device-installation ID. The foreign profile remains unlinked;
  the original profile can still restore its own credential. Invalid-format
  credential cleanup remains as before.

## Verification completed

- Flutter combined targeted suites for comments, ratings/favorites sync,
  stream sources, home, app diagnostics, artwork lifecycle and download
  renewal/startup races: **171 passed**, no failures.
- Auth/session API tests after the cross-profile credential fix: **53 passed**.
- Home/view-all/manga/catalog suites: **61 passed**; stream+source picker:
  **34 passed**; cloud storage suite: **65 passed**.
- Download V2 artwork lifecycle: **7 passed**, repeated three times. The
  download deep-race and startup replay tests: **28 passed** combined after
  waiting for complete state transitions.
- The full `test/core/services/download_v2` suite was **rerun after the race
  test synchronization fixes: 850 passed, 0 failed** (`-j 2`, 2026-11-06).
- Linux ARM64 `flutter build linux --release --no-pub` succeeded with
  `--dart-define-from-file` pointing to an **outside-repository local file**.
  The app launched in XFCE and loaded public AnimeRift home and comments.
- Static analysis showed **no errors**, although pre-existing style / strict
  typing warnings remain (especially in old mock test maps).

## Not yet verified and blocking full parity claims

- Old incomplete comment requests on the live linked account returned
  HTTP **406**, and an old POST reaction received HTTP **302**. After the
  native PUT method was corrected but before the context fields were added,
  a PUT reaction still received HTTP **406**. This is **not proof of an IP
  ban**. The **new** protocol-correct POST/PUT payloads have **not been
  successfully exercised on a linked production account**.
- The Linux test profile currently has no persisted linked account token.
  The previously proven credential-deletion code path has been fixed, but a
  missing credential cannot be reconstructed or re-used. A fresh, user-issued
  linking code is needed for an authorized live POST/PUT test. No repeated
  rejected or unauthenticated writes should be sent meanwhile.
- A Flutter fixture validates request shape and local state handling; it
  does **not** demonstrate that the real AnimeRift backend accepts a write.
  iOS live activities, device downloads, cloud writes and every official APK
  screen have not been checked end-to-end in this audit.
- Earlier full Download V2 run had four race-related assertion failures under
  load; the corrected full suite now passed all **850 tests**. This verifies
  the local regression suite, not real iOS background transfers or the
  provider server's download permissions.

## Local workflow and safeguards

```sh
flutter test --no-pub -j 2 \
  test/core/extensions/providers/anime_rift_api_client_test.dart \
  test/core/extensions/providers/anime_rift_comments_test.dart \
  test/core/extensions/providers/anime_rift_streams_test.dart \
  test/core/extensions/providers/anime_rift_reaction_integration_test.dart \
  test/core/storage/anime_rift_auto_sync_test.dart \
  test/features/comments/presentation/anime_rift_comments_screen_test.dart \
  test/features/home/presentation/home_provider_test.dart
flutter test --no-pub -j 2 test/core/services/download_v2
flutter build linux --release --no-pub \
  --dart-define-from-file="$HOME/.config/animewitcher/local-animerift-dart-defines.json"
```

Never commit the local Dart defines, secret-storage files, the linked account
token, or raw request/response bodies. Do not merge PR #280 or claim full
official-app parity without explicit authorization and confirmed live results.
