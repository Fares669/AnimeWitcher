import '../../domain/entity/multimedia_item.dart';
import '../../utils/anime_rift_identity.dart';

bool isAnimeRiftDownloadProviderV2(String? providerId) =>
    providerId?.trim() == 'com.animerift.provider';

/// Only provider-owned identities can be persisted for renewal. A CDN URL is
/// transport state, even if its query is removed. No API format is inferred.
String? animeRiftDownloadTrackingIdentityV2(String value) {
  final trimmed = value.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri == null || trimmed.isEmpty) return null;
  if (!uri.hasScheme && !uri.hasAuthority) {
    return RegExp(r'^[A-Za-z0-9._~-]+(?:/[A-Za-z0-9._~-]+)*$').hasMatch(trimmed)
        ? trimmed
        : null;
  }
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      (uri.host != animeRiftCatalogHost &&
          uri.host != 'www.$animeRiftCatalogHost') ||
      uri.pathSegments.isEmpty ||
      uri.pathSegments.any(
        (part) =>
            part == '.' ||
            part == '..' ||
            !RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(part),
      ) ||
      RegExp(
        r'\.(mp4|m3u8|mpd|mkv|webm|ts)$',
        caseSensitive: false,
      ).hasMatch(uri.path)) {
    return null;
  }
  return canonicalAnimeRiftPlaybackStorageUrl(trimmed);
}

String? _publicArtwork(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment)
    return null;
  return uri.toString();
}

/// A display snapshot, deliberately built without copyWith/toJson on the
/// original object: those retain nested streams, headers and provider payloads.
MultimediaItem animeRiftDownloadItemSnapshotV2(MultimediaItem item) =>
    MultimediaItem(
      title: item.title,
      url: _animeRiftDurableItemIdentity(item.url),
      provider: 'com.animerift.provider',
      posterUrl: _publicArtwork(item.posterUrl) ?? '',
      bannerUrl: _publicArtwork(item.bannerUrl),
      contentType: item.contentType,
      year: item.year,
      duration: item.duration,
      status: item.status,
      isDubbed: item.isDubbed,
      catalogType: item.catalogType,
    );

String _animeRiftDurableItemIdentity(String value) {
  final trimmed = value.trim();
  final canonical = canonicalAnimeRiftStorageUrl(trimmed);
  final catalog = canonicalAnimeRiftCatalogUrl(canonical);
  if (catalog != null) return catalog;
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null || parsed.hasScheme || parsed.hasAuthority) return '';
  return animeRiftDownloadTrackingIdentityV2(trimmed) ?? '';
}

Episode animeRiftDownloadEpisodeSnapshotV2(Episode episode) => Episode(
  name: episode.name,
  url: animeRiftDownloadTrackingIdentityV2(episode.url) ?? '',
  season: episode.season,
  episode: episode.episode,
  posterUrl: _publicArtwork(episode.posterUrl),
  isFiller: episode.isFiller,
  isFinal: episode.isFinal,
  serverName: episode.serverName,
  serverNumber: episode.serverNumber,
  runtime: episode.runtime,
  dubStatus: episode.dubStatus,
);

/// Source descriptors are durable selectors, never captured transport payloads.
/// Legacy logical IDs/destination paths are left intact by callers.
Map<String, Object?> safeDownloadSourceDescriptorV2(Map<String, Object?> raw) {
  if (!isAnimeRiftDownloadProviderV2(raw['providerId']?.toString())) {
    return Map<String, Object?>.from(raw);
  }
  final tracking = animeRiftDownloadTrackingIdentityV2(
    raw['trackingUrl']?.toString() ?? '',
  );
  return <String, Object?>{
    'providerId': 'com.animerift.provider',
    if (tracking != null) 'trackingUrl': tracking,
    for (final key in const ['source', 'quality', 'ownerTaskId', 'logicalId'])
      if (_safeSelector(raw[key]) case final String value) key: value,
    for (final key in const ['updatedAtMillis', 'generation'])
      if (raw[key] is num) key: raw[key],
  };
}

String? _safeSelector(Object? raw) {
  if (raw is! String) return null;
  final value = raw.trim();
  if (value.isEmpty || value.contains(RegExp(r'[:/?#&=\r\n{}]'))) return null;
  return value;
}
