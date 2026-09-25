import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'download_v2_identity.dart';
import 'download_v2_models.dart';

enum DownloadV2HoldCategory { packageHeld }

enum DownloadV2SourceRefreshReason { authorizationExpired }

enum DownloadV2IntegrityResult { valid, missing, empty, sizeMismatch, invalid }

/// Allowlisted diagnostic event for Download Manager V2.
///
/// This type deliberately has no URL, header, provider response, or free-form
/// exception/message field, so signed query parameters and authorization data
/// cannot enter V2 diagnostic serialization through this API.
final class DownloadDiagnosticEventV2 {
  const DownloadDiagnosticEventV2({
    required this.logicalId,
    required this.generation,
    required this.taskId,
    required this.status,
    required this.progress,
    this.transferredBytes,
    this.totalBytes,
    this.networkSpeedMBps,
    this.timeRemainingSeconds,
    this.configuredConnections,
    this.activeConnections,
    this.failureCategory,
    this.holdCategory,
    this.sourceRefreshReason,
    this.integrityResult,
  }) : assert(generation > 0),
       assert(taskId != ''),
       assert(progress >= 0 && progress <= 1);

  final DownloadLogicalId logicalId;
  final int generation;
  final String taskId;
  final DownloadTransportStatus status;
  final double progress;
  final int? transferredBytes;
  final int? totalBytes;
  final double? networkSpeedMBps;
  final int? timeRemainingSeconds;
  final int? configuredConnections;
  final int? activeConnections;
  final DownloadFailureCategory? failureCategory;
  final DownloadV2HoldCategory? holdCategory;
  final DownloadV2SourceRefreshReason? sourceRefreshReason;
  final DownloadV2IntegrityResult? integrityResult;

  Map<String, Object?> toJson() => <String, Object?>{
    'logicalId': logicalId.value,
    'generation': generation,
    'taskId': taskId,
    'status': status.name,
    'progress': progress,
    if (transferredBytes != null) 'transferredBytes': transferredBytes,
    if (totalBytes != null) 'totalBytes': totalBytes,
    if (networkSpeedMBps != null && networkSpeedMBps! >= 0)
      'networkSpeedMBps': networkSpeedMBps,
    if (timeRemainingSeconds != null && timeRemainingSeconds! > 0)
      'timeRemainingSeconds': timeRemainingSeconds,
    if (configuredConnections != null && configuredConnections! > 0)
      'configuredConnections': configuredConnections,
    if (activeConnections != null && activeConnections! >= 0)
      'activeConnections': activeConnections,
    if (failureCategory != null) 'failureCategory': failureCategory!.name,
    if (holdCategory != null) 'holdCategory': holdCategory!.name,
    if (sourceRefreshReason != null)
      'sourceRefreshReason': sourceRefreshReason!.name,
    if (integrityResult != null) 'integrityResult': integrityResult!.name,
  };
}

abstract interface class DownloadDiagnosticsV2 {
  void record(DownloadDiagnosticEventV2 event);

  /// Records transport/coordinator facts that have no application logical ID
  /// yet (startup inventory, child ownership, recovery, checkpoint health).
  /// Implementations must keep a strict field allowlist: no URLs, headers or
  /// free-form exception/message text may cross this boundary.
  void recordTransport(String event, Map<String, Object?> fields);
}

final class NoopDownloadDiagnosticsV2 implements DownloadDiagnosticsV2 {
  const NoopDownloadDiagnosticsV2();

  @override
  void record(DownloadDiagnosticEventV2 event) {}

  @override
  void recordTransport(String event, Map<String, Object?> fields) {}
}

/// Deterministic sink used by V2 regression tests and debug projections.
final class InMemoryDownloadDiagnosticsV2 implements DownloadDiagnosticsV2 {
  final List<DownloadDiagnosticEventV2> _events =
      <DownloadDiagnosticEventV2>[];
  final List<Map<String, Object?>> _transportEvents =
      <Map<String, Object?>>[];

  List<DownloadDiagnosticEventV2> get events =>
      List<DownloadDiagnosticEventV2>.unmodifiable(_events);
  List<Map<String, Object?>> get transportEvents =>
      List<Map<String, Object?>>.unmodifiable(_transportEvents);

  @override
  void record(DownloadDiagnosticEventV2 event) {
    _events.add(event);
  }

  @override
  void recordTransport(String event, Map<String, Object?> fields) {
    _transportEvents.add(<String, Object?>{
      'event': event,
      ..._sanitizeTransportFields(fields),
    });
  }
}

/// Append-only JSONL diagnostics for production V2 downloads.
///
/// The sink accepts only [DownloadDiagnosticEventV2], so transport URLs,
/// request headers, signed query parameters and free-form exception text never
/// cross this serialization boundary. File I/O is serialized and deliberately
/// isolated from download control: a logging failure can never fail a transfer.
final class FileDownloadDiagnosticsV2 implements DownloadDiagnosticsV2 {
  FileDownloadDiagnosticsV2({
    required Future<Directory> Function() directoryProvider,
    required bool Function() enabled,
    int Function()? nowMillis,
    String? sessionId,
    this.fileName = 'download_v2.jsonl',
    this.maxBytes = 5 * 1024 * 1024,
    this.maxFiles = 3,
  }) : assert(maxBytes > 0),
       assert(maxFiles > 0),
       _directoryProvider = directoryProvider,
       _enabled = enabled,
       _nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch),
       _sessionId =
           sessionId ?? '${DateTime.now().microsecondsSinceEpoch}-$pid';

  final Future<Directory> Function() _directoryProvider;
  final bool Function() _enabled;
  final int Function() _nowMillis;
  final String _sessionId;
  final String fileName;
  final int maxBytes;
  final int maxFiles;

  Future<void> _tail = Future<void>.value();
  Object? _lastError;
  int _sequence = 0;
  final Stopwatch _elapsed = Stopwatch()..start();

  Object? get lastError => _lastError;

  Future<Directory> directory() async {
    final directory = await _directoryProvider();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<List<File>> listFiles() async {
    final logDirectory = await directory();
    final files = await logDirectory
        .list()
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  @override
  void record(DownloadDiagnosticEventV2 event) {
    _enqueue(<String, Object?>{
      'recordType': 'snapshot',
      'event': 'snapshot',
      ...event.toJson(),
    });
  }

  @override
  void recordTransport(String event, Map<String, Object?> fields) {
    if (!_safeDiagnosticToken(event)) return;
    _enqueue(<String, Object?>{
      'recordType': 'transport',
      'event': event,
      ..._sanitizeTransportFields(fields),
    });
  }

  void _enqueue(Map<String, Object?> body) {
    if (!_enabled()) return;
    final payload = <String, Object?>{
      'timestampMillis': _nowMillis(),
      'sessionId': _sessionId,
      'sequence': ++_sequence,
      'elapsedMs': _elapsed.elapsedMilliseconds,
      ...body,
    };
    _tail = _tail.then<void>((_) async {
      try {
        final logDirectory = await directory();
        final file = File(
          '${logDirectory.path}${Platform.pathSeparator}$fileName',
        );
        final encoded = '${jsonEncode(payload)}\n';
        await _rotateIfNeeded(
          logDirectory,
          file,
          utf8.encode(encoded).length,
        );
        await file.writeAsString(
          encoded,
          mode: FileMode.append,
          // Diagnostics must never turn high-frequency progress into an fsync
          // workload on the same device that is writing video ranges. The file
          // is still closed after each append; only terminal logical snapshots
          // force storage synchronization so crash reports keep their final
          // state without stalling normal download/UI work.
          flush: _shouldFlushDiagnosticRecord(body),
        );
        _lastError = null;
      } catch (error) {
        _lastError = error;
        // Diagnostics are observability only and never transport authority.
      }
    });
  }

  Future<void> _rotateIfNeeded(
    Directory directory,
    File active,
    int incomingBytes,
  ) async {
    if (!await active.exists()) return;
    final length = await active.length();
    if (length == 0 || length + incomingBytes <= maxBytes) return;

    for (var index = maxFiles - 1; index >= 1; index--) {
      final target = _rotatedLogFile(directory, index);
      if (index == maxFiles - 1 && await target.exists()) {
        await target.delete();
      }
      final source = index == 1
          ? active
          : _rotatedLogFile(directory, index - 1);
      if (!await source.exists()) continue;
      await source.rename(target.path);
    }
  }

  File _rotatedLogFile(Directory directory, int index) {
    final dot = fileName.lastIndexOf('.');
    final rotatedName = dot > 0
        ? '${fileName.substring(0, dot)}.$index${fileName.substring(dot)}'
        : '$fileName.$index';
    return File(
      '${directory.path}${Platform.pathSeparator}$rotatedName',
    );
  }

  /// Testing/support hook for callers that need the append queue settled.
  Future<void> flush() => _tail;
}


bool _shouldFlushDiagnosticRecord(Map<String, Object?> body) {
  if (body['recordType'] != 'snapshot') return false;
  final status = body['status'];
  if (status is! String) return false;
  return status != 'queued' && status != 'running' && status != 'held';
}

const Set<String> _transportFieldAllowlist = <String>{
  'taskId',
  'parentTaskId',
  'childTaskId',
  'status',
  'previousStatus',
  'reason',
  'anomaly',
  'networkType',
  'errorType',
  'liveBytes',
  'durableBytes',
  'diskBytes',
  'nativeWrittenBytes',
  'totalBytes',
  'rangeStart',
  'rangeEnd',
  'attemptGeneration',
  'checkpointSequence',
  'configuredConnections',
  'activeConnections',
  'recordCount',
  'nativeTaskCount',
  'packageTaskCount',
  'pausedTaskCount',
  'resumeDataCount',
  'manifestPartCount',
  'lastByteAgeMs',
  'lastNativeCallbackAgeMs',
  'lastCheckpointAgeMs',
  'lastStatusAgeMs',
  'freeBytes',
  'httpStatus',
  'count',
  'progress',
  'speedMBps',
  'diskObservedSpeedMBps',
  'launched',
  'nativeLive',
  'packagePaused',
  'resumeDataPresent',
  'slotReserved',
  'completed',
  'result',
  'parentActive',
  'pauseRequested',
};

Map<String, Object?> _sanitizeTransportFields(Map<String, Object?> fields) {
  final result = <String, Object?>{};
  for (final entry in fields.entries) {
    if (!_transportFieldAllowlist.contains(entry.key)) continue;
    final value = entry.value;
    if (value is num) {
      if (value.isFinite) result[entry.key] = value;
    } else if (value is bool || value == null) {
      result[entry.key] = value;
    } else if (value is String && _safeDiagnosticToken(value)) {
      result[entry.key] = value;
    }
  }
  return result;
}

bool _safeDiagnosticToken(String value) =>
    value.isNotEmpty &&
    value.length <= 160 &&
    RegExp(r'^[a-zA-Z0-9_.:+-]+$').hasMatch(value) &&
    !value.contains('://');
