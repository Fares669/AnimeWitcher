# AnimeRift comments — 2026-11-05 investigation

## Actual read-only gateway evidence

Two opt-in GitHub Actions read-only runs with existing CI configuration and **guest** authentication were executed: `42075147183` and `42076058181`. They queried comment lists for two popular catalogue titles. Both returned successful responses with the keys `items`, `interactions`, `hasNext`, `page`, `userId`, but `items` was empty. The alternative requests also returned zero entries: no `level`, `level=1`, `page=1`, no `canReply`, no query filters (global), the same title as `eventId`, and `sort_by=date`, `createdAt`, or `top`. The data had no comments count in the two catalogue detail responses. No comment texts, account IDs, credentials, or headers were printed. These observations **do not prove** comments are absent for a signed-in AnimeRift user, or that the origin is authenticated; there was no owner-issued user session in CI.

## Verified client-side issue and correction

The Flutter screen previously rendered an empty-state `ListView` without attaching its pagination controller when page 0 was empty even if the server's `hasNext=true`. This made later pages unreachable. It now advances through up to three additional empty pages before deciding the list is empty. Regression coverage reproduces page 0 empty + `hasNext=true` + page 1 populated.

The live gateway response contains `userId`. The code now retains only its presence as a nullable boolean, **never the identifier**, and logs this with the client's signed-in status through `app.jsonl` as `active` and `parentActive` under `rift.comments.page`. The empty-state UI distinguishes guest responses and a server response that does not confirm the linked account, instead of always saying nobody posted comments. An authenticated Dio fixture proves GET `/comment/all` sends the linked account bearer token with integrity scope `COMMENTS.VIEW`. There is no authenticated E2E run here, so gateway acceptance of the owner's existing Rift token and actual comment visibility remain unresolved.

## Next diagnostic needed for a persistent empty list

On the updated app, open the problematic comment screen while the AnimeRift account is linked, then export `log/app.jsonl` from Settings > application/download logs. The relevant `rift.comments.page` record has only safe metadata (`count`, `active`, `parentActive`, `result`, and timing). If `active=true` but `parentActive=false`, investigate account recognition or server-side eligibility before changing query parameters. If both are true but `count=0` while the official client demonstrably displays comments for the same anime, investigate the official request target/pagination under that same account. No device-specific session or credential should be uploaded to the repository.
