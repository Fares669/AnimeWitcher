import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/providers/animewitcher_native_provider.dart';
import '../../../core/network/dio_client_provider.dart';
import '../../../core/storage/storage_service.dart';
import '../../../core/utils/artwork_host_fallback.dart';

/// MyAnimeList's rankings shown on the search page.
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

/// Entries per ranking page, as Jikan and AniList are asked for.
const int malRankingPageSize = 25;

const String _jikanTopEndpoint = 'https://api.jikan.moe/v4/top/anime';
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

// Jikan allows three requests a second; the rows ask together.
Future<void> _jikanTurn = Future<void>.value();

Future<T> _inJikanTurn<T>(Future<T> Function() request) {
  final result = _jikanTurn.then((_) => request());
  _jikanTurn = result
      .then((_) {}, onError: (_) {})
      .then((_) => Future<void>.delayed(const Duration(milliseconds: 400)));
  return result;
}

/// Page [page] (from 1) of [ranking]: MyAnimeList's own, through Jikan, or
/// when Jikan cannot reach MyAnimeList — it often cannot — AniList's
/// equivalent, which carries the MyAnimeList ids too.
Future<MalRankingPage> fetchMalRanking(
  Dio dio,
  MalRanking ranking,
  int page,
) async {
  // Films are ranked as AniList ranks them; Jikan is for the other rows.
  if (ranking != MalRanking.topMovies) {
    try {
      final response = await _inJikanTurn(
        () => dio.get<Map<String, dynamic>>(
          _jikanTopEndpoint,
          queryParameters: <String, dynamic>{
            'page': page,
            'limit': malRankingPageSize,
            'sfw': true,
            if (ranking == MalRanking.airing) 'filter': 'airing',
            if (ranking == MalRanking.popular) 'filter': 'bypopularity',
          },
          // Jikan answers a compressed request with 504 instead of the list.
          options: Options(
            headers: const <String, String>{
              'Accept': 'application/json',
              'Accept-Encoding': 'identity',
            },
          ),
        ),
      );
      final ids = malIdsFromJikanList(response.data);
      if (ids.isNotEmpty) {
        final pagination = response.data?['pagination'];
        final hasMore = pagination is Map
            ? pagination['has_next_page'] == true
            : ids.length >= malRankingPageSize;
        return MalRankingPage(ids, hasMore: hasMore);
      }
    } catch (_) {
      // Falls through to AniList.
    }
  }

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
  final pageInfo = data is Map && data['Page'] is Map
      ? (data['Page'] as Map)['pageInfo']
      : null;
  return MalRankingPage(
    malIdsFromAniListPage(body),
    hasMore: pageInfo is Map && pageInfo['hasNextPage'] == true,
  );
}

AnimeWitcherNativeProvider? _catalogue(Ref ref) {
  final active = ref.read(activeProviderProvider);
  if (active is AnimeWitcherNativeProvider) return active;
  for (final provider in ref.read(extensionManagerProvider)) {
    if (provider is AnimeWitcherNativeProvider) return provider;
  }
  return null;
}

/// Page [offset] of [ranking] as the catalogue's own entries, for a
/// "view all" page: MyAnimeList ranks [offset] onward, less the shows the
/// catalogue does not carry.
Future<ProviderMediaPage> loadMalRankingPage(
  Ref ref,
  MalRanking ranking,
  int offset,
) async {
  final catalogue = _catalogue(ref);
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

/// The first page of each ranking, for the rows on the search page. Empty
/// when neither ranking service nor the catalogue can be reached.
///
/// The last list fetched is kept on disk and shown at once, while a fresh
/// one is fetched for next time: rankings move slowly, and the two services
/// and the catalogue together take seconds. With nothing kept yet, it waits
/// for the network.
final malRankingProvider =
    FutureProvider.family<List<MultimediaItem>, MalRanking>((
      ref,
      ranking,
    ) async {
      final storage = ref.read(storageServiceProvider);
      final key = 'mal_ranking_${ranking.name}';
      var kept = _readKept(storage, key);
      // Kept before MyAnimeList's CDN was found blocked here: its posters
      // would only hang, so the list is fetched again with reachable ones.
      if (malArtworkUnreachable.value &&
          kept.any((item) => isMalArtworkUrl(item.posterUrl))) {
        kept = const <MultimediaItem>[];
      }

      Future<List<MultimediaItem>> fetch() async {
        try {
          final items = (await loadMalRankingPage(ref, ranking, 0)).items;
          if (items.isNotEmpty) {
            unawaited(
              storage
                  .setString(
                    key,
                    jsonEncode(<String, dynamic>{
                      'items': items.map((item) => item.toJson()).toList(),
                    }),
                  )
                  .catchError((_) {}),
            );
          }
          return items;
        } catch (_) {
          return const <MultimediaItem>[];
        }
      }

      if (kept.isNotEmpty) {
        unawaited(fetch());
        return kept;
      }
      return fetch();
    });

List<MultimediaItem> _readKept(StorageService storage, String key) {
  try {
    final raw = storage.getString(key);
    if (raw == null || raw.isEmpty) return const <MultimediaItem>[];
    final decoded = jsonDecode(raw);
    final items = decoded is Map ? decoded['items'] : null;
    if (items is! List) return const <MultimediaItem>[];
    return <MultimediaItem>[
      for (final item in items)
        if (item is Map)
          MultimediaItem.fromJson(Map<String, dynamic>.from(item)),
    ];
  } catch (_) {
    return const <MultimediaItem>[];
  }
}

/// This week's ten most popular airing anime that the catalogue carries,
/// for the numbered row on the search page: the first page of the ranking,
/// and the next ones while fewer than ten of it are in the catalogue.
final malTopTenProvider = FutureProvider<List<MultimediaItem>>((ref) async {
  final first = await ref.watch(malRankingProvider(MalRanking.airing).future);
  if (first.length >= 10) return first.take(10).toList(growable: false);
  final items = <MultimediaItem>[...first];
  final seen = <String>{for (final item in first) item.url};
  try {
    for (var page = 1; page <= 3 && items.length < 10; page++) {
      final more = await loadMalRankingPage(
        ref,
        MalRanking.airing,
        page * malRankingPageSize,
      );
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
