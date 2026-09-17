import 'download_v2_identity.dart';
import 'download_v2_models.dart';
import 'logical_download_store_v2.dart';

const String kLegacyRestartRequiredSourceDescriptorV2 =
    'legacyRestartRequired';

/// Builds the application-owned placeholder used when an incomplete legacy
/// presentation row has no usable refresh descriptor.
///
/// This deliberately contains no transport URL, headers, resume data, ranges,
/// chunks, retry state, or native/package ownership. Startup can therefore keep
/// the row visible while doing zero network work. Explicit restart must first
/// reconstruct a fresh source from the stable provider/tracking metadata.
Map<String, Object?> legacyRestartRequiredSourceDescriptorV2({
  required String trackingUrl,
  required String providerId,
  String? sourceHint,
  String? quality,
}) {
  final descriptor = <String, Object?>{
    kLegacyRestartRequiredSourceDescriptorV2: true,
    'trackingUrl': trackingUrl.trim(),
    'providerId': providerId.trim(),
  };
  final normalizedSource = sourceHint?.trim();
  if (normalizedSource != null && normalizedSource.isNotEmpty) {
    descriptor['sourceHint'] = normalizedSource;
  }
  final normalizedQuality = quality?.trim();
  if (normalizedQuality != null && normalizedQuality.isNotEmpty) {
    descriptor['quality'] = normalizedQuality;
  }
  return descriptor;
}

bool sourceDescriptorRequiresLegacyRestartV2(
  Map<String, Object?> descriptor,
) => descriptor[kLegacyRestartRequiredSourceDescriptorV2] == true;

/// Presentation-only legacy input accepted by the V2 migration boundary.
///
/// Deliberately absent: package/native task identity, chunk/range state,
/// resume offsets/data, durable byte checkpoints, retries, or writer ownership.
/// Incomplete legacy work is represented only as a logical item that requires
/// an explicit user resume before V2 creates any transport.
final class LegacyDownloadPresentationV2 {
  const LegacyDownloadPresentationV2({
    required this.logicalId,
    required this.animeId,
    required this.episodeKey,
    required this.variantKey,
    required this.destinationPath,
    required this.sourceDescriptor,
    this.completedAtMillis,
    this.expectedBytes,
  }) : assert(animeId != ''),
       assert(episodeKey != ''),
       assert(variantKey != ''),
       assert(destinationPath != ''),
       assert(expectedBytes == null || expectedBytes > 0);

  final DownloadLogicalId logicalId;
  final String animeId;
  final String episodeKey;
  final String variantKey;
  final String destinationPath;
  final Map<String, Object?> sourceDescriptor;

  /// Non-null only when the legacy logical item already owns a final file.
  final int? completedAtMillis;

  /// Trusted size evidence copied from application presentation metadata only.
  /// This is never reconstructed from percentages or legacy transport state.
  final int? expectedBytes;

  bool get isCompleted => completedAtMillis != null;
}

/// One-way Policy-A migration into the V2 logical store.
///
/// Completed legacy downloads keep their final-file metadata. Incomplete
/// downloads become durable paused logical records. Startup therefore performs
/// zero network work for them; an explicit resume creates the first real V2
/// transport generation from byte zero through [DownloadManagerV2].
final class LegacyDownloadMigrationV2 {
  LegacyDownloadMigrationV2({
    required LogicalDownloadStoreV2 store,
    int Function()? nowMillis,
  }) : _store = store,
       _nowMillis = nowMillis ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LogicalDownloadStoreV2 _store;
  final int Function() _nowMillis;

  Future<LogicalDownloadRecordV2> migrate(
    LegacyDownloadPresentationV2 legacy,
  ) async {
    final migrated = await _store.mutate(legacy.logicalId, (current) {
      // A V2 record is always newer authority than legacy presentation data.
      // This also makes repeated startup migration idempotent.
      if (current != null) return current;

      const generation = 1;
      return LogicalDownloadRecordV2(
        schemaVersion: kLogicalDownloadSchemaVersionV2,
        logicalId: legacy.logicalId,
        animeId: legacy.animeId,
        episodeKey: legacy.episodeKey,
        variantKey: legacy.variantKey,
        generation: generation,
        taskId: taskIdForGeneration(legacy.logicalId, generation),
        // Policy A never auto-starts an incomplete legacy download. Completed
        // records are terminal by completedAtMillis, so paused is harmless and
        // keeps migration from inventing active transport intent.
        intent: DownloadUserIntent.paused,
        destinationPath: legacy.destinationPath,
        sourceDescriptor: Map<String, Object?>.from(legacy.sourceDescriptor),
        expectedBytes: legacy.expectedBytes,
        completedAtMillis: legacy.completedAtMillis,
        updatedAtMillis: _nowMillis(),
      );
    });

    if (migrated == null) {
      throw StateError(
        'Legacy migration unexpectedly removed ${legacy.logicalId}',
      );
    }
    return migrated;
  }
}
