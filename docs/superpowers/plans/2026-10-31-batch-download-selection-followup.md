# Batch download and selection UI follow-up — 2026-10-31

## User requirements / acceptance checklist

- [x] Anime episode multi-selection: place full-width `تنزيل N حلقة` above the watched/unwatched/select-all row, matching manga.
- [x] Downloads and Completed selection panels use the same rounded elevated Material, header with count and close, and RTL direction as the anime/manga selection panels.
- [x] Completed selection panel: one large Delete button, circular Select All button to its left, no Pause/Resume.
- [x] Active Downloads selection panel: single horizontal row with Delete, Pause, Resume sharing the remaining width, with circular Select All at the left; disabled actions remain visible, small screens do not overflow.
- [x] Normal Downloads header: Delete All and Pause All / Resume All each occupy half the row; Completed has no Delete All header action.
- [x] Batch anime download: query episode *server lists* only before showing the picker; do not resolve video URLs before user selects a server.
- [x] Server picker lists only servers shared by selected episodes; selecting one resolves valid URLs only for that server, honoring configured quality priority within it, then adds the episodes in ascending order to V2 downloads.
- [x] Preserve existing V2 deduplication, deletion confirmation, error reporting, and per-task controls.
- [ ] Update focused UI and launcher tests for the new behavior; run formatting, tests, analysis, and diff checks.
- [ ] Commit and push changes to `feat/batch-download-controls` for GitHub PR review; do not merge.

## Implementation notes

Modify `details_screen.dart`, `downloads_tab.dart`, and `download_launcher.dart` using existing UI components and existing provider interfaces. Pick a common *server* from the raw `loadStreamSources` results, treating quality as a later property of the chosen server. Resolve only matching candidates after the picker and verify URLs before enqueue. Retain the reference screenshots' action order and proportions.
