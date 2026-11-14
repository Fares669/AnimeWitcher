# AnimeRift watched uploads and episode scrolling — app(2).jsonl review

Review of user-supplied `app(2).jsonl` (470 valid JSONL events from
AnimeWitcher 1.6.6+7, seven application starts). The uploaded image shows the
portrait episode list with image thumbnails, labels and action buttons.

## What the log actually establishes

- No recorded HTTP 403 or 429. Of 139 logged HTTP completions, 130 were 200,
  five 202 and four 201; these are **sampled**: before this patch, successful
  fast non-comment PUT calls under 900ms were not logged at all.
- The Rift pending queue grew from 0 to 1, 3 and **20** entries. There were
  unconfirmed writes, but those may include history/playback operations whose
  cloud contract is not verified. A queued entry by itself does not prove a
  server denial or even identify the pending kind.
- The full Rift library import awaited up to **33,286ms**, with an overall
  combined Rift sync drain lasting **57,221ms**. A selective shelf import took
  up to **24,854ms**, and individual requests sometimes exceeded 16 seconds.
- The frame sampler recorded nine individual slow frames and five summaries,
  with observed spans **51–69ms** and almost all delay in Flutter build time
  (not raster). The details screen appears in many frame events. This
  supports prioritizing row subscription and intrinsic-layout changes; it
  does **not** predict FPS gains without another device trace.
- Eight native sync runs emitted five stage events each; all 40 stages
  reported success, but native animeLibrary alone often took 7–9 seconds.
- After the second app start, later starts had `rift.sync.skip` with
  `sessionUnavailable` despite successful **device registration**. Registration
  does not mean the linked Rift **user** credential was restored; the previous
  log cannot distinguish missing credentials, identity mismatch, or storage
  failure. New fixed-status session restoration diagnostics address this gap.

## Proven code defects and changes

1. Watched changes scheduled a 3-second pending flush, but opening a shelf,
   refreshing history or immediately rating could **cancel the flush timer**
   while flushing only selected kinds. Other queued watched edits stayed
   durable without a scheduled upload. Deterministic regressions reproduce
   this ordering with up to 20 watched edits before the fix. Partial refresh
   no longer cancels the unrelated pending timer.
2. Per-card `downloadedFilesProvider` full-map watchers caused unrelated
   downloaded-file map publications to rebuild all visible episode cards.
   Narrowing the subscription to that episode's file avoids those redraws.
3. Single-card rows used `IntrinsicHeight` even when no equal-height siblings
   exist. Portrait lists can bypass the speculative intrinsic-layout pass
   while keeping lazy sliver rows and multi-column equal-height behavior.
   Per-card completed-file checks are additionally coalesced by UI batch:
   mounting 100 missing files reads one durable record snapshot rather than
   scanning the same store 100 times. Fresh batches still verify actual bytes,
   file additions/removals, and account context; stale older results cannot
   replace a newer scan of the same file.
4. Fast successful watch/rating `PUT` calls were omitted from the API log.
   The revised log always captures these *fixed-route* mutations with safe
   status/duration, and a new `rift.sync.writeOutcome` indicates the mutation
   kind and `acknowledged|unconfirmed|rejected|error` without IDs or payload.
5. The session restore diagnostic now records only finite safe statuses:
   `missing`, `invalid`, `installationMismatch`, `restored`, or
   `storageError`. The credential, user/device IDs and raw error remain private.

## Important limits

- These changes are tested with local state, timing fakes and Flutter widget
  tests; they do not prove the live server accepted previously unsent watched
  episodes. A normal authorized watch/unwatch followed by an ordinary sync
  and a fresh official-app/cloud read is needed to prove end-to-end delivery.
- Avoid repeated forced registration or retries if the server refuses a
  session. Account and local pending data must stay isolated.
- Download-file batching improves redundant local metadata reads but does
  not cache external file state indefinitely; offline playback keeps its
  own fresh integrity verification path.
- Recheck `rift.auth.sessionRestore`, `rift.sync.writeOutcome`,
  `rift.api.complete(status=watch_history.watch)`, `rift.sync.pending`, and
  `app.frame.jank` in the next exported app.jsonl. No secret data is needed.
