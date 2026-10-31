# iOS download queue implementation plan

> Execute inline with superpowers:executing-plans; finish with a fresh code review.

**Goal:** Keep manga queue transfers productive while the existing iOS continued-processing lease is alive, on `fix/ios-background-downloads`.

**Evidence:** October 31 logs show foreground-created pages progressing in background, followed by background-created pages remaining at zero until foreground return. Continued tasks expire at 92.8 and 65.1 seconds. Native capability reports false with installed background_downloader 9.6.5. Apple's background URLSession documentation makes background-created transfers discretionary even when `isDiscretionary` is false.

**Architecture:** Preserve the package transport authority and configured chapter/page concurrency. Select a default URLSession for manga pages only during a concrete attached continued-processing lease. Preserve the existing background session for all other cases. Both sessions use the package delegate and remain discoverable by package pause/cancel/recovery/Wi-Fi controls. Lease identity fencing prevents a stale expiration from revoking a new lease. Validate and enable the installed 9.6.5 completion contract.

**Tech stack:** Swift, CocoaPods Ruby patches, Flutter tests, portable Swift platform-boundary harnesses.

## Task 1: Regressions, then lease-bound manga transport

- [x] Add and run failing native session-selection and task-inventory tests, plus compatibility 9.6.5 coverage.
- [x] Add an idempotent, fail-closed build patch using existing Podfile integration patterns. Preserve plugin timeouts, proxy/network settings and delegate behavior.
- [x] Connect concrete lease attachment/completion/expiration to transport selection. Never cancel or replace an existing transfer during selection changes.
- [x] Prove selection, concurrency, pause/cancel visibility and stale lease fencing with portable Swift and Flutter checks.

## Task 2: Validate and update the same branch

- [x] Run native checks, Flutter suite, analysis, and whitespace checks; report actual limitations.
- [x] Document evidence, behavior and remaining physical-iOS validation.
- [x] Get a fresh reviewer, resolve important findings, then commit and update the existing branch (the user's explicit request authorizes that update).

**Device boundary:** A default session relies on the continued-processing execution lease. Expiration/process termination can interrupt it; no indefinite-background guarantee. Existing background-session work stays independent. No Xcode/device result may be claimed from portable tests.
