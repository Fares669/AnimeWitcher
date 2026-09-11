from pathlib import Path

path = Path('DOWNLOAD_MANAGER_PLAN.md')
text = path.read_text()
old = '- [ ] **DM-09 — Introduce one network-interruption/hold policy across all transports**'
new = '- [x] **DM-09 — Introduce one network-interruption/hold policy across all transports**'
if text.count(old) != 1:
    raise SystemExit(f'DM-09 plan marker drift: count={text.count(old)}')
text = text.replace(old, new, 1)
anchor = new + '\n'
notes = (
    '  - **Implemented:** offline transport failures now enter a durable `waitingForNetwork` state instead of spending host/server retry backoff; connectivity restoration reconciles behind generation + runtime-ownership fences, and native/iOS/Range paths share the same logical hold contract.\n'
    '  - **Verification passed:** network-hold RED→GREEN coverage, retry-policy/server-backoff separation, durable job/recovery state, Range/multipart adjacency, runtime ownership/generation fencing, startup reconciliation, queue authority, iOS offline retry-budget guards, and analyzer.\n'
)
if notes.strip() not in text:
    text = text.replace(anchor, anchor + notes, 1)
path.write_text(text)
