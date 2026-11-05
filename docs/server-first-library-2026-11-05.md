# Server-first library (AnimeWitcher + AnimeRift)

The library is now **stale-while-revalidate**, rather than delaying its first
frame for a full-account synchronization:

- The existing per-provider cached anime/manga shelf is shown synchronously.
- Entering the Library tab (including returning to a retained StatefulShellRoute
  branch) triggers a non-blocking read of the visible shelf.
- Selecting another category or switching between anime and manga immediately
  shows that shelf's cache and triggers its own remote read.
- On successful import, the account data revision updates the visible grid,
  counts, sorting, and phone shelf cache. Network errors keep cached data.
- AnimeRift reads only the selected `favorite/anime/all` or
  `my_list/all?my_list=...` list plus `my_list/overview` (to verify whether a
  response is complete). When the overview reports more than the initial list
  (e.g. 290 completed anime versus the first 30 returned), the client attempts
  bounded read-only `page` requests and deduplicates rows. Page numbering may
  start at 0 or 1: one repeated first page is tolerated, while another
  repeated page or rejected parameter stops safely. It does not mark a partial
  list complete or delete older cached entries. Rows with a verified anime ID
  are not discarded solely because a separate details request fails; locally
  known title/poster metadata is reused where possible, otherwise the verified
  ID appears temporarily until details are available. Watch history uses a
  **separate** full/latest GET.
- Native AnimeWitcher reads the Firestore anime collections `fav_anime` and
  `user_anime` for an anime shelf, or their manga equivalents for a manga
  shelf. Its server stores multiple categories in a shared collection, so one
  category still requires reading that collection; it does **not** run the
  unrelated watched/progress account synchronization on every shelf change.
- Pending local writes are flushed using the existing account-aware writer
  before a Rift pull. Unconfirmed edits remain protected. Rift's previous
  imported-item snapshots permit remote removals only when server overview
  counts and the actual returned list are complete and parseable; local-only
  items are never removed as if they were server-owned.
- Existing background startup/resume synchronization, offline/download storage,
  watched marks, and precise local playback seconds remain intact.

This is an architecture change, not a claim that the original apps use the
exact same in-memory cache lifetime. Full end-to-end authenticated server
verification and latest mobile Preview CI are tracked by PR #280.
