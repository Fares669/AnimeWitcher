import 'download_v2_identity.dart';

const int kLogicalDownloadSchemaVersionV2 = 1;

enum DownloadUserIntent { active, paused, canceled }

enum DownloadFailureCategory {
  sourceExpired,
  transport,
  filesystem,
  integrity,
  unknown,
}

enum DownloadTransportStatus {
  queued,
  running,
  paused,
  held,
  complete,
  failed,
  canceled,
  missing,
}

/// Package-neutral view of one parent transfer.
///
/// No package-managed chunk identity is exposed here.
final class DownloadTransportSnapshot {
  const DownloadTransportSnapshot({
    required this.taskId,
    required this.status,
    required this.progress,
    this.transferredBytes,
    this.totalBytes,
    this.failureCategory,
    this.failureMessage,
  }) : assert(progress >= 0 && progress <= 1);

  final String taskId;
  final DownloadTransportStatus status;
  final double progress;
  final int? transferredBytes;
  final int? totalBytes;
  final DownloadFailureCategory? failureCategory;
  final String? failureMessage;

  bool get isFinal => switch (status) {
    DownloadTransportStatus.complete ||
    DownloadTransportStatus.failed ||
    DownloadTransportStatus.canceled => true,
    _ => false,
  };
}

/// Durable application-owned metadata for a logical download.
///
/// Transport resume data, ranges, child chunks, package retry counters, and
/// writer ownership are intentionally absent. `background_downloader` owns
/// those details.
final class LogicalDownloadRecordV2 {
  const LogicalDownloadRecordV2({
    required this.schemaVersion,
    required this.logicalId,
    required this.animeId,
    required this.episodeKey,
    required this.variantKey,
    required this.generation,
    required this.taskId,
    required this.intent,
    required this.destinationPath,
    required this.sourceDescriptor,
    required this.updatedAtMillis,
    this.expectedBytes,
    this.completedAtMillis,
    this.failureCategory,
    this.failureMessage,
  });

  final int schemaVersion;
  final DownloadLogicalId logicalId;
  final String animeId;
  final String episodeKey;
  final String variantKey;
  final int generation;
  final String taskId;
  final DownloadUserIntent intent;
  final String destinationPath;
  final Map<String, Object?> sourceDescriptor;
  final int? expectedBytes;
  final int? completedAtMillis;
  final DownloadFailureCategory? failureCategory;
  final String? failureMessage;
  final int updatedAtMillis;

  LogicalDownloadRecordV2 copyWith({
    int? schemaVersion,
    DownloadLogicalId? logicalId,
    String? animeId,
    String? episodeKey,
    String? variantKey,
    int? generation,
    String? taskId,
    DownloadUserIntent? intent,
    String? destinationPath,
    Map<String, Object?>? sourceDescriptor,
    int? expectedBytes,
    int? completedAtMillis,
    DownloadFailureCategory? failureCategory,
    String? failureMessage,
    int? updatedAtMillis,
  }) {
    return LogicalDownloadRecordV2(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      logicalId: logicalId ?? this.logicalId,
      animeId: animeId ?? this.animeId,
      episodeKey: episodeKey ?? this.episodeKey,
      variantKey: variantKey ?? this.variantKey,
      generation: generation ?? this.generation,
      taskId: taskId ?? this.taskId,
      intent: intent ?? this.intent,
      destinationPath: destinationPath ?? this.destinationPath,
      sourceDescriptor: sourceDescriptor ?? this.sourceDescriptor,
      expectedBytes: expectedBytes ?? this.expectedBytes,
      completedAtMillis: completedAtMillis ?? this.completedAtMillis,
      failureCategory: failureCategory ?? this.failureCategory,
      failureMessage: failureMessage ?? this.failureMessage,
      updatedAtMillis: updatedAtMillis ?? this.updatedAtMillis,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'logicalId': logicalId.value,
    'animeId': animeId,
    'episodeKey': episodeKey,
    'variantKey': variantKey,
    'generation': generation,
    'taskId': taskId,
    'intent': intent.name,
    'destinationPath': destinationPath,
    'sourceDescriptor': Map<String, Object?>.from(sourceDescriptor),
    if (expectedBytes != null) 'expectedBytes': expectedBytes,
    if (completedAtMillis != null) 'completedAtMillis': completedAtMillis,
    if (failureCategory != null) 'failureCategory': failureCategory!.name,
    if (failureMessage != null) 'failureMessage': failureMessage,
    'updatedAtMillis': updatedAtMillis,
  };

  static LogicalDownloadRecordV2? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);

    final schemaVersion = _asInt(map['schemaVersion']);
    final logicalId = _asString(map['logicalId']);
    final animeId = _asString(map['animeId']);
    final episodeKey = _asString(map['episodeKey']);
    final variantKey = _asString(map['variantKey']);
    final generation = _asInt(map['generation']);
    final taskId = _asString(map['taskId']);
    final intent = _enumByName(DownloadUserIntent.values, map['intent']);
    final destinationPath = _asString(map['destinationPath']);
    final updatedAtMillis = _asInt(map['updatedAtMillis']);
    final rawSource = map['sourceDescriptor'];

    if (schemaVersion == null ||
        logicalId == null ||
        animeId == null ||
        episodeKey == null ||
        variantKey == null ||
        generation == null ||
        generation <= 0 ||
        taskId == null ||
        intent == null ||
        destinationPath == null ||
        updatedAtMillis == null ||
        rawSource is! Map) {
      return null;
    }

    return LogicalDownloadRecordV2(
      schemaVersion: schemaVersion,
      logicalId: DownloadLogicalId(logicalId),
      animeId: animeId,
      episodeKey: episodeKey,
      variantKey: variantKey,
      generation: generation,
      taskId: taskId,
      intent: intent,
      destinationPath: destinationPath,
      sourceDescriptor: Map<String, Object?>.from(rawSource),
      expectedBytes: _asInt(map['expectedBytes']),
      completedAtMillis: _asInt(map['completedAtMillis']),
      failureCategory: _enumByName(
        DownloadFailureCategory.values,
        map['failureCategory'],
      ),
      failureMessage: _asString(map['failureMessage']),
      updatedAtMillis: updatedAtMillis,
    );
  }
}

String? _asString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int? _asInt(Object? value) => value is int ? value : null;

T? _enumByName<T extends Enum>(Iterable<T> values, Object? raw) {
  if (raw is! String) return null;
  for (final value in values) {
    if (value.name == raw) return value;
  }
  return null;
}
