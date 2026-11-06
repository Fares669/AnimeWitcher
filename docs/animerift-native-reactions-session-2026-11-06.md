# AnimeRift: server-owned comment reactions and device session (2026-11-06)

## Evidence from the official APK

Source: original version **3.13.5**, `com.riftapps.animerift`, Flutter ARM64
`libapp.so` (SHA-256
`a82b01e798a662694271d133429f5d29d654266dcbfb8392f5e2206d2a8e176d`).
The restored AOT constant pool and original ELF instructions were inspected.
No account or signing secrets are included here.

- `GET /comment/all`, scope `COMMENTS.VIEW`:
  `0xab6f0c–0xab701c` reads `items` and **`interactions`** as lists and
  `interaction_keys` as an optional map, then calls the native interaction
  processing routine `0xab77f8`.
- `0xab80ec–0xab8450` normalizes `interaction_keys['like']` to the actual
  action string, defaulting to `like`; analogous keys for `reply` and `report`.
  Each viewer interaction's **`_comment`** is a plain comment ID and `action`
  is a string. For a like, `reaction_type` is matched directly against the
  original enum name (`thumbsUp`, `heartFace`, etc.). It is **not** remapped
  through `interaction_keys`. The native app attaches the viewer's selected
  reaction to each matching comment. Missing/`none` means no reaction.
- `GET /comment/reactions/{commentId}`, scope `COMMENTS.REACTIONS`, is a
  **separate list of reacting users**. The native routine reads top-level
  `reactions` and `users` arrays; it does not need to be called per comment
  to determine whether the viewer already reacted.

This establishes that reaction ownership comes from the **server's own
viewer-scoped interactions** on every comment-page GET, including a cold app
launch. A local optimistic cache is optional and cannot replace that data.

## Corrected implementation

- `AnimeRiftCommentPage.fromJson` now parses `interactions` and optional
  mapped like action, associates `_comment` with the displayed row, and sets
  a nullable `likedByMe` flag for an explicit `thumbsUp` reaction. When
  `interactions` is missing, ownership stays **unknown** rather than false.
- The comments UI prefers authoritative server-reported reaction state after
  each GET and retains optimistic updates while a mutation is pending. The
  same server state is read again after closing and reopening the screen or
  restarting the app; no persisted user comment IDs or arbitrary author IDs
  are required. Non-`thumbsUp` reaction types are not mislabeled as thumbsUp.
- Regression tests cover mapped/default action keys, reaction type filtering,
  missing interaction metadata and a fresh provider instance with an already
  liked comment, plus toggling it off without refetching the entire page.

## Device registration difference

The official APK's registration handler at `0xb0a1b4–0xb0a618` obtains a
`sessionKey` from an HTTP **201** registration response. Its integrity/JWT
signer at `0x55775c–0x557944` uses the bootstrap key for the **register**
scope and the returned **sessionKey** for ordinary requests, with a 10-second
integrity JWT lifetime. Previously AnimeWitcher ignored `sessionKey`, reused
a local success timestamp on a cold start and signed ordinary calls with the
bootstrap key. This mismatch may explain some 403 responses, but no live
server observation yet proves that it caused every rejection.

The correction must use this key only in memory, never in diagnostics,
plaintext preferences or test output; must not change device identity or
automatically replay any rejected write; must honor normal registration
cooldowns. New mocked cold-start checks must prove the real server-provided
key is required and the existing signed-in user session survives.

## Remaining validation boundary

The tests prove request and response handling using native-grounded fixtures.
They do not establish that the production server currently accepts the
user's particular installation after `DEVICE_SUSPENDED`. That requires an
authorized login and restart on a real device with ordinary traffic, not
repeated requests, identity rotation or circumvention of server restrictions.
