String _normalizeEpisodeDigits(String value) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const eastern = '۰۱۲۳۴۵۶۷۸۹';
  return value
      .replaceAllMapped(
        RegExp(r'[٠-٩]'),
        (m) => '${arabic.indexOf(m.group(0)!)}',
      )
      .replaceAllMapped(
        RegExp(r'[۰-۹]'),
        (m) => '${eastern.indexOf(m.group(0)!)}',
      );
}

String _normalizeEpisodeLabel(String value) {
  return _normalizeEpisodeDigits(
    value.trim().toLowerCase(),
  ).replaceAll(RegExp(r'\s+'), ' ');
}

/// True when [value] is only a generic episode placeholder such as
/// "الحلقة 12", "حلقة 12 والأخيرة", or "Episode 3".
bool isGenericEpisodeTitle(String? value) {
  final title = _normalizeEpisodeLabel(value ?? '');
  if (title.isEmpty) return true;
  return RegExp(
        r'^(?:ال)?حلق[ةه]\s*\d+(?:\s+(?:والأخيرة|والاخيرة))?$',
      ).hasMatch(title) ||
      RegExp(
        r'^(?:episode|ep\.?)\s*\d+(?:\s+(?:final|last))?$',
        caseSensitive: false,
      ).hasMatch(title) ||
      RegExp(r'^\d+$').hasMatch(title);
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
  final value = (title ?? '').trim();
  if (value.isEmpty ||
      isGenericEpisodeTitle(value) ||
      isStandaloneEpisodeLabel(value)) {
    return '';
  }
  return value;
}

/// Primary episode name line: "حلقة 12" or "حلقة 12 والأخيرة".
String formatEpisodeNumberLabel({
  required int episode,
  required bool isArabic,
  bool isFinal = false,
}) {
  if (isArabic) {
    return isFinal ? 'حلقة $episode والأخيرة' : 'حلقة $episode';
  }
  return isFinal ? 'Episode $episode (Final)' : 'Episode $episode';
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
/// AnimeWitcher's `name` field ([serverName]) owns the primary line: catalog
/// labels such as `مترجم` or `الحلقة الخاصة` are shown exactly as written, while
/// placeholders like `الحلقة 12` are rebuilt as "حلقة 12" from the number they
/// carry. [title] only ever contributes a creative title. Every display,
/// download-name and history helper below is a view on this result.
EpisodeLabel resolveEpisodeLabel({
  required int episode,
  required bool isArabic,
  String? title,
  String? serverName,
  bool isFinal = false,
}) {
  final rawTitle = (title ?? '').trim();
  final server = (serverName ?? '').trim();
  // Without a server name, a placeholder or catalog title is still the row's
  // identity — that is what downloads and history were saved under.
  final catalogLabel = server.isNotEmpty
      ? server
      : (isGenericEpisodeTitle(rawTitle) || isStandaloneEpisodeLabel(rawTitle))
      ? rawTitle
      : '';

  return EpisodeLabel(
    primary: _primaryLine(
      episode: episode,
      isArabic: isArabic,
      catalogLabel: catalogLabel,
      isFinal:
          isFinal ||
          hasFinalEpisodeSuffix(catalogLabel) ||
          hasFinalEpisodeSuffix(rawTitle),
    ),
    secondary: realEpisodeTitle(rawTitle),
  );
}

String _primaryLine({
  required int episode,
  required bool isArabic,
  required String catalogLabel,
  required bool isFinal,
}) {
  if (catalogLabel.isNotEmpty && !isGenericEpisodeTitle(catalogLabel)) {
    return catalogLabel;
  }

  var number = episode;
  if (number <= 0 && catalogLabel.isNotEmpty) {
    final match = RegExp(
      r'\d+',
    ).firstMatch(_normalizeEpisodeDigits(catalogLabel));
    number = match == null ? 0 : (int.tryParse(match.group(0)!) ?? 0);
  }
  if (number <= 0) return catalogLabel;

  return formatEpisodeNumberLabel(
    episode: number,
    isArabic: isArabic,
    isFinal: isFinal,
  );
}

/// Latest-episodes poster badge: the server episode name, unchanged.
///
/// Examples: `الفيلم`, `حلقة 5`, `حلقة 12 والأخيرة`, `مترجم`, `مدبلج`.
String? latestEpisodesPosterBadge(String? episodeName) {
  final value = (episodeName ?? '').trim();
  return value.isEmpty ? null : value;
}

/// Primary line only — episode rows, poster badges and player headers.
String formatEpisodePrimaryLabel({
  required int episode,
  required bool isArabic,
  bool isFinal = false,
  String? serverName,
}) {
  return resolveEpisodeLabel(
    episode: episode,
    isArabic: isArabic,
    serverName: serverName,
    isFinal: isFinal,
  ).primary;
}

/// Full display name: primary line plus the creative title when there is one.
String formatEpisodeLabel({
  required int episode,
  required bool isArabic,
  String? title,
  bool isFinal = false,
  String? serverName,
}) {
  return resolveEpisodeLabel(
    episode: episode,
    isArabic: isArabic,
    title: title,
    serverName: serverName,
    isFinal: isFinal,
  ).full;
}

/// Characters that break or get rewritten on common mobile filesystems.
final RegExp _illegalDownloadFileChars = RegExp(r'[\\/:*?"<>|]');

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
  return normalizeDownloadText(name)
      .replaceAll(_illegalDownloadFileChars, '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
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
  final base = formatEpisodeLabel(
    episode: episode,
    isArabic: true,
    title: title,
    isFinal: isFinal,
    serverName: serverName,
  );
  final qualityLabel = formatDownloadQualityLabel(quality);
  return qualityLabel == null ? base : '$base ($qualityLabel)';
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
    isArabic: true,
    title: title,
    serverName: serverName,
  ).isEmpty;
}

/// True when [fileName] is a downloaded file for this episode identity.
///
/// Numbered episodes:
/// `حلقة {n}[ والأخيرة][_|: title][ ({height}p)].ext`
///
/// Numberless rows (specials / movies / مترجم / مدبلج):
/// `{name}[_ title][ ({height}p)].ext`
///
/// Quality is always `(\d{3,4}p)` — the trailing `p` separates it from numbers.
bool isDownloadedEpisodeFileName(
  String fileName,
  int episode, {
  String? title,
  String? serverName,
}) {
  final stem = sanitizeDownloadFileName(
    fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName,
  );
  const qualitySuffix = r'(?:\s*\(\d{3,4}p\))?$';

  if (episode > 0) {
    // Accept composed أ and decomposed أ inside والأخيرة.
    final pattern = RegExp(
      '^حلقة\\s*$episode'
      r'(?:\s+(?:والأ|والأ|والا)خيرة)?'
      r'(?:[:_].*?)?'
      '$qualitySuffix',
      caseSensitive: false,
    );
    return pattern.hasMatch(stem);
  }

  final label = sanitizeDownloadFileName(
    resolveEpisodeLabel(
      episode: 0,
      isArabic: true,
      title: title,
      serverName: serverName,
    ).full,
  );
  if (label.isEmpty) return false;

  return RegExp(
    '^${RegExp.escape(label)}$qualitySuffix',
    caseSensitive: false,
  ).hasMatch(stem);
}

/// Title persisted in watch history / sync. Keeps a final-episode marker when
/// there is no creative title so "والأخيرة" survives round-trips.
String episodeTitleForStorage({
  required int episode,
  String? title,
  bool isFinal = false,
  String? serverName,
}) {
  final label = resolveEpisodeLabel(
    episode: episode,
    isArabic: true,
    title: title,
    serverName: serverName,
    isFinal: isFinal,
  );
  if (label.secondary.isNotEmpty) return label.secondary;
  // Numberless episodes have nothing else to identify them, so keep their
  // label (الحلقة الخاصة, OVA, مترجم, …) in history.
  if (episode <= 0 ||
      isStandaloneEpisodeLabel(label.primary) ||
      hasFinalEpisodeSuffix(label.primary)) {
    return label.primary;
  }
  return '';
}

/// Primary label for continue-watching / history cards.
///
/// Prefer [episodeServerName] from AnimeWitcher. Fall back to markers that were
/// previously stored in [episodeTitle], otherwise build "حلقة N".
String continueWatchingPrimaryLabel({
  required int? episode,
  required bool isArabic,
  String? episodeTitle,
  String? episodeServerName,
}) {
  final number = episode ?? 0;
  final server = (episodeServerName ?? '').trim();
  final stored = (episodeTitle ?? '').trim();
  // A stored creative title is a secondary line while there is a number to
  // show; without one it is all the row has.
  final catalogLabel = server.isNotEmpty
      ? server
      : (stored.isNotEmpty &&
            (number <= 0 ||
                isGenericEpisodeTitle(stored) ||
                isStandaloneEpisodeLabel(stored) ||
                hasFinalEpisodeSuffix(stored)))
      ? stored
      : '';

  if (catalogLabel.isNotEmpty) {
    return _primaryLine(
      episode: number,
      isArabic: isArabic,
      catalogLabel: catalogLabel,
      isFinal: hasFinalEpisodeSuffix(catalogLabel),
    );
  }
  if (number > 0) {
    return formatEpisodeNumberLabel(episode: number, isArabic: isArabic);
  }
  return '';
}

/// Secondary creative title for continue-watching / history cards.
String continueWatchingSecondaryTitle({
  String? episodeTitle,
  String? episodeServerName,
  int? episode,
}) {
  final stored = (episodeTitle ?? '').trim();
  final title = realEpisodeTitle(stored);
  if (title.isEmpty) return '';
  final server = (episodeServerName ?? '').trim();
  if (server.isNotEmpty && stored == server) return '';
  // Without a number and without a server label, the stored text is already
  // the primary line; showing it twice reads like a duplicate.
  if (server.isEmpty && (episode ?? 0) <= 0) return '';
  return title;
}
