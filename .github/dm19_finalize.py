from pathlib import Path

path = Path('DOWNLOAD_MANAGER_PLAN.md')
text = path.read_text()
text = text.replace(
    '- [ ] **DM-19 — Replace DB-filtered liveness with an independent runtime ownership oracle**',
    '- [x] **DM-19 — Replace DB-filtered liveness with an independent runtime ownership oracle**',
    1,
)
status = "  - **Implementation status (2026-09-11):** Runtime ownership model and fail-closed writer guard are being implemented. The plugin's public `allTasks(allGroups: true)` active-executor query is now the native ownership source instead of filtering that result with persisted DB `paused` rows; Range ownership remains an independent positive signal. Query failure maps to `unknown`, which blocks a new writer, and accepted-but-unsettled ownership has an explicit `settling` state for subsequent control-ack work.\n"
replacement = "  - **Implementation notes (2026-09-11):** Added explicit `owned / notOwned / settling / unknown` runtime ownership semantics with a fail-closed `blocksNewWriter` rule. `_liveTransferTasks()` now consumes the plugin's runtime-active `allTasks(allGroups: true)` result directly instead of removing IDs based on persisted `paused` rows. Range activity is independent positive ownership evidence, successful runtime absence is the negative acknowledgement for `notOwned`, and query failure remains `unknown`. Multipart start/pause paths now consult this oracle so an ambiguous owner cannot cause a second writer.\n"
if status not in text:
    raise SystemExit('DM-19 in-progress note missing')
text = text.replace(status, replacement, 1)
anchor = "  - **Confirmed root cause:** `_liveTransferTasks()` took an executor-active result and then removed IDs solely because the persistent database projected them as `paused`, allowing stale DB state to overrule stronger runtime evidence.\n"
verification = anchor + "  - **Verification passed:** `Guarded DM-19 implementation` run 34537930159 passed patch application, formatting, generation, `download_runtime_ownership_test.dart`, all three targeted multipart/lease regression suites, `flutter analyze --no-fatal-warnings --no-fatal-infos`, diff checks, commit and push. Coverage verifies runtime-active ownership wins regardless of stale persisted pause, successful runtime absence yields `notOwned`, failed liveness with a rehydrated Transfer handle remains `unknown`, `settling` and `unknown` block a writer, and Range activity is authoritative positive evidence.\n"
if anchor not in text:
    raise SystemExit('DM-19 root cause note missing')
text = text.replace(anchor, verification, 1)
path.write_text(text)
