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
