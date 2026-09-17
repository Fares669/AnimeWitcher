import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Stable application-owned identity for one logical episode download.
///
/// It deliberately contains no transport URL, package task state, or local
/// byte-range information so signed URL rotation cannot change identity.
final class DownloadLogicalId {
  const DownloadLogicalId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadLogicalId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Builds a compact deterministic ID from stable application identity only.
DownloadLogicalId logicalDownloadIdFor({
  required String animeId,
  required String episodeKey,
  required String variantKey,
}) {
  final canonical = <String>[
    animeId.trim(),
    episodeKey.trim(),
    variantKey.trim(),
  ].join('\u001f');
  final digest = sha256.convert(utf8.encode(canonical)).toString();
  return DownloadLogicalId('dl_${digest.substring(0, 32)}');
}

/// Returns the one package task identity for a logical download generation.
///
/// A new generation always gets a new task ID, making late callbacks from an
/// obsolete transfer safe to reject without reconstructing writer ownership.
String taskIdForGeneration(DownloadLogicalId logicalId, int generation) {
  if (generation <= 0) {
    throw ArgumentError.value(
      generation,
      'generation',
      'must be greater than zero',
    );
  }
  return 'aw_v2_${logicalId.value}_g$generation';
}
