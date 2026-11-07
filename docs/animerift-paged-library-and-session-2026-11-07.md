# Library pagination, session restoration and watched episodes — 2026-11-07

## Behavior

- Both account providers expose the visible library category in **30-item
  pages**. The library screen asks for the next page near the end of the
  scroll, with a manual load-more option if a scroll notification is missed.
- Native AnimeWitcher queries Firestore with a 30-item limit, ordered by date
  and document ID, and reads its total using an aggregation. Its cursor is
  specific to the signed-in account, media type and shelf.
- AnimeRift uses a 30-item client-side cap on the initial `/my_list/all` or
  `/favorite/anime/all` response. Additional pages request the same read-only
  endpoint with a page query; the server's `my_list/overview` supplies counts
  for unopened shelves. If the server ignores pagination, the client stops
  after bounded duplicate-page detection, rather than fabricating rows.
- Existing offline edits and locally cached titles are not deleted based on
  an incomplete remote page. Startup/foreground syncs still upload pending
  changes; they no longer fetch every library category in the background.
- Rift's linked-account owner survives provider registry rebuilds. Device
  registration session keys can be reused only from platform secure storage,
  scoped to the exact installation and bounded registration freshness; the
  linked user token stays in a separate secure-storage record.
- Startup and account-linking refresh watch history independently of the six
  library lists. Explicit watched and unwatched episode arrays are honored,
  including integer strings, without inferring that all earlier episodes were
  watched based on a last-episode marker.

## Investigation and regression coverage

- Fixed a real self-await deadlock in the Rift per-shelf request cache:
  `Future.whenComplete` must not return the same future it is completing.
  The reproducer previously timed out after 30 seconds on page one.
- Added tests for cursor ownership, first 30 items, scroll-triggered local
  page expansion, native Firestore paging/counts, overview totals for
  unopened Rift shelves, cross-account protection and explicit watched states.
- Fixed repeat reads of local shelves on each search edit: the first search
  builds a per-shelf cache, subsequent search edits reuse it until the actual
  library/account/sort changes.

## Validation limits

- Tests use local and fake-server responses. The exact server-side page-size
  contract for an authenticated AnimeRift account remains unverified; some
  default API responses may already contain many items before the client caps
  the rendered page at 30.
- The official server must actually expose individual watched/unwatched
  episode states to import them all. A response that exposes only the latest
  watched episode cannot safely imply the state of earlier episodes.
- End-to-end persistence of a real iPhone account session and cloud watched
  flags requires a new authorized-device test. No attempt was made to rotate
  identities or bypass a server refusal.
- The Linux ARM64 build validates desktop compilation and startup, not iOS
  real-time performance or every official AnimeRift API schema.
