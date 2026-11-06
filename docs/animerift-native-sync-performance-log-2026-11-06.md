# Native account sync, AnimeRift sync and frame diagnostics

All events are appended to the existing `log/app.jsonl` next to the download
logs (2 MiB rotation, three files). These measurements are local only.
There are no additional network requests, retries or new synchronization
timers; all durations are observations of already-scheduled work.

## Native AnimeWitcher account (`native.sync.*`)

- `native.sync.start`: foreground sync began
- `native.sync.skipped`: `reason=signedOut` or `reason=throttled`
- `native.sync.stage`: parallel Firestore phases: `animeLibrary`,
  `mangaLibrary`, `watchedEpisodes`, `watchedManga`, `continueWatching`,
  with `durationMs` and `result=true/false`
- `native.sync.complete`: aggregate `durationMs`, `result=true/false`
- `app.exception` with `reason=nativeSync`: `errorType` and an allowlisted
  account `status` code (or `other`), without the exception message

The native stages run in parallel, so their durations **must not be summed**
to approximate the overall time. When a stage fails, check the corresponding
`app.exception` code and nearby stage events.

## AnimeRift cloud sync (`rift.sync.*`)

- `rift.sync.await`: `action=restore|importFull|importShelf|importHistory|
  write|acknowledge|debounce|coalescedWait`, plus `durationMs`, `status`
- `rift.sync.phase`: requested sync kind and pass number
- `rift.sync.pending`: count of queued local mutations, not network requests
- `rift.sync.skip`: safe reason for a skipped operation
- `rift.sync.complete` / `rift.sync.error`: total duration and pass count
- `rift.api.complete`: already-existing slow/failed HTTP operation timing

`importFull/importShelf/importHistory` include remote reads **and** local
persistence. `write` may include remote verification requests. The `count`
for a timed phase means one coordinator operation, **not** an HTTP request.
Very frequent skip/coalesced-wait events are limited to one per fixed reason
per 30 seconds to avoid perturbing performance.

## UI stutters (`app.frame.*`)

- `app.frame.jank`: first frame at least 50ms in a 10-second sampling window
- `app.frame.jankSummary`: number of additional slow frames and the slowest
  one observed in that window; also flushed on log export
- `durationMs`: total Flutter frame span
- `buildMs`, `rasterMs`, `vsyncMs`: Dart/UI building, graphics rasterization,
  and vsync scheduling portions, respectively
- `status`: `build`, `raster`, `mixed`, or `other`, indicating which portion
  exceeded a simple fixed diagnostic threshold
- `action`: known navigation section (`home`, `details`, `player`, `library`,
  `downloads`, `search`, etc.) or `other`, never the full route/URL
- `memoryBytes`: current process resident memory

The diagnostic `status` is a clue rather than proof of the root cause.
Screens without named routes remain `other`. Logs intentionally never include
account identities, comment bodies, tokens, API keys, response bodies, raw
exceptions, signed URLs, or paths.

## How to reproduce and capture

1. Install a build containing these diagnostics; launch AnimeWitcher normally.
2. Open the problematic account/provider; trigger one foreground sync by
   leaving and returning to the app, avoiding repeated forced refreshes.
3. Reproduce the scrolling/player/download stutter with the same actions.
4. Export the shared `log/app.jsonl` and rotated `app.1.jsonl` / `app.2.jsonl`
   if present. Preserve their event order and timestamps.

Older logs lack stage and frame breakdowns, so they cannot establish exactly
which async operation was slow or which native stage produced the exception.
