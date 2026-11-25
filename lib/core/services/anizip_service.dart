
import 'package:dio/dio.dart';

import '../domain/entity/multimedia_item.dart';

/// Best-effort AniZip enrichment for episode artwork and franchise season
/// labels. Playback episodes keep AnimeWitcher's local season identity; the
/// TVDB season fields below are consumed only by the seasons bar.
class AniZipMapping {
  const AniZipMapping({
    required this.seasonNumber,
    this.episodeNumber,
    this.absoluteEpisodeNumber,
    this.tvdbShowId,
    this.tvdbEpisodeId,
    this.tvdbMappingId,
  });

  final int seasonNumber;
  final int? episodeNumber;
  final int? absoluteEpisodeNumber;
  final int? tvdbShowId;
  final int? tvdbEpisodeId;
  final int? tvdbMappingId;
}

class AniZipService {
  static const int _seasonCacheMax = 300;
  static final Map<int, Future<AniZipMapping?>> _seasonCache =
      <int, Future<AniZipMapping?>>{};
  static final Map<String, Future<_AniZipPayload?>> _sharedMappingsCache =
      <String, Future<_AniZipPayload?>>{};

  final Dio _dio;
  final bool _useSharedCache;
  final Map<String, Future<_AniZipPayload?>> _localMappingsCache =
      <String, Future<_AniZipPayload?>>{};

  AniZipService({Dio? dio})
      : _useSharedCache = dio == null,
        _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: 'https://api.ani.zip',
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 8),
              ),
            );

  Future<AniZipMapping?> fetchSeasonMapping(int aniListId) {
    if (aniListId <= 0) return Future<AniZipMapping?>.value();
    final cached = _seasonCache.remove(aniListId);
    if (cached != null) {
      _seasonCache[aniListId] = cached;
      return cached;
    }

    final pending = _fetchSeasonMapping(aniListId);
    _seasonCache[aniListId] = pending;
    while (_seasonCache.length > _seasonCacheMax) {
      _seasonCache.remove(_seasonCache.keys.first);
    }
    return pending;
  }

  Future<AniZipMapping?> _fetchSeasonMapping(int aniListId) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/mappings',
        queryParameters: <String, dynamic>{'anilist_id': aniListId},
      );
      final data = response.data;
      if (response.statusCode != 200 || data == null) return null;
      return aniZipMappingFromJson(data);
    } on DioException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<Episode>?> enrichEpisodes(
    MultimediaItem item,
    List<Episode> sourceEpisodes,
  ) async {
    if (sourceEpisodes.isEmpty) return null;

    final ids = _candidateIds(item.syncData);
    if (ids.isEmpty) return _normalizeToSeasonOne(sourceEpisodes);

    _AniZipPayload? payload;
    for (final id in ids) {
      final result = await _fetchMappings(id.type, id.value);
      if (result != null && !result.isEmpty) {
        payload = result;
        break;
      }
    }

    if (payload == null || payload.isEmpty) {
      return _normalizeToSeasonOne(sourceEpisodes);
    }

    var changed = false;
    final enriched = sourceEpisodes.map((source) {
      final match = payload!.episodeFor(source.episode);
      final image = match?.image?.trim();
      final nextPoster = image != null && image.isNotEmpty
          ? image
          : source.posterUrl;

      if (source.season == 1 && nextPoster == source.posterUrl) {
        return source;
      }
      changed = true;
      // AniZip may only refresh artwork / season. Never rewrite AnimeWitcher
      // identity fields such as serverName, isFinal, or the creative title.
      return source.copyWith(
        season: 1,
        posterUrl: nextPoster,
      );
    }).toList(growable: false);

    return changed ? enriched : sourceEpisodes;
  }

  List<Episode> _normalizeToSeasonOne(List<Episode> episodes) {
    var changed = false;
    final result = episodes.map((source) {
      if (source.season == 1) return source;
      changed = true;
      return source.copyWith(season: 1);
    }).toList(growable: false);
    return changed ? result : episodes;
  }

  Future<_AniZipPayload?> _fetchMappings(
    String type,
    String value,
  ) {
    final cache = _useSharedCache ? _sharedMappingsCache : _localMappingsCache;
    final cacheKey = '$type:$value';
    final cached = cache.remove(cacheKey);
    if (cached != null) {
      cache[cacheKey] = cached;
      return cached;
    }

    final pending = _fetchMappingsUncached(type, value).then((payload) {
      if (payload == null) {
        cache.remove(cacheKey);
      }
      return payload;
    });
    cache[cacheKey] = pending;
    while (cache.length > _seasonCacheMax) {
      cache.remove(cache.keys.first);
    }
    return pending;
  }

  Future<_AniZipPayload?> _fetchMappingsUncached(
    String type,
    String value,
  ) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/mappings',
        queryParameters: <String, dynamic>{type: value},
      );
      final data = response.data;
      if (response.statusCode != 200 || data == null) return null;

      final rawEpisodes = data['episodes'];
      final byKey = <int, _AniZipEpisode>{};
      final byEpisode = <int, List<_AniZipEpisode>>{};
      final byAbsolute = <int, List<_AniZipEpisode>>{};

      void addEpisode(Map<String, dynamic> map, {int? mapKey}) {
        final episode = _AniZipEpisode.fromJson(map);
        final keyNum =
            mapKey ?? int.tryParse('${map['episode'] ?? ''}'.trim());
        if (keyNum != null && keyNum > 0) {
          byKey.putIfAbsent(keyNum, () => episode);
        }
        if (episode.episodeNumber > 0) {
          byEpisode.putIfAbsent(episode.episodeNumber, () => []).add(episode);
        }
        if (episode.absoluteEpisodeNumber > 0) {
          byAbsolute
              .putIfAbsent(episode.absoluteEpisodeNumber, () => [])
              .add(episode);
        }
      }

      if (rawEpisodes is Map) {
        for (final entry in rawEpisodes.entries) {
          if (entry.value is! Map) continue;
          addEpisode(
            Map<String, dynamic>.from(entry.value as Map),
            mapKey: int.tryParse('${entry.key}'.trim()),
          );
        }
      } else if (rawEpisodes is List) {
        for (final value in rawEpisodes) {
          if (value is! Map) continue;
          addEpisode(Map<String, dynamic>.from(value));
        }
      }

      return _AniZipPayload(
        byKey: byKey,
        byEpisode: byEpisode,
        byAbsolute: byAbsolute,
      );
    } on DioException {
      return null;
    } catch (_) {
      return null;
    }
  }

  List<_AniZipId> _candidateIds(Map<String, dynamic>? syncData) {
    if (syncData == null) return const [];
    final result = <_AniZipId>[];
    final anilist = syncData['anilist_id'] ?? syncData['anilistId'];
    final mal = syncData['mal_id'] ?? syncData['malId'];
    final anidb = syncData['anidb_id'] ?? syncData['anidbId'];
    if (anilist != null && anilist.toString().isNotEmpty) {
      result.add(_AniZipId('anilist_id', anilist.toString()));
    }
    if (mal != null && mal.toString().isNotEmpty) {
      result.add(_AniZipId('mal_id', mal.toString()));
    }
    if (anidb != null && anidb.toString().isNotEmpty) {
      result.add(_AniZipId('anidb_id', anidb.toString()));
    }
    return result;
  }
}

AniZipMapping? aniZipMappingFromJson(Map<String, dynamic> data) {
  final episodes = data['episodes'];
  final candidates = <Map<String, dynamic>>[];

  if (episodes is Map) {
    final ordered = episodes.entries
        .map((entry) => (key: int.tryParse('${entry.key}'), value: entry.value))
        .where(
          (entry) =>
              entry.key != null && entry.key! > 0 && entry.value is Map,
        )
        .toList()
      ..sort((a, b) => a.key!.compareTo(b.key!));
    for (final entry in ordered) {
      candidates.add(Map<String, dynamic>.from(entry.value as Map));
    }
  } else if (episodes is List) {
    for (final value in episodes) {
      if (value is Map) {
        candidates.add(Map<String, dynamic>.from(value));
      }
    }
  }

  final mappings = data['mappings'];
  final tvdbMappingId = mappings is Map
      ? (mappings['thetvdb_id'] as num?)?.toInt()
      : null;

  for (final episode in candidates) {
    final seasonNumber = (episode['seasonNumber'] as num?)?.toInt();
    if (seasonNumber == null || seasonNumber <= 0) continue;
    return AniZipMapping(
      seasonNumber: seasonNumber,
      episodeNumber: (episode['episodeNumber'] as num?)?.toInt(),
      absoluteEpisodeNumber:
          (episode['absoluteEpisodeNumber'] as num?)?.toInt(),
      tvdbShowId: (episode['tvdbShowId'] as num?)?.toInt(),
      tvdbEpisodeId: (episode['tvdbId'] as num?)?.toInt(),
      tvdbMappingId: tvdbMappingId,
    );
  }
  return null;
}

class _AniZipPayload {
  final Map<int, _AniZipEpisode> byKey;
  final Map<int, List<_AniZipEpisode>> byEpisode;
  final Map<int, List<_AniZipEpisode>> byAbsolute;

  const _AniZipPayload({
    required this.byKey,
    required this.byEpisode,
    required this.byAbsolute,
  });

  bool get isEmpty =>
      byKey.isEmpty && byEpisode.isEmpty && byAbsolute.isEmpty;

  _AniZipEpisode? episodeFor(int number) {
    if (number <= 0) return null;
    final direct = byKey[number];
    if (direct != null) return direct;
    final ep = byEpisode[number];
    if (ep != null && ep.isNotEmpty) return ep.first;
    final abs = byAbsolute[number];
    if (abs != null && abs.isNotEmpty) return abs.first;
    return null;
  }
}

class _AniZipId {
  final String type;
  final String value;
  const _AniZipId(this.type, this.value);
}

class _AniZipEpisode {
  final int episodeNumber;
  final int absoluteEpisodeNumber;
  final String? image;

  const _AniZipEpisode({
    required this.episodeNumber,
    required this.absoluteEpisodeNumber,
    this.image,
  });

  factory _AniZipEpisode.fromJson(Map<String, dynamic> json) => _AniZipEpisode(
        episodeNumber: (json['episodeNumber'] as num?)?.toInt() ?? 0,
        absoluteEpisodeNumber:
            (json['absoluteEpisodeNumber'] as num?)?.toInt() ?? 0,
        image: json['image']?.toString(),
      );
}
