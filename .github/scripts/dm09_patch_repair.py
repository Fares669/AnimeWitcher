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
