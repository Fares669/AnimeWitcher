const String animeRiftCatalogHost = 'anime-rift.com';

final RegExp _animeRiftCatalogId = RegExp(r'^[A-Za-z0-9._~-]+$');

/// Returns one stable public Anime Rift catalog URL, or null when [value] is
/// not a safe public catalog identity.
String? canonicalAnimeRiftCatalogUrl(String value) {
  final parsed = Uri.tryParse(value.trim());
  if (parsed == null ||
      parsed.scheme != 'https' ||
      parsed.userInfo.isNotEmpty ||
      parsed.hasQuery ||
      parsed.hasFragment ||
      (parsed.host != animeRiftCatalogHost &&
          parsed.host != 'www.$animeRiftCatalogHost')) {
    return null;
  }
  final segments = parsed.pathSegments;
  if (segments.length != 2 ||
      segments.first != 'anime' ||
      !_animeRiftCatalogId.hasMatch(segments[1])) {
    return null;
  }
  return Uri(
    scheme: 'https',
    host: animeRiftCatalogHost,
    pathSegments: <String>['anime', segments[1]],
  ).toString();
}

/// Local Rift records may also use internal/offline identities. Only public
/// catalog URLs are canonicalized; opaque local identities stay unchanged.
/// Unlike public deep links, legacy local rows may contain stale query tokens;
/// those are intentionally discarded while recovering the stable catalog ID.
String canonicalAnimeRiftStorageUrl(String value) {
  final trimmed = value.trim();
  return canonicalAnimeRiftCatalogUrl(trimmed) ??
      _canonicalAnimeRiftHostedUrl(trimmed, requireCatalogPath: true) ??
      trimmed;
}

/// Stable local playback identity for Rift episode/source URLs. Query and
/// fragment data are transient credentials, not identity. Opaque provider IDs
/// remain unchanged for backward compatibility.
String canonicalAnimeRiftPlaybackStorageUrl(String value) {
  final trimmed = value.trim();
  return _canonicalAnimeRiftHostedUrl(trimmed) ?? trimmed;
}

/// Value that may be kept in Rift history as a reusable URL. Signed external
/// HTTP(S) resources are transient and may contain credentials, so they are
/// omitted instead of being persisted as an invalid query-stripped playback
/// URL. Opaque provider IDs stay unchanged for backward compatibility.
String? safeAnimeRiftPersistedResourceUrl(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  final hosted = _canonicalAnimeRiftHostedUrl(trimmed);
  if (hosted != null) return hosted;

  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || parsed.scheme.isEmpty) return trimmed;
  final scheme = parsed.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (parsed.userInfo.isNotEmpty || parsed.hasQuery || parsed.hasFragment) {
    return null;
  }
  return trimmed;
}

/// Stable, non-secret identity for Rift history progress/watched keys.
/// External HTTP(S) query/fragment/user-info values are never part of the
/// persisted key, while the host/path still distinguish different episodes.
String canonicalAnimeRiftPersistenceIdentity(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  final hosted = _canonicalAnimeRiftHostedUrl(trimmed);
  if (hosted != null) return hosted;

  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || parsed.scheme.isEmpty) return trimmed;
  final scheme = parsed.scheme.toLowerCase();
  if ((scheme != 'http' && scheme != 'https') || parsed.host.isEmpty) {
    return trimmed;
  }
  final host = parsed.host.toLowerCase();
  final authority = parsed.hasPort ? '$host:${parsed.port}' : host;
  return '$scheme://$authority${parsed.path}';
}

String? _canonicalAnimeRiftHostedUrl(
  String value, {
  bool requireCatalogPath = false,
}) {
  final parsed = Uri.tryParse(value);
  if (parsed == null ||
      parsed.scheme != 'https' ||
      parsed.userInfo.isNotEmpty ||
      (parsed.host != animeRiftCatalogHost &&
          parsed.host != 'www.$animeRiftCatalogHost')) {
    return null;
  }
  final segments = parsed.pathSegments;
  if (segments.isEmpty) return null;
  if (requireCatalogPath &&
      (segments.length != 2 ||
          segments.first != 'anime' ||
          !_animeRiftCatalogId.hasMatch(segments[1]))) {
    return null;
  }
  return Uri(
    scheme: 'https',
    host: animeRiftCatalogHost,
    pathSegments: segments,
  ).toString();
}
