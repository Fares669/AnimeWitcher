# iOS background download audit

Audited against PR 268 branch `fix/downloaded-player-nonblocking-start`, commit
`093c9d6950e153fa078a9b568329ac788f3aa8b9`, and background_downloader 9.6.2.

## Evidence and confirmed defect

The supplied download diagnostic export contains 578 records. The current
transfer's section has a 143.683-second gap, then resumes reporting progress.
Its final sample is still running at 47.52%, with 16 active connections.
There are no app lifecycle, continued-processing expiration, or transport
failure events in that export. It does not establish why that particular gap
occurred, or prove that iOS terminated the app.

The code has a separate, reproducible background-continuation defect:

- `DownloadHookInstallation` accepts only 9.6.1, while the lockfile uses 9.6.2.
- Its result represents retired legacy transport ownership, which defaults to
  false. That result was also used as native immutable-range refill capability.
- Consequently, native refill is disabled even though Dart persists a refill
  plan. Once Flutter is suspended, the Dart scheduler cannot launch subsequent
  waves after the already-submitted URLSession ranges finish.

The original diagnostic file is not included in the repository.

## Changes

- Validate the exact 9.6.1/9.6.2 delegate contract and all required selectors
  before installing the observation seam. Unknown versions fail closed.
- Separate native immutable V2 range refill from retired whole-episode
  scheduling, retries, and logical completion. Those legacy controls stay off.
- Serialize Dart's pre-enqueue offer withdrawal against native claim commit.
  Use parent ID, child ID, attempt generation, real native ownership and dated
  owner-absence evidence. An ambiguous acknowledgement never starts a duplicate.
- Recheck active parent/plan authority at commit. Withdrawn, paused, canceled,
  or superseded offers cannot resurrect a transfer.
- Refill after terminal URLSession completion and background event delivery,
  with bounded execution grace for asynchronous task enumeration. Coalesced
  refill requests are retained. No timer is treated as unlimited execution.
- Forward generation-fenced native child observations to the durable
  coordinator. Inactive speed samples are not mistaken for successful files.
- Reconcile native-only live/completed ranges on foreground return, including
  children Dart never launched. Verify source/file evidence before assembly.
- Defer replacement continued-processing requests after background lease loss
  until foreground return. Expiration does not pause or cancel URLSession.
- Add download-only capability, lifecycle, handoff, and lease diagnostics.
  Signed URLs, headers, display names and free-form errors are excluded.

## What remains OS-managed or requires app runtime

Background URLSession owns submitted transfers in a separate process. Apple
controls when they run. A user force quit cancels background transfers and
prevents automatic relaunch until the user opens the app again.

Apple may delay newly created background transfers, including transfers
created from completion wakeups. Foreground return resets the background
resume-rate limiter. A continued-processing task is an expiring execution
lease and system UI, not a guarantee of unlimited processing time.

Native refill is deliberately limited to prepared, generation-fenced,
zero-byte immutable GET ranges. Source refresh, partial-range recovery,
verification, final assembly/publication, and admission of subsequent logical
episodes still belong to Dart/the package. If Flutter has no execution time,
those operations wait for runtime or foreground reconciliation. Range files
finishing is not presented as verified logical completion. This change does
not claim every episode in a playlist completes after indefinite suspension.

## Required physical-device validation

1. Start a multi-wave ranged video transfer in foreground. Background/lock the
   device long enough to outlast the continued-processing lease. Confirm native
   promotion events continue without new Dart scheduling, then compare final
   output bytes/hash after verified foreground assembly.
2. Repeat on supported pre-iOS-26 devices, where there is no continued task UI.
   Separate OS scheduling delays from application ownership failures.
3. Pause/cancel during asynchronous enumeration and immediately reopen. Verify
   no withdrawn child starts, no duplicate range writer appears, and progress
   reflects recoverable bytes.
4. Interrupt network connectivity, let a range fail, then reopen. Verify the
   remaining partial-range recovery uses the current attempt/source and retains
   completed ranges. Do not infer failure from a paused telemetry clock alone.
5. Exercise process termination by the OS separately from user force quit.
   Check native task inventory and checkpoint recovery after relaunch.
6. Complete the final ranges while Flutter is suspended. On foreground return,
   confirm reconciliation verifies and assembles exactly once, publishes without
   replacement, and only then marks logical completion.

## Automated validation

- 739 Flutter tests passed across V2, persistent parallel recovery, iOS native
  integration contracts, and continued-processing behavior.
- 19 additional offline/open/delete regressions passed.
- Portable Swift tests execute extracted production claim, snapshot,
  revocation, selection, resume and bounded-assertion code using platform fakes.
  They include 100 concurrent handoffs and cleanup of 1,000 completed parents.
- Native compatibility behavior, six Python integration/privacy/order guards,
  five Ruby version-export assertions, Swift production-source parsing, and
  diff whitespace checks passed.

The portable tests do not constitute an Xcode build or a physical-device
background-duration test. Those remain required before claiming device-proven
background reliability.

## Primary references

- [Apple: downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [Apple: background URLSession configuration](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:))
- [Apple: extending app background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
- [Apple: continued-processing requests](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest)
- [background_downloader 9.6.2 delegate source](https://github.com/781flyingdutchman/background_downloader/blob/V9.6.2/ios/background_downloader/Sources/background_downloader/UrlSessionDelegate.swift)
