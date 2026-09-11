import '../domain/entity/multimedia_item.dart';

/// Stable identity for one logical media download.
///
/// This key deliberately excludes executor-attempt details such as taskId,
/// signed delivery URLs, target filenames, localized labels and poster data.
/// Those values may change while the same logical episode is retried/adopted.
class DownloadLogicalIdentity {
  const DownloadLogicalIdentity._({
    required this.key,
    required this.contentKey,
    required this.season,
    required this.episode,
    required this.dubStatus,
  });

  final String key;
  final String contentKey;
  final int season;
  final int episode;
  final DubStatus dubStatus;

  factory DownloadLogicalIdentity.fromMedia({
    required MultimediaItem item,
    Episode? episode,
  }) {
    final contentKey = _contentIdentity(item);
    final episodeDub = episode?.dubStatus ?? DubStatus.none;
    final dubStatus = episodeDub != DubStatus.none
        ? episodeDub
        : (item.isDubbed ? DubStatus.dubbed : DubStatus.none);
    final season = episode?.season ?? 0;
    final episodeNumber = episode?.episode ?? 0;
    final key = <String>[
      'download:v1',
      contentKey,
      's$season',
      'e$episodeNumber',
      'dub:${dubStatus.name}',
    ].join('|');

    return DownloadLogicalIdentity._(
      key: key,
      contentKey: contentKey,
      season: season,
      episode: episodeNumber,
      dubStatus: dubStatus,
    );
  }

  static String _contentIdentity(MultimediaItem item) {
    final sync = item.syncData;
    if (sync != null && sync.isNotEmpty) {
      const stableSyncKeys = <String>[
        'malId',
        'mal_id',
        'anilistId',
        'anilist_id',
        'kitsuId',
        'kitsu_id',
      ];
      for (final key in stableSyncKeys) {
        final value = sync[key]?.trim();
        if (value != null && value.isNotEmpty) {
          return 'sync:${key.toLowerCase()}:${Uri.encodeComponent(value)}';
        }
      }
    }

    if (item.tmdbId != null) {
      return 'tmdb:${item.tmdbId}';
    }
    final imdbId = item.imdbId?.trim().toLowerCase();
    if (imdbId != null && imdbId.isNotEmpty) {
      return 'imdb:${Uri.encodeComponent(imdbId)}';
    }

    final canonicalUrl = _canonicalCatalogUrl(item.url);
    if (canonicalUrl.isNotEmpty) {
      return 'url:${Uri.encodeComponent(canonicalUrl)}';
    }

    // Last-resort migration identity for providers that supplied neither a
    // stable external ID nor a catalog URL. This is intentionally namespaced
    // as weak evidence so callers can replace it when stronger identity is
    // discovered later; it must never be confused with an execution URL.
    final provider = (item.provider ?? item.source ?? 'unknown')
        .trim()
        .toLowerCase();
    final title = item.title.trim().toLowerCase();
    return 'weak:${Uri.encodeComponent(provider)}:${Uri.encodeComponent(title)}';
  }

  static String _canonicalCatalogUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return trimmed;

    if (!uri.hasScheme || uri.host.isEmpty) {
      final withoutFragment = trimmed.split('#').first;
      return withoutFragment.split('?').first.replaceFirst(RegExp(r'/+$'), '');
    }

    var path = uri.path.isEmpty ? '/' : uri.path;
    if (path.length > 1) {
      path = path.replaceFirst(RegExp(r'/+$'), '');
    }
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final includePort =
        uri.hasPort &&
        !((scheme == 'https' && uri.port == 443) ||
            (scheme == 'http' && uri.port == 80));
    final authority = includePort ? '$host:${uri.port}' : host;
    return '$scheme://$authority$path';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadLogicalIdentity && key == other.key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => key;
}

/// Restores the stable logical identity from presentation metadata.
///
/// New metadata carries the key explicitly. Legacy rows may be migrated only
/// from the original media/episode snapshots; executor URLs, filenames and
/// task IDs are never accepted as substitutes because they are mutable attempt
/// details and can collide across episodes.
String? logicalDownloadIdFromMetadata(Map<String, dynamic>? metadata) {
  if (metadata == null) return null;
  final explicit = metadata['logicalId']?.toString().trim();
  if (explicit != null && explicit.isNotEmpty) return explicit;

  final rawItem = metadata['item'];
  if (rawItem is! Map) return null;
  try {
    final item = MultimediaItem.fromJson(Map<String, dynamic>.from(rawItem));
    Episode? episode;
    final rawEpisode = metadata['episode'];
    if (rawEpisode is Map) {
      episode = Episode.fromJson(Map<String, dynamic>.from(rawEpisode));
    }
    return DownloadLogicalIdentity.fromMedia(item: item, episode: episode).key;
  } catch (_) {
    return null;
  }
}
