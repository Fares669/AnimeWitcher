# iOS manga background queue: October 31 investigation

The supplied `1.6.5+6` device logs show the first chapter completing at
06:21:59 UTC while the app is in the background. Subsequent chapter page
handles are created but remain queued without native progress until the app
returns to the foreground. The third chapter repeats this: page handles appear
at 06:23:43, settle at zero active connections, and the continued-processing
lease expires at 06:24:10. There is no reported transport error explaining the
stall. The two reasonless expiration callbacks occur after 92.8 and 65.1 seconds;
they do not establish whether Apple ended runtime or the user pressed Stop.

This pattern is consistent with Apple's documented rule: transfers started in
a **background URLSession while the app is already in the background** are
always discretionary, regardless of `isDiscretionary`. Keeping Dart alive or
promoting the next chapter does not make those transfers start promptly.
[Apple: isDiscretionary](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/isdiscretionary)

The logs also expose a definite compatibility defect: every
`background.capability` reports version `9.6.5` with `success: false`, while the
native completion hook allowlist ends at `9.6.4`. The installed 9.6.5 delegate
was compared with 9.6.4: its only change suppresses a cancellation notification
during reenqueue; the validated finish/move, completion and background-events
contracts remain intact. The allowlist now includes 9.6.5.

## Transport change

During an attached `BGContinuedProcessingTask`, canonical V2 manga page tasks
use a default URLSession, with the package's existing delegate, serial delegate
queue, timeout/proxy settings and host connection cap. This uses the runtime
Apple grants for continued processing, avoiding background-session scheduling
for the next chapter and later page waves. The chapter/page concurrency
settings and the Dart admission/verification authority remain in effect.
[Apple: continued processing](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)

A small, idempotent CocoaPods patch selects this session and combines both
sessions in all package task inventory reads. Pause, cancel, resume, tracking,
Wi-Fi changes and holding-queue accounting therefore continue to see existing
tasks. Upload cleanup is restricted to upload tasks because numeric
`taskIdentifier` values can collide between sessions.
[Apple: taskIdentifier](https://developer.apple.com/documentation/foundation/urlsessiontask/taskidentifier)

Only concrete attachment authorizes direct transport. Expiration revokes that
permission synchronously before OS task completion; concrete task identity
prevents an old callback from revoking a replacement lease. A submitted request
alone grants no permission. New work without a live lease, including older iOS
versions, keeps the background-session fallback. Existing tasks keep their
original session and are never recreated or canceled merely by a selection
change. The patch rejects unsupported package versions or changed source seams
before writing any source files.

## Validation and limits

The regression harness executes the patched production scheduling expression,
session helper and upload cleanup against fake Foundation transport boundaries.
It fails against the previous scheduling behavior and passes with the patch:
selection, exact task identity scope, preserved configuration/serial queue,
combined inventory, upload ID safety, stale expiration and retained tasks.
The production manager lifecycle harness also fails its new lease assertions
against the old manager and passes with the fix. Swift iOS-target syntax parsing
covers the patched plugin sources and app manager; this is not Xcode typechecking.

A default session depends on process runtime. Apple can still expire continued
processing, suspend/terminate the app or delay background-session fallback.
Existing direct tasks remain available to package controls when runtime returns;
they cannot independently transfer after process termination. This change does
not promise indefinite background execution or alter the existing ambiguous
system Stop policy.

Physical iOS validation remains required: queue seven chapters with concurrency
one, background/lock before the first completes, and verify that chapters two
through seven receive bytes without reopening. Repeat with a page limit below
the chapter length, pause/resume/cancel, network loss, lease expiration, and
foreground return. Confirm real `progress.plugin` events and verified chapter
files, rather than judging success from the system banner alone.

Automated checks also passed the native range handoff/refill, retry metadata,
callback compatibility (including 9.6.5), Ruby version export (nine assertions),
diagnostic wiring/privacy guards and CI YAML syntax checks. The new session and
21-scenario lifecycle harnesses were independently rerun by a second reviewer.
`flutter analyze` reported zero errors, seven existing warnings and 505 infos.
The unchanged logger executable test, `ios_download_diagnostics_test.py`, cannot
compile its Apple URLSession APIs on Linux without FoundationNetworking; the
CryptoKit/Security checks explicitly require macOS. Native macOS CI retains
those checks and now runs the new transport regression against the pinned pub
archive as well.

The repository-wide run used CI's harmless Firebase test define and disk-backed
`TMPDIR`. It recorded 3,139 passes, one skip and these two failures before the
session restarted during the final shared-widget files:

- `download_ios_restart_telemetry_regression_test.dart`: `restored multipart owners that disappear are recovered without callbacks` (expected a nonempty recovery list).
- `media_kit_native_open_test.dart`: `native single-local-media open: starvation` (20-second timeout).

Both failures were independently reproduced on an archive of the original
`17e5f219` branch head. No Dart production or player code changed. The final
shared-widget files and focused chapter transport/admission checks were run
separately after the restart; the interrupted run is not claimed as a completed
green repository suite.

Post-restart verification: all 131 remaining/focused Flutter checks passed,
including shared widgets, chapter admission/concurrency, manga page transport
and native authority guards. The patched native session harness and all 21
manager lifecycle scenarios also passed again.
