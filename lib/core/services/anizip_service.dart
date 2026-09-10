
import 'package:dio/dio.dart';

import '../domain/entity/multimedia_item.dart';

/// Best-effort AniZip enrichment for anime episode metadata.
///
/// AniZip is used only for optional episode artwork enrichment.
///
/// Season identity is owned by the app and is always normalized to Season 1;
/// AniZip seasonNumber is deliberately ignored and is never parsed.
class AniZipService {
  final Dio _dio;

  AniZipService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: 'https://api.ani.zip',
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 8),
              ),
            );

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
      if (result != null && result.episodes.isNotEmpty) {
        payload = result;
        break;
      }
    }

    if (payload == null || payload.episodes.isEmpty) {
      return _normalizeToSeasonOne(sourceEpisodes);
    }

    final mappings = payload.episodes;
    var changed = false;
    final enriched = sourceEpisodes.map((source) {
      final candidates = mappings[source.episode];
      final match = candidates != null && candidates.isNotEmpty
          ? candidates.first
          : null;
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
  ) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>('/mappings', queryParameters: {type: value});
      final data = response.data;
      if (response.statusCode != 200 || data == null) return null;

      final rawEpisodes = data['episodes'];
      final result = <int, List<_AniZipEpisode>>{};
      if (rawEpisodes is Map) {
        for (final value in rawEpisodes.values) {
          if (value is! Map) continue;
          final episode = _AniZipEpisode.fromJson(Map<String, dynamic>.from(value));
          if (episode.episodeNumber <= 0) continue;
          result.putIfAbsent(episode.episodeNumber, () => []).add(episode);
        }
      } else if (rawEpisodes is List) {
        for (final value in rawEpisodes) {
          if (value is! Map) continue;
          final episode = _AniZipEpisode.fromJson(Map<String, dynamic>.from(value));
          if (episode.episodeNumber <= 0) continue;
          result.putIfAbsent(episode.episodeNumber, () => []).add(episode);
        }
      }

      return _AniZipPayload(episodes: result);
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
    if (anilist != null && anilist.toString().isNotEmpty) {
      result.add(_AniZipId('anilist_id', anilist.toString()));
    }
    if (mal != null && mal.toString().isNotEmpty) {
      result.add(_AniZipId('mal_id', mal.toString()));
    }
    return result;
  }
}

class _AniZipPayload {
  final Map<int, List<_AniZipEpisode>> episodes;
  const _AniZipPayload({required this.episodes});
}

class _AniZipId {
  final String type;
  final String value;
  const _AniZipId(this.type, this.value);
}

class _AniZipEpisode {
  final int episodeNumber;
  final String? image;
  const _AniZipEpisode({required this.episodeNumber, this.image});

  factory _AniZipEpisode.fromJson(Map<String, dynamic> json) => _AniZipEpisode(
        episodeNumber: (json['episodeNumber'] as num?)?.toInt() ?? 0,
        image: json['image']?.toString(),
      );
}
