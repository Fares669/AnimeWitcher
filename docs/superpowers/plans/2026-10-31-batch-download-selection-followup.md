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
- [x] Selected anime/manga downloads and completed episodes/chapters use a theme-accent highlight and circular selection markers without shrinking or shifting their cards.
- [x] Download selection and completed selection Delete buttons, plus the Downloads Delete All button, remain red even when temporarily disabled.
- [x] Manga completed chapters display a single selection circle and preserve their action-column width.
- [x] Update focused UI and launcher tests for the new behavior; run formatting, tests, analysis, and diff checks.
- [x] Commit and push changes to `feat/batch-download-controls` for GitHub PR review; do not merge.

## Implementation notes

Modify `details_screen.dart`, `downloads_tab.dart`, and `download_launcher.dart` using existing UI components and existing provider interfaces. Pick a common *server* from the raw `loadStreamSources` results, treating quality as a later property of the chosen server. Resolve only matching candidates after the picker and verify URLs before enqueue. Retain the reference screenshots' action order and proportions.

## Widget preview captures

- [Active Downloads selection](../previews/2026-10-31-active-selection.png)
- [Completed Downloads selection](../previews/2026-10-31-completed-selection.png)

These are automated Flutter widget previews using fixture download records and a dark/cyan test theme; real cover artwork and the user's theme settings are not included.

## Quality picker correction

- [x] Use the single-episode source picker with shared quality/server pairs, preserving quality headings instead of collapsing servers into one section.
- [x] Resolve only the selected quality/server pair after confirmation; do not fall back to a different quality. Multi-quality sources retain their existing automatic behavior.
- [x] Include the selected quality in the batch confirmation.
- [x] Regression test checks multiple quality headings, the same server under two qualities, and no stream resolution before confirmation.

This supersedes the server-only picker and automatic quality choice described above.

## Selection panel over the bottom taskbar

- [x] Anchor active/completed download selection panels to the root overlay so they cover the entire bottom taskbar.
- [x] Keep device safe insets, leave scroll room for the final row, and remove the panel when selection is cleared.
- [x] Hide the overlay when its navigation branch is inactive.
- [x] Add active and completed regression checks with an actual bottom navigation bar.

## Manga batch submission correction

- [x] Submit every selected chapter without waiting for the first chapter's asynchronous startup; retain manager admission/concurrency limits.
- [x] Count failures per chapter without blocking remaining submissions.
- [x] Regression check holds the first startup pending and verifies all three chapters were submitted, including an independently failed chapter.

## Manga chapter selection marker placement

- [x] Keep the book icon beside the chapter title in both Manga and Completed.
- [x] Replace the trailing delete/download action with the circular selection marker while selecting, keeping its width and row dimensions.
- [x] Check selected/unselected marker positions against the original action and preserve the book position.

This supersedes the earlier book-replacement selection icon.

## PD and cancellation follow-up from iOS diagnostics

- [x] Move bulk buttons and download-session summary into the active TabBarView page so they travel with that page throughout swipes.
- [x] Logs show successful 206 transfers beside 403 failures on parallel PD ranges (16 configured connections). Limit PD source descriptors to one transport connection, including queue promotion/restarts. This is a compatibility mitigation; an actual device download is still needed to confirm the server behavior.
- [x] Final cancellation awaits pending native ACKs and verifies native writers stopped, then fences late checkpoint writes instead of waiting forever for missing resume data. Keep the existing checkpoint fence for ordinary pause/resume and range recovery.
- [x] Add regressions for unavailable checkpoints during delete, late persistent writes, PD connection width, and bulk controls inside the active pager.

## Preserve ascending manga queue order

- [x] Fix the race introduced by parallel batch submissions: asynchronous destination/metadata preparation could reorder persisted admission stamps.
- [x] Add an enqueue-only start mode that durably queues a request and returns before provider page resolution or native startup.
- [x] Submit the already-sorted chapter list sequentially in enqueue-only mode; continue after individual enqueue errors.
- [x] Verify chapters 1–4 retain persisted FIFO order and start in that order while page resolution is deliberately blocked, without blocking batch enqueue.

This supersedes simultaneous manga batch submission from the previous correction.
