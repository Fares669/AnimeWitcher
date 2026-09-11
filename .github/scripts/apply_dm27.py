from pathlib import Path

pub = Path('pubspec.yaml')
s = pub.read_text()
needle = '  path_provider: ^2.1.5\n'
if '  disk_usage: ^1.0.0\n' not in s:
    if needle not in s:
        raise SystemExit('pubspec path_provider anchor drift')
    s = s.replace(needle, needle + '  disk_usage: ^1.0.0\n', 1)
pub.write_text(s)

path = Path('lib/core/services/persistent_parallel_download.dart')
s = path.read_text()

const_anchor = 'const Duration kParallelProgressPersistInterval = Duration(seconds: 1);\n'
addition = """const Duration kParallelProgressPersistInterval = Duration(seconds: 1);

/// Keep a small reserve beyond the remaining staging allocation so assembly
/// does not consume the filesystem down to its last metadata blocks.
const int kParallelAssemblyStorageReserveBytes = 8 * 1024 * 1024;

enum ParallelAssemblyFailureReason { insufficientStorage }

class ParallelAssemblyFailure {
  const ParallelAssemblyFailure({required this.parentTaskId, required this.reason});

  final String parentTaskId;
  final ParallelAssemblyFailureReason reason;
}
"""
if 'enum ParallelAssemblyFailureReason' not in s:
    if const_anchor not in s:
        raise SystemExit('parallel constants anchor drift')
    s = s.replace(const_anchor, addition, 1)

ctor_anchor = '    this.onHostPressure,\n    this.onHostSample,\n  });'
ctor_repl = """    this.onHostPressure,
    this.onHostSample,
    this.availableStorageBytes,
    this.onAssemblyFailure,
    this.assemblyStorageReserveBytes = kParallelAssemblyStorageReserveBytes,
  });"""
if 'this.availableStorageBytes,' not in s:
    if ctor_anchor not in s:
        raise SystemExit('parallel constructor anchor drift')
    s = s.replace(ctor_anchor, ctor_repl, 1)

field_anchor = """  final void Function(String url, int activeConnections, double bytesPerSecond)?
  onHostSample;
"""
field_repl = """  final void Function(String url, int activeConnections, double bytesPerSecond)?
  onHostSample;

  /// Returns free bytes on the volume containing [path]. Null means the host
  /// could not answer, in which case allocation errors remain the safety net.
  final Future<int?> Function(String path)? availableStorageBytes;
  final void Function(ParallelAssemblyFailure failure)? onAssemblyFailure;
  final int assemblyStorageReserveBytes;
"""
if 'final Future<int?> Function(String path)? availableStorageBytes;' not in s:
    if field_anchor not in s:
        raise SystemExit('parallel field anchor drift')
    s = s.replace(field_anchor, field_repl, 1)

start = s.find('  Future<void> _assemble(_ParallelSession session) async {')
end = s.find('\n}\n\nclass _ParallelSession {', start)
if start < 0 or end < 0:
    raise SystemExit('assembly method boundary drift')

method = r"""  bool _isInsufficientStorageError(FileSystemException error) {
    final code = error.osError?.errorCode;
    if (code == 28 || code == 69 || code == 112 || code == 122) return true;
    final message =
        '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
    return message.contains('no space left') ||
        message.contains('disk full') ||
        message.contains('not enough space') ||
        message.contains('quota exceeded');
  }

  Future<bool> _hasAssemblyHeadroom(
    _ParallelSession session,
    File target, {
    required int remainingBytes,
  }) async {
    final probe = availableStorageBytes;
    if (probe == null) return true;
    try {
      final free = await probe(target.parent.path);
      if (free == null || free < 0) return true;
      final reserve =
          assemblyStorageReserveBytes < 0 ? 0 : assemblyStorageReserveBytes;
      return free >= remainingBytes + reserve;
    } catch (_) {
      // Storage telemetry is advisory. The write path below still catches
      // ENOSPC/EDQUOT and preserves every verified part.
      return true;
    }
  }

  Future<void> _handleAssemblyStorageFailure(
    _ParallelSession session,
    File staging, {
    FileSystemException? error,
  }) async {
    diagnosticLog?.record('assembly.insufficientStorage', {
      'taskId': session.task.taskId,
      'total': session.size,
      if (error?.osError?.errorCode != null)
        'osError': error!.osError!.errorCode,
    });
    try {
      if (await staging.exists()) await staging.delete();
    } catch (_) {}
    onAssemblyFailure?.call(
      ParallelAssemblyFailure(
        parentTaskId: session.task.taskId,
        reason: ParallelAssemblyFailureReason.insufficientStorage,
      ),
    );
    await _pause(session);
  }

  Future<void> _assemble(_ParallelSession session) async {
    diagnosticLog?.record('assembly.begin', {
      'taskId': session.task.taskId,
      'total': session.size,
      'count': session.parts.length,
    });
    final target = File(await session.task.filePath());
    if (await target.exists()) {
      if (await target.length() == session.size) {
        await _finishCompleteSession(session);
        return;
      }
      await _pause(session);
      return;
    }

    final staging = File('${target.path}.assembling');
    if (!await _hasAssemblyHeadroom(
      session,
      target,
      remainingBytes: session.size,
    )) {
      await _handleAssemblyStorageFailure(session, staging);
      return;
    }

    RandomAccessFile? output;
    try {
      output = await staging.open(mode: FileMode.write);
      await output.truncate(session.size);
      await output.setPosition(0);
      var assembledBytes = 0;
      for (final part in session.parts) {
        final file = File(await part.task.filePath());
        if (!await file.exists() || await file.length() != part.size) {
          await _pause(session);
          return;
        }
        final remaining = session.size - assembledBytes;
        if (!await _hasAssemblyHeadroom(
          session,
          target,
          remainingBytes: remaining,
        )) {
          await output.close();
          output = null;
          await _handleAssemblyStorageFailure(session, staging);
          return;
        }
        await for (final bytes in file.openRead()) {
          if (session.deleted) return;
          if (assembledBytes + bytes.length > session.size) {
            await _pause(session);
            return;
          }
          await output.writeFrom(bytes);
          assembledBytes += bytes.length;
        }
      }
      if (assembledBytes != session.size) {
        await _pause(session);
        return;
      }
      await output.flush();
    } on FileSystemException catch (error) {
      if (!_isInsufficientStorageError(error)) rethrow;
      try {
        await output?.close();
      } catch (_) {}
      output = null;
      await _handleAssemblyStorageFailure(session, staging, error: error);
      return;
    } finally {
      try {
        await output?.close();
      } catch (_) {}
    }
    if (session.deleted) return;
    if (!await staging.exists() || await staging.length() != session.size) {
      await _pause(session);
      return;
    }
    try {
      await staging.rename(target.path);
    } on FileSystemException catch (error) {
      if (!_isInsufficientStorageError(error)) rethrow;
      await _handleAssemblyStorageFailure(session, staging, error: error);
      return;
    }
    await _finishCompleteSession(session);
  }
"""
s = s[:start] + method + s[end:]
path.write_text(s)

service = Path('lib/core/services/download_service.dart')
d = service.read_text()
import_anchor = "import 'package:device_info_plus/device_info_plus.dart';\n"
if "package:disk_usage/disk_usage.dart" not in d:
    if import_anchor not in d:
        raise SystemExit('download service import anchor drift')
    d = d.replace(import_anchor, import_anchor + "import 'package:disk_usage/disk_usage.dart';\n", 1)

args_anchor = '      onPartProgress: (parent, child, progress) {'
args_add = """      availableStorageBytes: (path) => DiskUsage.freeSpace(path),
      onAssemblyFailure: (failure) {
        diagnosticLog.record('parallel.failure', {
          'taskId': failure.parentTaskId,
          'reason': failure.reason.name,
        });
        if (!_disposed) _parallelFailures.add(failure);
      },
      onPartProgress: (parent, child, progress) {"""
if 'availableStorageBytes: (path) => DiskUsage.freeSpace(path)' not in d:
    if args_anchor not in d:
        raise SystemExit('download service parallel callback anchor drift')
    d = d.replace(args_anchor, args_add, 1)

controller_anchor = '  final _updatesController = StreamController<TaskUpdate>.broadcast();\n'
controller_add = """  final _updatesController = StreamController<TaskUpdate>.broadcast();
  final _parallelFailures = StreamController<ParallelAssemblyFailure>.broadcast();

  Stream<ParallelAssemblyFailure> get parallelFailures => _parallelFailures.stream;
"""
if 'Stream<ParallelAssemblyFailure> get parallelFailures' not in d:
    if controller_anchor not in d:
        raise SystemExit('download service failure stream anchor drift')
    d = d.replace(controller_anchor, controller_add, 1)

dispose_anchor = '    await _updatesController.close();'
if 'await _parallelFailures.close();' not in d:
    if dispose_anchor not in d:
        raise SystemExit('download service dispose anchor drift')
    d = d.replace(dispose_anchor, dispose_anchor + '\n    await _parallelFailures.close();', 1)
service.write_text(d)

test = Path('test/core/services/persistent_parallel_download_storage_headroom_test.dart')
t = test.read_text()
statuses_anchor = '      final statuses = <TaskStatus>[];\n'
if 'final assemblyFailures = <ParallelAssemblyFailure>[];' not in t:
    if statuses_anchor not in t:
        raise SystemExit('DM27 statuses anchor drift')
    t = t.replace(statuses_anchor, statuses_anchor + '      final assemblyFailures = <ParallelAssemblyFailure>[];\n', 1)
ctor_test_anchor = '        livePartIds: () async => <String>{},\n'
ctor_test_add = """        livePartIds: () async => <String>{},
        availableStorageBytes: (path) async {
          final result = await Process.run('df', <String>['-Pk', path]);
          if (result.exitCode != 0) return null;
          final lines = (result.stdout as String).trim().split('\\n');
          final columns = lines.last.trim().split(RegExp(r'\\s+'));
          return int.parse(columns[3]) * 1024;
        },
        assemblyStorageReserveBytes: 4 * 1024,
        onAssemblyFailure: assemblyFailures.add,
"""
if 'onAssemblyFailure: assemblyFailures.add' not in t:
    if ctor_test_anchor not in t:
        raise SystemExit('DM27 test constructor anchor drift')
    t = t.replace(ctor_test_anchor, ctor_test_add, 1)
assertion_anchor = '      expect(statuses, isNot(contains(TaskStatus.complete)));\n'
assertion_add = """      expect(statuses, isNot(contains(TaskStatus.complete)));
      expect(assemblyFailures, hasLength(1));
      expect(
        assemblyFailures.single.reason,
        ParallelAssemblyFailureReason.insufficientStorage,
      );
"""
if 'assemblyFailures.single.reason' not in t:
    if assertion_anchor not in t:
        raise SystemExit('DM27 test assertion anchor drift')
    t = t.replace(assertion_anchor, assertion_add, 1)
test.write_text(t)
