import 'package:dio/dio.dart';

import '../../domain/entity/multimedia_item.dart';
import '../../storage/provider_local_library.dart';
import '../../storage/library_category.dart';
import '../../storage/anime_rift_cloud_sync.dart';
import '../../storage/anime_rift_rating.dart';
import '../../storage/anime_rift_account_scope.dart';
import '../../storage/storage_service.dart';
import '../../services/app_diagnostics.dart';
import '../base_provider.dart';
import '../../utils/anime_rift_identity.dart';
import 'anime_rift_api_client.dart';
import 'anime_rift_comments.dart';
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
  // The comments GET contract has no verified per-viewer liked flag. Remember
  // only locally acknowledged reactions, scoped to the linked account, so
  // reopening the page in this app session does not disguise one's own like.
  final _knownCommentReactions = <String, ({bool liked, int count})>{};

  String? _commentReactionKey(AnimeRiftCommentTarget target, String commentId) {
    final account = AnimeRiftLocalAccountScope.accountHash;
    if (account == null) return null;
    return '$account:${target.animeId}:${target.episodeId ?? ''}:$commentId';
  }

  ({bool liked, int count})? knownCommentReaction(
    AnimeRiftCommentTarget target,
    String commentId,
  ) {
    final key = _commentReactionKey(target, commentId);
    return key == null ? null : _knownCommentReactions[key];
  }

  void rememberCommentReaction(
    AnimeRiftCommentTarget target,
    String commentId, {
    required bool liked,
    required int count,
  }) {
    final key = _commentReactionKey(target, commentId);
    if (key == null) return;
    if (_knownCommentReactions.length >= 500 &&
        !_knownCommentReactions.containsKey(key)) {
      _knownCommentReactions.remove(_knownCommentReactions.keys.first);
    }
    _knownCommentReactions[key] = (liked: liked, count: count);
  }

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
  bool get supportsCharacters => true;
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

  bool get isAccountLinked => _api.isAccountLinked;
  AnimeRiftAccountIdentity? get accountIdentity => _api.accountIdentity;

  Future<Map<String, dynamic>> setCloudFavorite(
    String id,
    bool favorite, {
    required String accountHash,
  }) => _api.setFavoriteAnime(id, favorite, accountHash: accountHash);

  Future<Map<String, dynamic>> setCloudCategory(
    String id,
    String? category, {
    required String accountHash,
  }) => _api.setMyListCategory(id, category, accountHash: accountHash);

  Future<Map<String, dynamic>> fetchCloudCategory(String category) =>
      _api.fetchMyList(category);

  Future<Map<String, dynamic>> fetchCloudFavorites() =>
      _api.fetchFavoriteAnime();

  Future<Map<String, dynamic>> setCloudEpisodeWatched(
    String id,
    int number,
    bool watched, {
    required String accountHash,
  }) => _api.setEpisodeViewed(id, number, watched, accountHash: accountHash);

  Future<Map<String, dynamic>> setCloudRating(
    String id,
    AnimeRiftRating rating, {
    required String accountHash,
  }) => _api.rateAnime(
    id,
    story: rating.story,
    characters: rating.characters,
    animation: rating.animation,
    music: rating.music,
    accountHash: accountHash,
  );

  Future<Map<String, dynamic>> clearCloudRating(
    String id, {
    required String accountHash,
  }) => _api.clearAnimeRating(id, accountHash: accountHash);

  Future<AnimeRiftRating?> fetchCloudRating(String url) async {
    if (!await restoreAccountSession()) return null;
    final account = AnimeRiftLocalAccountScope.accountHash;
    if (account == null) return null;
    final response = await _api.fetchAnimeRating(
      _catalogId(url),
      accountHash: account,
    );
    if (AnimeRiftLocalAccountScope.accountHash != account) {
      throw const AnimeRiftAuthenticationRequired();
    }
    return AnimeRiftRating.fromServer(response);
  }

  Future<Map<String, dynamic>> fetchCloudWatchHistory() =>
      _api.fetchWatchHistoryFull();

  Future<Map<String, dynamic>> clearCloudWatchHistoryRecord(
    String recordId,
    String animeId, {
    required String accountHash,
  }) => _api.removeWatchHistoryRecord(
    recordId,
    animeId,
    accountHash: accountHash,
  );

  Future<Map<String, dynamic>> clearCloudWatchHistoryMany(
    List<String> recordIds, {
    required String accountHash,
  }) => _api.removeWatchHistoryMany(recordIds, accountHash: accountHash);

  Future<bool> restoreAccountSession() async {
    final previous = _api.accountIdentity?.id;
    final restored = await _api.restoreAccountSession();
    if (previous != _api.accountIdentity?.id) _streams.invalidate();
    return restored;
  }

  Future<void> signInWithCode(String code) async {
    await _api.signInWithCode(code);
    _streams.invalidate();
  }

  Future<void> signOut() async {
    await _api.signOut();
    _streams.invalidate();
  }

  /// Shows verified server-side list totals without changing local library
  /// rows. Importing anime records requires a confirmed account list schema.
  Future<Map<String, int>> fetchCloudLibraryCounts() async {
    final response = await _api.fetchMyListOverview();
    if (response['items'] is! Map) throw const AnimeRiftAccessUnavailable();
    return Map<String, int>.unmodifiable(parseMyListOverviewCounts(response));
  }

  /// Populate this Rift account's local library and watch history from the
  /// authenticated account's lists. Unknown server rows remain untouched.
  Future<AnimeRiftCloudImportResult> importCloudLibrary(
    StorageService storage,
  ) =>
      AnimeRiftCloudSync(AnimeRiftCloudApiReader(_api))
          .importToLocal(storage: storage, hydrate: getDetails);

  /// Read exactly the chosen Rift shelf, rather than all account lists/history.
  Future<AnimeRiftCloudImportResult> importCloudLibraryCategory(
    StorageService storage,
    LibraryCategory category,
  ) => AnimeRiftCloudSync(AnimeRiftCloudApiReader(_api)).importSelectedList(
    storage: storage,
    category: category,
    hydrate: getDetails,
  );

  Future<AnimeRiftCloudImportResult> importCloudHistory(
    StorageService storage,
  ) =>
      AnimeRiftCloudSync(AnimeRiftCloudApiReader(_api))
          .importHistoryToLocal(storage: storage, hydrate: getDetails);

  final _homeSectionRows = <String, Map<dynamic, dynamic>>{};
  Future<Map<String, List<MultimediaItem>>>? _homeRequest;

  Future<AnimeRiftCommentPage> loadComments(
    AnimeRiftCommentTarget target, {
    int page = 0,
  }) async {
    final elapsed = Stopwatch()..start();
    final scope = target.parentId != null
        ? 'replies'
        : target.episodeId != null
        ? 'episode'
        : 'anime';
    try {
      final response = await _api.request(
        'comment/all',
        'COMMENTS.VIEW',
        query: {
          ...AnimeRiftApiClient.commentTargetFields(
            animeId: target.animeId,
            episodeId: target.episodeId,
            parentId: target.parentId,
          ),
          'page': page < 0 ? 0 : page,
          'level': target.parentId == null ? 0 : 1,
          'canReply': '1',
          'sort_by': 'recently_added',
        },
      );
      final result = AnimeRiftCommentPage.fromJson(response);
      appDiagnostics.record('rift.comments.page', {
        'status': scope,
        'durationMs': elapsed.elapsedMilliseconds,
        'count': result.items.length,
        'result': result.hasMore,
        'active': _api.isAccountLinked,
        if (result.serverUserIdPresent case final account?)
          'parentActive': account,
      });
      if (result.termsAccepted != null ||
          result.replyAllowed != null ||
          result.canReplyToNext != null) {
        appDiagnostics.record('rift.comments.permissions', {
          'termsAccepted': result.termsAccepted,
          'replyAllowed': result.replyAllowed,
          'canReplyNext': result.canReplyToNext,
        });
      }
      return result;
    } catch (error) {
      appDiagnostics.record('rift.comments.failure', {
        'status': scope,
        'durationMs': elapsed.elapsedMilliseconds,
        'errorType': error.runtimeType.toString(),
      });
      rethrow;
    }
  }

  Future<void> publishComment(
    AnimeRiftCommentTarget target,
    String text,
  ) async {
    await _api.createComment(
      animeId: target.animeId,
      episodeId: target.episodeId,
      parentId: target.parentId,
      text: text,
    );
  }

  Future<void> reactToComment(
    AnimeRiftCommentTarget target,
    String commentId,
  ) async {
    // Native Rift includes its current anime/episode target in the reaction
    // body. A bare comment ID is insufficient to reproduce its write request.
    await _api.reactToComment(
      commentId,
      animeId: target.animeId,
      episodeId: target.episodeId,
    );
  }

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() {
    // Home and continue-watching cards can request the same rail concurrently.
    // Share the in-flight read; otherwise one render can issue a burst of
    // identical home_content calls and amplify server 403/429 responses.
    final existing = _homeRequest;
    if (existing != null) return existing;
    late final Future<Map<String, List<MultimediaItem>>> request;
    request = _fetchHome().whenComplete(() {
      if (identical(_homeRequest, request)) _homeRequest = null;
    });
    _homeRequest = request;
    return request;
  }

  Future<Map<String, List<MultimediaItem>>> _fetchHome() async {
    if (!_api.isConfigured) throw const AnimeRiftAccessUnavailable();
    final data = await _api.request(
      'library/home_content',
      'ANIME.LIBRARY.HOME_CONTENT',
      query: {'with_genres': true},
    );
    final sections = <String, List<MultimediaItem>>{};
    final descriptors = <String, Map<dynamic, dynamic>>{};
    final rows = data['sections'];
    if (rows is! List) throw const AnimeRiftAccessUnavailable();
    for (final row in rows.whereType<Map<dynamic, dynamic>>()) {
      final title = row['sectionTitle'];
      if (title is! String || title.trim().isEmpty) continue;
      descriptors[title] = Map<dynamic, dynamic>.of(row)..remove('items');
      final items = _items(
        row['items'],
        recentReleases:
            row['filterBy'] == 'recent_releases' ||
            _isRecentReleaseSection(title),
      );
      if (items.isNotEmpty) sections.putIfAbsent(title, () => []).addAll(items);
    }
    _homeSectionRows
      ..clear()
      ..addAll(descriptors);
    return sections;
  }

  @override
  Future<ProviderMediaPage> getHomeSectionPage(
    String sectionName, {
    int offset = 0,
    int limit = 30,
  }) async {
    if (!_homeSectionRows.containsKey(sectionName)) await getHome();
    final row = _homeSectionRows[sectionName];
    final filter = row?['filterBy'];
    final sort = row?['sortkey'];
    if (row == null ||
        !const {'library', 'recent_releases'}.contains(filter) ||
        !const {
          'recently_updated',
          'recently_added',
          'popularity',
          'rating',
          'likes',
        }.contains(sort)) {
      // An unknown descriptor must not silently become an unrelated catalogue.
      return super.getHomeSectionPage(
        sectionName,
        offset: offset,
        limit: limit,
      );
    }
    final page = offset < 0 ? 0 : offset;
    final query = <String, dynamic>{
      'page': '$page',
      'filter_by': filter,
      'sort_by': sort,
      'sort_direction': -1,
      'text_direction': 'jp',
    };
    final body = <String, dynamic>{};
    void copyString(Map<String, dynamic> target, String from, String to) {
      final value = row[from];
      if (value == null || value == '') return;
      if (value is! String) throw const AnimeRiftAccessUnavailable();
      target[to] = value;
    }

    copyString(query, 'contentType', 'content_type');
    if (row['filterByDubReleases'] == true) {
      copyString(query, 'dubLang', 'dub');
      if (!query.containsKey('dub')) throw const AnimeRiftAccessUnavailable();
    }
    copyString(body, 'studioId', 'studio');
    copyString(body, 'releaseSeason', 'release_season');
    copyString(body, 'countryOfOrigin', 'country_origin');
    final year = row['releaseYear'];
    if (year != null && year != '') {
      if (!RegExp(r'^\d{4}$').hasMatch('$year')) {
        throw const AnimeRiftAccessUnavailable();
      }
      body['release_year'] = '$year';
    }
    final genre = row['genreId'];
    if (genre != null && genre != '') {
      if (genre is! String || !_safeId.hasMatch(genre)) {
        throw const AnimeRiftAccessUnavailable();
      }
      body['multi_genres'] = [genre];
    }
    // Original AOT: 0xabf340 -> 0xa8a278 -> POST at 0x58ac80.
    // Paging/sort belong in the query; genre/season/year belong in JSON.
    final data = await _api.request(
      'library/all',
      'ANIME.LIBRARY.ALL',
      method: 'POST',
      body: body,
      query: query,
    );
    if (data['items'] is! List) throw const AnimeRiftAccessUnavailable();
    return ProviderMediaPage(
      items: _items(data['items'], recentReleases: filter == 'recent_releases'),
      nextOffset: page + 1,
      hasMore: data['hasNext'] == true,
    );
  }

  static final _safeId = RegExp(r'^[A-Za-z0-9_-]+$');

  static bool _isRecentReleaseSection(String title) {
    final normalized = title
        .toLowerCase()
        .replaceAll(RegExp(r'[أإآ]'), 'ا')
        .replaceAll('ة', 'ه');
    return normalized.contains('اصدارات حديثه') ||
        normalized.contains('الاصدارات الحديثه') ||
        normalized.contains('احدث الاصدارات') ||
        normalized.contains('احدث اصدارات') ||
        normalized.contains('اخر الاصدارات') ||
        normalized.contains('recent releases') ||
        normalized.contains('latest releases') ||
        normalized.contains('recently updated');
  }

  static String? _latestReleaseEpisodeBadge(Map<dynamic, dynamic> row) {
    // The original Rift catalog exposes
    // latest_episode_released.episode_number. This is the released episode,
    // unlike available_episodes (a count that may differ from its number).
    final released = row['latest_episode_released'];
    final number = released is Map ? released['episode_number'] : null;
    if (number is! num || !number.isFinite || number <= 0 || number > 100000) {
      return null;
    }
    final label = number == number.roundToDouble()
        ? number.toInt().toString()
        : number.toString();
    return 'الحلقة $label';
  }

  List<MultimediaItem> _items(dynamic rows, {bool recentReleases = false}) {
    if (rows is! List) return [];
    return [
      for (final row in rows.whereType<Map<dynamic, dynamic>>())
        if (row['_id'] is String &&
            _safeId.hasMatch(row['_id'] as String) &&
            row['title'] is String &&
            (row['title'] as String).trim().isNotEmpty)
          _item(row).copyWith(
            episodeBadge: recentReleases
                ? _latestReleaseEpisodeBadge(row)
                : null,
          ),
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

  static const _statuses = {
    'مستمر': 'on_going',
    'مكتمل': 'finished',
    'توقف مؤقت': 'hiatus',
    'القادمة': 'upcoming',
  };
  static const _types = {
    'مسلسل': 'tv',
    'فيلم': 'movie',
    'اوفا': 'ova',
    'اونا': 'ona',
    'خاصة': 'special',
  };
  static const _ages = {
    'G': 'g',
    'PG': 'pg',
    'PG-13': 'pg_13',
    'R': 'r',
    'R+': 'r+',
    // Accept the former UI labels in previously selected filter state.
    'لجميع الأعمار': 'g',
    '+13': 'pg_13',
    '+17': 'r',
  };
  static const _countries = {
    'اليابان': 'japan',
    'الصين': 'china',
    'كوريا': 'korea',
    'تايوان': 'taiwan',
  };
  static const _sortFields = {
    'title',
    'rating',
    'popularity',
    'likes',
    'release_year',
    'recently_updated',
  };
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
      ageRatings: _ages.keys.take(5).toList(),
      countries: _countries.keys.toList(),
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
    // Old saved year_asc/year_desc values remain readable after the UI
    // switches to a single item per field with a reversible direction.
    final rawSort = filters.sort.isEmpty ? 'year_asc' : filters.sort;
    final ascending = rawSort.endsWith('_asc');
    final field = rawSort == 'year_asc' || rawSort == 'year_desc'
        ? 'release_year'
        : rawSort.endsWith('_asc') || rawSort.endsWith('_desc')
        ? rawSort.substring(0, rawSort.lastIndexOf('_'))
        : '';
    if (!_sortFields.contains(field)) {
      throw UnsupportedError('ترتيب غير مدعوم في Anime Rift.');
    }
    if (filters.countries.length > 1) {
      throw UnsupportedError('اختر بلد منشأ واحدًا فقط في Anime Rift.');
    }
    final body = <String, dynamic>{
      'query': query,
      if (filters.statuses.isNotEmpty)
        'multi_release_status': _filterValues(filters.statuses, _statuses),
      if (filters.types.isNotEmpty)
        'multi_content_types': _filterValues(filters.types, _types),
      if (filters.countries.isNotEmpty)
        'country_origin': _filterValues(filters.countries, _countries).single,
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
        'sort_by': field,
        'sort_direction': ascending ? 1 : -1,
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
  Future<ProviderCharacterPage> getCharacterPage({int page = 0}) {
    return searchCharacterPage('', page: page);
  }

  @override
  Future<ProviderCharacterPage> searchCharacterPage(
    String query, {
    int page = 0,
  }) async {
    final safePage = page < 0 ? 0 : page;
    final data = await _api.request(
      'character/all',
      'CHARACTERS.ALL',
      query: <String, dynamic>{
        'searchText': query.trim(),
        if (safePage > 0) 'page': safePage,
      },
    );
    final rows = data['items'];
    if (rows is! List) throw const AnimeRiftAccessUnavailable();
    final characters = <Actor>[];
    final seen = <String>{};
    for (final row in rows.whereType<Map<dynamic, dynamic>>()) {
      final id = row['_id'];
      final name = row['name'];
      if (id is! String ||
          !_safeId.hasMatch(id) ||
          name is! String ||
          name.trim().isEmpty ||
          !seen.add(id)) {
        continue;
      }
      characters.add(
        Actor(
          id: id,
          name: name.trim(),
          image: _art(row['image_jpg_url']),
          likes: (row['likes'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    final responsePage = (data['page'] as num?)?.toInt() ?? safePage;
    return ProviderCharacterPage(
      items: characters,
      page: responsePage < 0 ? safePage : responsePage,
      hasMore: data['hasNext'] == true,
    );
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
