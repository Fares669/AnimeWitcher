from pathlib import Path

path = Path('test/core/services/persistent_parallel_download_test.dart')
source = path.read_text()
old = '''      await completePart(first, <int>[0, 1, 2, 3, 4]);
      await waitUntil(() => coordinator.activeConnectionCount == 0);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(records[first.taskId]?.status, TaskStatus.complete);
      expect(settled, contains(parent.taskId));
'''
new = '''      await completePart(first, <int>[0, 1, 2, 3, 4]);
      await waitUntil(() => coordinator.activeConnectionCount == 0);
      await waitUntil(() => settled.contains(parent.taskId));
      expect(records[first.taskId]?.status, TaskStatus.complete);
      expect(settled, contains(parent.taskId));
'''
count = source.count(old)
if count != 1:
    raise SystemExit(f'expected exactly one pause-drain test block, found {count}')
path.write_text(source.replace(old, new, 1))
Path('.github/workflows/_temporary_flutter_checks_patch.yml').unlink()
Path('tool/_temporary_flutter_checks_patch.py').unlink()
