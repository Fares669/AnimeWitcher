# AnimeRift comments — confirmed contract fix, 2026-11-05

## Confirmed root causes

Two client mismatches prevented comments from appearing:

1. The original request sends `sort_by=recently_added`. Without it, the real gateway returned HTTP 200 with empty `items` and null `userId`, including for a locally linked account. With it, the same One Piece thread returned 30 rows. Earlier probes tested other sort values, not this native default.
2. Those rows contain their body in `text`. The parser accepted only `comment` and rejected every row. It now accepts the live field while retaining compatibility with the older fixture format.

The shared provider sends the native sort for anime, episode, and reply reads. Regression coverage uses a sanitized real row and asserts anime/reply queries. The guard against silently dropping every nonempty server row remains intact.

## Shipped-artifact evidence

The APK SHA-256 is `5e0cba4d9bb397a94f9809ae7344394f0efcacb31f874b02909239174f00f288`. Its size and MD5 matched the file linked from the official site during this investigation. Its internal manifest version is 3.13.5; the external filename is not version proof.

REA/Ghidra overview evidence `ev_88afe9d374056de75c9dcc709508fc921866bec0e069c51aff6b097fcf76cf51` identifies extracted arm64 `libapp.so`, SHA-256 `a82b01e798a662694271d133429f5d29d654266dcbfb8392f5e2206d2a8e176d`. The overview does not recover Dart methods. Focused inspection of the existing Blutter pool and the same ARM64 bytes established:

- Constructor `0x7a1b54` loads pool entry `0x326e8`, the string `recently_added`; `0x7a1b90` stores it in state field offset 35.
- The request reads that field at `0xab6c38` and associates it with pool entry `0x31b50`, `sort_by`, at `0xab6c44`–`0xab6c4c`.
- The request uses pool entries `0x50af8` (`/comment/all`), `0x50b00` (`COMMENTS.VIEW`), and `0x50af0` (`canReply`), whose value is `1`.

Static instructions establish construction, not execution; live reads corroborate the correction.

## Live verification with the corrected provider and parser

An owner-issued temporary linking code was used locally. No credentials, identity values, or comment texts were printed, committed, passed in subagent task text, or retained in fixtures. The actual built-reference signing key matched the original APK, and the validated APK Firebase configuration was used.

| Read | Observed result |
| --- | --- |
| Exact main-series One Piece, page 0 | 30 parsed comments, more pages available, server user identity present |
| Page 1 | 30 parsed comments, including IDs absent from page 0 |
| Replies to a comment advertising replies | 1 parsed reply |

The final probe asserted all three outcomes without query rewriting. It made no comment, rating, favourite, or library mutations. These are API/provider checks, not a physical iOS UI run; no Android device/emulator was attached.

## Attached-log findings and bounded repairs

- Five HTTP 400 records labeled `other` precede successful device registration and belong to optional Firebase bootstrap. The built-reference Firebase API key differed from the APK resource key and reproduced HTTP 400 `INVALID_ARGUMENT` mentioning the API key. The APK key succeeded; `ANIMERIFT_FIREBASE_API_KEY` in GitHub was updated privately to that validated key.
- Live controls disproved a proposed FID-prefix explanation: Firebase accepted both tested prefix variants with the APK key. No speculative FID migration was shipped.
- The 241,939 ms request overlapped an iOS pause from elapsed 82,734 ms to 324,117 ms and failed immediately on return. It does not establish a four-minute foreground stall. A proposed extra Dart timeout was removed because it also pauses with the isolate.
- Concurrent home reads share their pending request, reducing duplicate traffic that can contribute to rate limits. This does not claim to eliminate server IP restrictions.
- Linked-account HTTP 403 remains an access failure rather than being mislabeled as a missing login. Paginated 403/429 errors propagate instead of silently reporting partial sync success. Credentials are preserved.
- The logger now retains the previously discarded `active` boolean, rejecting non-boolean values. An obsolete source-text assertion for the former inline log directory was removed; executable shared-directory coverage remains.
- The independent AnimeWitcher `nativeSync` record contains only its exception class, so its underlying cause cannot be determined from the attachment.

At the owner's request, the unsorted request was also compared through a verified different WARP IP and a verified German exit. It still returned empty data. Changing network location did not identify the comments defect; matching the native sort and row schema did. Temporary proxy experiments were disconnected.

## Automated verification

- The final focused provider, comments UI, cloud sync, and logging run passed 154 tests.
- A broad run with concurrency 4 reported 3,717 passing tests, 12 failures, and 3 skips. Its 8 affected download/reader test files were rerun serially: all 161 tests passed. No download/reader implementation was changed to mask those timing-sensitive failures.
- Analyzer completed without errors; 652 baseline warnings/information diagnostics remain.
- DeepSeek's final production-diff review found no blocking issues. A transient home-refresh error across an account switch remains possible; existing session guards prevent data from the previous account being exposed.

## Historical notes below — superseded by the verified fix above

## Actual read-only gateway evidence

Two opt-in GitHub Actions read-only runs with existing CI configuration and **guest** authentication were executed: `42075147183` and `42076058181`. They queried comment lists for two popular catalogue titles. Both returned successful responses with the keys `items`, `interactions`, `hasNext`, `page`, `userId`, but `items` was empty. The alternative requests also returned zero entries: no `level`, `level=1`, `page=1`, no `canReply`, no query filters (global), the same title as `eventId`, and `sort_by=date`, `createdAt`, or `top`. The data had no comments count in the two catalogue detail responses. No comment texts, account IDs, credentials, or headers were printed. These observations **do not prove** comments are absent for a signed-in AnimeRift user, or that the origin is authenticated; there was no owner-issued user session in CI.

## Verified client-side issue and correction

The Flutter screen previously rendered an empty-state `ListView` without attaching its pagination controller when page 0 was empty even if the server's `hasNext=true`. This made later pages unreachable. It now advances through up to three additional empty pages before deciding the list is empty. Regression coverage reproduces page 0 empty + `hasNext=true` + page 1 populated.

The live gateway response contains `userId`. The code now retains only its presence as a nullable boolean, **never the identifier**, and logs this with the client's signed-in status through `app.jsonl` as `active` and `parentActive` under `rift.comments.page`. The empty-state UI distinguishes guest responses and a server response that does not confirm the linked account, instead of always saying nobody posted comments. An authenticated Dio fixture proves GET `/comment/all` sends the linked account bearer token with integrity scope `COMMENTS.VIEW`. There is no authenticated E2E run here, so gateway acceptance of the owner's existing Rift token and actual comment visibility remain unresolved.

## Next diagnostic needed for a persistent empty list

On the updated app, open the problematic comment screen while the AnimeRift account is linked, then export `log/app.jsonl` from Settings > application/download logs. The relevant `rift.comments.page` record has only safe metadata (`count`, `active`, `parentActive`, `result`, and timing). If `active=true` but `parentActive=false`, investigate account recognition or server-side eligibility before changing query parameters. If both are true but `count=0` while the official client demonstrably displays comments for the same anime, investigate the official request target/pagination under that same account. No device-specific session or credential should be uploaded to the repository.
