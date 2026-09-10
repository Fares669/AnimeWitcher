import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Optional JSON-lines journal. No URLs, headers, filenames or exception text
/// are accepted: callers supply numeric diagnostics and internal identifiers.
/// Appends are serialized; failures never escape into the download engine.
class DownloadDiagnosticLog {
  DownloadDiagnosticLog(
    this.directory, {
    this.maxBytes = 4 * 1024 * 1024,
    this.maxFiles = 5,
    this.maxPending = 512,
  });
  final Future<Directory> Function() directory;
  final int maxBytes;
  final int maxFiles;
  final int maxPending;
  bool enabled = false;
  String? lastError;
  Future<void> _tail = Future.value();
  File? _file;
  int _rotation = 0;
  int _bytes = 0, _sequence = 0, _pending = 0, _dropped = 0;
  final String _session = '${DateTime.now().microsecondsSinceEpoch}-$pid';
  static const Duration _highFrequencySampleInterval = Duration(seconds: 1);
  final Map<String, DateTime> _lastHighFrequencyEventAt = <String, DateTime>{};

  Future<void> configure(bool value) async {
    if (enabled && !value) record('logging.disabled');
    enabled = false;
    await flush();
    _lastHighFrequencyEventAt.clear();
    if (value) {
      final dir = await directory();
      await dir.create(recursive: true);
      // Verify writability before the settings switch reports success.
      final probe = File('${dir.path}/.probe-$_session');
      await probe.writeAsString('');
      await probe.delete();
      lastError = null;
    }
    enabled = value;
    record('logging.enabled', {'enabled': value});
  }

  void record(String event, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    if (_suppressHighFrequencyProgress(event, fields)) return;
    if (_pending >= maxPending) {
      _dropped++;
      return;
    }
    // Strict allowlist prevents accidental disclosure through future callers.
    const allowed = {
      'taskId',
      'parentTaskId',
      'status',
      'progress',
      'bytes',
      'total',
      'speed',
      'attempt',
      'delayMs',
      'elapsedMs',
      'httpStatus',
      'errorType',
      'rangeStart',
      'rangeEnd',
      'count',
      'enabled',
      'active',
      'result',
      'reason',
      'range',
      'timeoutMs',
    };
    final data = <String, Object?>{};
    for (final entry in fields.entries) {
      if (!allowed.contains(entry.key)) continue;
      final value = entry.value;
      if (value is num) {
        if (value.isFinite) data[entry.key] = value;
      } else if (value is bool || value == null) {
        data[entry.key] = value;
      } else if (value is String &&
          value.length <= 160 &&
          RegExp(r'^[a-zA-Z0-9_. :/=-]+$').hasMatch(value) &&
          !value.contains('://')) {
        data[entry.key] = value;
      }
    }
    final line = jsonEncode({
      'time': DateTime.now().toUtc().toIso8601String(),
      'session': _session,
      'sequence': ++_sequence,
      'source': 'dart',
      'event': event,
      if (_dropped > 0) 'droppedEvents': _dropped,
      ...data,
    });
    _dropped = 0;
    _pending++;
    _tail = _tail.then((_) async {
      try {
        final bytes = utf8.encode('$line\n');
        if (_file == null || _bytes + bytes.length > maxBytes) {
          final dir = await directory();
          await dir.create(recursive: true);
          _file = File(
            '${dir.path}/download-dart-$_session-${(_rotation++).toString().padLeft(20, '0')}.log',
          );
          _bytes = 0;
          await _file!.writeAsString('');
          final files = await listFiles();
          final own = files
              .where(
                (f) => f.uri.pathSegments.last.startsWith('download-dart-'),
              )
              .toList();
          for (final old in own.skip(maxFiles)) {
            await old.delete();
          }
        }
        // Diagnostic progress is not recovery state. Closing each append is
        // sufficient here; forcing fsync on every sampled child is expensive on
        // iOS and can turn a 16-part download into continuous storage pressure.
        await _file!.writeAsBytes(bytes, mode: FileMode.append);
        _bytes += bytes.length;
        lastError = null;
      } catch (error) {
        lastError = error.runtimeType.toString();
        _file = null;
      } finally {
        _pending--;
      }
    });
  }

  bool _suppressHighFrequencyProgress(
    String event,
    Map<String, Object?> fields,
  ) {
    final highFrequency =
        event == 'native.progress' ||
        event == 'chunk.update' ||
        (event == 'task.update' && fields.containsKey('progress'));
    if (!highFrequency) return false;

    final taskId = fields['taskId']?.toString() ?? '';
    if (taskId.isEmpty) return false;
    final parentTaskId = fields['parentTaskId']?.toString() ?? '';
    final sampleId = parentTaskId.isNotEmpty
        ? parentTaskId
        : _inferredProgressOwner(taskId);
    final terminal =
        fields['result'] == true ||
        fields['status'] != null ||
        fields['errorType'] != null ||
        fields['httpStatus'] != null;
    if (terminal) {
      _lastHighFrequencyEventAt.remove('$event:$sampleId');
      return false;
    }

    final key = '$event:$sampleId';
    final now = DateTime.now();
    final previous = _lastHighFrequencyEventAt[key];
    if (previous != null &&
        now.difference(previous) < _highFrequencySampleInterval) {
      return true;
    }
    _lastHighFrequencyEventAt[key] = now;
    return false;
  }

  String _inferredProgressOwner(String taskId) {
    final marker = taskId.lastIndexOf('.part.');
    if (marker > 0) return taskId.substring(0, marker);
    return taskId;
  }

  Future<void> flush() => _tail;
  Future<List<File>> listFiles() async {
    final dir = await directory();
    if (!await dir.exists()) return [];
    final files = await dir
        .list()
        .where(
          (f) =>
              f is File &&
              f.uri.pathSegments.last.startsWith('download-') &&
              f.path.endsWith('.log'),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }
}
