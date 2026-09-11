from pathlib import Path

path = Path('DOWNLOAD_MANAGER_PLAN.md')
text = path.read_text()
pending = '- [ ] **DM-16 — Separate historical presentation progress from recoverable-byte evidence**'
done = '- [x] **DM-16 — Separate historical presentation progress from recoverable-byte evidence**'

if pending in text:
    text = text.replace(pending, done, 1)
elif done not in text:
    raise SystemExit('DM-16 heading not found')

start = text.index(done)
dep = '  - **Dependencies:** DM-20, DM-29, DM-05, DM-06.\n'
dep_index = text.index(dep, start)
notes = (
    '  - **Implementation notes (2026-09-11):** Resume/restart decisions now consume native-resume ownership and surviving local bytes only. Historical percentage remains a presentation high-water mark for UI continuity, but cannot fabricate durable bytes or block a safe zero-byte restart; multipart follows the same rule.\n'
    '  - **Confirmed root cause:** `savedProgress > 0` was used as a recovery-evidence fence in both the generic resume helpers and multipart resume path, so stale UI progress could strand a task even after all native resume data and local bytes were gone.\n'
    '  - **Verification passed:** RED→GREEN stale-42% and 0.999-sentinel zero-restart coverage, legacy resume-helper expectations, multipart historical-progress guard, visible-partial/native-resume protections, DM-20 byte reconciliation, DM-06 resource-identity regressions, runtime ownership regressions, and analyzer.\n'
)
if 'Resume/restart decisions now consume native-resume ownership' not in text[start:]:
    insert_at = dep_index + len(dep)
    text = text[:insert_at] + notes + text[insert_at:]

path.write_text(text)
