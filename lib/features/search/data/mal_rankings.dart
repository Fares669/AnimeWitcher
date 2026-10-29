import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/native_provider_resolution.dart';
import '../../../core/network/dio_client_provider.dart';
import '../../../core/storage/storage_service.dart';
import '../../../core/utils/artwork_host_fallback.dart';

/// MAL-linked rankings shown on the home and search pages.
enum MalRanking {
  /// Top airing: what is popular now.
  airing,

  /// Highest rated of all time.
  top,

  /// Most members: the most watched.
  popular,

  /// The best rated films, as AniList's "top movies" ranks them.
  topMovies,
}

/// One page of a ranking: MyAnimeList ids in rank order.
@immutable
class MalRankingPage {
  const MalRankingPage(this.ids, {required this.hasMore});

  final List<int> ids;
  final bool hasMore;
}

/// Entries requested upstream for each Home rail and subsequent page.
const int malRankingPageSize = 10;

const String _aniListEndpoint = 'https://graphql.anilist.co';

/// The MyAnimeList ids in a Jikan list response, in its order.
@visibleForTesting
List<int> malIdsFromJikanList(Object? body) {
  if (body is! Map) return const <int>[];
  final data = body['data'];
  if (data is! List) return const <int>[];
  return _distinctIds(
    data.map((entry) => entry is Map ? entry['mal_id'] : null),
  );
}

/// The MyAnimeList ids in an AniList `Page.media` response, in its order.
@visibleForTesting
List<int> malIdsFromAniListPage(Object? body) {
  if (body is! Map) return const <int>[];
  final data = body['data'];
  final page = data is Map ? data['Page'] : null;
  final media = page is Map ? page['media'] : null;
  if (media is! List) return const <int>[];
  return _distinctIds(
    media.map((entry) => entry is Map ? entry['idMal'] : null),
  );
}

List<int> _distinctIds(Iterable<Object?> raw) {
  final ids = <int>[];
  for (final id in raw) {
    final value = id is int ? id : int.tryParse('${id ?? ''}');
    if (value != null && value > 0 && !ids.contains(value)) ids.add(value);
  }
  return ids;
}

/// Page [page] (from 1) of AniList's equivalent ranking, carrying MAL ids.
Future<MalRankingPage> fetchMalRanking(
  Dio dio,
  MalRanking ranking,
  int page,
) async {
  // Jikan's public API closed on 2026-10-01; do not queue every page behind it.
  final sort = switch (ranking) {
    MalRanking.airing => 'TRENDING_DESC',
    MalRanking.top || MalRanking.topMovies => 'SCORE_DESC',
    MalRanking.popular => 'POPULARITY_DESC',
  };
  final response = await dio.post<Map<String, dynamic>>(
    _aniListEndpoint,
    data: <String, dynamic>{
      'query': r'''
query ($page: Int, $perPage: Int, $sort: [MediaSort], $status: MediaStatus,
    $format: MediaFormat) {
  Page(page: $page, perPage: $perPage) {
    pageInfo { hasNextPage }
    media(type: ANIME, isAdult: false, sort: $sort, status: $status,
        format: $format) { idMal }
  }
}''',
      'variables': <String, dynamic>{
        'page': page,
        'perPage': malRankingPageSize,
        'sort': <String>[sort],
        if (ranking == MalRanking.airing) 'status': 'RELEASING',
        if (ranking == MalRanking.topMovies) 'format': 'MOVIE',
      },
    },
    options: Options(
      headers: const <String, String>{'Accept': 'application/json'},
    ),
  );
  final body = response.data;
  final data = body?['data'];
  final result = data is Map ? data['Page'] : null;
  final pageInfo = result is Map ? result['pageInfo'] : null;
  final errors = body?['errors'];
  if ((errors is List && errors.isNotEmpty) ||
      result is! Map ||
      result['media'] is! List ||
      pageInfo is! Map ||
      pageInfo['hasNextPage'] is! bool) {
    throw StateError('Unable to load the anime ranking page.');
  }
  return MalRankingPage(
    malIdsFromAniListPage(body),
    hasMore: pageInfo['hasNextPage'] == true,
  );
}

/// Page [offset] of [ranking] as the catalogue's own entries, for a
/// "view all" page: MyAnimeList ranks [offset] onward, less the shows the
/// catalogue does not carry.
Future<ProviderMediaPage> loadMalRankingPage(
  Ref ref,
  MalRanking ranking,
  int offset,
) async {
  final catalogue = ref.nativeProvider;
  if (catalogue == null) {
    return const ProviderMediaPage(items: [], nextOffset: 0, hasMore: false);
  }
  final page = offset ~/ malRankingPageSize + 1;
  final ranked = await fetchMalRanking(
    ref.read(dioClientProvider),
    ranking,
    page,
  );
  final items = ranked.ids.isEmpty
      ? const <MultimediaItem>[]
      : await catalogue.getAnimesByMalIds(ranked.ids);
  return ProviderMediaPage(
    items: items,
    nextOffset: page * malRankingPageSize,
    hasMore: ranked.hasMore,
  );
}

/// A fresh Home seed with its actual source cursor. Cached pages are used
/// only offline, so View All cannot skip new titles on the first source page.
final homeMalRankingPageProvider =
    FutureProvider.family<ProviderMediaPage, MalRanking>((ref, ranking) async {
      final storage = ref.read(storageServiceProvider);
      // Older snapshots did not preserve the source cursor after sparse pages.
      final key = 'mal_ranking_anilist_10_page_${ranking.name}';
      var kept = _readKeptPage(storage, key);
      if (malArtworkUnreachable.value &&
          kept?.items.any((item) => isMalArtworkUrl(item.posterUrl)) == true) {
        kept = null;
      }

      try {
        var offset = 0;
        for (var attempt = 0; attempt < 3; attempt++) {
          final page = await loadMalRankingPage(ref, ranking, offset);
          if (page.items.isNotEmpty || !page.hasMore || attempt == 2) {
            unawaited(
              storage
                  .setString(
                    key,
                    jsonEncode(<String, dynamic>{
                      'items': page.items.map((item) => item.toJson()).toList(),
                      'nextOffset': page.nextOffset,
                      'hasMore': page.hasMore,
                    }),
                  )
                  .catchError((_) {}),
            );
            return page;
          }
          offset = page.nextOffset;
        }
      } catch (_) {
        if (kept != null) return kept;
      }
      return const ProviderMediaPage(items: [], nextOffset: 0, hasMore: false);
    });

/// List compatibility for the numbered row on the search page.
final malRankingProvider =
    FutureProvider.family<List<MultimediaItem>, MalRanking>(
      (ref, ranking) async =>
          (await ref.watch(homeMalRankingPageProvider(ranking).future)).items,
    );

ProviderMediaPage? _readKeptPage(StorageService storage, String key) {
  try {
    final raw = storage.getString(key);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    final items = decoded is Map ? decoded['items'] : null;
    if (items is! List ||
        decoded['nextOffset'] is! int ||
        decoded['hasMore'] is! bool) {
      return null;
    }
    final nextOffset = decoded['nextOffset'] as int;
    if (nextOffset < malRankingPageSize ||
        nextOffset % malRankingPageSize != 0) {
      return null;
    }
    return ProviderMediaPage(
      items: <MultimediaItem>[
        for (final item in items)
          if (item is Map)
            MultimediaItem.fromJson(Map<String, dynamic>.from(item)),
      ].take(malRankingPageSize).toList(growable: false),
      nextOffset: nextOffset,
      hasMore: decoded['hasMore'] as bool,
    );
  } catch (_) {
    return null;
  }
}

/// This week's ten most popular airing anime that the catalogue carries,
/// for the numbered row on the search page: the first page of the ranking,
/// and the next ones while fewer than ten of it are in the catalogue.
final malTopTenProvider = FutureProvider<List<MultimediaItem>>((ref) async {
  final firstPage = await ref.watch(
    homeMalRankingPageProvider(MalRanking.airing).future,
  );
  final first = firstPage.items;
  if (first.length >= 10) return first.take(10).toList(growable: false);
  final items = <MultimediaItem>[...first];
  final seen = <String>{for (final item in first) item.url};
  try {
    var offset = firstPage.nextOffset;
    for (
      var page = 1;
      page <= 3 && items.length < 10 && firstPage.hasMore;
      page++
    ) {
      final more = await loadMalRankingPage(ref, MalRanking.airing, offset);
      offset = more.nextOffset;
      for (final item in more.items) {
        if (seen.add(item.url)) items.add(item);
      }
      if (!more.hasMore) break;
    }
  } catch (_) {}
  return items.take(10).toList(growable: false);
});

/// Loads page offsets of a ranking, for the rows' "view all" pages.
final malRankingLoaderProvider =
    Provider<Future<ProviderMediaPage> Function(MalRanking, int)>(
      (ref) =>
          (ranking, offset) => loadMalRankingPage(ref, ranking, offset),
    );
