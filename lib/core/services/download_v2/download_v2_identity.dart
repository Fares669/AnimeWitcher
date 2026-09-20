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

/// Builds a semantic variant key from user-visible media properties only.
///
/// Provider/server/source selection is deliberately excluded: those values are
/// transport/source-resolution metadata and may change while the same logical
/// download still owns the same destination. Keeping them out of identity
/// prevents two server selections from becoming independent writers for one
/// file.
String downloadVariantKeyV2({
  required String audioVariant,
  String? quality,
}) {
  final normalizedAudio = audioVariant.trim().toLowerCase();
  final audio = normalizedAudio.isEmpty ? 'default' : normalizedAudio;
  final normalizedQuality = quality?.trim().toLowerCase() ?? '';
  return normalizedQuality.isEmpty ? audio : '$audio|$normalizedQuality';
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

/// Builds a compact deterministic ID for one Manga chapter.
///
/// Identity contains only stable Manga/chapter IDs. Page URLs are transport
/// metadata and may rotate without changing the logical download.
DownloadLogicalId logicalDownloadIdForMangaChapter({
  required String mangaId,
  required String chapterId,
}) {
  final canonical = <String>[
    'manga',
    mangaId.trim(),
    'chapter',
    chapterId.trim(),
  ].join('\u001f');
  final digest = sha256.convert(utf8.encode(canonical)).toString();
  return DownloadLogicalId('manga_${digest.substring(0, 32)}');
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
