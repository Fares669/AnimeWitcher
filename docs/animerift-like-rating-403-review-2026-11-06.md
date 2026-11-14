# AnimeRift optimistic interactions and session rejection review — 2026-11-06

The uploaded `app(1).jsonl` (345 valid records) and the supplied screenshots
were inspected without printing private comment bodies, account identities,
authorization headers or credentials. This file records the facts and limits
of the local PR #280 fixes.

## Observed

- Seven `PUT comment.react` requests had **HTTP 202**. The previous comments
  UI called `_reload()` after each accepted reaction and always used the
  unfilled heart because the comment parser only knows aggregate likes.
- Eight requests had **HTTP 403** with the recognized `deviceSuspended`
  server code, affecting catalog, details, search, characters and comments.
  The rejected requests were preceded by `registrationReused` on two app
  starts. The subsequent app start made a normal device registration
  (`HTTP 201` accepted), after which catalog requests were `HTTP 200`.
  These observations **do not establish an IP or physical-device ban** or
  establish that the separately installed official app uses the same session.
- The log contained one deferred native AnimeWitcher account `nativeSync`
  exception without its safe error code, and one 145-ms frame. Its exact
  nativeSync cause cannot be reconstructed from the old log.

## Changes

- Optimistic comments reaction display updates the number and filled heart
  immediately, prevents duplicate pending taps, and rolls back on failure.
  No full comments page refetch happens merely because a reaction succeeds.
  A bounded, account-scoped in-memory cache retains acknowledged reactions
  across reopening the comments page within this app session, without
  leaking them to another signed-in account.
- Rift rating saving updates the hero and ratings-panel display when selected,
  before waiting for the cloud write; failed **local journal persistence**
  rolls back. Successful local persistence queues the requested rating and
  attempts cloud confirmation asynchronously, reporting an unconfirmed write
  without discarding the local pending edit. Older rating fetches cannot
  overwrite the newer selection.
- On explicit `403 / DEVICE_SUSPENDED`, invalidate the stale local
  registration-success marker and retain a minimum one-minute cooldown.
  Do not mutate hardware identifiers, delete the user's linked-account
  credentials, immediately retry the blocked request or bypass server policy.
  A later ordinary app initialization may register the **same installation**
  only after the cooldown.
- Display `deviceSuspended` as **server refused the current device session**,
  rather than stating the device is categorically stopped.
- Add allowlisted error codes to new `nativeSync` diagnostic events. Do not
  serialize exception messages or arbitrary error codes.

## Verification and limits

- Flutter tests cover optimistic reactions, rollback, pending state,
  account-switch isolation, rating optimistic display, failed journal write,
  delayed server confirmation, and 403 cache invalidation/backoff.
- The native comment GET response has no **verified** field showing whether
  the current viewer previously liked each comment. The in-memory cache
  therefore only represents confirmed **local** actions in the current app
  process, not a complete cross-device reaction history.
- A new upload or real iOS session is necessary to see the specific native
  account `nativeSync` code, and authorized server requests are necessary to
  prove whether a previously rejected installation is now accepted.
- No live attempts to change the official server's suspension policies were
  made as part of this review.
