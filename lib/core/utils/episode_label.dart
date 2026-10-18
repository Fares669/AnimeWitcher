import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'digit_normalization.dart';

String _normalizeEpisodeLabel(String value) {
  return normalizeLocalizedDigits(value.trim().toLowerCase())
      .replaceAll(RegExp(r'\s+'), ' ');
}

/// Preserve a supplied numeric display value without changing episode identity.
String? rawEpisodeNumberForDisplay(Object? value) {
  if (value is! String && value is! num) return null;
  final raw = value.toString();
  final normalized = normalizeLocalizedDigits(raw.trim());
  return RegExp(r'^-?\d+(?:[.,٫]\d+)?$').hasMatch(normalized) ? raw : null;
}

/// True when [value] is only a generic episode placeholder such as
/// "الحلقة 12", "حلقة 12 والأخيرة", or "Episode 3".
bool isGenericEpisodeTitle(String? value) {
  final title = _normalizeEpisodeLabel(value ?? '');
  if (title.isEmpty) return true;
  return RegExp(
        r'^(?:ال)?حلق[ةه]\s*\d+(?:[.,٫]\d+)?(?:\s+(?:والأخيرة|والاخيرة))?$',
      ).hasMatch(title) ||
      RegExp(
        r'^(?:episode|ep\.?)\s*\d+(?:[.,٫]\d+)?(?:\s+(?:final|last))?$',
        caseSensitive: false,
      ).hasMatch(title) ||
      RegExp(r'^\d+(?:[.,٫]\d+)?$').hasMatch(title);
}

/// True when [value] ends with a final-episode suffix such as "والأخيرة".
bool hasFinalEpisodeSuffix(String? value) {
  final title = _normalizeEpisodeLabel(value ?? '');
  if (title.isEmpty) return false;
  return RegExp(r'(?:والأخيرة|والاخيرة)\s*$').hasMatch(title) ||
      RegExp(
        r'(?:\(\s*)?(?:final|last)(?:\s*\))?\s*$',
        caseSensitive: false,
      ).hasMatch(title);
}

/// Movie/OVA catalog labels that AnimeWitcher shows instead of "حلقة N".
bool isStandaloneEpisodeLabel(String? value) {
  final title = _normalizeEpisodeLabel(value ?? '');
  if (title.isEmpty || isGenericEpisodeTitle(title)) return false;
  return RegExp(
    r'^(مترجم|مدبلج|مترجمة|مدبلجة|sub(?:bed)?|dub(?:bed)?)$',
    caseSensitive: false,
  ).hasMatch(title);
}

/// True when an episode row is a مترجم/مدبلج-style catalog entry.
bool isStandaloneEpisodeEntry({String? serverName, String? name}) {
  return isStandaloneEpisodeLabel(serverName) || isStandaloneEpisodeLabel(name);
}

/// True when every episode is a مترجم/مدبلج-style row (hide sub/dub filter).
bool isStandaloneEpisodeCatalog(
  Iterable<({String? serverName, String? name})> episodes,
) {
  final list = episodes.toList(growable: false);
  if (list.isEmpty) return false;
  return list.every(
    (episode) => isStandaloneEpisodeEntry(
      serverName: episode.serverName,
      name: episode.name,
    ),
  );
}

/// Real creative title only; empty when missing or generic/standalone labels.
String realEpisodeTitle(String? title) {
  final value = title ?? '';
  if (value.trim().isEmpty ||
      isGenericEpisodeTitle(value) ||
      isStandaloneEpisodeLabel(value)) {
    return '';
  }
  return value;
}

/// How an episode is named, in the two lines the UI shows.
class EpisodeLabel {
  const EpisodeLabel({required this.primary, required this.secondary});

  /// Number or catalog line: "حلقة 12 والأخيرة", "مترجم", "الحلقة الخاصة".
  /// Empty only for a numberless row that carries no name at all.
  final String primary;

  /// Creative episode title, empty when the source only had a placeholder.
  final String secondary;

  bool get isEmpty => primary.isEmpty && secondary.isEmpty;

  /// Both lines as one string: "حلقة 12: نهاية الرحلة".
  String get full {
    if (primary.isEmpty) return secondary;
    if (secondary.isEmpty) return primary;
    return '$primary: $secondary';
  }
}

/// The single place that decides how an episode is named.
///
/// AnimeWitcher's `name` field ([serverName]) owns the primary line and is
/// shown exactly as the server sent it (`الفيلم`, `حلقة 5`, `الحلقة 12
/// والأخيرة`, `مترجم`, …). [title] only ever contributes a creative title.
/// A number is turned into "حلقة N" only when the server sent no name.
EpisodeLabel resolveEpisodeLabel({
  required int episode,
  String? title,
  String? serverName,
  bool isFinal = false,
}) {
  final rawTitle = title ?? '';
  final server = serverName ?? '';
  // Without a server name, a placeholder or catalog title is still the row's
  // identity — that is what downloads and history were saved under.
  final catalogLabel = server.trim().isNotEmpty
      ? server
      : (isGenericEpisodeTitle(rawTitle) || isStandaloneEpisodeLabel(rawTitle))
      ? rawTitle
      : '';

  return EpisodeLabel(
    primary: catalogLabel.trim().isNotEmpty
        ? catalogLabel
        : episode > 0
        ? 'حلقة $episode${isFinal || hasFinalEpisodeSuffix(rawTitle) ? ' والأخيرة' : ''}'
        : '',
    secondary: realEpisodeTitle(rawTitle),
  );
}

/// Latest-episodes poster badge: the server episode name, unchanged.
///
/// Examples: `الفيلم`, `حلقة 5`, `حلقة 12 والأخيرة`, `مترجم`, `مدبلج`.
String? latestEpisodesPosterBadge(String? episodeName) {
  final value = episodeName ?? '';
  return value.trim().isEmpty ? null : value;
}

/// Primary line only — episode rows, poster badges and player headers.
String formatEpisodePrimaryLabel({
  required int episode,
  bool isFinal = false,
  String? serverName,
}) {
  return resolveEpisodeLabel(
    episode: episode,
    serverName: serverName,
    isFinal: isFinal,
  ).primary;
}

/// The exact server name, or a legacy display fallback when it is missing.
String formatEpisodeLabel({
  required int episode,
  String? title,
  bool isFinal = false,
  String? serverName,
}) {
  if (serverName?.trim().isNotEmpty ?? false) return serverName!;
  return resolveEpisodeLabel(
    episode: episode,
    title: title,
    serverName: serverName,
    isFinal: isFinal,
  ).full;
}

/// Characters that break or get rewritten on common mobile filesystems.
final RegExp _illegalDownloadFileChars = RegExp(
  r'[\x00-\x1f\x7f-\x9f\\/:*?"<>|]',
);

/// Compose common Arabic NFD sequences (e.g. ا + ٔ → أ) so filenames match
/// across iOS (often NFD) and Android/Linux (often NFC).
String normalizeDownloadText(String value) {
  return value
      .replaceAll('\u0627\u0654', '\u0623') // ا + hamza above → أ
      .replaceAll('\u0648\u0654', '\u0624') // و + hamza above → ؤ
      .replaceAll('\u064A\u0654', '\u0626') // ي + hamza above → ئ
      .replaceAll('\u0627\u0655', '\u0625'); // ا + hamza below → إ
}

/// Sanitize a display label into a stable on-disk filename stem.
String sanitizeDownloadFileName(String name) {
  var stem = normalizeDownloadText(name)
      .replaceAll(_illegalDownloadFileChars, '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (stem.isEmpty) return '';
  if (RegExp(
    r'^(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
    caseSensitive: false,
  ).hasMatch(stem)) {
    stem = '_$stem';
  }

  final bytes = utf8.encode(stem);
  if (bytes.length <= 200) return stem;
  final suffix = '-${sha256.convert(bytes).toString().substring(0, 12)}';
  final prefix = StringBuffer();
  var prefixBytes = 0;
  for (final rune in stem.runes) {
    final runeBytes = rune <= 0x7f
        ? 1
        : rune <= 0x7ff
        ? 2
        : rune <= 0xffff
        ? 3
        : 4;
    if (prefixBytes + runeBytes > 200 - suffix.length) break;
    prefix.writeCharCode(rune);
    prefixBytes += runeBytes;
  }
  return '$prefix$suffix';
}

/// Normalize stream quality for download filenames as `{height}p`.
///
/// Examples: `1080` → `1080p`, `720p` → `720p`, `FHD` → `1080p`.
/// Returns null when there is no numeric height so the filename never embeds
/// an ambiguous bare number that could look like an episode.
String? formatDownloadQualityLabel(String? quality) {
  final raw = (quality ?? '').trim();
  if (raw.isEmpty) return null;

  final lower = raw.toLowerCase();
  final already = RegExp(r'^(\d{3,4})p$').firstMatch(lower);
  if (already != null) return '${already.group(1)}p';

  final digitsOnly = RegExp(r'^(\d{3,4})$').firstMatch(lower);
  if (digitsOnly != null) return '${digitsOnly.group(1)}p';

  if (lower.contains('2160') || lower.contains('4k') || lower.contains('uhd')) {
    return '2160p';
  }
  if (lower.contains('1080') ||
      lower.contains('fhd') ||
      lower.contains('fullhd')) {
    return '1080p';
  }
  if (lower.contains('720')) return '720p';
  if (lower.contains('480')) return '480p';
  if (RegExp(r'(^|[^a-z])hd([^a-z]|$)').hasMatch(lower)) return '720p';
  if (RegExp(r'(^|[^a-z])sd([^a-z]|$)').hasMatch(lower)) return '480p';

  final embedded = RegExp(r'(\d{3,4})\s*p?\b').firstMatch(lower);
  if (embedded != null) return '${embedded.group(1)}p';
  return null;
}

String formatEpisodeFileName({
  required int episode,
  String? title,
  String? quality,
  bool isFinal = false,
  String? serverName,
}) {
  final base = resolveEpisodeLabel(
    episode: episode,
    title: title,
    isFinal: isFinal,
    serverName: serverName,
  ).full;
  final qualityLabel = formatDownloadQualityLabel(quality);
  return qualityLabel == null ? base : '$base ($qualityLabel)';
}

/// Bound the base before adding quality, so it stays readable and matchable.
String formatEpisodeDownloadFileName({
  required int episode,
  String? title,
  String? quality,
  bool isFinal = false,
  String? serverName,
}) {
  final stem = sanitizeDownloadFileName(
    formatEpisodeFileName(
      episode: episode,
      title: title,
      isFinal: isFinal,
      serverName: serverName,
    ),
  );
  final qualityLabel = formatDownloadQualityLabel(quality);
  return stem.isEmpty || qualityLabel == null ? stem : '$stem ($qualityLabel)';
}

/// True when this episode should be saved/looked up by its own label instead
/// of the series title.
///
/// Any episode with a usable name qualifies, numbered or not, so specials like
/// `الحلقة الخاصة` are saved under their own name instead of collapsing into
/// `One Piece.mp4` next to the rest of the series.
bool usesEpisodeDownloadFileName({
  required int episode,
  String? title,
  String? serverName,
}) {
  if (episode > 0) return true;
  return !resolveEpisodeLabel(
    episode: 0,
    title: title,
    serverName: serverName,
  ).isEmpty;
}

/// True when [fileName] is a downloaded file for this episode identity.
///
/// The stem must be the server name as written (`الفيلم`, `حلقة 5`,
/// `الحلقة 12 والأخيرة`, `مترجم`, …), plus an optional creative title and
/// `({height}p)` quality suffix. There is no rewritten-name fallback.
bool isDownloadedEpisodeFileName(
  String fileName,
  int episode, {
  String? title,
  String? serverName,
  bool isFinal = false,
}) {
  final rawStem = fileName.contains('.')
      ? fileName.substring(0, fileName.lastIndexOf('.'))
      : fileName;
  final label = formatEpisodeDownloadFileName(
    episode: episode,
    title: title,
    isFinal: isFinal,
    serverName: serverName,
  );
  if (label.isEmpty) return false;
  final normalizedLabel = label.toLowerCase();
  if (sanitizeDownloadFileName(rawStem).toLowerCase() == normalizedLabel)
    return true;
  final quality = RegExp(
    r' \(\d{3,4}p\)$',
    caseSensitive: false,
  ).firstMatch(rawStem);
  // Old legal files can have an unbounded base; strip quality before hashing it.
  return quality != null &&
      sanitizeDownloadFileName(rawStem.substring(0, quality.start))
              .toLowerCase() ==
          normalizedLabel;
}

/// Original display title persisted in history, independently of file names.
String episodeTitleForStorage({
  required int episode,
  String? title,
  bool isFinal = false,
  String? serverName,
}) {
  if (title?.trim().isNotEmpty ?? false) return title!;
  if (serverName?.trim().isNotEmpty ?? false) return serverName!;
  // Legacy callers may only know the final marker, with no original text.
  if (isFinal) {
    return formatEpisodePrimaryLabel(episode: episode, isFinal: true);
  }
  return '';
}

/// Primary label for continue-watching / history cards.
///
/// Prefer [episodeServerName] from AnimeWitcher. Fall back to markers that were
/// previously stored in [episodeTitle], otherwise build "حلقة N".
String continueWatchingPrimaryLabel({
  required int? episode,
  String? episodeTitle,
  String? episodeServerName,
  String? episodeServerNumber,
}) {
  final number = episode ?? 0;
  final server = episodeServerName ?? '';
  final stored = episodeTitle ?? '';
  // A stored creative title is a secondary line while there is a number to
  // show; without one it is all the row has.
  final catalogLabel = server.trim().isNotEmpty
      ? server
      : (stored.trim().isNotEmpty &&
            (number <= 0 ||
                isGenericEpisodeTitle(stored) ||
                isStandaloneEpisodeLabel(stored) ||
                hasFinalEpisodeSuffix(stored)))
      ? stored
      : '';

  if (catalogLabel.isNotEmpty) return catalogLabel;
  if (episodeServerNumber?.trim().isNotEmpty ?? false) {
    return episodeServerNumber!;
  }
  return formatEpisodePrimaryLabel(episode: number);
}

/// Secondary creative title for continue-watching / history cards.
String continueWatchingSecondaryTitle({
  String? episodeTitle,
  String? episodeServerName,
  int? episode,
}) {
  final stored = episodeTitle ?? '';
  final title = realEpisodeTitle(stored);
  if (title.isEmpty) return '';
  final server = episodeServerName ?? '';
  if (server.trim().isNotEmpty && stored.trim() == server.trim()) return '';
  // Without a number and without a server label, the stored text is already
  // the primary line; showing it twice reads like a duplicate.
  if (server.trim().isEmpty && (episode ?? 0) <= 0) return '';
  return title;
}
