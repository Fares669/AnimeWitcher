from pathlib import Path

path = Path('.github/scripts/dm09_network_hold_patch.py')
text = path.read_text()
block = '''replace_once(
    job_state,
    "    DownloadJobState.retryWaiting => TaskStatus.waitingToRetry,\\n",
    "    DownloadJobState.retryWaiting ||\\n    DownloadJobState.waitingForNetwork => TaskStatus.waitingToRetry,\\n",
)
'''
if text.count(block) != 2:
    raise SystemExit(f'DM-09 mapping repair drift: count={text.count(block)}')
replacement = '''p = Path(job_state)
text = p.read_text()
old_status_mapping = "    DownloadJobState.retryWaiting => TaskStatus.waitingToRetry,\\n"
new_status_mapping = (
    "    DownloadJobState.retryWaiting ||\\n"
    "    DownloadJobState.waitingForNetwork => TaskStatus.waitingToRetry,\\n"
)
if text.count(old_status_mapping) != 2:
    raise SystemExit(
        f"DM-09 status mapping drift: expected 2 occurrences, got {text.count(old_status_mapping)}"
    )
p.write_text(text.replace(old_status_mapping, new_status_mapping))
'''
first = text.index(block)
second = text.index(block, first + len(block))
text = text[:first] + replacement + text[first + len(block):second] + text[second + len(block):]
path.write_text(text)

# The retry-policy regression was reformatted after the original DM-09 patch
# was authored. Normalize only that pre-implementation test shape so the main
# patch can still assert the behavioral change with its exact replacement.
retry_test = Path('test/core/services/download_retry_policy_test.dart')
retry_text = retry_test.read_text()
formatted = '''  test('connection failure is retryable without an HTTP status', () {
    final decision = planDownloadFailure(
      connectionFailure: true,
      retryIndex: 0,
      jitterUnit: 0.5,
    );
    expect(decision.action, DownloadFailureAction.retry);
    expect(decision.delay, kDownloadRetryBaseDelay);
  });
'''
legacy_anchor = '''  test('connection failure is retryable without an HTTP status', () {
    final decision = planDownloadFailure(connectionFailure: true);
    expect(decision.action, DownloadFailureAction.retry);
    expect(decision.delay, kDownloadRetryBaseDelay);
  });
'''
if formatted in retry_text:
    retry_test.write_text(retry_text.replace(formatted, legacy_anchor, 1))
elif legacy_anchor not in retry_text:
    raise SystemExit('DM-09 retry test repair drift')
