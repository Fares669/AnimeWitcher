import 'package:dio/dio.dart';

import '../../domain/entity/multimedia_item.dart';
import '../../storage/provider_local_library.dart';
import '../base_provider.dart';
import '../../utils/anime_rift_identity.dart';
import 'anime_rift_api_client.dart';
export 'anime_rift_api_client.dart' show AnimeRiftAccessUnavailable;

/// Rift catalog integration. Playback remains unavailable until separately verified.
class AnimeRiftProvider extends AnimeWitcherProvider {
  AnimeRiftProvider({Dio? dio, AnimeRiftApiClient? client})
    : _api = client ?? AnimeRiftApiClient(dio: dio);

  // Own transport: never forward the AnimeWitcher account's credentials.
  final AnimeRiftApiClient _api;

  @override
  String get packageName => animeRiftProviderId;
  @override
  String get name => 'Anime Rift';
  @override
  String get mainUrl => 'https://anime-rift.com';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    if (!_api.isConfigured) throw const AnimeRiftAccessUnavailable();
    final data = await _api.request(
      'library/home_content',
      'ANIME.LIBRARY.HOME_CONTENT',
      query: {'with_genres': true},
    );
    final sections = <String, List<MultimediaItem>>{};
    final rows = data['sections'];
    if (rows is! List) throw const AnimeRiftAccessUnavailable();
    for (final row in rows.whereType<Map>()) {
      final title = row['sectionTitle'];
      if (title is! String || title.trim().isEmpty) continue;
      final items = _items(row['items']);
      if (items.isNotEmpty) sections.putIfAbsent(title, () => []).addAll(items);
    }
    return sections;
  }

  static final _safeId = RegExp(r'^[A-Za-z0-9_-]+$');

  List<MultimediaItem> _items(dynamic rows) {
    if (rows is! List) return [];
    return [
      for (final row in rows.whereType<Map>())
        if (row['_id'] is String &&
            _safeId.hasMatch(row['_id'] as String) &&
            row['title'] is String &&
            (row['title'] as String).trim().isNotEmpty)
          _item(row),
    ];
  }

  String _art(dynamic value) {
    if (value is! String) return '';
    final uri = Uri.tryParse(value);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? value
        : '';
  }

  MultimediaItem _item(Map row) => MultimediaItem(
    title: (row['title'] as String).trim(),
    url: '$mainUrl/anime/${row['_id']}',
    posterUrl: _art(row['main_picture']).isNotEmpty
        ? _art(row['main_picture'])
        : _art(row['medium_picture']),
    provider: packageName,
    contentType: MultimediaContentType.anime,
    year: (row['release_year'] as num?)?.toInt(),
    score: (row['myAnimeList_rating'] as num?)?.toDouble(),
    status: switch (row['release_status']) {
      'finished' => ShowStatus.completed,
      'not_yet_aired' => ShowStatus.upcoming,
      _ => ShowStatus.ongoing,
    },
  );

  String _catalogId(String url) {
    final canonical = canonicalAnimeRiftCatalogUrl(url);
    if (canonical == null) throw const AnimeRiftAccessUnavailable();
    final id = Uri.parse(canonical).pathSegments.last;
    if (!_safeId.hasMatch(id)) throw const AnimeRiftAccessUnavailable();
    return id;
  }

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => (await searchPage(
    query,
    const ProviderSearchFilters(),
    cancelToken: cancelToken,
  )).items;

  @override
  Future<List<MultimediaItem>> searchWithFilters(
    String query,
    ProviderSearchFilters filters, {
    CancelToken? cancelToken,
  }) async =>
      (await searchPage(query, filters, cancelToken: cancelToken)).items;

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async {
    if (filters.isNotEmpty ||
        !const {'', 'year_asc', 'year_desc'}.contains(filters.sort)) {
      throw UnsupportedError('هذه الفلاتر غير مدعومة حاليًا في Anime Rift.');
    }
    final page = offset < 0 ? 0 : offset;
    final data = await _api.request(
      'library/search',
      'ANIME.LIBRARY.SEARCH',
      method: 'POST',
      body: {'query': query},
      query: {
        'page': page,
        'sort_by': 'release_year',
        'sort_direction': filters.sort == 'year_desc' ? -1 : 1,
        'text_direction': 'jp',
      },
      cancelToken: cancelToken,
    );
    // This API exposes page numbers, so nextOffset is an opaque page cursor.
    return ProviderMediaPage(
      items: _items(data['items']),
      nextOffset: page + 1,
      hasMore: data['hasNext'] == true,
    );
  }

  @override
  bool get supportsIndependentDetailSections => true;

  @override
  Future<MultimediaItem> getDetails(String url) async {
    final id = _catalogId(url);
    final data = await _api.request(
      'library/details/$id',
      'ANIME.LIBRARY.DETAILS',
    );
    final row = data['item'];
    if (row is! Map || row['_id'] != id || row['title'] is! String)
      throw const AnimeRiftAccessUnavailable();
    final genreRows = row['genreLabels'];
    final others = data['others'];
    return _item(row).copyWith(
      description: row['synopsis'] is String ? row['synopsis'] as String : null,
      tags: genreRows is List
          ? [
              for (final genre in genreRows.whereType<Map>())
                if (genre['label'] is String) genre['label'] as String,
            ]
          : null,
      recommendations: _items(others is Map ? others['recommendations'] : null),
    );
  }

  @override
  Future<List<Episode>> getEpisodes(String url) async {
    final id = _catalogId(url);
    final data = await _api.request(
      'library/episodes/$id',
      'ANIME.LIBRARY.EPISODES.ALL',
      query: {'sort_by_latest': 1, 'with_arcs': true, 'with_favorites': true},
    );
    final rows = data['items'];
    if (rows is! List) throw const AnimeRiftAccessUnavailable();
    final episodes = <Episode>[];
    final seen = <String>{};
    for (final row in rows.whereType<Map>()) {
      final episodeId = row['_id'];
      final number = row['episode_number'];
      if (episodeId is! String ||
          !_safeId.hasMatch(episodeId) ||
          number is! num ||
          !seen.add(episodeId))
        continue;
      episodes.add(
        Episode(
          name: 'الحلقة $number',
          url: '$mainUrl/anime/$id/episode/$episodeId',
          season: 1,
          episode: number.toInt(),
          posterUrl: _art(row['thumbnail']),
        ),
      );
    }
    episodes.sort((a, b) => a.episode.compareTo(b.episode));
    return episodes;
  }

  @override
  Future<List<MultimediaItem>> getRecommendations(String url) async =>
      (await getDetails(url)).recommendations ?? [];

  @override
  Future<List<Actor>> getCast(String url) async => [];
  @override
  Future<List<Trailer>> getTrailers(String url) async => [];
  @override
  Future<List<MultimediaItem>> getRelated(String url) async => [];
  @override
  Future<NextAiring?> getNextAiring(String url) async => null;

  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      Future.error(const AnimeRiftPlaybackUnavailable());
}

class AnimeRiftPlaybackUnavailable extends AnimeRiftAccessUnavailable {
  const AnimeRiftPlaybackUnavailable();
  @override
  String toString() => 'لم يُفعّل التشغيل من Anime Rift بعد.';
}
