from pathlib import Path

path = Path('DOWNLOAD_MANAGER_PLAN.md')
text = path.read_text()
old = '- [ ] **DM-13 — Prevent head-of-line blocking and prove fairness across simultaneous downloads**'
new = '- [x] **DM-13 — Prevent head-of-line blocking and prove fairness across simultaneous downloads**'
if text.count(old) != 1:
    raise SystemExit(f'DM-13 checklist anchor count={text.count(old)}')
text = text.replace(old, new, 1)
marker = '  - **Dependencies:** DM-01, DM-10, DM-25.\n'
note = (
    '  - **Implementation notes (2026-09-11):** Multipart session pumps now run concurrently across logical downloads while each session retains its own serialization. Admission is revalidated immediately before the synchronous native-slot reservation, so a slow enqueue/persist in one session cannot block healthy sessions and concurrent pumps cannot overbook the global or per-session connection budget.\n'
    '  - **Confirmed root cause:** `_schedulePumpAll()` awaited every session serially, so slow `startPart`/storage work in one host prevented later sessions from reaching promotion. Simply parallelizing pumps would have introduced a stale-capacity race because global availability was computed before async record/manifest work; the final pre-reservation recheck closes that race.\n'
    '  - **Verification passed:** RED→GREEN stalled-host vs fast-host fairness coverage, pending-start lease/global budget regressions, persistent multipart scheduler/auto-recovery regressions, concurrency/governor tests, analyzer, and `git diff --check`.\n'
)
start = text.index(new)
pos = text.index(marker, start) + len(marker)
text = text[:pos] + note + text[pos:]
path.write_text(text)
