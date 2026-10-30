# iOS download background lifecycle

## Continued-processing expiration is ambiguous

Apple invokes `BGContinuedProcessingTask.expirationHandler` both when the
system ends continued processing and when a person cancels through the system
Live Activity. The public handler takes no arguments; it does not provide a
stop reason. The app cannot reliably infer user intent from that callback.

Sources, checked 2026-10-16:

- [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados/)
- [BGTask.expirationHandler](https://developer.apple.com/documentation/backgroundtasks/bgtask/expirationhandler)
- [WWDC25: Finish tasks in the background](https://developer.apple.com/videos/play/wwdc2025/227/)

## Current app policy

- An expiration callback immediately acknowledges that concrete OS task with
  `success: false`, through a completion gate shared with explicit session end.
  It does not wait for the main actor before acknowledging expiration.
- Main-actor cleanup releases presentation state only if that same concrete
  task still owns the lease. A stale callback cannot clear a replacement lease,
  even when both tasks have the same scheduler identifier.
- Expiration does not call the download coordinator's cancel/pause path, cancel
  independent background URLSession transfers, or submit a replacement lease.
  This preserves transfer continuity when iOS revokes continued-processing
  runtime. It does not guarantee uninterrupted background execution.
- Explicit in-app download cancellation remains owned by the download
  coordinator. The separate native `stop(endSession: true)` bridge ends the
  umbrella presentation session, withdraws its pending request, and records a
  known canceled status. Per-episode `stop`/`finish` calls without `endSession`
  do not end a live queue's presentation session.

## System UI Stop limitation

The system's Stop action is not a reliable download-cancel control under this
continuity policy: its callback releases the continued-processing task, while
independent URLSession transfers can continue. This is a known product
limitation, not a fixed system-UI cancellation path. Use the app's download
controls to stop the actual transfer.

Canceling all downloads on every expiration would also cancel them on ordinary
OS expiration. No private API, timing heuristic, or location keepalive is used
to pretend those cases are distinguishable. A different policy needs a product
decision about that tradeoff or a supported, distinct cancellation signal.

## Verification boundaries

`test/native/continued_processing_lifecycle_test.py` compiles the production
manager with fake Apple scheduler/task and bundle boundaries. It checks
explicit stop versus unclassified expiration, immediate and once-only task
completion, stale callback fencing, and late attachment ordering. Run it with
`python3 test/native/continued_processing_lifecycle_test.py` on a host with
`swiftc` available. Flutter source-contract tests additionally guard bridge
wiring; they do not execute Swift.

Neither harness simulates Apple's scheduling policy or actual background
URLSession behavior. A real iOS build and physical-device checks remain needed
for system UI Stop, OS expiration, foreground return, and download cancellation.

## Retry timing and source recovery

The multipart coordinator owns retries. Numeric and HTTP-date `Retry-After`
values are minimum waits, including across Pause/Resume and checkpoint restore.
For dates, a valid response `Date` prevents a fast device clock from shortening
the server interval. Only locally chosen backoff uses bounded jitter and a
30-second cap; server waits are not truncated to that cap.

The supported native status callback saves only task/parent identity, attempt
generation, HTTP status, `Retry-After`, and response `Date` before the package
forwards its header-less failure message. This small cache uses UserDefaults;
its disk flush is OS-managed. Dart atomically checkpoints the actual retry
deadline before allowing another attempt. A hard kill before either store
reaches disk remains a physical-device validation boundary, not a guaranteed
durability property of UserDefaults.

Legacy unqualified validators and refreshed URLs require byte verification of
visible saved prefixes. Sources without usable validators can still pass that
verification. Completed ranges are retained. Opaque native resume data cannot
prove its source identity, so only the affected unfinished immutable range may
need a fresh request. A visible prefix is preserved in a recoverable sibling
file before that request; rejected enqueue or failed native publication must
not erase it. Ordinary same-source native Resume keeps its existing path.

## Saved-range verification and final publication

Fallback source comparison remains byte-for-byte and validates the requested
range and qualified resource validator. A verified byte block renews a
20-second inactivity timeout. Connecting, response headers, and an idle body
cannot keep a probe alive without matching bytes. An independent ten-minute
deadline bounds even a continuously trickling response: that permits a typical
6 MiB range around 10 KiB/s but does not promise success at arbitrarily low
rates or for arbitrarily large legacy ranges. The two-probe global limit,
connection budgets, three-attempt backoff, and immediate cancellation remain.
Timeout diagnostics identify the phase, timeout kind, and bytes already
compared; these bytes are not credited as durable until the whole check passes.

Verification-only work reports running. Adopting previously saved bytes resets
the native throughput estimate.
This prevents local verification credit from appearing as new network traffic.
Once every input range is durable,
assembly reports all received bytes with zero network speed and no ETA, while
remaining nonterminal until publication succeeds. Assembly begin/completion
events include total bytes and elapsed duration. A Pause queued behind successful
publication cannot replace its completed record or recreate deleted checkpoints.

The tests use real loopback HTTP and a fake clock for productive body progress,
idle-body timeout, and the independent deadline. They also exercise publication
held behind a gate with Pause queued concurrently. These tests do not establish
physical-device throughput, native scheduling behavior, or full video playback.

### iOS 26 continued-processing progress

The continued-processing lease covers the whole queue. Its system progress uses
fine-grained, monotonic queue progress rather than resetting to each episode's
percentage. Manga native `_pNNNN` callbacks are routed only to their exact current
chapter/generation. Movement since each page's first observed fraction (including
its final `1`) advances network-work presentation before a full page is validated.
A fixed handoff baseline prevents later durable checkpoints from counting that
movement twice. First observations may undercount work already received; they
never invent a page completion. Dart remains the authority for validated page
counts, files and successful session completion.

The activity dot animates only with fresh positive throughput: a finite positive
speed sample or increasing native page fractions. Zero, stale, repeated or
regressing observations do not manufacture work. Title updates alone cannot keep
a BGContinuedProcessingTask alive. There is no app-owned 30-second no-progress
failure timer for this lease, and iOS provides no API to replace its expiration
policy with a speed threshold. OS expiration still releases the lease once and
leaves independent URLSession transport ownership intact.

The supplied October 30 device logs contain six reasonless `continued.expired`
callbacks (lease ages approximately 49–179 seconds), 1,948 rejected native page
observations, and one expiration reporting completedUnits == totalUnits despite
an unfinished queue. These observations motivate the page routing and queue
progress fixes; they do not establish Apple's expiration reason. Real-device
background/lock-screen testing on iOS 26 remains necessary.

Validation for this change: 21 production-manager lifecycle scenarios (platform
scheduler/timer fakes), seven diagnostic wiring/privacy checks, range handoff and
main-actor completion checks, retry metadata checks, and Swift iOS-target syntax
parsing passed. The regression scenarios fail against the previous PR head.
Flutter tests cannot initialize because the environment denies the Dart SDK
request to storage.googleapis.com (HTTP 403). The existing native diagnostic
logger executable test does not compile on this Linux host because its extracted
Apple URLSession APIs lack Linux FoundationNetworking support; native
CryptoKit/Security checks skip outside macOS. These limits do not establish an
iOS build or real-device background result.
