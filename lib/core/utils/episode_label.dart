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
  return _normalizeEpisodeDigits(value.trim().toLowerCase())
      .replaceAll(RegExp(r'\s+'), ' ');
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
  return isStandaloneEpisodeLabel(serverName) ||
      isStandaloneEpisodeLabel(name);
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

/// Catalog / “latest episodes” poster badge.
///
/// Prefer AnimeWitcher’s server episode `name` (e.g. `الحلقة 10 والأخيرة`) so
/// the final-episode suffix is preserved the same way as in the official app.
String formatCatalogEpisodeBadge({
  required int episode,
  String? serverName,
  bool isFinal = false,
  bool isArabic = true,
}) {
  return formatEpisodePrimaryLabel(
    episode: episode,
    isArabic: isArabic,
    isFinal: isFinal,
    serverName: serverName,
  );
}

/// Primary episode name line: "حلقة 12" or "حلقة 12 والأخيرة".
String formatEpisodeNumberLabel({
  required int episode,
  required bool isArabic,
  bool isFinal = false,
  String? rawName,
}) {
  final finalEpisode = isFinal || hasFinalEpisodeSuffix(rawName);
  if (isArabic) {
    return finalEpisode ? 'حلقة $episode والأخيرة' : 'حلقة $episode';
  }
  return finalEpisode ? 'Episode $episode (Final)' : 'Episode $episode';
}

/// Primary label matching AnimeWitcher: prefer the server `name` as-is for
/// standalone labels (مترجم/مدبلج), otherwise build "حلقة X" / "حلقة X والأخيرة".
///
/// [serverName] must stay the original AnimeWitcher `name` field and must not
/// be overwritten by optional AniZip artwork enrichment.
String formatEpisodePrimaryLabel({
  required int episode,
  required bool isArabic,
  bool isFinal = false,
  String? serverName,
}) {
  final raw = (serverName ?? '').trim();
  if (raw.isNotEmpty && !isGenericEpisodeTitle(raw)) {
    return raw;
  }

  var number = episode;
  if (number <= 0 && raw.isNotEmpty) {
    final match = RegExp(r'(\d+)').firstMatch(_normalizeEpisodeDigits(raw));
    number = match == null ? 0 : (int.tryParse(match.group(1)!) ?? 0);
  }

  if (number > 0) {
    return formatEpisodeNumberLabel(
      episode: number,
      isArabic: isArabic,
      isFinal: isFinal,
      rawName: raw,
    );
  }
  return raw;
}

String formatEpisodeLabel({
  required int episode,
  required bool isArabic,
  String? title,
  bool isFinal = false,
  String? serverName,
}) {
  final serverTitle = realEpisodeTitle(title);
  // Prefer AnimeWitcher serverName; if missing, a generic title like
  // "الحلقة 12 والأخيرة" or a standalone catalog label like "مترجم" /
  // "مدبلج" still carries the identity used for downloads.
  final resolvedServerName = () {
    final server = (serverName ?? '').trim();
    if (server.isNotEmpty) return server;
    final rawTitle = (title ?? '').trim();
    if (rawTitle.isNotEmpty &&
        (isGenericEpisodeTitle(rawTitle) ||
            isStandaloneEpisodeLabel(rawTitle))) {
      return rawTitle;
    }
    return null;
  }();
  final prefix = formatEpisodePrimaryLabel(
    episode: episode,
    isArabic: isArabic,
    isFinal: isFinal ||
        hasFinalEpisodeSuffix(resolvedServerName) ||
        hasFinalEpisodeSuffix(title),
    serverName: resolvedServerName,
  );
  if (episode <= 0 && prefix.isEmpty) return serverTitle;
  if (prefix.isEmpty) return serverTitle;
  return serverTitle.isEmpty ? prefix : '$prefix: $serverTitle';
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
  if (lower.contains('1080') || lower.contains('fhd') || lower.contains('fullhd')) {
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

/// True when this episode should be saved/looked up by its episode label
/// (number or standalone name like مترجم/مدبلج) instead of the series title.
bool usesEpisodeDownloadFileName({
  required int episode,
  String? title,
  String? serverName,
}) {
  if (episode > 0) return true;
  return isStandaloneEpisodeEntry(serverName: serverName, name: title);
}

/// True when [fileName] is a downloaded file for this episode identity.
///
/// Numbered episodes:
/// `حلقة {n}[ والأخيرة][_|: title][ ({height}p)].ext`
///
/// Numberless standalone rows (movies / مترجم / مدبلج):
/// `{name}[ ({height}p)].ext`
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
    // Accept composed أ and decomposed أ inside والأخيرة.
    final pattern = RegExp(
      '^حلقة\\s*$episode'
      r'(?:\s+(?:والأ|والأ|والا)خيرة)?'
      r'(?:[:_].*?)?'
      '$qualitySuffix',
      caseSensitive: false,
    );
    return pattern.hasMatch(stem);
  }

  final label = sanitizeDownloadFileName(
    formatEpisodePrimaryLabel(
      episode: 0,
      isArabic: true,
      serverName: () {
        final server = (serverName ?? '').trim();
        if (server.isNotEmpty) return server;
        final rawTitle = (title ?? '').trim();
        if (isStandaloneEpisodeLabel(rawTitle)) return rawTitle;
        return null;
      }(),
    ),
  );
  if (label.isEmpty || !isStandaloneEpisodeLabel(label)) return false;

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
  final real = realEpisodeTitle(title);
  if (real.isNotEmpty) return real;
  final primary = formatEpisodePrimaryLabel(
    episode: episode,
    isArabic: true,
    isFinal: isFinal,
    serverName: serverName,
  );
  if (isStandaloneEpisodeLabel(primary) || hasFinalEpisodeSuffix(primary)) {
    return primary;
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
  if (server.isNotEmpty) {
    return formatEpisodePrimaryLabel(
      episode: number,
      isArabic: isArabic,
      serverName: server,
      isFinal: hasFinalEpisodeSuffix(server),
    );
  }

  final stored = (episodeTitle ?? '').trim();
  if (stored.isNotEmpty &&
      (isGenericEpisodeTitle(stored) ||
          isStandaloneEpisodeLabel(stored) ||
          hasFinalEpisodeSuffix(stored))) {
    return formatEpisodePrimaryLabel(
      episode: number,
      isArabic: isArabic,
      serverName: stored,
      isFinal: hasFinalEpisodeSuffix(stored),
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
}) {
  final stored = (episodeTitle ?? '').trim();
  if (stored.isEmpty) return '';
  if (isGenericEpisodeTitle(stored) || isStandaloneEpisodeLabel(stored)) {
    return '';
  }
  final server = (episodeServerName ?? '').trim();
  if (server.isNotEmpty && stored == server) return '';
  return realEpisodeTitle(stored);
}
