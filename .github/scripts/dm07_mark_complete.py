from pathlib import Path

path = Path('DOWNLOAD_MANAGER_PLAN.md')
text = path.read_text()
heading = '- [ ] **DM-07 — Make delete a durable tombstone-first ownership-settlement transaction**'
if text.count(heading) != 1:
    raise SystemExit(f'expected one unchecked DM-07 heading, got {text.count(heading)}')
text = text.replace(
    heading,
    '- [x] **DM-07 — Make delete a durable tombstone-first ownership-settlement transaction**',
    1,
)
anchor = '  - **Dependencies:** DM-19, DM-21, DM-30, DM-10.\n'
start = text.index('- [x] **DM-07 —')
pos = text.index(anchor, start) + len(anchor)
notes = (
    '  - **Implementation notes (2026-09-11):** User delete now persists a generation-fenced `canceled` JobStore tombstone before any Range/native/multipart cancellation. Destructive plugin DB, metadata, refresh-descriptor and video cleanup occurs only after the runtime ownership oracle proves `notOwned`; the JobStore tombstone remains durable after cleanup. Repeated delete is idempotent, and missing/completed execution rows can be explicitly tombstoned without weakening the generic terminal-state fence.\n'
    '  - **Tombstone retention/GC:** canceled tombstones use an explicit 30-day retention policy and may be removed only after age threshold plus independently proven released ownership and absent plugin/metadata projections. Startup reconciliation retries idempotent cleanup for settled tombstones before evaluating GC.\n'
    '  - **Confirmed root cause:** the prior cancel path deleted its own JobStore `canceled` row immediately after ownership settlement, while `downloads_provider.dart` separately deleted plugin DB rows, Hive metadata and files. A crash/late callback could therefore outlive the only terminal fact, and presentation code raced the service for destructive cleanup.\n'
    '  - **Verification passed:** RED→GREEN explicit completed→canceled deletion tombstone, late-reopen fence, repeated-delete idempotency, missing-row tombstone, age/ownership/projection GC policy, service-owned delete guards, cancel ownership/checkpoint/settlement regressions, DM-10 callback-generation regressions, logical-identity/JobState presentation regressions, analyzer and `git diff --check`.\n'
)
if notes.splitlines()[0] not in text:
    text = text[:pos] + notes + text[pos:]
path.write_text(text)
