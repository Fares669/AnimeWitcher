from pathlib import Path

path = Path('DOWNLOAD_MANAGER_PLAN.md')
text = path.read_text()
pending = '- [ ] **DM-10 — Replace time-based correctness fences with generations/acks**'
done = '- [x] **DM-10 — Replace time-based correctness fences with generations/acks**'

if pending in text:
    text = text.replace(pending, done, 1)
elif done not in text:
    raise SystemExit('DM-10 heading not found')

start = text.index(done)
dep = '  - **Dependencies:** DM-01, DM-19, DM-05.\n'
dep_index = text.index(dep, start)
notes = (
    '  - **Implementation notes (2026-09-11):** Ownership-changing pause, resume, cancel, retry/resume execution, waiter restack, fresh start and source replacement now advance the durable JobStore generation before executor effects. Token-aware callbacks from superseded generations are rejected; native callbacks without an operation id are fenced by authoritative logical state plus runtime ownership acknowledgement. Completion is published only after DM-06 resource verification commits the durable completed state.\n'
    '  - **Confirmed root cause:** cancel/restack still depended on 500 ms / 800 ms suppression sets, while several native control operations changed ownership without advancing the durable generation. A callback delayed beyond those windows could therefore cross into a newer operation; canceled/orphaned rows could also be reopened by a newer write.\n'
    '  - **Verification passed:** RED→GREEN canceled-tombstone reopening, pause→resume stale callback, retry stale failure, source-level removal of the 500 ms/800 ms correctness windows, ownership-acknowledged restack, generation-before-effect guards for pause/cancel/source refresh, verified-completion-before-publication, adjacent pause/cancel/runtime ownership/source-refresh/JobStore regressions, and analyzer.\n'
)
if 'Ownership-changing pause, resume, cancel' not in text[start:]:
    insert_at = dep_index + len(dep)
    text = text[:insert_at] + notes + text[insert_at:]

path.write_text(text)
