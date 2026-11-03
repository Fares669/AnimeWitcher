import 'package:dio/dio.dart';

import '../../domain/entity/multimedia_item.dart';
import '../../storage/provider_local_library.dart';
import '../base_provider.dart';
import '../../utils/anime_rift_identity.dart';
import 'anime_rift_api_client.dart';
import 'anime_rift_streams.dart';
export 'anime_rift_streams.dart'
    show AnimeRiftPlaybackUnavailable, AnimeRiftAuthenticationRequired;
export 'anime_rift_api_client.dart' show AnimeRiftAccessUnavailable;

/// Independent Rift catalog, source selection and permitted media resolution.
class AnimeRiftProvider extends AnimeWitcherProvider {
  AnimeRiftProvider({Dio? dio, AnimeRiftApiClient? client})
    : _api = client ?? AnimeRiftApiClient(dio: dio),
      _externalDio = dio;

  // Own transport: never forward the AnimeWitcher account's credentials.
  final AnimeRiftApiClient _api;
  final Dio? _externalDio;
  final _episodeNumbers = <String, int>{};
  late final _streams = AnimeRiftStreams(
    _api,
    _episodeNumber,
    externalDio: _externalDio,
  );

  Future<int> _episodeNumber(String anime, String episode) async {
    final key = '$anime:$episode';
    if (!_episodeNumbers.containsKey(key))
      await getEpisodes('$mainUrl/anime/$anime');
    final number = _episodeNumbers[key];
    if (number == null) throw const AnimeRiftPlaybackUnavailable();
    return number;
  }

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
    for (final row in rows.whereType<Map<dynamic, dynamic>>()) {
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
      for (final row in rows.whereType<Map<dynamic, dynamic>>())
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

  MultimediaItem _item(Map<dynamic, dynamic> row) => MultimediaItem(
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

  static const _statuses = {'مستمر': 'on_going', 'مكتمل': 'finished'};
  static const _types = {
    'مسلسل': 'tv',
    'فيلم': 'movie',
    'اوفا': 'ova',
    'اونا': 'ona',
    'خاصة': 'special',
  };
  static const _ages = {'+13': 'pg_13', '+17': 'r', 'لجميع الأعمار': 'g'};
  static const _seasons = {
    'شتاء': 'winter',
    'ربيع': 'spring',
    'صيف': 'summer',
    'خريف': 'fall',
  };
  final _filterLabels =
      <String, ({DateTime expires, Future<Map<String, String>> value})>{};

  Future<Map<String, String>> _labelOptions(String kind) async {
    final cached = _filterLabels[kind];
    if (cached != null && cached.expires.isAfter(DateTime.now()))
      return cached.value;
    final pending = _loadLabels(kind);
    _filterLabels[kind] = (
      expires: DateTime.now().add(const Duration(minutes: 10)),
      value: pending,
    );
    try {
      return await pending;
    } catch (_) {
      if (identical(_filterLabels[kind]?.value, pending))
        _filterLabels.remove(kind);
      rethrow;
    }
  }

  Future<Map<String, String>> _loadLabels(String kind) async {
    final data = await _api.request(
      'library/$kind',
      'ANIME.LIBRARY.FILTERS.${kind.toUpperCase()}',
    );
    final rows = data['items'];
    if (rows is! List) throw const AnimeRiftAccessUnavailable();
    return {
      for (final row in rows.whereType<Map<dynamic, dynamic>>())
        if (row['id'] is String &&
            _safeId.hasMatch(row['id'] as String) &&
            row['label'] is String &&
            (row['label'] as String).trim().isNotEmpty)
          (row['label'] as String).trim(): row['id'] as String,
    };
  }

  @override
  Future<ProviderSearchFilterOptions> getSearchFilterOptions() async {
    final labels = await Future.wait([
      _labelOptions('genres'),
      _labelOptions('tags'),
    ]);
    return ProviderSearchFilterOptions(
      statuses: _statuses.keys.toList(),
      types: _types.keys.toList(),
      ageRatings: _ages.keys.toList(),
      seasons: _seasons.keys.toList(),
      years: [for (var y = DateTime.now().year + 1; y >= 1900; y--) '$y'],
      genres: labels[0].keys.toList(),
      tags: labels[1].keys.toList(),
    );
  }

  List<String> _filterValues(Set<String> values, Map<String, String> options) =>
      [
        for (final value in values)
          options[value] ??
              (throw UnsupportedError('قيمة فلتر غير مدعومة في Anime Rift.')),
      ];

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
    if (!const {'', 'year_asc', 'year_desc'}.contains(filters.sort)) {
      throw UnsupportedError('هذه الفلاتر غير مدعومة حاليًا في Anime Rift.');
    }
    final body = <String, dynamic>{
      'query': query,
      if (filters.statuses.isNotEmpty)
        'multi_release_status': _filterValues(filters.statuses, _statuses),
      if (filters.types.isNotEmpty)
        'multi_content_types': _filterValues(filters.types, _types),
      if (filters.ageRatings.isNotEmpty)
        'multi_age_rating': _filterValues(filters.ageRatings, _ages),
      if (filters.seasons.isNotEmpty)
        'multi_seasons': _filterValues(filters.seasons, _seasons),
      if (filters.genres.isNotEmpty)
        'multi_genres': _filterValues(
          filters.genres,
          await _labelOptions('genres'),
        ),
      if (filters.tags.isNotEmpty)
        'multi_tags': _filterValues(filters.tags, await _labelOptions('tags')),
      if (filters.years.isNotEmpty)
        'multi_release_year': [
          for (final year in filters.years)
            if (RegExp(r'^\d{4}$').hasMatch(year))
              year
            else
              throw UnsupportedError('سنة غير صالحة.'),
        ],
    };
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final page = offset < 0 ? 0 : offset;
    final data = await _api.request(
      'library/search',
      'ANIME.LIBRARY.SEARCH',
      method: 'POST',
      body: body,
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

  static const _weekdays = {
    'السبت': 'saturday',
    'الأحد': 'sunday',
    'الإثنين': 'monday',
    'الثلاثاء': 'tuesday',
    'الأربعاء': 'wednesday',
    'الخميس': 'thursday',
    'الجمعة': 'friday',
  };
  Map<String, dynamic>? _schedule;
  DateTime? _scheduleAt;
  Future<Map<String, dynamic>> _scheduleData({
    bool refresh = false,
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    var data = _schedule;
    if (refresh ||
        data == null ||
        DateTime.now().difference(_scheduleAt!) >= const Duration(minutes: 1)) {
      data = await _api.request(
        'library/schedule',
        'ANIME.LIBRARY.SCHEDULE',
        cancelToken: cancelToken,
      );
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      if (data['schedule'] is! List) throw const AnimeRiftAccessUnavailable();
      _schedule = data;
      _scheduleAt = DateTime.now();
    }
    return data;
  }

  @override
  bool get supportsBroadcastSchedule => true;
  @override
  Future<ProviderMediaPage> getBroadcastSchedulePage(
    String day, {
    int offset = 0,
    int limit = 30,
    bool refresh = false,
    CancelToken? cancelToken,
  }) async {
    final weekday = _weekdays[day];
    if (weekday == null) throw UnsupportedError('يوم غير صالح.');
    final data = await _scheduleData(
      refresh: refresh,
      cancelToken: cancelToken,
    );
    final items = <MultimediaItem>[];
    final days = data['schedule'] as List;
    for (final entry in days.whereType<Map<dynamic, dynamic>>()) {
      if (entry['dayName'] != weekday || entry['animes'] is! List) continue;
      final rows =
          (entry['animes'] as List).whereType<Map<dynamic, dynamic>>().toList()
            ..sort(
              (a, b) => ((a['localBroadcastTimeInt'] as num?) ?? 9999)
                  .compareTo((b['localBroadcastTimeInt'] as num?) ?? 9999),
            );
      for (final row in rows) {
        final titles = _items([row['anime']]);
        if (titles.isEmpty) continue;
        final episode = row['episodeNumber'];
        final time = row['localBroadcastTime'];
        final labels = [
          if (episode is num) 'الحلقة $episode',
          if (time is String && RegExp(r'^\d{1,2}:\d{2}$').hasMatch(time)) time,
        ];
        items.add(
          titles.single.copyWith(
            episodeBadge: labels.isEmpty ? null : labels.join(' • '),
          ),
        );
      }
    }
    final start = offset.clamp(0, items.length);
    final end = (start + limit.clamp(1, 100)).clamp(start, items.length);
    return ProviderMediaPage(
      items: items.sublist(start, end),
      nextOffset: end,
      hasMore: end < items.length,
    );
  }

  @override
  bool get supportsSeasons => true;
  String _seasonLabel(int year, int quarter) =>
      '${_seasons.keys.elementAt(quarter)} عام $year';
  @override
  Future<ProviderSeasonConfig> getSeasonConfig() async {
    final now = DateTime.now();
    final quarter = (now.month - 1) ~/ 3;
    return ProviderSeasonConfig(
      past: _seasonLabel(
        quarter == 0 ? now.year - 1 : now.year,
        (quarter + 3) % 4,
      ),
      current: _seasonLabel(now.year, quarter),
      next: _seasonLabel(
        quarter == 3 ? now.year + 1 : now.year,
        (quarter + 1) % 4,
      ),
    );
  }

  @override
  Future<List<String>> getAllSeasons({bool refresh = false}) async => [
    for (var year = DateTime.now().year + 1; year >= 1900; year--)
      for (var quarter = 3; quarter >= 0; quarter--)
        _seasonLabel(year, quarter),
  ];
  @override
  Future<ProviderMediaPage> getSeasonPage(
    String season, {
    int offset = 0,
    int limit = 30,
  }) {
    final match = RegExp(r'^(شتاء|ربيع|صيف|خريف) عام (\d{4})$')
        .firstMatch(season);
    if (match == null) throw UnsupportedError('موسم غير صالح.');
    return searchPage(
      '',
      ProviderSearchFilters(
        seasons: {match[1]!},
        years: {match[2]!},
        sort: 'year_desc',
      ),
      offset: offset,
      limit: limit,
    );
  }

  @override
  bool get supportsIndependentDetailSections => true;

  final _details =
      <String, ({DateTime until, Future<Map<String, dynamic>> value})>{};
  Future<Map<String, dynamic>> _detailData(String url) async {
    final id = _catalogId(url);
    final cached = _details[id];
    if (cached != null && cached.until.isAfter(DateTime.now()))
      return cached.value;
    final future = _api.request('library/details/$id', 'ANIME.LIBRARY.DETAILS');
    _details[id] = (
      until: DateTime.now().add(const Duration(minutes: 2)),
      value: future,
    );
    if (_details.length > 32) _details.remove(_details.keys.first);
    try {
      final data = await future;
      final row = data['item'];
      if (row is! Map<dynamic, dynamic> ||
          row['_id'] != id ||
          row['title'] is! String)
        throw const AnimeRiftAccessUnavailable();
      return data;
    } catch (_) {
      if (identical(_details[id]?.value, future)) _details.remove(id);
      rethrow;
    }
  }

  @override
  Future<MultimediaItem> getDetails(String url) async {
    final data = await _detailData(url);
    final row = data['item'] as Map<dynamic, dynamic>;
    final genreRows = row['genreLabels'];
    final others = data['others'];
    return _item(row).copyWith(
      description: row['synopsis'] is String ? row['synopsis'] as String : null,
      tags: genreRows is List
          ? [
              for (final genre in genreRows.whereType<Map<dynamic, dynamic>>())
                if (genre['label'] is String) genre['label'] as String,
            ]
          : null,
      recommendations: _items(
        others is Map<dynamic, dynamic> ? others['recommendations'] : null,
      ),
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
    for (final row in rows.whereType<Map<dynamic, dynamic>>()) {
      final episodeId = row['_id'];
      final number = row['episode_number'];
      if (episodeId is! String ||
          !_safeId.hasMatch(episodeId) ||
          number is! num ||
          !seen.add(episodeId))
        continue;
      _episodeNumbers['$id:$episodeId'] = number.toInt();
      episodes.add(
        Episode(
          name: _episodeTitle(row, number),
          isFiller: row['is_filler'] == true,
          airDate: row['airedAt'] is String ? row['airedAt'] as String : null,
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

  String _episodeTitle(Map<dynamic, dynamic> row, num number) {
    final titles = row['title_translations'];
    if (titles is Map<dynamic, dynamic>) {
      for (final lang in const ['ar', 'en']) {
        final title = titles[lang];
        if (title is String && title.trim().isNotEmpty) return title.trim();
      }
    }
    return 'الحلقة $number';
  }

  @override
  Future<List<Actor>> getCast(String url) async {
    final data = await _detailData(url);
    final others = data['others'];
    final rows = others is Map<dynamic, dynamic> ? others['characters'] : null;
    if (rows is! List) return [];
    return [
      for (final row in rows.whereType<Map<dynamic, dynamic>>())
        if (row['name'] is String && (row['name'] as String).trim().isNotEmpty)
          Actor(
            name: (row['name'] as String).trim(),
            id: row['_id'] is String ? row['_id'] as String : null,
            image: _art(row['image_jpg_url']),
            likes: (row['likes'] as num?)?.toInt() ?? 0,
          ),
    ];
  }

  @override
  Future<List<Trailer>> getTrailers(String url) async => [];
  @override
  Future<List<MultimediaItem>> getRelated(String url) async {
    final data = await _detailData(url);
    final others = data['others'];
    final rows = (data['item'] as Map<dynamic, dynamic>)['_related'];
    final relations = <String, String>{};
    if (rows is List) {
      for (final row in rows.whereType<Map<dynamic, dynamic>>()) {
        final id = row['_anime'], rawType = row['relation_type'];
        if (id is! String || rawType is! String || rawType.length > 64)
          continue;
        final type = rawType
            .trim()
            .replaceAll(RegExp(r'[\s-]+'), '_')
            .toUpperCase();
        if (RegExp(r'^[A-Z_]+$').hasMatch(type)) relations[id] = type;
      }
    }
    const labels = {
      'PREQUEL': 'السابق',
      'SEQUEL': 'التالي',
      'PARENT': 'القصة الرئيسية',
      'PARENT_STORY': 'القصة الرئيسية',
      'SIDE_STORY': 'قصة جانبية',
      'SPIN_OFF': 'عمل مشتق',
      'ALTERNATIVE': 'نسخة بديلة',
      'ALTERNATIVE_VERSION': 'نسخة بديلة',
      'SUMMARY': 'ملخص',
      'COMPILATION': 'تجميعة',
      'ADAPTATION': 'اقتباس',
      'CHARACTER': 'عمل مرتبط بالشخصيات',
      'SOURCE': 'المصدر',
    };
    return [
      for (final item in _items(
        others is Map<dynamic, dynamic> ? others['related'] : null,
      ))
        item.copyWith(
          relationType: relations[_catalogId(item.url)],
          relationLabel: labels[relations[_catalogId(item.url)]],
        ),
    ];
  }

  @override
  Future<NextAiring?> getNextAiring(String url) async {
    final id = _catalogId(url);
    final data = await _scheduleData();
    final now = DateTime.now();
    NextAiring? next;
    for (final day
        in (data['schedule'] as List).whereType<Map<dynamic, dynamic>>()) {
      final rows = day['animes'];
      if (rows is! List) continue;
      for (final row in rows.whereType<Map<dynamic, dynamic>>()) {
        final anime = row['anime'],
            rawDate = row['airingDate'],
            episode = row['episodeNumber'];
        if (anime is! Map<dynamic, dynamic> ||
            anime['_id'] != id ||
            rawDate is! String ||
            episode is! num ||
            episode <= 0 ||
            !RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(rawDate))
          continue;
        final date = DateTime.tryParse(rawDate);
        if (date == null || !date.isAfter(now)) continue;
        final timestamp = date.millisecondsSinceEpoch ~/ 1000;
        if (next == null || timestamp < next.unixTime) {
          next = NextAiring(episode: episode.toInt(), unixTime: timestamp);
        }
      }
    }
    return next;
  }

  @override
  Future<List<StreamResult>> loadStreamSources(String url) =>
      _streams.loadSources(url);
  @override
  Future<List<StreamResult>> loadStreams(String url) => _streams.resolve(url);
  @override
  Future<List<StreamResult>> loadDownloadStreamSources(String url) =>
      _streams.loadSources(url, download: true);
  @override
  Future<List<StreamResult>> loadDownloadStreams(String url) =>
      _streams.resolve(url, download: true);
  @override
  bool isExplicitStreamSelection(String url) =>
      AnimeRiftStreams.isSourceSelection(url);
  @override
  void invalidateDetailCaches(String url) {
    _details.remove(_catalogId(url));
    _streams.invalidate();
  }
}
