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
    if (failureCategory != null) 'failureCategory': failureCategory!.name,
    if (holdCategory != null) 'holdCategory': holdCategory!.name,
    if (sourceRefreshReason != null)
      'sourceRefreshReason': sourceRefreshReason!.name,
    if (integrityResult != null) 'integrityResult': integrityResult!.name,
  };
}

abstract interface class DownloadDiagnosticsV2 {
  void record(DownloadDiagnosticEventV2 event);
}

final class NoopDownloadDiagnosticsV2 implements DownloadDiagnosticsV2 {
  const NoopDownloadDiagnosticsV2();

  @override
  void record(DownloadDiagnosticEventV2 event) {}
}

/// Deterministic sink used by V2 regression tests and debug projections.
final class InMemoryDownloadDiagnosticsV2 implements DownloadDiagnosticsV2 {
  final List<DownloadDiagnosticEventV2> _events =
      <DownloadDiagnosticEventV2>[];

  List<DownloadDiagnosticEventV2> get events =>
      List<DownloadDiagnosticEventV2>.unmodifiable(_events);

  @override
  void record(DownloadDiagnosticEventV2 event) {
    _events.add(event);
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
    this.fileName = 'download_v2.jsonl',
  }) : _directoryProvider = directoryProvider,
       _enabled = enabled,
       _nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Future<Directory> Function() _directoryProvider;
  final bool Function() _enabled;
  final int Function() _nowMillis;
  final String fileName;

  Future<void> _tail = Future<void>.value();
  Object? _lastError;

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
    if (!_enabled()) return;
    final payload = <String, Object?>{
      'timestampMillis': _nowMillis(),
      ...event.toJson(),
    };
    _tail = _tail.then<void>((_) async {
      try {
        final logDirectory = await directory();
        final file = File(
          '${logDirectory.path}${Platform.pathSeparator}$fileName',
        );
        await file.writeAsString(
          '${jsonEncode(payload)}\n',
          mode: FileMode.append,
          flush: true,
        );
        _lastError = null;
      } catch (error) {
        _lastError = error;
        // Diagnostics are observability only and never transport authority.
      }
    });
  }

  /// Testing/support hook for callers that need the append queue settled.
  Future<void> flush() => _tail;
}
