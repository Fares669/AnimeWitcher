# AnimeRift PR #280 — parity follow-up (2026-11-10)

This review compares the official APK (`com.riftapps.animerift`, internal
version `3.13.5`) with the `feat/animerift-multi-provider` branch. It is a
client-side regression review, **not** a claim of complete server or iOS parity.

## Fixes

- **Server fallback:** automatic playback and download now try the ordered
  catalogue without silently skipping options after the sixth. An explicitly
  selected server/quality remains pinned. Regression fixtures place the only
  usable server after six rejected options.
- **Fractional episode numbers:** preserve the native numeric value in source
  selection, local pending watched state, authenticated watched PUT bodies,
  and near-complete playback. The shared `Episode.episode` index remains an
  `int` for cross-provider compatibility, while `serverNumber` carries the
  exact value and fractional episodes receive a visible label. Local watched
  identity continues to use the stable episode URL.
- **Paged episode lists:** when the episode response explicitly reports
  `hasNext`, request subsequent pages, deduplicate by episode ID, and fail
  closed if the backend repeats a page or exceeds 256 pages. Single-response
  series do not make extra requests. The exact behavior of real authenticated
  `/library/episodes/{id}` pagination still needs live verification.
- **Bulk local watched selections:** one UI multi-select now commits its
  account-scoped pending states in a single journal write instead of rewriting
  the journal separately for each selected episode. Remote flushing still
  uses verified individual calls, not an unverified native bulk endpoint.
- **Comments:** respect an explicit `canReplyToNext=false` on reply screens,
  in addition to `replyAllowed` and terms acceptance. If an empty list still
  advertises further pages after the bounded initial probe, show a manual
  load-more action rather than trapping users in a non-scrollable empty view.

## Previously identified differences deliberately left unchanged

- **Seasons:** `/library/seasons` occurs in the official AOT string pool, but
  previous live GET requests received redirects to 404. The existing
  year/season-filtered search worked, so an unverified seasons endpoint must
  not replace it. The generated calendar is a navigation index, not a claim
  that each calendar season contains a title.
- **Account-only API features:** native strings for bulk watched actions,
  comment edit/delete/report, character/episode favorites, hidden catalogue,
  and Google sign-in do not alone establish request methods, body schemas,
  scopes, permissions, or authenticated server responses. Do not manufacture
  write calls or report these features as complete before contract and account
  verification.
- **Session/device refusals, linked-account comments, background iOS
  downloads and cloud reconciliation:** local mocks cannot prove acceptance
  on the production gateway or real iOS persistence. Do not bypass server
  refusals or recreate a previous owner-issued linking code.

## Testing

### Follow-up fixes after the first commit

- **Previously red GitHub Flutter checks:** an optional Rift HTTP proxy read
  exposed uninitialized Hive access in lightweight fake settings stores. The
  shared in-memory test store now handles `getString` / `setString`, and the
  isolated provider registration test supplies disabled proxy settings.
  This fixes test harness setup, not production proxy permissions.
- **Lazy library contract:** the account-settings test no longer demands a
  favorites download before the library is opened. It checks that no such
  request occurs in settings, preserving the requested lazy-loading policy.
- **Download startup CI guard:** tests accept equivalent, Dart-formatted
  multiline `catchError` callbacks instead of matching a single layout.
- **Comment permissions:** denial flags survive later pages that omit them,
  including automatic empty-page advancement. Account-specific optimistic
  reactions are dropped when the active Rift account changes mid-request.
  A comments list response fetched for the previous account is discarded,
  with a visible retry state, instead of showing its comments under the new
  account. A regression test gates the response during the account switch.

The earlier CI job on commit `c4713ca1` reported 22 failing cases; these
changes address the identified fixture/expectation failures. A new full CI
result is required before describing the PR as green.


Focused tests cover fallback past six options, fractional playback and watched
sync, pagination/deduplication, reply rights and continuation through empty
comment pages. Run against the current branch:

```sh
flutter test --no-pub -j 2 \
  test/core/extensions/providers/anime_rift_api_client_test.dart \
  test/core/storage/anime_rift_auto_sync_test.dart \
  test/core/extensions/providers/anime_rift_streams_test.dart \
  test/core/storage/anime_rift_cloud_import_test.dart \
  test/core/extensions/providers/anime_rift_catalog_test.dart \
  test/features/comments/presentation/anime_rift_comments_screen_test.dart
```

Generated Riverpod `.g.dart` files must exist before tests; they are not
committed to the repository. No APK, private account token, request signing
material or server response body should be committed.
