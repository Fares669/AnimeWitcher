# AnimeRift PR #280 — Stability and parity review

Date: 2026-11-05. Compared `origin/main` and `feat/animerift-multi-provider` (205 changed paths at review time). This is a **risk-based code and regression review** of the integrated PR, not a claim that every device/server scenario has been reproduced on real hardware.

## Key findings and fixes

| Area | Contrast with native AnimeWitcher | Finding / action |
|---|---|---|
| Library refresh | AnimeWitcher refreshes the visible library when requested | Rift's `_scheduleRefresh()` triggered a **full six-list + history cloud import** after local edits, including frequent playback progress. This is now a pending-write-only flush; explicit full refresh and visible-shelf refresh are retained. |
| App resume | Native provider has foreground refresh throttling | Rift previously triggered full import at *every* resume. Quick returns now only flush pending changes; full foreground refresh is limited to once per five minutes. |
| Large watch history | Native cached entries can render before network detail hydration | Rift's history import could perform a **serial detail request for every one of 290 records**, in addition to reading the history list. Lists longer than 30 now use server metadata, cached entries, or a verified ID placeholder; full details load when opened. |
| Cloud write queue | Independent edits must not starve one another | A rejected non-authentication 4xx mutation used to abort the entire outgoing queue. It now retains the rejected edit but continues unrelated writes; 401/403/429, network failures and 5xx still stop retries rather than causing a request storm. |
| Observability | Download V2 already has safe, bounded JSONL diagnostics | Added an always-on bounded `app.jsonl` alongside download logs. Captures lifecycle, navigation, Flutter/unhandled exception *classes*, UI frame stalls, slow/failed Rift HTTP requests, sync phases and per-page comment counts. |

## Logging

`<ApplicationDocuments>/log/app.jsonl`, rotated to `app.1.jsonl` and `app.2.jsonl` (2 MiB per file). Download logs remain separate in **the same** `log` directory. Go to the app's **Settings → download/application log** dialog to view/export individual log files; the download tracing toggle only controls download telemetry.

Only allowlisted, structured fields are written, such as a fixed route/operation category, HTTP status, duration, count, exception type, and numeric process-resident memory size at lifecycle transitions and sampled frame stalls. **No authentication codes, token values, user IDs, anime/episode identifiers, URLs, request/response bodies, headers, raw exception messages or stack traces are written.** Logging never awaits disk I/O on the UI path, and slow-frame events are sampled at most once every ten seconds.

An OS-native hard deadlock or crash before Flutter starts may not be captured. For an intermittent freeze, export the JSONL logs after reproducing it and include the approximate device time; on iOS also collect the system crash/hang report if the process terminates.

## Scope of comparison

- **Reviewed:** entry point and lifecycle, router, shared diagnostic sink, Rift API client (request boundaries), authenticated cloud queues, paginated library/history import, provider source and comment routing, download V2's logging/identity boundary, and native account/library refresh policies.
- **Regression checks:** new pending-only sync, isolation of rejected edits, long history without per-title requests, safe log metadata/sampling, and existing storage/provider/library/router/comment/download tests.
- **Preserved:** provider-separated authentication, guest data, account-scoped downloads, original AnimeWitcher list operations and download recovery; no schema migration or silent deletion of user data.

## Remaining external verification

The APK's undocumented write contracts remain an external boundary. In particular, AnimeRift server acceptance of a zero-valued `PUT /my_list/rate` as delete and the precise comment list targeting/pagination **must be verified using a linked test account**. Tests with intercepted Dio or synthetic fixtures cannot prove production API acceptance. The app logs now record safe status and item counts for these requests, without exposing session secrets.

No iOS/Android physical-device hang profile, memory trace, or live server session was available in this review. A completely exhaustive review of every execution path in this large PR requires those runtime traces and device reproduction.
