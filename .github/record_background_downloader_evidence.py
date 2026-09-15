from pathlib import Path

plan_path = Path('docs/superpowers/plans/2026-09-15-background-downloader-authority.md')
text = plan_path.read_text()


def replace_once(old: str, new: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'expected exactly one match for {old!r}, found {count}')
    text = text.replace(old, new, 1)

replace_once(
    '- [ ] **Step 2: Run full Flutter verification**\n\n```bash\nflutter pub get\nflutter analyze --no-fatal-warnings --no-fatal-infos\nflutter test --dart-define=ANIMEWITCHER_FIREBASE_API_KEY=test-api-key\n```\nExpected: 0 analyzer errors and 0 test failures.',
    '- [x] **Step 2: Run full Flutter verification**\n\n```bash\nflutter pub get\nflutter analyze --no-fatal-warnings --no-fatal-infos\nflutter test --dart-define=ANIMEWITCHER_FIREBASE_API_KEY=test-api-key\n```\nExpected: 0 analyzer errors and 0 test failures.\n\nEvidence: PR CI run `34991783176` passed generation, analyzer, full Flutter tests, and native Swift logger typecheck on head `2a8d4209bcd0e09224ec4fc154db94eac2d269c7`.',
)

replace_once(
    '- [ ] **Step 1: Write migration RED tests from schema v7 rows**',
    '- [x] **Step 1: Write migration RED tests from schema v7 rows**',
)
replace_once(
    '- [ ] **Step 2: Run RED**\n\n```bash\nflutter test test/core/services/download_job_store_test.dart\n```',
    '- [x] **Step 2: Run RED**\n\n```bash\nflutter test test/core/services/download_job_store_test.dart\n```\n\nEvidence: schema-v7 compatibility and JobStore/state/logical-identity/recovery verification passed in focused run `34988261570`; the compatibility test preserves pause/delete intent, logical identity, and resource fingerprint.',
)

replace_once(
    '- [ ] **Step 1: Prove no normal-path references remain**',
    '- [x] **Step 1: Prove no normal-path references remain**',
)
replace_once(
    'Every surviving reference must be either explicit legacy migration/exceptional refreshed-source recovery or removed.',
    'Every surviving reference must be either explicit legacy migration/exceptional refreshed-source recovery or removed.\n\nAudit evidence: `_rangeTransfers.start(...)` survives only in verified partial/source recovery; `downloadConnectionRampBatches(...)` and the remaining iOS multipart claim state are confined to the still-active legacy fallback and therefore are not removable until real-device plugin-parallel acceptance closes that fallback.',
)

replace_once(
    '- [ ] **Step 2: Run full analyzer/test suite fresh**\n\n```bash\nflutter pub get\nflutter analyze --no-fatal-warnings --no-fatal-infos\nflutter test --dart-define=ANIMEWITCHER_FIREBASE_API_KEY=test-api-key\n```\nExpected: 0 failures.',
    '- [x] **Step 2: Run full analyzer/test suite fresh**\n\n```bash\nflutter pub get\nflutter analyze --no-fatal-warnings --no-fatal-infos\nflutter test --dart-define=ANIMEWITCHER_FIREBASE_API_KEY=test-api-key\n```\nExpected: 0 failures.\n\nEvidence: run `34991783176` completed with 0 analyzer errors and 0 Flutter test failures; native Swift logger typecheck also passed.',
)

plan_path.write_text(text)
