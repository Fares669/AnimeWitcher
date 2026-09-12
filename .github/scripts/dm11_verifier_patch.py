from pathlib import Path
import runpy

runpy.run_path('.github/scripts/dm11_foundation_patch.py', run_name='__main__')

path = Path('lib/core/services/download_job_store.dart')
source = path.read_text()
if 'class InMemoryDownloadJobStoreBackend' not in source:
    anchor = '''abstract interface class DownloadJobBackend {
  Future<Map<String, dynamic>?> read(String taskId);
  Future<List<Map<String, dynamic>>> readAll();
  Future<void> write(String taskId, Map<String, Object?> value);
  Future<void> delete(String taskId);
}
'''
    implementation = r'''

/// Deterministic durable-backend double used by transaction tests.
/// Reusing one backend simulates relaunch with a new store instance.
class InMemoryDownloadJobStoreBackend implements DownloadJobBackend {
  final Map<String, Map<String, Object?>> _rows =
      <String, Map<String, Object?>>{};

  @override
  Future<Map<String, dynamic>?> read(String taskId) async {
    final row = _rows[taskId];
    return row == null ? null : Map<String, dynamic>.from(row);
  }

  @override
  Future<List<Map<String, dynamic>>> readAll() async => _rows.values
      .map((row) => Map<String, dynamic>.from(row))
      .toList(growable: false);

  @override
  Future<void> write(String taskId, Map<String, Object?> value) async {
    _rows[taskId] = Map<String, Object?>.from(value);
  }

  @override
  Future<void> delete(String taskId) async {
    _rows.remove(taskId);
  }
}
'''
    if anchor not in source:
        raise SystemExit('DM-11 in-memory backend anchor drift')
    path.write_text(source.replace(anchor, anchor + implementation, 1))
