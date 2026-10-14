# Application diagnostics

Use **Settings → App diagnostic log** (الإعدادات ← سجل التطبيق):

1. Enable logging before reproducing the problem.
2. Reproduce it, including leaving/reopening the affected screen if relevant.
3. Return to the dialog and export the log. The system save dialog lets you choose where to save it.
4. Disable logging when finished. Existing log files remain available.

Logging is off by default and stays on across restarts only when its setting was saved successfully. Nothing is uploaded automatically. Review the exported file before sharing it.

## What it records

- Numeric application version/build and platform category, without device identifiers.
- Application startup after the saved preference becomes available, lifecycle changes, and static screen categories.
- Framework/platform errors, provider failures, and caught errors sent through the existing application logger.
- Instrumented HTTP request attempts, cancellation/failure categories, status codes, and timings.
- Player source sessions, readiness waits, engine opening, playback state/position confirmation, resume/recovery, and teardown.
- Download initialization stages/state changes, artwork lookup/capture results, and local proxy failures.

A begin event without its matching end helps identify a stalled operation. Player position confirmation is not proof that the native renderer displayed a frame.

The separate **Download log** remains available for detailed downloader/native transport diagnostics.

## Privacy and limits

The journal accepts fixed event names, fixed categorical values, and bounded numeric/boolean measurements. It does not store request URLs, query strings, headers, response bodies, credentials, account identifiers, media titles, search text, or downloaded file paths. Error messages are excluded; safe error types and restricted source-code stack locations are retained.

App files live in the application's support directory. Three rotating files are retained, each at most 2 MiB. Pending events and record sizes are bounded; repeated/high-frequency events are sampled, with dropped-event counts recorded. Writes are asynchronous and batched. Export combines only owned app-log files, oldest first, into a bounded JSONL file.

This is not a full native crash recorder or a record of every packet/action. Failures before the saved opt-in can be restored, OS termination, native engine crashes, and the final buffered events during abrupt process death may be absent. Physical-device reproduction is still necessary for renderer and hardware-specific failures.
