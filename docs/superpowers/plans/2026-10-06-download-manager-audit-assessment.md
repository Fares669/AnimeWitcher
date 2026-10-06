# Download Manager V2 audit assessment

Scope: supplied deep audit versus PR264 head `770416556d64e887c5dd4461e3142da310988126`, followed by verified fixes on the same branch. The report lists 30 findings despite its stated total of 32. Severity and platform-policy conclusions are not accepted without supporting evidence.

| Finding | Assessment and resulting behavior |
| --- | --- |
| P0-1 recursive deletion | Restrict recursive deletion to owned manga chapter directories, with lexical and canonical containment. Absolute missing/file deletion avoids an unrelated path-provider call. |
| P0-2 admission leak | PR already rolls back some launches; persist terminal failures and promotion failures consistently. Count in-flight reservations while source resolution runs. |
| P0-3 start loses paused bytes | PR already shares exact resume logic. Preserve paused generation and metadata when exact resume fails; Retry is an explicit fresh start. |
| P0-4 startup retry loop | PR already adds failed intent, but transport/integrity failures must actually persist it. Restored failed rows can now explicitly restart from durable source descriptors. |
| P0-5 Windows assembly | Remove non-atomic copy fallback. Retry final rename, then park with ranges retained. Never adopt preallocated staging by size alone. Rebuild from verified parts. |
| P0-6 iOS expiration | Immediate completion already existed. Fence delayed cleanup to the expired task and acknowledge a lease once. The report does not establish its claimed SIGKILL cause. |
| P1-1 Android storage | Probe actual writes and fall back to app-specific storage. Remove all-files permission declaration; legacy write request matches API ≤28 manifest limit. Store acceptance is not guaranteed by this change. |
| P1-2 failed UI | State mapping already existed. Add visible failed state and Retry → restart, rather than paused → resume. |
| P1-3 registration timing | Report is incorrect for BGContinuedProcessingTask. Apple permits registration after launch when user intent occurs; retain dynamic registration. |
| P1-4 expired source loop | Fence budget accounting by current task inside the logical command queue; limit actual renewals and reset on explicit retry or verified completion. |
| P1-5 startup replay | Subscribe coordinator before package startup and disable startup age/count cleanup until initial reconciliation. Package tracking handles ordinary transfer replay independently. |
| P1-6 Content-Range parsing | Already fixed at PR head. Add characterization coverage for case, whitespace and wildcard totals. |
| P1-7 tiny byte ranges | Limit number of work units to byte count; reject reversed legacy checkpoint layouts. |
| P1-8 assembly headroom | Wire destination-volume native free-space query into existing durable assembler. Remove owned stale regular staging before measuring replacement space. Retain ranges when storage is insufficient. |
| P1-9 foreground main hop | Replace periodic main-thread queries with a locked lifecycle cache initialized at launch. |
| P1-10 queue credentials | Encrypt the complete native Codable queue using AES-GCM; store only its key in Keychain. Remove old plaintext only after successful migration. |
| P1-11 finite telemetry | Existing speed formatting was finite-safe. Add finite progress and zero aggregate-size guards. |
| P2-1 cleanup paths | Align exact media/legacy roots with public, app-specific and documents fallback paths. Broad Downloads directories are not ownership authority. |
| P2-2 ignored Range | Existing exact-206 preflight, slow start, full-body completion and sibling cancellation reduce waste. Package 9.6.2 exposes response metadata at completion; early cancellation after an origin changes behavior remains limited. |
| P2-3 rehydrate identity | Incorrect for locked package 9.6.2: Transfers returns the existing Transfer for a task ID. Do not replace this working adapter. |
| P2-4 admission pumps | Coalesce repeated requests while retaining a rerun flag for events arriving during a pass. |
| P2-5 periodic UI | Timer projects ephemeral manager progress; removing it would freeze updates. Skip idle publications and retain slow durable reconciliation. |
| P2-6 duplicate launch | Keep manager serialization and guard each UI item through selection, verification, confirmation and start. Other episodes remain independent. |
| P2-7 diagnostic retention | Incorrect at PR head: 4 MiB rotation, five retained files, cross-session retention, a bounded pending queue and progress sampling already exist. |
| P2-8 global network lock | Reserve logical admission under the short global lock; keep source/native work outside it with per-item/destination serialization. |
| P2-9 pause persistence | Durable pause intent before transport settlement protects crash recovery. Roll back rejected/throwing pause commands without claiming a running writer is paused. |
| P2-10 manga checkpoint | Temporary write and flush already exist. Remove live-file deletion before rename so failed replacement preserves the old checkpoint. |
| P3-1 host profile | Remove unreferenced host profile source and its obsolete tests. |
| P3-2 concurrency utility | Blanket deletion is unsafe: preference parsing, clamping and notification helpers remain live in V2/settings/UI. Retain them. |
| P3-3 connection governor | Report is incorrect: the parallel coordinator uses it for connection ceilings and HTTP pressure. Retain it. |

## Validation and limits

Baseline CI run 37497720984 had seven focused V2 failures. Most were caused by the newly unconditional documents lookup during deletion; one asserted the obsolete all-files permission request. New behavioral tests cover state recovery, admission, range assembly, checkpoint replacement, storage fallback, retry and metadata rollback. macOS CI compiles actual production encryption/completion helpers and exercises AES authentication and concurrent once-only completion. The iOS build checks full native integration.

No local Flutter/Swift runtime is installed. Static checks and Dart formatting do not substitute for CI. Device checks remain useful for Windows sharing violations, Android upgrade access to historical public files, and iOS lifecycle/protected-data behavior. Native queue encryption does not encrypt separate package/Dart stores. Device-only keys do not migrate to a new device; unreadable native state is protected from callback overwrites and requires a fresh authoritative Dart snapshot.
