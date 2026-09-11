from pathlib import Path

path = Path('test/core/services/download_source_refresh_checkpoint_guard_test.dart')
text = path.read_text()
old = '''    expect(\n      refresh,\n      contains(\n        r"throw StateError('Failed to persist source refresh boundary for ${task.taskId}')",\n      ),\n    );\n'''
new = '''    expect(\n      refresh,\n      contains(r'Failed to persist source refresh boundary for ${task.taskId}'),\n    );\n'''
if text.count(old) != 1:
    raise SystemExit(f'expected one formatter-sensitive assertion, got {text.count(old)}')
path.write_text(text.replace(old, new, 1))
