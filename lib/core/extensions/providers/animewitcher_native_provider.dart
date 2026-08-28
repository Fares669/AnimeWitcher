import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html_unescape/html_unescape.dart';

import '../../account/animewitcher_character_models.dart';
import '../../domain/entity/multimedia_item.dart';
import '../../network/bounded_batch_scheduler.dart';
import '../../network/next_airing_timeout.dart';
import '../../network/stale_connection_retry.dart';
import '../../storage/settings_repository.dart';
import '../../utils/episode_label.dart';
import '../../utils/safe_uri.dart';
import '../base_provider.dart';
import 'mediafire_utils.dart';
import 'server_extraction_utils.dart';

class AnimeWitcherSeasonConfig {
  final String past;
  final String current;
  final String next;

  const AnimeWitcherSeasonConfig({
    required this.past,
    required this.current,
    required this.next,
  });
}

const List<String> animeWitcherBroadcastDays = <String>[
  'السبت',
  'الأحد',
  'الإثنين',
  'الثلاثاء',
  'الأربعاء',
  'الخميس',
  'الجمعة',
];

enum AnimeWitcherGlobalRanking { all, continuing, movies, series, ova, ona }

extension AnimeWitcherGlobalRankingInfo on AnimeWitcherGlobalRanking {
  String get queryType => switch (this) {
        AnimeWitcherGlobalRanking.all => 'all_ranking_mal',
        AnimeWitcherGlobalRanking.continuing => 'continuing_ranking_mal',
        AnimeWitcherGlobalRanking.movies => 'movies_ranking_mal',
        AnimeWitcherGlobalRanking.series => 'series_ranking_mal',
        AnimeWitcherGlobalRanking.ova => 'ova_ranking_mal',
        AnimeWitcherGlobalRanking.ona => 'ona_ranking_mal',
      };

  String get arabicTitle => switch (this) {
        AnimeWitcherGlobalRanking.all => 'أفضل الأنميات',
        AnimeWitcherGlobalRanking.continuing => 'أفضل الأنميات المستمرة',
        AnimeWitcherGlobalRanking.movies => 'أفضل الأفلام',
        AnimeWitcherGlobalRanking.series => 'أفضل المسلسلات',
        AnimeWitcherGlobalRanking.ova => 'أفضل الاوفا',
        AnimeWitcherGlobalRanking.ona => 'أفضل الاونا',
      };

  String get englishTitle => switch (this) {
        AnimeWitcherGlobalRanking.all => 'Top anime',
        AnimeWitcherGlobalRanking.continuing => 'Top ongoing anime',
        AnimeWitcherGlobalRanking.movies => 'Top movies',
        AnimeWitcherGlobalRanking.series => 'Top series',
        AnimeWitcherGlobalRanking.ova => 'Top OVA',
        AnimeWitcherGlobalRanking.ona => 'Top ONA',
      };

  String? get filterField => switch (this) {
        AnimeWitcherGlobalRanking.all => null,
        AnimeWitcherGlobalRanking.continuing => 'details.state',
        AnimeWitcherGlobalRanking.movies => 'type',
        AnimeWitcherGlobalRanking.series => 'type',
        AnimeWitcherGlobalRanking.ova => 'type',
        AnimeWitcherGlobalRanking.ona => 'type',
      };

  String? get filterValue => switch (this) {
        AnimeWitcherGlobalRanking.all => null,
        AnimeWitcherGlobalRanking.continuing => 'مستمر',
        AnimeWitcherGlobalRanking.movies => 'فيلم',
        AnimeWitcherGlobalRanking.series => 'مسلسل',
        AnimeWitcherGlobalRanking.ova => 'اوفا',
        AnimeWitcherGlobalRanking.ona => 'اونا',
      };
}

typedef AnimeWitcherMalIdResolver =
    Future<List<Map<String, dynamic>>> Function(Iterable<int> malIds);

/// Native AnimeWitcher implementation used during the JS-to-native migration.
///
/// It mirrors the current plugin's Firestore/Algolia metadata, independent
/// detail sections, optional AniZip episode artwork, and MF/ST/PD playback
/// paths while the JavaScript provider remains installed for verification.
class AnimeWitcherNativeProvider extends AnimeWitcherProvider {
  AnimeWitcherNativeProvider(
    this._dio,
    this._settings, {
    AnimeWitcherMalIdResolver? resolveAnimeByMalIds,
    bool Function()? isEcchiHidden,
  }) : _resolveAnimeByMalIds = resolveAnimeByMalIds,
       _isEcchiHidden = isEcchiHidden ?? _ecchiIsVisible;

  final Dio _dio;
  final SettingsRepository _settings;
  final AnimeWitcherMalIdResolver? _resolveAnimeByMalIds;
  final bool Function() _isEcchiHidden;
  final HtmlUnescape _unescape = HtmlUnescape();

  static const String _baseUrl = 'https://animewitcher.com';
  static const String _firestoreProjectId = 'animewitcher-1c66d';
  static const String _defaultAlgoliaAppId = '5UIU27G8CZ';
  static const String _defaultAlgoliaApiKey = 'ef06c5ee4a0d213c011694f18861805c';
  static const String _aniZipUrl = 'https://api.ani.zip/mappings';

  String _algoliaAppId = _defaultAlgoliaAppId;
  String _algoliaApiKey = _defaultAlgoliaApiKey;
  String _algoliaBrowseApiKey = '';
  Map<String, dynamic> _searchSettings2 = <String, dynamic>{};
  String _serverLoadType = '';
  final Map<String, Map<String, dynamic>> _animeDocumentCache =
      <String, Map<String, dynamic>>{};
  final Map<String, DateTime> _animeDocumentExpiresAt = <String, DateTime>{};
  final Map<String, Future<Map<String, dynamic>>> _animeDocumentRequests =
      <String, Future<Map<String, dynamic>>>{};
  final Map<String, Map<String, dynamic>> _posterFieldsCache =
      <String, Map<String, dynamic>>{};
  final Map<String, DateTime> _posterFieldsExpiresAt = <String, DateTime>{};
  final Map<String, Map<String, dynamic>> _detailSourceCache =
      <String, Map<String, dynamic>>{};
  final Map<String, DateTime> _detailSourceExpiresAt = <String, DateTime>{};
  final Map<String, Future<Map<String, dynamic>>> _detailSourceRequests =
      <String, Future<Map<String, dynamic>>>{};
  final Map<String, List<_EpisodeRecord>> _episodeRecordCache =
      <String, List<_EpisodeRecord>>{};
  final Map<String, DateTime> _episodeRecordExpiresAt = <String, DateTime>{};
  final Map<String, Future<List<_EpisodeRecord>>> _episodeRecordRequests =
      <String, Future<List<_EpisodeRecord>>>{};
  final Map<int, Map<String, dynamic>> _animeByMalIdCache =
      <int, Map<String, dynamic>>{};
  final Map<int, DateTime> _animeByMalIdExpiresAt = <int, DateTime>{};
  final Map<int, Future<void>> _malIdResolutionRequests =
      <int, Future<void>>{};
  List<_OfficialHomeSection>? _officialHomeSectionsCache;
  DateTime _officialHomeSectionsExpiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<List<_OfficialHomeSection>>? _officialHomeSectionsRequest;
  DateTime _remoteConstantsExpiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void>? _remoteConstantsRequest;
  String _seasonPast = '';
  String _seasonCurrent = '';
  String _seasonNext = '';
  List<String>? _allSeasonsCache;
  DateTime _allSeasonsExpiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  Map<String, List<MultimediaItem>>? _broadcastScheduleCache;
  DateTime _broadcastScheduleExpiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<Map<String, List<MultimediaItem>>>? _broadcastScheduleRequest;
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Safari/537.36';

  static const Duration _httpTimeout = Duration(seconds: 15);
  static const Duration _algoliaConnectTimeout = Duration(milliseconds: 2000);
  static const Duration _algoliaReadTimeout = Duration(milliseconds: 5000);
  static const int _comingSoonHitsPerPage = 100;
  static const Duration _serverTimeout = Duration(seconds: 6);
  static const Duration _streamTimeout = Duration(seconds: 12);
  static const Duration _mediaFireTimeout = Duration(seconds: 30);
  static const Duration _aniZipTimeout = Duration(seconds: 12);
  static const Duration _remoteConstantsTtl = Duration(hours: 6);
  static const Duration _homeSectionsTtl = Duration(minutes: 30);
  static const Duration _detailDataTtl = Duration(minutes: 2);
  static const Duration _broadcastScheduleTtl = Duration(minutes: 2);
  static const Duration _episodeDataTtl = Duration(minutes: 1);
  static const Duration _relatedDataTtl = Duration(minutes: 5);
  static const Duration _posterFieldsTtl = Duration(hours: 6);
  static const int _posterBatchSize = 30;
  // Home sections are independent Algolia requests. Bound their fan-out so a
  // remotely configured home layout cannot monopolize sockets or UI parsing.
  static const int _homeSectionConcurrency = 3;
  static const int _previewSize = 10;
  static const int _maxRelatedItems = 10;
  static const int _maxRecommendations = 10;

  static bool _ecchiIsVisible() => false;


  bool get _useAniZipEpisodeImages =>
      _settings.isEpisodeImagesFromAniZipEnabled();

  bool get _useHighQualityPosters => _settings.isHighQualityPostersEnabled();


  @override
  String get packageName => 'com.fares669.animewitcher.native';

  @override
  String get name => 'AnimeWitcher';

  @override
  String get mainUrl => _baseUrl;

  @override
  String get version => '0.2.0';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const <ProviderType>{
        ProviderType.anime,
        ProviderType.movie,
      };

  @override
  int get viewAllPageSize => 30;

  @override
  int get searchPageSize => 30;

  @override
  bool get supportsIndependentDetailSections => true;

  Options _jsonOptions({
    Map<String, String>? headers,
    Duration timeout = _httpTimeout,
  }) {
    return Options(
      headers: <String, String>{
        'Accept': 'application/json',
        'User-Agent': _userAgent,
        ...?headers,
      },
      sendTimeout: timeout,
      receiveTimeout: timeout,
    );
  }

  dynamic _decodeData(dynamic raw) {
    if (raw is String) {
      try {
        return jsonDecode(raw);
      } catch (_) {
        return null;
      }
    }
    return raw;
  }

  Map<String, dynamic> _map(dynamic raw) {
    raw = _decodeData(raw);
    if (raw is! Map) return <String, dynamic>{};
    return raw.map<String, dynamic>(
      (dynamic key, dynamic value) => MapEntry<String, dynamic>(
        key.toString(),
        value,
      ),
    );
  }

  List<dynamic> _list(dynamic raw) {
    raw = _decodeData(raw);
    return raw is List ? raw : const <dynamic>[];
  }

  Future<({bool reachedServer, Map<String, dynamic> json})> _getJsonResult(
    String url, {
    CancelToken? cancelToken,
    Duration timeout = _httpTimeout,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.get<dynamic>(
        url,
        cancelToken: cancelToken,
        options: _jsonOptions(headers: headers, timeout: timeout),
      );
      if ((response.statusCode ?? 0) < 200 ||
          (response.statusCode ?? 0) >= 300) {
        return (reachedServer: false, json: <String, dynamic>{});
      }
      return (reachedServer: true, json: _map(response.data));
    } on DioException {
      return (reachedServer: false, json: <String, dynamic>{});
    }
  }

  Future<Map<String, dynamic>?> _getJson(
    String url, {
    CancelToken? cancelToken,
    Duration timeout = _httpTimeout,
    Map<String, String>? headers,
  }) async {
    final result = await _getJsonResult(
      url,
      cancelToken: cancelToken,
      timeout: timeout,
      headers: headers,
    );
    if (!result.reachedServer || result.json.isEmpty) return null;
    return result.json;
  }

  Future<Map<String, dynamic>?> _postJson(
    String url,
    Map<String, dynamic> body, {
    CancelToken? cancelToken,
    Duration timeout = _httpTimeout,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        url,
        data: body,
        cancelToken: cancelToken,
        options: _jsonOptions(
          headers: <String, String>{
            'Content-Type': 'application/json; charset=UTF-8',
            ...?headers,
          },
          timeout: timeout,
        ),
      );
      if ((response.statusCode ?? 0) < 200 || (response.statusCode ?? 0) >= 300) {
        return null;
      }
      final value = _map(response.data);
      return value.isEmpty ? null : value;
    } on DioException {
      return null;
    }
  }

  String _encodeFirestorePath(String path) {
    return path.split('/').map((segment) {
      if (segment.isEmpty) return segment;

      // Keep provider/document IDs raw inside the app and percent-encode each
      // Firestore REST path segment exactly once at the network boundary.
      // This preserves Unicode, literal `%`, and even valid-looking literals
      // such as `%20` without double-decoding or double-encoding.
      return safeEncodeUriComponent(segment);
    }).join('/');
  }

  String _firestoreUrl(String path) {
    return 'https://firestore.googleapis.com/v1/projects/'
        '${Uri.encodeComponent(_firestoreProjectId)}'
        '/databases/(default)/documents/${_encodeFirestorePath(path)}';
  }

  String _firestoreBatchGetUrl() {
    return 'https://firestore.googleapis.com/v1/projects/'
        '${Uri.encodeComponent(_firestoreProjectId)}'
        '/databases/(default)/documents:batchGet';
  }

  /// Resource name for a request body, where Firestore expects raw ids rather
  /// than the percent-encoded segments used in URLs.
  String _firestoreDocumentName(String path) {
    return 'projects/$_firestoreProjectId/databases/(default)/documents/$path';
  }

  String _firestoreRunQueryUrl([String parent = '']) {
    final base = 'https://firestore.googleapis.com/v1/projects/'
        '${Uri.encodeComponent(_firestoreProjectId)}'
        '/databases/(default)/documents';
    final cleanParent = parent.trim();
    return cleanParent.isEmpty
        ? '$base:runQuery'
        : '$base/${_encodeFirestorePath(cleanParent)}:runQuery';
  }

  dynamic _firestoreValue(dynamic raw) {
    final value = _map(raw);
    if (value.isEmpty) return null;
    if (value.containsKey('stringValue')) {
      return value['stringValue']?.toString() ?? '';
    }
    if (value.containsKey('integerValue')) {
      return int.tryParse(value['integerValue']?.toString() ?? '') ?? 0;
    }
    if (value.containsKey('doubleValue')) {
      final rawDouble = value['doubleValue'];
      if (rawDouble is num) return rawDouble.toDouble();
      return double.tryParse(rawDouble?.toString() ?? '') ?? 0.0;
    }
    if (value.containsKey('booleanValue')) return value['booleanValue'] == true;
    if (value.containsKey('timestampValue')) {
      return value['timestampValue']?.toString() ?? '';
    }
    if (value.containsKey('nullValue')) return null;
    if (value.containsKey('referenceValue')) {
      return value['referenceValue']?.toString() ?? '';
    }
    if (value.containsKey('bytesValue')) return value['bytesValue']?.toString() ?? '';
    if (value.containsKey('geoPointValue')) return _map(value['geoPointValue']);

    final arrayValue = _map(value['arrayValue']);
    if (arrayValue.isNotEmpty) {
      return _list(arrayValue['values'])
          .map<dynamic>(_firestoreValue)
          .toList(growable: false);
    }
    final mapValue = _map(value['mapValue']);
    if (mapValue.isNotEmpty) return _firestoreFields(mapValue['fields']);
    return null;
  }

  Map<String, dynamic> _firestoreFields(dynamic raw) {
    final fields = _map(raw);
    final output = <String, dynamic>{};
    for (final entry in fields.entries) {
      output[entry.key] = _firestoreValue(entry.value);
    }
    return output;
  }

  Map<String, dynamic> _firestoreDocumentHit(dynamic raw) {
    final document = _map(raw);
    if (document.isEmpty) return <String, dynamic>{};
    final hit = _firestoreFields(document['fields']);
    final name = _text(document['name']);
    final id = name.isEmpty ? '' : name.split('/').last;
    if (id.isNotEmpty) {
      hit.putIfAbsent('objectID', () => id);
      hit.putIfAbsent('anime_id', () => id);
      hit.putIfAbsent('path', () => id);
    }
    return hit;
  }

  Future<List<dynamic>?> _firestoreRestRunQueryIfOk(
    Map<String, dynamic> structuredQuery, {
    String parent = '',
    Duration timeout = _httpTimeout,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        _firestoreRunQueryUrl(parent),
        data: <String, dynamic>{'structuredQuery': structuredQuery},
        cancelToken: cancelToken,
        options: _jsonOptions(timeout: timeout),
      );
      if ((response.statusCode ?? 0) < 200 ||
          (response.statusCode ?? 0) >= 300) {
        return null;
      }
      return _list(response.data);
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      return null;
    }
  }

  Future<List<dynamic>> _firestoreRestRunQuery(
    Map<String, dynamic> structuredQuery, {
    String parent = '',
    Duration timeout = _httpTimeout,
    CancelToken? cancelToken,
  }) async {
    return await _firestoreRestRunQueryIfOk(
          structuredQuery,
          parent: parent,
          timeout: timeout,
          cancelToken: cancelToken,
        ) ??
        const <dynamic>[];
  }

  Future<Map<String, dynamic>> _firestoreDocumentFields(
    String path, {
    Duration timeout = _httpTimeout,
  }) async {

    final payload = await _getJson(_firestoreUrl(path), timeout: timeout);
    if (payload == null) return <String, dynamic>{};
    return _firestoreFields(payload['fields']);
  }

  Future<Response<String>?> _getText(
    String url, {
    Duration timeout = _httpTimeout,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          validateStatus: (status) => status != null && status >= 200 && status < 400,
          headers: <String, String>{
            'User-Agent': _userAgent,
            ...?headers,
          },
          sendTimeout: timeout,
          receiveTimeout: timeout,
        ),
      );
      return response;
    } on DioException {
      return null;
    }
  }

  Future<void> _refreshRemoteConstants({bool force = false}) async {
    final now = DateTime.now();
    if (!force && _remoteConstantsExpiresAt.isAfter(now)) return;
    final inFlight = _remoteConstantsRequest;
    if (inFlight != null) return inFlight;

    final request = () async {
      var fields = await _firestoreConstantsFields();
      if (fields.isEmpty) {
        fields = await _loadConstantsFromAlgoliaFallback();
      }
      if (fields.isEmpty) return;
      await _applyRemoteConstants(fields);
      _remoteConstantsExpiresAt = DateTime.now().add(_remoteConstantsTtl);
    }();
    _remoteConstantsRequest = request;
    try {
      await request;
    } finally {
      if (identical(_remoteConstantsRequest, request)) {
        _remoteConstantsRequest = null;
      }
    }
  }

  Future<Map<String, dynamic>> _firestoreConstantsFields() async {
    final result = await _getJsonResult(_firestoreUrl('Settings/constants'));
    if (!result.reachedServer) return const <String, dynamic>{};
    return _firestoreFields(result.json['fields']);
  }

  Future<Map<String, dynamic>> _loadConstantsFromAlgoliaFallback() async {
    if (_searchSettings2.isEmpty) {
      _searchSettings2 = _settings.getAnimeWitcherSearchSettings2();
    }
    final appId = _searchSettings2AppId(_searchSettings2);
    final apiKey = _searchSettings2ApiKey(_searchSettings2);
    if (appId.isEmpty || apiKey.isEmpty) return const <String, dynamic>{};
    final payload = await _algoliaSdkGet(
      appId: appId,
      apiKey: apiKey,
      path: '/1/indexes/Settings/constants',
    );
    if (payload == null) return const <String, dynamic>{};
    if (payload['fields'] is Map) {
      final fields = _firestoreFields(payload['fields']);
      if (fields.isNotEmpty) return fields;
    }
    return payload;
  }

  Future<void> _applyRemoteConstants(Map<String, dynamic> fields) async {
    final settings = _map(fields['search_settings']);
    final settings2 = _map(fields['search_settings2']);
    final appId = _text(
      settings['app_id_v3'] ?? settings['app_id'] ?? settings['application_id'],
    );
    final apiKey = _text(settings['api_key'] ?? settings['search_api_key']);
    final browseKey = _text(
      settings['browse_api_key'] ?? settings['browseApiKey'],
    );
    if (appId.isNotEmpty) _algoliaAppId = appId;
    if (apiKey.isNotEmpty) _algoliaApiKey = apiKey;
    if (browseKey.isNotEmpty) _algoliaBrowseApiKey = browseKey;
    if (settings2.isNotEmpty) {
      _searchSettings2 = Map<String, dynamic>.from(settings2);
    }

    final serverLoadType = _text(fields['load_servers_type']).toLowerCase();
    if (serverLoadType.isNotEmpty) _serverLoadType = serverLoadType;

    final seasons = _map(fields['seasons']);
    final past = _text(seasons['past']);
    final current = _text(seasons['current']);
    final next = _text(seasons['next']);
    if (past.isNotEmpty) _seasonPast = past;
    if (current.isNotEmpty) _seasonCurrent = current;
    if (next.isNotEmpty) _seasonNext = next;

    if (settings.isNotEmpty) {
      await _settings.saveAnimeWitcherSearchSettings(settings);
    }
    if (settings2.isNotEmpty) {
      await _settings.saveAnimeWitcherSearchSettings2(settings2);
    }
  }

  String _searchSettings2AppId(Map<String, dynamic> settings2) {
    return _text(
      settings2['algolia_app_id2'] ??
          settings2['app_id_v3'] ??
          settings2['app_id'] ??
          settings2['application_id'],
    );
  }

  String _searchSettings2ApiKey(Map<String, dynamic> settings2) {
    return _text(
      settings2['algolia_api_key2'] ??
          settings2['api_key'] ??
          settings2['search_api_key'],
    );
  }

  Map<String, String> _algoliaAuthHeaders(String appId, String apiKey) {
    return <String, String>{
      'X-Algolia-Application-Id': appId,
      'X-Algolia-API-Key': apiKey,
      'X-Algolia-Agent': 'Algolia for Android (3.27.0); Android (13)',
      'User-Agent': 'Algolia for Android (3.27.0); Android (13)',
    };
  }

  List<String> _algoliaHosts(String appId) {
    return <String>[
      '$appId-dsn.algolia.net',
      '$appId-1.algolianet.com',
      '$appId-2.algolianet.com',
      '$appId-3.algolianet.com',
    ];
  }

  /// GET helper matching Algolia Android SDK host fallback and timeouts.
  Future<Map<String, dynamic>?> _algoliaSdkGet({
    required String appId,
    required String apiKey,
    required String path,
    Map<String, dynamic>? queryParameters,
  }) async {
    final headers = _algoliaAuthHeaders(appId, apiKey);
    for (final host in _algoliaHosts(appId)) {
      try {
        final response = await _dio.get<dynamic>(
          'https://$host$path',
          queryParameters: queryParameters,
          options: Options(
            headers: <String, String>{
              'Accept': 'application/json',
              ...headers,
            },
            sendTimeout: _algoliaConnectTimeout,
            receiveTimeout: _algoliaReadTimeout,
            connectTimeout: _algoliaConnectTimeout,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 500,
          ),
        );
        final status = response.statusCode ?? 0;
        if (status >= 200 && status < 300) {
          final json = _map(response.data);
          return json.isEmpty ? null : json;
        }
        if (status >= 400 && status < 500 && status != 429) {
          return null;
        }
      } on DioException {
        continue;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _algoliaQuery(
    String index, {
    String query = '',
    int page = 0,
    int hitsPerPage = 30,
    int maxHitsPerPage = 100,
    String filters = '',
    List<String>? attributes,
    CancelToken? cancelToken,
    bool throwOnFailure = false,
  }) async {
    await _refreshRemoteConstants();
    return _algoliaIndexRequest(
      index: index,
      operation: 'query',
      appId: _algoliaAppId,
      apiKey: _algoliaApiKey,
      query: query,
      page: page,
      hitsPerPage: hitsPerPage,
      maxHitsPerPage: maxHitsPerPage,
      filters: filters,
      attributes: attributes,
      cancelToken: cancelToken,
      throwOnFailure: throwOnFailure,
    );
  }

  Future<Map<String, dynamic>> _algoliaIndexRequest({
    required String index,
    required String operation,
    required String appId,
    required String apiKey,
    String query = '',
    int page = 0,
    int hitsPerPage = 30,
    int maxHitsPerPage = 100,
    String filters = '',
    List<String>? attributes,
    CancelToken? cancelToken,
    bool throwOnFailure = false,
  }) async {
    final params = <String>[];
    void append(String key, Object? value) {
      if (value == null || value.toString().isEmpty) return;
      params.add(
        '${Uri.encodeQueryComponent(key)}='
        '${Uri.encodeQueryComponent(value.toString())}',
      );
    }

    append('query', query);
    append('hitsPerPage', hitsPerPage.clamp(1, maxHitsPerPage));
    append('page', page < 0 ? 0 : page);
    if (attributes != null && attributes.isNotEmpty) {
      append('attributesToRetrieve', jsonEncode(attributes));
    }
    if (filters.isNotEmpty) append('filters', filters);

    final url =
        'https://$appId-dsn.algolia.net/1/indexes/'
        '${Uri.encodeComponent(index)}/$operation';
    final payload = await _postJson(
      url,
      <String, dynamic>{'params': params.join('&')},
      cancelToken: cancelToken,
      headers: <String, String>{
        'X-Algolia-Application-Id': appId,
        'X-Algolia-API-Key': apiKey,
        'X-Algolia-Agent': 'Algolia for JavaScript (4.x); AnimeWitcher',
        'User-Agent': 'Algolia for Android (3.27.0); Android (13)',
      },
    );
    if (payload == null || payload['hits'] is! List) {
      if (throwOnFailure) {
        throw StateError('AnimeWitcher catalog request failed.');
      }
      return <String, dynamic>{
        'hits': const <dynamic>[],
        'page': 0,
        'nbPages': 0,
      };
    }
    return payload;
  }

  Future<AnimeWitcherSearchServiceSettings> _loadSearchService() async {
    final fields = await _firestoreDocumentFields(animeWitcherSearchServicePath);
    return AnimeWitcherSearchServiceSettings.fromFields(fields);
  }

  Future<AnimeWitcherCharacterPage> getCharactersPage({
    int page = 0,
    int hitsPerPage = animeWitcherCharacterBrowseHitsPerPage,
  }) async {
    final settings = await _loadSearchService();
    if (!settings.isSearchActive) {
      throw AnimeWitcherSearchDisabledException(
        settings.errorMessage.isEmpty ? 'لا يوجد بيانات' : settings.errorMessage,
      );
    }
    if (settings.appId.isEmpty || settings.browseApiKey.isEmpty) {
      throw StateError('AnimeWitcher catalog request failed.');
    }
    final safePage = page < 0 ? 0 : page;
    final payload = await _algoliaIndexRequest(
      index: animeWitcherCharactersAlgoliaIndex,
      operation: 'browse',
      appId: settings.appId,
      apiKey: settings.browseApiKey,
      page: safePage,
      hitsPerPage: hitsPerPage,
      maxHitsPerPage: hitsPerPage < 20 ? 20 : hitsPerPage,
      attributes: animeWitcherCharacterAlgoliaAttributes,
      throwOnFailure: true,
    );
    return _characterPageFromAlgolia(payload, requestedPage: safePage);
  }

  Future<AnimeWitcherCharacterPage> searchCharacters(String query) async {
    final text = query.trim();
    if (text.isEmpty) {
      return getCharactersPage();
    }
    final settings = await _loadSearchService();
    if (!settings.isSearchActive) {
      throw AnimeWitcherSearchDisabledException(
        settings.errorMessage.isEmpty ? 'لا يوجد بيانات' : settings.errorMessage,
      );
    }
    final payload = await _algoliaQuery(
      animeWitcherCharactersAlgoliaIndex,
      query: text,
      page: 0,
      hitsPerPage: animeWitcherCharacterSearchHitsPerPage,
      maxHitsPerPage: animeWitcherCharacterSearchHitsPerPage,
      attributes: animeWitcherCharacterAlgoliaAttributes,
      throwOnFailure: true,
    );
    return _characterPageFromAlgolia(payload, requestedPage: 0, isSearch: true);
  }

  AnimeWitcherCharacterPage _characterPageFromAlgolia(
    Map<String, dynamic> payload, {
    required int requestedPage,
    bool isSearch = false,
  }) {
    final rawHits = _list(payload['hits']);
    final items = rawHits
        .map(AnimeWitcherCharacterHit.fromAlgolia)
        .where((hit) => hit.id.isNotEmpty && hit.name.isNotEmpty)
        .toList(growable: false);
    final nbPages = int.tryParse(_text(payload['nbPages'])) ?? 0;
    final page = int.tryParse(_text(payload['page'])) ?? requestedPage;
    final pageSize = isSearch
        ? animeWitcherCharacterSearchHitsPerPage
        : animeWitcherCharacterBrowseHitsPerPage;
    final hasMore = isSearch
        ? false
        : nbPages > 0
            ? page + 1 < nbPages
            : items.length >= pageSize;
    return AnimeWitcherCharacterPage(
      items: items,
      page: page,
      hasMore: hasMore,
    );
  }

  Future<AnimeWitcherCharacterDocument?> getCharacterDocument(
    String characterId,
  ) async {
    final id = characterId.trim();
    if (id.isEmpty) return null;
    final fields = await _firestoreDocumentFields(
      animeWitcherCharactersListPath(id),
    );
    if (fields.isEmpty) return null;
    final document = AnimeWitcherCharacterDocument.fromFields(id, fields);
    if (document.name.isEmpty) return null;
    return document;
  }

  Future<List<AnimeWitcherCharacterShow>> getCharacterAnimes(
    AnimeWitcherCharacterDocument character,
  ) async {
    final shows = <AnimeWitcherCharacterShow>[];
    final seen = <String>{};
    for (final reference in character.animes) {
      final raw = await _firestoreRestRunQuery(
        <String, dynamic>{
          'from': const <Map<String, dynamic>>[
            <String, dynamic>{'collectionId': 'anime_list'},
          ],
          'where': <String, dynamic>{
            'fieldFilter': <String, dynamic>{
              'field': const <String, dynamic>{'fieldPath': 'mal_id'},
              'op': 'EQUAL',
              'value': <String, dynamic>{'stringValue': reference.malId},
            },
          },
          'limit': 1,
        },
      );
      if (raw.isEmpty) continue;
      final hit = _firestoreDocumentHit(_map(raw.first)['document']);
      if (hit.isEmpty) continue;
      final item = _mapHit(hit);
      if (item.title.trim().isEmpty || item.url.trim().isEmpty) continue;
      if (!seen.add(item.url)) continue;
      shows.add(AnimeWitcherCharacterShow(item: item, role: reference.role));
    }
    return _filterEcchiItems(shows.map((show) => show.item))
        .map((item) {
          final match = shows.firstWhere((show) => show.item.url == item.url);
          return AnimeWitcherCharacterShow(item: item, role: match.role);
        })
        .toList(growable: false);
  }

  static const List<String> _searchAttributes = <String>[
    'objectID',
    'anime_id',
    'name',
    'english_title',
    'poster_uri',
    'order',
    'path',
    'type',
    'details',
    'tags',
    'mal_id',
    'malId',
    'rating',
    'dubbed',
    'poster',
    'cover_uri',
    'show_time',
  ];

  /// Attributes retrieved by the official Android `Index.browse` coming-soon
  /// drawer (`MainAnimeListFragment` with status "لم يتم بثه بعد").
  static const List<String> _comingSoonBrowseAttributes = <String>[
    'objectID',
    'name',
    'tags',
    'poster_uri',
    'order',
    'path',
    'type',
    'poster',
    'aniList_poster',
    'details',
    'dubbed',
  ];

  static const List<String> _similarAttributes = <String>[
    'objectID',
    'anime_id',
    'name',
    'english_title',
    'poster_uri',
    'order',
    'path',
    'type',
    'poster',
    'cover_uri',
    'tags',
    'mal_id',
    'malId',
    'details',
    'dubbed',
    'year',
  ];

  static const List<String> _recentAttributes = <String>[
    'filler',
    'note',
    'name',
    'date',
    'doc_ref',
    'episode_id',
    'anime_id',
    'episode_name',
    'title',
    'poster_uri',
    'poster',
    'cover_uri',
    'mal_id',
    'malId',
    'type',
    'tags',
    'thumb_uri',
    'year',
    'dubbed',
    'comments_closed',
    'is_final',
    'isFinal',
    'final',
    'last',
    'is_last',
    'isLast',
  ];

  static const List<String> _newsAttributes = <String>[
    'objectID',
    'date_created',
    'news_link',
    'thumb_link',
    'title',
    'anime_id',
  ];

  String _text(dynamic value) => value == null ? '' : value.toString().trim();

  String _firstText(
    Map<String, dynamic> source,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = _text(source[key]);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  DateTime? _newsDate(dynamic raw) {
    final source = _map(raw);
    dynamic value = source.isEmpty
        ? raw
        : source['_seconds'] ??
            source['seconds'] ??
            source['timestamp'] ??
            source['value'];
    if (value is Map) {
      final nested = _map(value);
      value = nested['_seconds'] ??
          nested['seconds'] ??
          nested['timestamp'] ??
          nested['value'];
    }

    final number = value is num ? value : num.tryParse(_text(value));
    if (number != null) {
      var timestamp = number.toInt();
      if (timestamp.abs() < 100000000000) {
        timestamp *= 1000;
      }
      return DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true).toLocal();
    }

    final parsed = DateTime.tryParse(_text(value));
    return parsed?.toLocal();
  }

  NewsItem? _newsItem(dynamic raw) {
    final source = _map(raw);
    final id = _firstText(source, const <String>[
      'objectID',
      'docId',
      'doc_id',
      'id',
    ]);
    final title = _decodeHtml(
      _firstText(source, const <String>[
        'title',
        'title_ar',
        'title_translated',
        'name',
      ]),
    );
    final imageUrl = _firstText(source, const <String>[
      'thumb_link',
      'thumb_uri',
      'thumb_url',
      'image_url',
      'image',
      'poster_uri',
      'cover_uri',
    ]);
    final newsUrl = _firstText(source, const <String>[
      'news_link',
      'newsLink',
      'url',
      'link',
      'path',
    ]);
    final animeId = _firstText(source, const <String>[
      'anime_id',
      'animeId',
      'series_id',
      'seriesId',
    ]);
    final stableId = id.isNotEmpty
        ? id
        : newsUrl.isNotEmpty
            ? newsUrl
            : title;
    if (stableId.isEmpty || title.isEmpty) return null;

    final rawDocRef = _firstText(source, const <String>[
      'doc_ref',
      'docRef',
    ]);
    return NewsItem(
      id: stableId,
      title: title,
      imageUrl: imageUrl,
      newsUrl: newsUrl.isEmpty ? null : newsUrl,
      animeId: animeId.isEmpty ? null : animeId,
      docRef: rawDocRef.isEmpty ? 'news/$stableId' : rawDocRef,
      publishedAt: _newsDate(source['date_created'] ?? source['date']),
    );
  }

  List<NewsItem> _dedupeNews(List<dynamic> rawHits) {
    final items = <NewsItem>[];
    final seen = <String>{};
    for (final raw in rawHits) {
      final item = _newsItem(raw);
      if (item == null || !seen.add(item.id)) continue;
      items.add(item);
    }
    return items;
  }

  bool _isTruthy(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;

    final normalized = _text(value).toLowerCase();
    return normalized == 'true' ||
        normalized == '1' ||
        normalized == 'yes' ||
        normalized == 'filler' ||
        normalized == 'فلر';
  }

  String _decodeHtml(dynamic value) {
    final text = _unescape.convert(_text(value));
    return text.replaceAll(RegExp(r'<[^>]+>'), '').trim();
  }

  String _lastPathSegment(String value) {
    final parts = value.split('/').where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? '' : parts.last;
  }

  String _animeIdFromHit(Map<String, dynamic> source) {
    final anime = _map(source['anime']);
    final series = _map(source['series']);
    final docRef = _text(source['doc_ref'] ?? source['docRef']);
    final docId = docRef.isEmpty
        ? ''
        : _lastPathSegment(docRef);
    final candidates = <dynamic>[
      source['anime_id'],
      source['animeId'],
      source['parent_anime_id'],
      source['parentAnimeId'],
      source['series_id'],
      source['seriesId'],
      anime['anime_id'],
      anime['animeId'],
      anime['id'],
      anime['name'],
      series['anime_id'],
      series['id'],
      series['name'],
      docId,
      source['objectID'],
      source['id'],
      source['path'],
    ];
    for (final candidate in candidates) {
      final value = _text(candidate);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String _makeAnimeUrl(Map<String, dynamic> hit) {
    // Keep one stable URL for an anime regardless of which Algolia index it
    // came from (recent episodes, search, season lists, etc.). Embedded hit
    // payloads made the same anime look like different items throughout the app.
    final animeId = _animeIdFromHit(hit);
    return '$_baseUrl/watch/${safeEncodeUriComponent(animeId)}';
  }

  _AnimeRoute _parseAnimeUrl(String url) {
    final source = url.trim();
    final uri = safeTryParseUri(source);
    String animeId = '';
    if (uri != null && uri.pathSegments.isNotEmpty) {
      animeId = uri.pathSegments.last;
    }
    Map<String, dynamic> hit = <String, dynamic>{};
    final raw = uri?.queryParameters['aw_data'];
    if (raw != null && raw.isNotEmpty) {
      // Uri.queryParameters already percent-decodes once. Prefer the decoded
      // value directly and only use the safe decoder as a legacy fallback for
      // old URLs that embedded an additional encoded payload.
      try {
        hit = _map(jsonDecode(raw));
      } catch (_) {
        try {
          hit = _map(jsonDecode(safeDecodeUriComponent(raw)));
        } catch (_) {}
      }
    }
    return _AnimeRoute(animeId: animeId, hit: hit);
  }

  String _highestQualityPosterFromHit(Map<String, dynamic> source) {
    final poster = _map(source['poster']);
    final candidates = <dynamic>[
      for (final key in _largePosterKeys) poster[key],
      source['poster_uri'],
      poster['medium'],
      source['cover_uri'],
    ];
    for (final candidate in candidates) {
      final value = _text(candidate);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String _posterFromHit(Map<String, dynamic> source) {
    if (_useHighQualityPosters) return _highestQualityPosterFromHit(source);
    final poster = _map(source['poster']);
    // Catalog cards keep the lighter artwork when the setting is off.
    final candidates = <dynamic>[
      source['poster_uri'],
      poster['medium'],
      poster['large'],
      source['cover_uri'],
    ];
    for (final candidate in candidates) {
      final value = _text(candidate);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String _coverFromHit(Map<String, dynamic> source) {
    final poster = _map(source['poster']);
    for (final candidate in <dynamic>[
      source['cover_uri'],
      poster['large'],
      source['poster_uri'],
    ]) {
      final value = _text(candidate);
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  bool _isMovieType(dynamic raw) {
    final value = _text(raw).trim().toLowerCase();
    return value.contains('فيلم') ||
        value.contains('فلم') ||
        value == 'movie' ||
        value == 'film' ||
        value.contains('movie');
  }

  String? _catalogTypeFromHit(Map<String, dynamic> source) {
    final details = _map(source['details']);
    final raw = _text(source['type'] ?? details['type']);
    return raw.isEmpty ? null : raw;
  }

  bool _isDubbedHit(Map<String, dynamic> source) {
    final details = _map(source['details']);
    final raw = source['dubbed'] ?? details['dubbed'];
    if (raw == true || raw == 1) return true;
    final value = _text(raw).toLowerCase();
    return value == 'true' ||
        value == '1' ||
        value.contains('مدبلج') ||
        value.contains('dub');
  }

  ShowStatus _statusFromHit(Map<String, dynamic> source) {
    final details = _map(source['details']);
    final raw = _text(
      details['state'] ??
          details['status'] ??
          source['state'] ??
          source['status'],
    ).toLowerCase();
    if (RegExp(r'مكتمل|منتهي|finished|completed', caseSensitive: false)
        .hasMatch(raw)) {
      return ShowStatus.completed;
    }
    if (RegExp(
      r'قادم|لم يعرض|لم يتم عرضه|لم يتم بثه بعد|لم يبث|upcoming|not yet',
      caseSensitive: false,
    )
        .hasMatch(raw)) {
      return ShowStatus.upcoming;
    }
    return ShowStatus.ongoing;
  }

  int? _yearFromHit(Map<String, dynamic> source) {
    final details = _map(source['details']);
    final match = RegExp(r'\b(19|20)\d{2}\b')
        .firstMatch(_text(details['year'] ?? source['year']));
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  List<String> _stringList(dynamic raw) {
    return _list(raw)
        .map<String>((value) => _text(value))
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  int _malId(Map<String, dynamic> source) {
    final details = _map(source['details']);
    final raw = source['mal_id'] ??
        source['malId'] ??
        source['malID'] ??
        details['mal_id'] ??
        details['malId'] ??
        details['malID'];
    final match = RegExp(r'\d+').firstMatch(_text(raw));
    return match == null ? 0 : (int.tryParse(match.group(0)!) ?? 0);
  }

  MultimediaItem _mapHit(
    Map<String, dynamic> source, {
    bool recent = false,
  }) {
    final title = _text(
      source['name'] ?? source['english_title'] ?? source['objectID'],
    );
    final story = _decodeHtml(source['story'] ?? source['description']);
    String description = story;
    String? episodeBadge;
    if (recent) {
      final episodeName = _decodeHtml(
        source['episode_name'] ?? source['episodeName'],
      );
      // Latest-episodes posters show the server label as-is: الفيلم, حلقة 5,
      // حلقة 12 والأخيرة, مترجم, مدبلج, …
      episodeBadge = latestEpisodesPosterBadge(episodeName);

      final creativeTitle = realEpisodeTitle(episodeName);
      if (creativeTitle.isNotEmpty) {
        description =
            story.isEmpty ? creativeTitle : '$creativeTitle • $story';
      }
    }

    return MultimediaItem(
      title: title.isEmpty ? 'AnimeWitcher' : title,
      url: _makeAnimeUrl(source),
      posterUrl: _posterFromHit(source),
      fullPosterUrl: _highestQualityPosterFromHit(source),
      description: description.isEmpty ? null : description,
      contentType:
          _isMovieType(source['type']) ? MultimediaContentType.movie : MultimediaContentType.anime,
      provider: packageName,
      year: _yearFromHit(source),
      status: _statusFromHit(source),
      tags: _stringList(source['tags']),
      source: 'AnimeWitcher Native',
      episodeBadge: episodeBadge,
      catalogType: _catalogTypeFromHit(source),
      publishedAt: recent ? _newsDate(source['date'] ?? source['created_at']) : null,
      isDubbed: _isDubbedHit(source),
    );
  }

  static const List<String> _largePosterKeys = <String>[
    'original',
    'full',
    'extraLarge',
    'extra_large',
    'extralarge',
    'xlarge',
    'large',
  ];

  static const List<String> _posterFieldPaths = <String>[
    'poster',
    'poster_uri',
    'cover_uri',
  ];

  bool _hasLargePoster(Map<String, dynamic> hit) {
    final poster = _map(hit['poster']);
    for (final key in _largePosterKeys) {
      if (_text(poster[key]).isNotEmpty) return true;
    }
    return false;
  }

  Map<String, dynamic>? _cachedPosterFields(String animeId) {
    final document = _animeDocumentCache[animeId];
    if (document != null && _hasLargePoster(document)) return document;
    final cached = _posterFieldsCache[animeId];
    if (cached == null) return null;
    if (_posterFieldsExpiresAt[animeId]?.isAfter(DateTime.now()) != true) {
      _posterFieldsCache.remove(animeId);
      _posterFieldsExpiresAt.remove(animeId);
      return null;
    }
    return cached;
  }

  void _applyPosterFields(
    Map<String, dynamic> hit,
    Map<String, dynamic> fields,
  ) {
    final poster = _map(fields['poster']);
    if (poster.isNotEmpty) {
      hit['poster'] = <String, dynamic>{..._map(hit['poster']), ...poster};
    }
    for (final key in const <String>['poster_uri', 'cover_uri']) {
      final value = _text(fields[key]);
      if (value.isNotEmpty && _text(hit[key]).isEmpty) hit[key] = value;
    }
  }

  /// Reads the poster fields of several `anime_list` documents in one call.
  ///
  /// The field mask keeps the response tiny, so this stays cheap enough to run
  /// for a whole page of cards.
  Future<Map<String, Map<String, dynamic>>> _fetchPosterFields(
    List<String> animeIds,
  ) async {
    if (animeIds.isEmpty) return const <String, Map<String, dynamic>>{};
    final response = await _dio.post<dynamic>(
      _firestoreBatchGetUrl(),
      data: <String, dynamic>{
        'documents': <String>[
          for (final id in animeIds) _firestoreDocumentName('anime_list/$id'),
        ],
        'mask': const <String, dynamic>{'fieldPaths': _posterFieldPaths},
      },
      options: _jsonOptions(timeout: _serverTimeout),
    );
    final output = <String, Map<String, dynamic>>{};
    for (final rowRaw in _list(response.data)) {
      final found = _map(_map(rowRaw)['found']);
      if (found.isEmpty) continue;
      final id = _lastPathSegment(_text(found['name']));
      if (id.isEmpty) continue;
      output[id] = _firestoreFields(found['fields']);
    }
    return output;
  }

  /// Gives every hit the poster the details page would show.
  ///
  /// Some Algolia indexes only store the small `poster_uri`, so cards stayed
  /// soft until the anime page fetched the full document. One masked batch read
  /// per page — cached per title, and skipped entirely when the hits already
  /// carry a large poster — lets search, home and the rest open at full quality.
  Future<void> _fillLargePosters(List<Map<String, dynamic>> hits) async {
    final pending = <String, List<Map<String, dynamic>>>{};
    for (final hit in hits) {
      if (_hasLargePoster(hit)) continue;
      final animeId = _animeIdFromHit(hit);
      if (animeId.isEmpty) continue;
      final cached = _cachedPosterFields(animeId);
      if (cached != null) {
        _applyPosterFields(hit, cached);
        continue;
      }
      pending.putIfAbsent(animeId, () => <Map<String, dynamic>>[]).add(hit);
    }
    if (pending.isEmpty) return;

    final ids = pending.keys.toList(growable: false);
    final chunks = <List<String>>[
      for (var start = 0; start < ids.length; start += _posterBatchSize)
        ids.sublist(
          start,
          start + _posterBatchSize > ids.length
              ? ids.length
              : start + _posterBatchSize,
        ),
    ];
    final results = await BoundedBatchScheduler.mapOrdered<
      List<String>,
      Map<String, Map<String, dynamic>>?
    >(
      chunks,
      maxConcurrent: _homeSectionConcurrency,
      mapper: _fetchPosterFields,
      onError: (chunk, error, stackTrace) {
        if (kDebugMode) {
          debugPrint(
            '[AnimeWitcher] Poster batch failed (${chunk.length} ids): $error',
          );
        }
        return null;
      },
    );

    final expiresAt = DateTime.now().add(_posterFieldsTtl);
    for (var index = 0; index < chunks.length; index++) {
      final fetched = results[index];
      // A failed batch must not be cached as "no large poster" or cards stay
      // soft for the full poster TTL.
      if (fetched == null) continue;
      for (final id in chunks[index]) {
        final fields = fetched[id] ?? const <String, dynamic>{};
        // Cache misses too: a title without a stored large poster should not be
        // requested again on every page.
        _posterFieldsCache[id] = fields;
        _posterFieldsExpiresAt[id] = expiresAt;
        if (fields.isEmpty) continue;
        for (final hit in pending[id] ?? const <Map<String, dynamic>>[]) {
          _applyPosterFields(hit, fields);
        }
      }
    }
  }

  Future<List<MultimediaItem>> _dedupeHits(
    Iterable<dynamic> hits, {
    bool recent = false,
    bool applyEcchiFilter = true,
  }) async {
    final maps = hits.map(_map).where((hit) => hit.isNotEmpty).toList();
    await _fillLargePosters(maps);
    final seen = <String>{};
    final output = <MultimediaItem>[];
    for (final hit in maps) {
      final item = _mapHit(hit, recent: recent);
      if (item.title.trim().isEmpty || item.url.trim().isEmpty) continue;
      if (!seen.add(item.url)) continue;
      output.add(item);
    }
    return applyEcchiFilter ? _filterEcchiItems(output) : output;
  }

  /// Applies the account-level content preference only to discovery results.
  /// A precise tag match is intentional: title/description matching would
  /// hide unrelated anime and `isAdult` is broader than AnimeWitcher's ecchi
  /// category.
  List<MultimediaItem> _filterEcchiItems(Iterable<MultimediaItem> items) {
    if (!_isEcchiHidden()) return items.toList(growable: false);
    return items
        .where((item) => !_containsEcchiTag(item.tags ?? const <String>[]))
        .toList(growable: false);
  }

  bool _containsEcchiTag(Iterable<String> tags) {
    for (final tag in tags) {
      for (final part in tag.split(RegExp(r'[,|/]+'))) {
        if (_isEcchiTag(part)) return true;
      }
    }
    return false;
  }

  bool _isEcchiTag(String value) {
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\u064B-\u065F\u0670]'), '')
        .replaceAll('إ', 'ا')
        .replaceAll('أ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ى', 'ي')
        .replaceAll(RegExp(r'[\s_-]+'), '');
    return normalized == 'ecchi' || normalized == 'ايتشي';
  }

  String _quotedFilterValue(String value) => jsonEncode(value);

  String _filterGroup(String field, Iterable<String> values, String joiner) {
    final clean = values.map((value) => value.trim()).where((value) => value.isNotEmpty).toList();
    if (clean.isEmpty) return '';
    final pieces = clean.map((value) => '$field:${_quotedFilterValue(value)}').toList();
    if (pieces.length == 1) return pieces.first;
    return '(${pieces.join(' $joiner ')})';
  }

  String _seasonFilter(ProviderSearchFilters filters) {
    final seasons = filters.seasons
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (seasons.isEmpty) return '';

    final selectedYears = filters.years
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (selectedYears.isEmpty) {
      // The UI blocks this state. Keep a defensive no-match filter for any
      // persisted/programmatic filter that selects a season without a year.
      return _filterGroup(
        'details.season',
        const <String>['__season_requires_year__'],
        'OR',
      );
    }

    final values = <String>[
      for (final season in seasons)
        for (final year in selectedYears) '$season عام $year',
    ];
    return _filterGroup('details.season', values, 'OR');
  }

  String _buildFilters(ProviderSearchFilters filters) {
    final hasSeason = filters.seasons.any((value) => value.trim().isNotEmpty);
    return <String>[
      _filterGroup('details.state', filters.statuses, 'OR'),
      _filterGroup('type', filters.types, 'OR'),
      _filterGroup('details.age', filters.ageRatings, 'OR'),
      if (!hasSeason) _filterGroup('details.year', filters.years, 'OR'),
      _seasonFilter(filters),
      _filterGroup('tags', filters.genres, 'AND'),
    ].where((value) => value.isNotEmpty).join(' AND ');
  }

  @override
  Future<ProviderSearchFilterOptions> getSearchFilterOptions() async {
    final years = <String>[
      for (var year = 2028; year >= 1961; year--) year.toString(),
    ];
    return ProviderSearchFilterOptions(
      statuses: const <String>['لم يتم بثه بعد', 'مستمر', 'مكتمل'],
      types: const <String>['مسلسل', 'اونا', 'اوفا', 'فيلم', 'خاصة'],
      ageRatings: const <String>['+17', '+13', 'لجميع الأعمار'],
      years: years,
      seasons: const <String>['شتاء', 'ربيع', 'صيف', 'خريف'],
      genres: const <String>[
        'اكشن', 'مغامرات', 'دراما', 'كوميدي', 'خيال', 'اعادة بعث', 'عالم مختلف',
        'سينين', 'شوجو', 'شونين', 'رعب', 'غموض', 'رومانسي', 'خيال علمي',
        'شريحة من الحياة', 'رياضي', 'خارق للطبيعة', 'تشويق', 'ايتشي', 'سيارات',
        'شياطين', 'لعبة', 'حريم', 'تاريخي', 'فنون قتالية', 'ميكا', 'عسكري',
        'موسيقي', 'طعام', 'بنات كيوت', 'رياضات قتالية', 'محاكاة ساخرة', 'بوليسي',
        'نفسي', 'اثارة شغب', 'راحة نفسية', 'تحول جنسي سحري', 'جريمة منظمة',
        'العاب خطيرة', 'تحقيق', 'دموي', 'ايدول', 'اساطير', 'سباق',
        'لعبة استراتيجية', 'فنون بصرية', 'سفر عبر الزمن', 'نجاة', 'ساموراي',
        'مدرسي', 'مكان عمل', 'فضاء', 'قوة خارقة', 'مصاصي دماء', 'جوسي', 'اطفال',
      ],
    );
  }

  AnimeWitcherSeasonConfig _fallbackSeasonConfig() {
    const names = <String>['شتاء', 'ربيع', 'صيف', 'خريف'];
    final now = DateTime.now();
    final currentIndex = ((now.month - 1) ~/ 3).clamp(0, 3).toInt();

    String valueFor(int index, int year) => '${names[index]} عام $year';

    final previousIndex = (currentIndex + 3) % 4;
    final nextIndex = (currentIndex + 1) % 4;
    final previousYear = currentIndex == 0 ? now.year - 1 : now.year;
    final nextYear = currentIndex == 3 ? now.year + 1 : now.year;
    return AnimeWitcherSeasonConfig(
      past: valueFor(previousIndex, previousYear),
      current: valueFor(currentIndex, now.year),
      next: valueFor(nextIndex, nextYear),
    );
  }

  Future<AnimeWitcherSeasonConfig> getSeasonConfig() async {
    await _refreshRemoteConstants();
    final fallback = _fallbackSeasonConfig();
    return AnimeWitcherSeasonConfig(
      past: _seasonPast.isEmpty ? fallback.past : _seasonPast,
      current: _seasonCurrent.isEmpty ? fallback.current : _seasonCurrent,
      next: _seasonNext.isEmpty ? fallback.next : _seasonNext,
    );
  }

  Future<List<String>> getAllSeasons({bool refresh = false}) async {
    final now = DateTime.now();
    final cached = _allSeasonsCache;
    if (!refresh && cached != null && _allSeasonsExpiresAt.isAfter(now)) {
      return List<String>.unmodifiable(cached);
    }

    final fields = await _firestoreDocumentFields('Settings/all_seasons');
    final values = _list(fields['all_seasons'])
        .map<String>(_text)
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (values.isNotEmpty) {
      _allSeasonsCache = values;
      _allSeasonsExpiresAt = now.add(_remoteConstantsTtl);
    }
    return List<String>.unmodifiable(values);
  }

  Future<ProviderMediaPage> getSeasonPage(
    String season, {
    int offset = 0,
    int limit = 30,
  }) async {
    final value = season.trim();
    final safeOffset = offset < 0 ? 0 : offset;
    final safeLimit = limit.clamp(10, 50).toInt();
    if (value.isEmpty) {
      return ProviderMediaPage(
        items: const <MultimediaItem>[],
        nextOffset: safeOffset,
        hasMore: false,
      );
    }

    final pageNumber = safeOffset ~/ safeLimit;
    final payload = await _algoliaQuery(
      'series',
      query: '',
      page: pageNumber,
      hitsPerPage: safeLimit,
      filters: _filterGroup('details.season', <String>[value], 'OR'),
      attributes: _searchAttributes,
    );
    final rawHits = _list(payload['hits']);
    final items = await _dedupeHits(rawHits);
    final nbPages = int.tryParse(_text(payload['nbPages'])) ?? 0;
    final hasMore = nbPages > 0
        ? pageNumber + 1 < nbPages
        : rawHits.length >= safeLimit;
    return ProviderMediaPage(
      items: items,
      nextOffset: (pageNumber + 1) * safeLimit,
      hasMore: hasMore,
    );
  }

  /// Loads the complete weekly map for existing callers. The page-based UI
  /// normally avoids this path, but this bounded cache preserves the original
  /// Algolia fallback without repeating it for every tab or pagination step.
  Future<Map<String, List<MultimediaItem>>> getBroadcastSchedule({
    bool refresh = false,
  }) async {
    final now = DateTime.now();
    final cached = _broadcastScheduleCache;
    if (!refresh &&
        cached != null &&
        _broadcastScheduleExpiresAt.isAfter(now)) {
      return _filterBroadcastSchedule(cached);
    }
    final inFlight = _broadcastScheduleRequest;
    if (!refresh && inFlight != null) return inFlight;

    final request = _loadBroadcastSchedule();
    _broadcastScheduleRequest = request;
    try {
      final schedule = await request;
      _broadcastScheduleCache = schedule;
      _broadcastScheduleExpiresAt = DateTime.now().add(_broadcastScheduleTtl);
      return _filterBroadcastSchedule(schedule);
    } finally {
      if (identical(_broadcastScheduleRequest, request)) {
        _broadcastScheduleRequest = null;
      }
    }
  }

  Future<Map<String, List<MultimediaItem>>> _loadBroadcastSchedule() async {
    final grouped = <String, List<Map<String, dynamic>>>{
      for (final day in animeWitcherBroadcastDays)
        day: <Map<String, dynamic>>[],
    };

    var foundScheduleHits = false;

    if (!foundScheduleHits) {
      final values = animeWitcherBroadcastDays
          .map<Map<String, dynamic>>(
            (day) => <String, dynamic>{'stringValue': day},
          )
          .toList(growable: false);
      final raw = await _firestoreRestRunQuery(<String, dynamic>{
        'from': const <Map<String, dynamic>>[
          <String, dynamic>{'collectionId': 'anime_list'},
        ],
        'where': <String, dynamic>{
          'fieldFilter': <String, dynamic>{
            'field': const <String, dynamic>{'fieldPath': 'show_time'},
            'op': 'IN',
            'value': <String, dynamic>{
              'arrayValue': <String, dynamic>{'values': values},
            },
          },
        },
        'limit': 500,
      });
      for (final rowRaw in raw) {
        final document = _map(_map(rowRaw)['document']);
        if (document.isEmpty) continue;
        final hit = _firestoreDocumentHit(document);
        if (hit.isEmpty) continue;
        final day = _text(hit['show_time']);
        final bucket = grouped[day];
        if (bucket == null) continue;
        bucket.add(hit);
        foundScheduleHits = true;
      }
    }

    if (!foundScheduleHits) {
      final algolia = await _algoliaQuery(
        'series',
        query: '',
        page: 0,
        hitsPerPage: 100,
        filters: _filterGroup(
          'details.state',
          const <String>['مستمر'],
          'OR',
        ),
        attributes: _searchAttributes,
      );
      for (final rawHit in _list(algolia['hits'])) {
        final hit = _map(rawHit);
        if (hit.isEmpty) continue;
        final details = _map(hit['details']);
        final day = _text(
          hit['show_time'] ??
              hit['showTime'] ??
              details['show_time'] ??
              details['showTime'],
        );
        grouped[day]?.add(hit);
      }
    }

    final lists = await Future.wait(
      animeWitcherBroadcastDays.map(
        (day) => _dedupeHits(grouped[day]!, applyEcchiFilter: false),
      ),
    );
    return <String, List<MultimediaItem>>{
      for (var i = 0; i < animeWitcherBroadcastDays.length; i++)
        animeWitcherBroadcastDays[i]: lists[i],
    };
  }

  Map<String, List<MultimediaItem>> _filterBroadcastSchedule(
    Map<String, List<MultimediaItem>> schedule,
  ) {
    return <String, List<MultimediaItem>>{
      for (final entry in schedule.entries)
        entry.key: _filterEcchiItems(entry.value),
    };
  }

  /// V1.4.8 parity: load one broadcast day at a time so the schedule screen
  /// can page lazily, refresh safely, and cancel a stale tab request.
  ///
  /// The existing [getBroadcastSchedule] API remains intact for any caller
  /// that needs the complete weekly map. Firestore is authoritative when it
  /// returns rows; the legacy weekly loader is only used as a first-page
  /// fallback when Firestore yields no schedule anywhere.
  Future<ProviderMediaPage> getBroadcastSchedulePage(
    String day, {
    int offset = 0,
    int limit = 30,
    bool refresh = false,
    CancelToken? cancelToken,
  }) async {
    final normalizedDay = day.trim();
    if (!animeWitcherBroadcastDays.contains(normalizedDay)) {
      return const ProviderMediaPage(
        items: <MultimediaItem>[],
        nextOffset: 0,
        hasMore: false,
      );
    }
    final safeOffset = offset < 0 ? 0 : offset;
    final safeLimit = limit.clamp(1, 100).toInt();
    final raw = await _firestoreRestRunQueryIfOk(
      <String, dynamic>{
        'from': const <Map<String, dynamic>>[
          <String, dynamic>{'collectionId': 'anime_list'},
        ],
        'where': <String, dynamic>{
          'fieldFilter': <String, dynamic>{
            'field': const <String, dynamic>{'fieldPath': 'show_time'},
            'op': 'EQUAL',
            'value': <String, dynamic>{'stringValue': normalizedDay},
          },
        },
        'orderBy': const <Map<String, dynamic>>[
          <String, dynamic>{
            'field': <String, dynamic>{'fieldPath': '__name__'},
            'direction': 'ASCENDING',
          },
        ],
        'offset': safeOffset,
        'limit': safeLimit + 1,
      },
      cancelToken: cancelToken,
    );
    if (raw != null) {
      final hits = <Map<String, dynamic>>[];
      for (final rowRaw in raw) {
        final document = _map(_map(rowRaw)['document']);
        if (document.isEmpty) continue;
        final hit = _firestoreDocumentHit(document);
        if (hit.isNotEmpty) hits.add(hit);
      }
      if (hits.isEmpty) {
        return ProviderMediaPage(
          items: const <MultimediaItem>[],
          nextOffset: safeOffset,
          hasMore: false,
        );
      }
      final items = await _dedupeHits(hits);
      final visible = items.take(safeLimit).toList(growable: false);
      final hasMore = hits.length > safeLimit;
      final consumedRows = hasMore ? safeLimit : hits.length;
      return ProviderMediaPage(
        items: visible,
        nextOffset: safeOffset + consumedRows,
        hasMore: hasMore,
      );
    }

    if (safeOffset > 0 || cancelToken?.isCancelled == true) {
      return ProviderMediaPage(
        items: const <MultimediaItem>[],
        nextOffset: safeOffset,
        hasMore: false,
      );
    }
    final fallback = await getBroadcastSchedule(refresh: refresh);
    if (cancelToken?.isCancelled == true) {
      return ProviderMediaPage(
        items: const <MultimediaItem>[],
        nextOffset: safeOffset,
        hasMore: false,
      );
    }
    final items = fallback[normalizedDay] ?? const <MultimediaItem>[];
    final end = safeLimit.clamp(0, items.length).toInt();
    return ProviderMediaPage(
      items: items.sublist(0, end),
      nextOffset: end,
      hasMore: end < items.length,
    );
  }

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    final page = await searchPage(
      query,
      const ProviderSearchFilters(),
      offset: 0,
      limit: searchPageSize,
      cancelToken: cancelToken,
    );
    return page.items;
  }

  @override
  Future<List<MultimediaItem>> searchWithFilters(
    String query,
    ProviderSearchFilters filters, {
    CancelToken? cancelToken,
  }) async {
    final page = await searchPage(
      query,
      filters,
      offset: 0,
      limit: searchPageSize,
      cancelToken: cancelToken,
    );
    return page.items;
  }

  String _searchIndexForSort(String sort) {
    switch (sort.trim().toLowerCase()) {
      case 'favorites':
        // AnimeWitcher's source app labels the primary series index as
        // "Most favorited".
        return 'series';
      case 'year_asc':
        return 'series_year_asc';
      case 'year_desc':
        return 'series_year_desc';
      case 'name_asc':
        return 'series_name_asc';
      case 'name_desc':
        return 'series_name_desc';
      case 'rating':
        return 'series_ranking_mal';
      case 'date_added':
        return 'series_date_created';
      default:
        return 'series';
    }
  }

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async {
    final text = query.trim();
    final expression = _buildFilters(filters);
    final safeLimit = limit.clamp(10, 50).toInt();
    final safeOffset = offset < 0 ? 0 : offset;
    final pageNumber = safeOffset ~/ safeLimit;
    // AnimeWitcher's MainAnimeListFragment initializes its catalog with
    // series_name_asc. Keep typed searches on the normal `series` index and
    // use the main-list index for an empty landing page unless the user
    // explicitly selects another sort mode.
    final searchIndex = text.isEmpty && filters.sort.trim().isEmpty
        ? 'series_name_asc'
        : _searchIndexForSort(filters.sort);
    final payload = await _algoliaQuery(
      searchIndex,
      query: text,
      page: pageNumber,
      hitsPerPage: safeLimit,
      filters: expression,
      attributes: _searchAttributes,
      cancelToken: cancelToken,
      throwOnFailure: true,
    );
    final rawHits = _list(payload['hits']);
    final items = await _dedupeHits(rawHits);
    final nbPages = int.tryParse(_text(payload['nbPages'])) ?? 0;
    final hasMore = nbPages > 0 ? pageNumber + 1 < nbPages : rawHits.length >= safeLimit;
    return ProviderMediaPage(
      items: items,
      nextOffset: (pageNumber + 1) * safeLimit,
      hasMore: hasMore,
    );
  }

  _OfficialHomeSection _officialHomeSection(dynamic raw) {
    final source = _map(raw);
    final rawHits = source['hits_per_page'] ?? source['hitsPerPage'] ?? source['limit'];
    final hits = rawHits is num ? rawHits.toInt() : int.tryParse(_text(rawHits)) ?? _previewSize;
    final rawOrder = source['order'];
    final order = rawOrder is num ? rawOrder.toInt() : int.tryParse(_text(rawOrder)) ?? (1 << 30);
    return _OfficialHomeSection(
      title: _text(source['title']),
      type: _text(source['type']).toLowerCase(),
      indexName: _text(source['index_name'] ?? source['indexName']),
      searchText: _text(source['search_text'] ?? source['searchText']),
      hitsPerPage: hits > 0 ? hits : _previewSize,
      order: order,
      enabled: source['enabled'] == null ? true : source['enabled'] == true,
      autoScroll: source['auto_scroll'] == true || source['autoScroll'] == true,
    );
  }

  Future<List<_OfficialHomeSection>> _fetchOfficialHomeSections() async {
    final now = DateTime.now();
    final cached = _officialHomeSectionsCache;
    if (cached != null && _officialHomeSectionsExpiresAt.isAfter(now)) {
      return cached;
    }
    final inFlight = _officialHomeSectionsRequest;
    if (inFlight != null) return inFlight;

    final request = () async {
      final fields = await _firestoreDocumentFields('Settings/home_sections');
      // `_firestoreDocumentFields` collapses HTTP/transport failures into an
      // empty map. Do not cache that result: retry and pull-to-refresh must
      // hit Firestore again as soon as connectivity is restored.
      if (fields.isEmpty) {
        throw StateError('AnimeWitcher home sections are unavailable.');
      }
      final sections = _list(fields['sections'])
          .map<_OfficialHomeSection>(_officialHomeSection)
          .where((section) =>
              section.enabled &&
              section.title.isNotEmpty &&
              section.indexName.isNotEmpty)
          .toList();
      sections.sort((a, b) => a.order.compareTo(b.order));
      if (sections.isNotEmpty) {
        _officialHomeSectionsCache = sections;
        _officialHomeSectionsExpiresAt = now.add(_homeSectionsTtl);
      }
      return sections;
    }();
    _officialHomeSectionsRequest = request;
    try {
      return await request;
    } finally {
      if (identical(_officialHomeSectionsRequest, request)) {
        _officialHomeSectionsRequest = null;
      }
    }
  }

  bool _isNewsHomeSection(_OfficialHomeSection section) {
    final text =
        (section.title + ' ' + section.type + ' ' + section.indexName)
            .toLowerCase();
    return section.type == 'news' ||
        section.indexName.toLowerCase() == 'news' ||
        section.indexName.toLowerCase().contains('news') ||
        RegExp(r'الأخبار|اخبار|news').hasMatch(text);
  }

  _OfficialHomeSection? _officialNewsSection(
    List<_OfficialHomeSection> sections,
  ) {
    for (final section in sections) {
      if (_isNewsHomeSection(section)) return section;
    }
    return null;
  }

  bool _isLatestHomeSection(_OfficialHomeSection section) {
    final text = '${section.title} ${section.type} ${section.indexName}'.toLowerCase();
    return section.type == 'recent' ||
        section.indexName.toLowerCase() == 'recent' ||
        RegExp(r'أحدث الحلقات|الحلقات الجديدة|آخر الحلقات|recent').hasMatch(text);
  }

  _HomePlan _homePlanFromOfficial(_OfficialHomeSection section) {
    return _HomePlan(
      index: section.indexName,
      query: _isLatestHomeSection(section) ? '' : section.searchText,
      recent: _isLatestHomeSection(section),
    );
  }

  Future<ProviderMediaPage> _loadHomePage(
    String sectionName, {
    int offset = 0,
    int limit = 30,
    bool throwOnFailure = false,
  }) async {
    await _refreshRemoteConstants();
    final sections = await _fetchOfficialHomeSections();
    _OfficialHomeSection? official;
    for (final section in sections) {
      if (section.title == sectionName.trim()) {
        official = section;
        break;
      }
    }
    final safeOffset = offset < 0 ? 0 : offset;
    final safeLimit = limit.clamp(1, 50).toInt();
    if (official == null) {
      return ProviderMediaPage(items: const [], nextOffset: safeOffset, hasMore: false);
    }
    final plan = _homePlanFromOfficial(official);
    final pageNumber = safeOffset ~/ safeLimit;
    Future<Map<String, dynamic>> load(String index) => _algoliaQuery(
          index,
          query: plan.query,
          page: pageNumber,
          hitsPerPage: safeLimit,
          filters: plan.filters,
          attributes: plan.recent ? _recentAttributes : _searchAttributes,
          throwOnFailure: throwOnFailure,
        );

    final payload = await load(plan.index);
    final rawHits = _list(payload['hits']);
    final items = await _dedupeHits(
      rawHits,
      recent: plan.recent,
    );
    final nbPages = int.tryParse(_text(payload['nbPages'])) ?? 0;
    final hasMore = nbPages > 0 ? pageNumber + 1 < nbPages : rawHits.length >= safeLimit;
    return ProviderMediaPage(
      items: items,
      nextOffset: (pageNumber + 1) * safeLimit,
      hasMore: hasMore,
    );
  }


  /// Coming soon lists titles whose AnimeWitcher status is "not yet aired",
  /// matching the official Android drawer item "قادم قريبا":
  /// `Index.browse` on `series` with `details.state:"لم يتم بثه بعد"`.
  /// There is no Firestore fallback when browse fails.
  Future<ProviderMediaPage> getUpcomingPage({
    int offset = 0,
  }) async {
    const unairedStatus = 'لم يتم بثه بعد';
    final safeOffset = offset < 0 ? 0 : offset;
    const hitsPerPage = _comingSoonHitsPerPage;
    final pageNumber = safeOffset ~/ hitsPerPage;
    await _refreshRemoteConstants();
    if (_algoliaBrowseApiKey.isEmpty) {
      throw StateError('AnimeWitcher catalog request failed.');
    }
    final filters = _filterGroup(
      'details.state',
      const <String>[unairedStatus],
      'OR',
    );
    final payload = await _algoliaSdkGet(
      appId: _algoliaAppId,
      apiKey: _algoliaBrowseApiKey,
      path: '/1/indexes/series/browse',
      queryParameters: <String, dynamic>{
        'filters': filters,
        'hitsPerPage': '$hitsPerPage',
        'page': '$pageNumber',
        'attributesToRetrieve': jsonEncode(_comingSoonBrowseAttributes),
      },
    );
    if (payload == null || payload['hits'] is! List) {
      throw StateError('AnimeWitcher catalog request failed.');
    }
    final rawHits = _list(payload['hits']);
    final items = await _dedupeHits(rawHits);
    final nbPages = int.tryParse(_text(payload['nbPages'])) ?? 0;
    final hasMore = nbPages > 0
        ? pageNumber + 1 < nbPages
        : rawHits.length >= hitsPerPage;
    return ProviderMediaPage(
      items: items,
      nextOffset: (pageNumber + 1) * hitsPerPage,
      hasMore: hasMore,
    );
  }

  Future<List<MultimediaItem>> getGlobalRanking(
    AnimeWitcherGlobalRanking ranking, {
    int limit = 100,
  }) async {
    final page = await getGlobalRankingPage(
      ranking,
      offset: 0,
      limit: limit,
    );
    return page.items;
  }

  Future<ProviderMediaPage> getGlobalRankingPage(
    AnimeWitcherGlobalRanking ranking, {
    int offset = 0,
    int limit = 30,
  }) async {
    final safeOffset = offset < 0 ? 0 : offset;
    final safeLimit = limit.clamp(1, 100).toInt();
    final filterField = ranking.filterField;
    final filterValue = ranking.filterValue;

    final structuredQuery = <String, dynamic>{
      'from': const <Map<String, dynamic>>[
        <String, dynamic>{'collectionId': 'anime_list'},
      ],
      if (filterField != null && filterValue != null)
        'where': <String, dynamic>{
          'fieldFilter': <String, dynamic>{
            'field': <String, dynamic>{'fieldPath': filterField},
            'op': 'EQUAL',
            'value': <String, dynamic>{'stringValue': filterValue},
          },
        },
      'orderBy': const <Map<String, dynamic>>[
        <String, dynamic>{
          'field': <String, dynamic>{'fieldPath': 'details.mal_rank'},
          'direction': 'ASCENDING',
        },
      ],
      if (safeOffset > 0) 'offset': safeOffset,
      'limit': safeLimit,
    };
    final raw = await _firestoreRestRunQuery(structuredQuery);
    final firestoreHits = <Map<String, dynamic>>[];
    for (final rowRaw in raw) {
      final document = _map(_map(rowRaw)['document']);
      if (document.isEmpty) continue;
      final hit = _firestoreDocumentHit(document);
      if (hit.isNotEmpty) firestoreHits.add(hit);
    }
    if (firestoreHits.isNotEmpty) {
      return ProviderMediaPage(
        items: await _dedupeHits(firestoreHits),
        nextOffset: safeOffset + firestoreHits.length,
        hasMore: firestoreHits.length >= safeLimit,
      );
    }

    final pageNumber = safeOffset ~/ safeLimit;
    ProviderMediaPage pageFromAlgolia(Map<String, dynamic> payload) {
      final rawHits = _list(payload['hits']);
      final nbPages = int.tryParse(_text(payload['nbPages'])) ?? 0;
      return ProviderMediaPage(
        items: const <MultimediaItem>[],
        nextOffset: (pageNumber + 1) * safeLimit,
        hasMore: nbPages > 0
            ? pageNumber + 1 < nbPages
            : rawHits.length >= safeLimit,
      );
    }

    final rankingPayload = await _algoliaQuery(
      ranking.queryType,
      query: '',
      page: pageNumber,
      hitsPerPage: safeLimit,
      attributes: _searchAttributes,
    );
    final rankingHits = _list(rankingPayload['hits']);
    if (rankingHits.isNotEmpty) {
      final pagination = pageFromAlgolia(rankingPayload);
      return ProviderMediaPage(
        items: await _dedupeHits(rankingHits),
        nextOffset: pagination.nextOffset,
        hasMore: pagination.hasMore,
      );
    }

    final filters = filterField != null && filterValue != null
        ? _filterGroup(filterField, <String>[filterValue], 'OR')
        : '';
    if (ranking.queryType != 'series_ranking_mal' || filters.isNotEmpty) {
      final legacyPayload = await _algoliaQuery(
        'series_ranking_mal',
        query: '',
        page: pageNumber,
        hitsPerPage: safeLimit,
        filters: filters,
        attributes: _searchAttributes,
      );
      final legacyHits = _list(legacyPayload['hits']);
      if (legacyHits.isNotEmpty) {
        final pagination = pageFromAlgolia(legacyPayload);
        return ProviderMediaPage(
          items: await _dedupeHits(legacyHits),
          nextOffset: pagination.nextOffset,
          hasMore: pagination.hasMore,
        );
      }
    }

    final fallbackPayload = await _algoliaQuery(
      'series',
      query: '',
      page: pageNumber,
      hitsPerPage: safeLimit,
      filters: filters,
      attributes: _searchAttributes,
    );
    final fallbackHits = _list(fallbackPayload['hits'])
        .map<Map<String, dynamic>>(_map)
        .where((hit) => hit.isNotEmpty)
        .toList(growable: false)
      ..sort((a, b) {
        int rank(Map<String, dynamic> hit) {
          final details = _map(hit['details']);
          final value = int.tryParse(_text(details['mal_rank'])) ?? (1 << 30);
          return value > 0 ? value : (1 << 30);
        }
        return rank(a).compareTo(rank(b));
      });
    final pagination = pageFromAlgolia(fallbackPayload);
    return ProviderMediaPage(
      items: await _dedupeHits(fallbackHits),
      nextOffset: pagination.nextOffset,
      hasMore: pagination.hasMore,
    );
  }

  Future<ProviderNewsPage> _loadNewsPage({
    int offset = 0,
    int limit = 20,
  }) async {
    await _refreshRemoteConstants();
    final sections = await _fetchOfficialHomeSections();
    final official = _officialNewsSection(sections);
    final index = official?.indexName.trim().isNotEmpty == true
        ? official!.indexName.trim()
        : 'news';
    final safeOffset = offset < 0 ? 0 : offset;
    final safeLimit = limit.clamp(1, 50).toInt();
    final pageNumber = safeOffset ~/ safeLimit;

    final payload = await _algoliaQuery(
      index,
      query: '',
      page: pageNumber,
      hitsPerPage: safeLimit,
      attributes: _newsAttributes,
    );
    final rawHits = _list(payload['hits']);

    final items = _dedupeNews(rawHits);
    final nbPages = int.tryParse(_text(payload['nbPages'])) ?? 0;
    final hasMore = nbPages > 0
        ? pageNumber + 1 < nbPages
        : rawHits.length >= safeLimit;
    return ProviderNewsPage(
      items: items,
      nextOffset: (pageNumber + 1) * safeLimit,
      hasMore: hasMore,
    );
  }

  @override
  Future<ProviderNewsPage> getHomeNewsPage({
    int offset = 0,
    int limit = 10,
  }) {
    return _loadNewsPage(offset: offset, limit: limit);
  }

  @override
  Future<ProviderNewsPage> getNewsPage({
    int offset = 0,
    int limit = 20,
  }) {
    return _loadNewsPage(offset: offset, limit: limit);
  }

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    final configured = await _fetchOfficialHomeSections();
    if (configured.isEmpty) {
      throw StateError('AnimeWitcher home sections are unavailable.');
    }
    final officialSections = configured
        .where((section) =>
            !_isNewsHomeSection(section) &&
            section.type != 'continue_watching')
        .toList(growable: false);
    if (officialSections.isEmpty) {
      return const <String, List<MultimediaItem>>{};
    }
    var failedSections = 0;
    Object? firstError;
    StackTrace? firstStackTrace;
    final pages = await BoundedBatchScheduler.mapOrdered<
      _OfficialHomeSection,
      ProviderMediaPage
    >(
      officialSections,
      maxConcurrent: _homeSectionConcurrency,
      mapper: (section) => _loadHomePage(
        section.title,
        limit: section.hitsPerPage.clamp(1, _previewSize).toInt(),
        throwOnFailure: true,
      ),
      onError: (section, error, stackTrace) {
        failedSections++;
        firstError ??= error;
        firstStackTrace ??= stackTrace;
        if (kDebugMode) {
          debugPrint(
            '[AnimeWitcher] Home section "${section.title}" failed: $error',
          );
        }
        return const ProviderMediaPage(
          items: <MultimediaItem>[],
          nextOffset: 0,
          hasMore: false,
        );
      },
    );
    BoundedBatchScheduler.throwIfBatchFailed(
      itemCount: officialSections.length,
      failureCount: failedSections,
      error: firstError,
      stackTrace: firstStackTrace,
    );
    final output = <String, List<MultimediaItem>>{};
    for (var i = 0; i < officialSections.length; i++) {
      final section = officialSections[i];
      // AnimeWitcher already treats "Trending" as the full-width hero carousel.
      // AnimeWitcher's backend marks the equivalent row as type=carousel.
      // Keep empty keys so a failed carousel does not promote another row into
      // the hero slot (home would then show that row twice).
      final key = section.type == 'carousel' ? 'Trending' : section.title;
      output[key] = pages[i].items;
    }
    return output;
  }

  @override
  Future<List<MultimediaItem>> getHomeSection(String sectionName) async {
    return (await _loadHomePage(sectionName, limit: viewAllPageSize)).items;
  }

  @override
  Future<ProviderMediaPage> getHomeSectionPage(
    String sectionName, {
    int offset = 0,
    int limit = 30,
  }) {
    return _loadHomePage(
      sectionName,
      offset: offset,
      limit: limit,
    );
  }

  Map<String, dynamic> _mergeMaps(
    Map<String, dynamic> base,
    Map<String, dynamic> overlay,
  ) {
    final result = <String, dynamic>{...base};
    for (final entry in overlay.entries) {
      final value = entry.value;
      if (value == null || _text(value).isEmpty && value is! Map && value is! List) continue;
      if (entry.key == 'details' && value is Map) {
        result['details'] = <String, dynamic>{
          ..._map(result['details']),
          ..._map(value),
        };
      } else {
        result[entry.key] = value;
      }
    }
    return result;
  }

  Future<Map<String, dynamic>> _fetchAnimeDocument(String animeId) async {
    final key = animeId.trim();
    if (key.isEmpty) return <String, dynamic>{};
    final cached = _animeDocumentCache[key];
    if (cached != null &&
        _animeDocumentExpiresAt[key]?.isAfter(DateTime.now()) == true) {
      return cached;
    }
    _animeDocumentCache.remove(key);
    _animeDocumentExpiresAt.remove(key);
    final inFlight = _animeDocumentRequests[key];
    if (inFlight != null) return inFlight;

    final request = () async {
      final result = await _getJsonResult(_firestoreUrl('anime_list/$key'));
      if (!result.reachedServer) {
        throw StateError('AnimeWitcher details request failed.');
      }
      final value = _firestoreFields(result.json['fields']);
      if (value.isEmpty) {
        throw StateError('AnimeWitcher anime was not found.');
      }
      _animeDocumentCache[key] = value;
      _animeDocumentExpiresAt[key] = DateTime.now().add(_detailDataTtl);
      return value;
    }();
    _animeDocumentRequests[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_animeDocumentRequests[key], request)) {
        _animeDocumentRequests.remove(key);
      }
    }
  }


  Future<Map<String, dynamic>> _detailSource(String url) async {
    final route = _parseAnimeUrl(url);
    if (route.animeId.isEmpty) {
      throw StateError('AnimeWitcher anime id is missing');
    }
    final key = route.animeId.trim();
    final cached = _detailSourceCache[key];
    if (cached != null &&
        _detailSourceExpiresAt[key]?.isAfter(DateTime.now()) == true) {
      return cached;
    }
    _detailSourceCache.remove(key);
    _detailSourceExpiresAt.remove(key);
    final inFlight = _detailSourceRequests[key];
    if (inFlight != null) return inFlight;

    final request = () async {
      final document = await _fetchAnimeDocument(key);
      final source = _mergeMaps(route.hit, document);
      if (source.isEmpty) {
        throw StateError('AnimeWitcher anime was not found');
      }
      _detailSourceCache[key] = source;
      _detailSourceExpiresAt[key] = DateTime.now().add(_detailDataTtl);
      return source;
    }();
    _detailSourceRequests[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_detailSourceRequests[key], request)) {
        _detailSourceRequests.remove(key);
      }
    }
  }


  @override
  void invalidateDetailCaches(String url) {
    final key = _parseAnimeUrl(url).animeId.trim();
    if (key.isEmpty) return;
    _detailSourceCache.remove(key);
    _detailSourceExpiresAt.remove(key);
    _detailSourceRequests.remove(key);
    _animeDocumentCache.remove(key);
    _animeDocumentExpiresAt.remove(key);
    _animeDocumentRequests.remove(key);
    _episodeRecordCache.remove(key);
    _episodeRecordExpiresAt.remove(key);
    _episodeRecordRequests.remove(key);
  }

  @override
  void prepareForNetworkRetry() {
    _remoteConstantsExpiresAt = DateTime.fromMillisecondsSinceEpoch(0);
    _remoteConstantsRequest = null;
    _officialHomeSectionsRequest = null;
    resetStaleHttpClient(_dio);
  }

  double? _scoreFromHit(Map<String, dynamic> source) {
    final details = _map(source['details']);
    final rating = _map(source['rating']);
    for (final raw in <dynamic>[details['mal_mean'], details['mal_score'], rating['rate'], source['score']]) {
      final value = raw is num ? raw.toDouble() : double.tryParse(_text(raw));
      if (value != null && value > 0) return value;
    }
    return null;
  }

  int? _durationFromHit(Map<String, dynamic> source) {
    final details = _map(source['details']);
    for (final raw in <dynamic>[details['duration'], source['duration']]) {
      if (raw is num && raw.toInt() > 0) return raw.toInt();
      final match = RegExp(r'\d+').firstMatch(_normalizeDigits(_text(raw)));
      final value = match == null ? 0 : int.tryParse(match.group(0)!) ?? 0;
      if (value > 0) return value;
    }
    return null;
  }


  @override
  Future<MultimediaItem> getDetails(String url) async {
    final route = _parseAnimeUrl(url);
    final source = await _detailSource(url);
    final details = _map(source['details']);
    final title = _text(source['name'] ?? source['english_title'] ?? route.animeId);
    final description = _decodeHtml(
      source['story'] ?? source['description'] ?? details['story'] ?? details['description'],
    );
    final malId = _malId(source);
    final poster = _posterFromHit(source);
    final providerCover = _coverFromHit(source);
    final banner = providerCover.isNotEmpty ? providerCover : poster;
    final syncData = <String, String>{};
    void putSync(String key, dynamic raw) {
      final value = _text(raw);
      if (value.isNotEmpty) syncData[key] = value;
    }
    if (malId > 0) {
      syncData['malId'] = '$malId';
      syncData['mal_id'] = '$malId';
    }
    final rating = _map(source['rating']);
    final statistics = _map(source['statictes']).isNotEmpty
        ? _map(source['statictes'])
        : _map(source['statistics']);
    final studios = _list(details['studio']).isNotEmpty
        ? _list(details['studio'])
        : _list(details['studios']).isNotEmpty
            ? _list(details['studios'])
            : _text(details['studio']).isNotEmpty
                ? <dynamic>[details['studio']]
                : const <dynamic>[];
    putSync('awEnglishTitle', details['english_title'] ?? source['english_title']);
    putSync(
      'awStudio',
      studios.map((value) => _text(value)).where((value) => value.isNotEmpty).join(', '),
    );
    putSync('awSource', details['source'] ?? source['source']);
    putSync('awSeason', details['season']);
    putSync('awSeasonName', details['season_name'] ?? details['seasonName']);
    putSync('awYear', details['year'] ?? _yearFromHit(source));
    putSync('awStartDate', details['start_date'] ?? details['startDate']);
    putSync('awEndDate', details['end_date'] ?? details['endDate']);
    putSync(
      'awState',
      details['state'] ?? details['status'] ?? source['state'] ?? source['status'],
    );
    putSync(
      'awShowTime',
      source['show_time'] ??
          source['showTime'] ??
          details['show_time'] ??
          details['showTime'],
    );
    putSync('awEpisodes', details['eps_num'] ?? details['episodes']);
    putSync('awDuration', source['duration'] ?? details['duration']);
    final age = _text(
      details['age'] ?? details['age_rating'] ?? details['content_rating'],
    );
    putSync('awAge', age);
    putSync('awMalScore', details['mal_mean'] ?? details['mal_score']);
    putSync('awMalRank', details['mal_rank']);
    putSync(
      'awMalScoringUsers',
      details['mal_num_scoring_users'] ?? details['mal_scoring_users'],
    );
    putSync('awScore', rating['rate']);
    putSync(
      'awRatingsCount',
      rating['totalRatingsCount'] ?? rating['total_ratings_count'],
    );
    putSync('awViews', source['views']);
    putSync('awFavorites', statistics['fav_count'] ?? statistics['favorite_count']);
    putSync('awType', source['type']);
    return MultimediaItem(
      title: title.isEmpty ? route.animeId : title,
      url: url,
      posterUrl: poster,
      fullPosterUrl: _highestQualityPosterFromHit(source),
      bannerUrl: banner.isEmpty ? null : banner,
      description: description.isEmpty ? null : description,
      contentType:
          _isMovieType(source['type']) ? MultimediaContentType.movie : MultimediaContentType.anime,
      provider: packageName,
      year: _yearFromHit(source),
      score: _scoreFromHit(source),
      duration: _durationFromHit(source),
      status: _statusFromHit(source),
      tags: _stringList(source['tags']),
      contentRating: age.isEmpty ? null : age,
      syncData: syncData.isEmpty ? null : syncData,
      source: 'AnimeWitcher',
      catalogType: _catalogTypeFromHit(source),
      isDubbed: _isDubbedHit(source),
    );
  }

  int _positiveInt(dynamic raw) {
    final match = RegExp(r'\d+').firstMatch(_normalizeDigits(_text(raw)));
    final value = match == null ? 0 : int.tryParse(match.group(0)!) ?? 0;
    return value > 0 ? value : 0;
  }

  String _characterRole(dynamic raw) {
    switch (_text(raw).toUpperCase()) {
      case 'MAIN':
        return 'شخصية رئيسية';
      case 'SUPPORTING':
        return 'شخصية مساندة';
      case 'BACKGROUND':
        return 'شخصية ثانوية';
      default:
        return 'شخصية';
    }
  }

  Future<List<_AnimeWitcherCharacterRef>>
      _animeWitcherCharacterRefsForRole(
    String animeId,
    String role, {
    int limit = animeWitcherAnimeCastStripLimit,
  }) async {

    final raw = await _firestoreRestRunQuery(
      <String, dynamic>{
        'from': const <Map<String, dynamic>>[
          <String, dynamic>{'collectionId': 'characters'},
        ],
        'where': <String, dynamic>{
          'fieldFilter': <String, dynamic>{
            'field': const <String, dynamic>{'fieldPath': 'role'},
            'op': 'EQUAL',
            'value': <String, dynamic>{'stringValue': role},
          },
        },
        'limit': limit,
      },
      parent: 'anime_list/$animeId',
    );
    final output = <_AnimeWitcherCharacterRef>[];
    for (final rowRaw in raw) {
      final document = _map(_map(rowRaw)['document']);
      var characterId = _text(document['name']);
      if (characterId.isNotEmpty) characterId = characterId.split('/').last;
      if (characterId.isEmpty) continue;
      output.add(_AnimeWitcherCharacterRef(characterId, role));
    }
    return output;
  }

  Future<List<_AnimeWitcherCharacterRef>> _animeWitcherCharacterRefs(
    String animeId, {
    int limit = animeWitcherAnimeCastStripLimit,
  }) async {
    final cleanId = animeId.trim();
    if (cleanId.isEmpty) return const <_AnimeWitcherCharacterRef>[];
    final groups = await Future.wait(<Future<List<_AnimeWitcherCharacterRef>>>[
      _animeWitcherCharacterRefsForRole(cleanId, 'Main', limit: limit),
      _animeWitcherCharacterRefsForRole(cleanId, 'Supporting', limit: limit),
    ]);
    return <_AnimeWitcherCharacterRef>[...groups[0], ...groups[1]];
  }

  Future<_AnimeWitcherCharacter?> _animeWitcherCharacter(
    _AnimeWitcherCharacterRef reference,
  ) async {
    final fields = await _firestoreDocumentFields(
      'characters_list/${reference.id}',
    );
    if (fields.isEmpty) return null;
    final data = _map(fields['data']);
    final name = _text(data['name'] ?? fields['name']);
    if (name.isEmpty) return null;

    final images = _map(data['images'] ?? fields['images']);
    final jpg = _map(images['jpg']);
    final webp = _map(images['webp']);
    var image = _text(
      jpg['image_url'] ??
          jpg['large_image_url'] ??
          webp['image_url'] ??
          webp['large_image_url'] ??
          fields['image'],
    );
    if (image ==
        'https://cdn.myanimelist.net/img/sp/icon/apple-touch-icon-256.png') {
      image = '';
    }

    return _AnimeWitcherCharacter(
      actor: Actor(
        id: reference.id,
        name: name,
        image: image.isEmpty ? null : image,
        role: _characterRole(reference.role),
      ),
      role: reference.role,
      likes: _positiveInt(fields['likes']),
    );
  }

  Future<List<Actor>> _animeWitcherServerCast(
    String animeId, {
    int limit = animeWitcherAnimeCastStripLimit,
  }) async {
    final references = await _animeWitcherCharacterRefs(
      animeId,
      limit: limit,
    );
    if (references.isEmpty) return const <Actor>[];

    final characters = await Future.wait(
      references.map(_animeWitcherCharacter),
    );
    final main = characters
        .whereType<_AnimeWitcherCharacter>()
        .where((item) => item.role == 'Main')
        .toList()
      ..sort((a, b) => b.likes.compareTo(a.likes));
    final supporting = characters
        .whereType<_AnimeWitcherCharacter>()
        .where((item) => item.role == 'Supporting')
        .toList()
      ..sort((a, b) => b.likes.compareTo(a.likes));
    final output = <Actor>[
      ...main.map((item) => item.actor),
      ...supporting.map((item) => item.actor),
    ];
    return output;
  }

  Future<List<Actor>> getAnimeCharacters(
    String animeId, {
    int limit = 50,
  }) async {
    return _animeWitcherServerCast(animeId, limit: limit);
  }

  @override
  Future<List<Actor>> getCast(String url) async {
    final route = _parseAnimeUrl(url);
    return _animeWitcherServerCast(route.animeId);
  }

  String _youtubeId(dynamic raw) {
    final source = raw is Map ? _map(raw) : <String, dynamic>{};
    final value = _text(source.isEmpty
        ? raw
        : source['id'] ?? source['youtube_video_id'] ?? source['youtubeVideoId'] ?? source['url']);
    if (value.isEmpty) return '';
    for (final pattern in <RegExp>[
      RegExp(r'youtube\.com/watch\?v=([A-Za-z0-9_-]{6,})', caseSensitive: false),
      RegExp(r'youtube\.com/embed/([A-Za-z0-9_-]{6,})', caseSensitive: false),
      RegExp(r'youtu\.be/([A-Za-z0-9_-]{6,})', caseSensitive: false),
      RegExp(r'youtube\.com/shorts/([A-Za-z0-9_-]{6,})', caseSensitive: false),
    ]) {
      final match = pattern.firstMatch(value);
      if (match != null) return match.group(1) ?? '';
    }
    return RegExp(r'^[A-Za-z0-9_-]{6,}$').hasMatch(value) ? value : '';
  }

  @override
  Future<List<Trailer>> getTrailers(String url) async {
    final route = _parseAnimeUrl(url);
    if (route.animeId.isEmpty) return const <Trailer>[];
    final fields = await _firestoreDocumentFields(
      'anime_list/${route.animeId}/details/anime_trailer',
    );
    if (fields.isEmpty) return const <Trailer>[];
    final id = _youtubeId(fields['youtube_video_id'] ?? fields['youtubeVideoId']);
    if (id.isEmpty) return const <Trailer>[];
    return <Trailer>[Trailer(url: 'https://www.youtube.com/watch?v=$id')];
  }

  Future<void> _loadMalIdBatch(List<int> ids) async {
    final requestedIds = ids.where((id) => id > 0).toSet();
    final resolver = _resolveAnimeByMalIds;
    if (requestedIds.isEmpty || resolver == null) return;

    // This is one public Firestore IN request for all ten related MAL IDs,
    // matching AnimeWitcher's RelatedAnimeFragment. Do not replace it
    // with an Algolia browse loop: mal_id is neither searchable nor facetable
    // in AnimeWitcher's index, so browsing turns one lookup into many pages.
    final hits = await resolver(requestedIds);

    final expiresAt = DateTime.now().add(_relatedDataTtl);
    for (final hit in hits) {
      final id = _malId(hit);
      if (id <= 0 || !requestedIds.contains(id)) continue;
      _animeByMalIdCache[id] = hit;
      _animeByMalIdExpiresAt[id] = expiresAt;
    }
  }

  Map<String, dynamic>? _cachedAnimeByMalId(int id) {
    final cached = _animeByMalIdCache[id];
    if (cached != null &&
        _animeByMalIdExpiresAt[id]?.isAfter(DateTime.now()) == true) {
      return cached;
    }
    _animeByMalIdCache.remove(id);
    _animeByMalIdExpiresAt.remove(id);
    return null;
  }

  Future<Map<int, Map<String, dynamic>>> _resolveMalIds(Iterable<int> rawIds) async {
    final ids = rawIds.where((id) => id > 0).toSet().toList(growable: false);
    if (ids.isEmpty) return <int, Map<String, dynamic>>{};

    final waits = <Future<void>>{};
    final missing = <int>[];
    for (final id in ids) {
      if (_cachedAnimeByMalId(id) != null) continue;
      final inFlight = _malIdResolutionRequests[id];
      if (inFlight != null) {
        waits.add(inFlight);
      } else {
        missing.add(id);
      }
    }
    final created = <MapEntry<List<int>, Future<void>>>[];
    for (var start = 0; start < missing.length; start += 10) {
      final end = (start + 10).clamp(0, missing.length).toInt();
      final batch = missing.sublist(start, end);
      final request = _loadMalIdBatch(batch);
      for (final id in batch) {
        _malIdResolutionRequests[id] = request;
      }
      waits.add(request);
      created.add(MapEntry<List<int>, Future<void>>(batch, request));
    }
    try {
      if (waits.isNotEmpty) await Future.wait(waits);
    } finally {
      for (final entry in created) {
        for (final id in entry.key) {
          if (identical(_malIdResolutionRequests[id], entry.value)) {
            _malIdResolutionRequests.remove(id);
          }
        }
      }
    }
    final output = <int, Map<String, dynamic>>{};
    for (final id in ids) {
      final cached = _cachedAnimeByMalId(id);
      if (cached != null) output[id] = cached;
    }
    return output;
  }

  String _relationType(dynamic raw) {
    final value = _text(raw).replaceAll(RegExp(r'[\s-]+'), '_').toUpperCase();
    return value.isEmpty ? 'OTHER' : value;
  }

  String _relationLabel(String type) {
    const labels = <String, String>{
      'PREQUEL': 'السابق',
      'SEQUEL': 'التالي',
      'PARENT': 'القصة الرئيسية',
      'PARENT_STORY': 'القصة الرئيسية',
      'FULL_STORY': 'القصة الرئيسية',
      'SIDE_STORY': 'قصة جانبية',
      'SPIN_OFF': 'عمل مشتق',
      'ALTERNATIVE': 'نسخة بديلة',
      'ALTERNATIVE_VERSION': 'نسخة بديلة',
      'SUMMARY': 'ملخص',
      'COMPILATION': 'تجميعة',
      'ADAPTATION': 'اقتباس',
      'CHARACTER': 'عمل مرتبط بالشخصيات',
      'SOURCE': 'المصدر',
      'OTHER': 'أخرى',
    };
    return labels[type] ?? 'عمل مرتبط';
  }

  int _relationPriority(String type) {
    const priorities = <String, int>{
      'PREQUEL': 0,
      'SEQUEL': 1,
      'PARENT': 2,
      'PARENT_STORY': 2,
      'FULL_STORY': 2,
      'SIDE_STORY': 3,
      'SPIN_OFF': 4,
      'ALTERNATIVE': 5,
      'ALTERNATIVE_VERSION': 5,
      'SUMMARY': 6,
      'COMPILATION': 7,
      'OTHER': 8,
      'CHARACTER': 9,
      'SOURCE': 10,
      'ADAPTATION': 10,
    };
    return priorities[type] ?? 8;
  }

  List<_RelatedCandidate> _officialRelations(Map<String, dynamic> source) {
    final details = _map(source['details']);
    dynamic raw = source['related_anime_ids'] ??
        source['relatedAnimeIds'] ??
        source['related_anime'] ??
        source['relatedAnime'] ??
        details['related_anime_ids'] ??
        details['relatedAnimeIds'] ??
        details['related_anime'];
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        raw = raw.split(RegExp(r'[\s,|]+')).where((value) => value.isNotEmpty).toList();
      }
    }
    final current = _malId(source);
    final output = <_RelatedCandidate>[];
    final seen = <int>{};
    for (final entry in _list(raw)) {
      final item = entry is Map ? _map(entry) : <String, dynamic>{'mal_id': entry};
      final id = _positiveInt(
        item['mal_id'] ?? item['malId'] ?? item['idMal'] ?? item['malID'],
      );
      if (id <= 0 || id == current || !seen.add(id)) continue;
      final type = _relationType(
        item['relation_type'] ?? item['relationType'] ?? item['type'] ?? item['relation'],
      );
      output.add(_RelatedCandidate(id, type, _relationLabel(type)));
    }
    output.sort((a, b) => _relationPriority(a.type).compareTo(_relationPriority(b.type)));
    return output.take(_maxRelatedItems).toList(growable: false);
  }

  MultimediaItem _relatedItem(
    Map<String, dynamic> hit, {
    String? relationType,
    String? relationLabel,
  }) {
    final item = _mapHit(hit);
    return MultimediaItem(
      title: item.title,
      url: item.url,
      posterUrl: item.posterUrl,
      fullPosterUrl: item.fullPosterUrl,
      bannerUrl: item.bannerUrl,
      description: item.description,
      contentType: item.contentType,
      provider: packageName,
      year: item.year,
      status: item.status,
      tags: item.tags,
      relationType: relationType,
      relationLabel: relationLabel,
      source: 'AnimeWitcher',
      catalogType: item.catalogType,
      isDubbed: item.isDubbed,
    );
  }

  @override
  Future<List<MultimediaItem>> getRelated(String url) async {
    final source = await _detailSource(url);
    final relations = _officialRelations(source);
    if (relations.isEmpty) return const <MultimediaItem>[];
    final resolved = await _resolveMalIds(relations.map((item) => item.malId));
    final output = <MultimediaItem>[];
    for (final relation in relations) {
      final hit = resolved[relation.malId];
      if (hit == null) continue;
      output.add(_relatedItem(
        hit,
        relationType: relation.type,
        relationLabel: relation.label,
      ));
    }
    return _filterEcchiItems(output);
  }

  Future<List<MultimediaItem>> _animeWitcherRecommendations(
    String animeId,
    Map<String, dynamic> source,
  ) async {
    final currentAnimeId = animeId.trim().isNotEmpty
        ? animeId.trim().toLowerCase()
        : _animeIdFromHit(source).trim().toLowerCase();
    final tags = _stringList(source['tags']);
    if (tags.isEmpty) return const <MultimediaItem>[];
    final hideEcchi = _isEcchiHidden();
    final payload = await _algoliaQuery(
      'series_similar',
      query: tags.join(' '),
      page: 0,
      hitsPerPage: hideEcchi ? 30 : 11,
      attributes: _similarAttributes,
    );
    final hits = <Map<String, dynamic>>[];
    final seenIds = <String>{};
    for (final raw in _list(payload['hits'])) {
      final hit = _map(raw);
      if (hit.isEmpty) continue;
      final hitAnimeId = _animeIdFromHit(hit).trim().toLowerCase();
      if (hitAnimeId.isEmpty ||
          hitAnimeId == currentAnimeId ||
          !seenIds.add(hitAnimeId)) {
        continue;
      }
      if (hideEcchi && _containsEcchiTag(_stringList(hit['tags']))) {
        continue;
      }
      hits.add(hit);
    }

    final output = <MultimediaItem>[];
    final seenUrls = <String>{};
    for (final hit in hits) {
      final item = _relatedItem(hit);
      if (!seenUrls.add(item.url)) continue;
      output.add(item);
      if (output.length >= _maxRecommendations) break;
    }
    return _filterEcchiItems(output);
  }

  @override
  Future<List<MultimediaItem>> getRecommendations(String url) async {
    final route = _parseAnimeUrl(url);
    final source = await _detailSource(url);
    return _animeWitcherRecommendations(route.animeId, source);
  }

  int _normalizeUnixSeconds(dynamic raw) {
    if (raw == null || _text(raw).isEmpty) return 0;
    double? value = raw is num ? raw.toDouble() : double.tryParse(_text(raw));
    if (value == null) {
      final date = DateTime.tryParse(_text(raw));
      if (date != null) value = date.millisecondsSinceEpoch / 1000;
    }
    if (value == null || value <= 0) return 0;
    if (value > 100000000000) value /= 1000;
    return value.floor();
  }

  int _nextEpisodeTimestamp(Map<String, dynamic> source) {
    return _normalizeUnixSeconds(
      source['nextEpTimeInSec'] ??
          source['next_ep_time_in_sec'] ??
          source['nextEpisodeTime'] ??
          source['next_episode_time'] ??
          source['nextAiringAt'] ??
          source['airingAt'],
    );
  }

  @override
  Future<NextAiring?> getNextAiring(String url) async {
    final source = await awaitWithTimeout(_detailSource(url));
    if (source == null || source.isEmpty) return null;
    if (_statusFromHit(source) == ShowStatus.completed) return null;
    final unixTime = _nextEpisodeTimestamp(source);
    if (unixTime <= 0) return null;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (unixTime < now - 5 * 60) return null;

    // The countdown does not depend on loading the episode list. Keep an
    // optional episode hint only when AnimeWitcher already exposes one in the
    // detail payload; the UI only needs the airing timestamp.
    var latest = 0;
    for (final raw in <dynamic>[
      source['episode_id'],
      source['episode'],
      source['latest_episode'],
      source['last_episode'],
    ]) {
      final value = _positiveInt(raw);
      if (value > latest) latest = value;
    }
    return NextAiring(episode: latest > 0 ? latest + 1 : 0, unixTime: unixTime);
  }

  String _normalizeDigits(String value) {
    const arabic = '٠١٢٣٤٥٦٧٨٩';
    const eastern = '۰۱۲۳۴۵۶۷۸۹';
    return value
        .replaceAllMapped(RegExp(r'[٠-٩]'), (m) => '${arabic.indexOf(m.group(0)!)}')
        .replaceAllMapped(RegExp(r'[۰-۹]'), (m) => '${eastern.indexOf(m.group(0)!)}');
  }

  String _localizedEpisodeTitle(dynamic raw) {
    if (raw is String) return _decodeHtml(raw);
    final source = _map(raw);
    for (final key in const <String>[
      'ar', 'ar-SA', 'ar_SA', 'arabic', 'translated', 'value', 'title', 'name',
    ]) {
      final value = _decodeHtml(source[key]);
      if (value.isNotEmpty) return value;
    }
    for (final value in source.values) {
      final text = _decodeHtml(value);
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  bool _isGenericEpisodeTitle(String value) => isGenericEpisodeTitle(value);

  bool _hasFinalEpisodeSuffix(String value) => hasFinalEpisodeSuffix(value);

  String _episodeTitle(Map<String, dynamic> source) {
    for (final key in const <String>[
      'title_translated',
      'titleTranslated',
      'title_ar',
      'titleAr',
      'arabic_title',
      'arabicTitle',
      'title_en',
      'titleEn',
      'title_english',
      'titleEnglish',
      'english_title',
      'englishTitle',
      'episode_title',
      'episodeTitle',
      'title',
    ]) {
      final title = _localizedEpisodeTitle(source[key]);
      if (title.isNotEmpty && !_isGenericEpisodeTitle(title)) return title;
    }
    // Never fall back to the AnimeWitcher `name` field here. That value is the
    // primary list label (الحلقة X / مترجم / مدبلج) and is stored on
    // Episode.serverName so AniZip artwork enrichment cannot rewrite it.
    return '';
  }

  int _episodeNumberFromId(String id) {
    final normalized = _normalizeDigits(id.trim());
    if (normalized.isEmpty) return 0;
    final explicit = RegExp(
      r'(?:episode|ep|الحلقة|حلقه|حلقة)[^0-9]*(\d+)$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (explicit != null) return int.tryParse(explicit.group(1)!) ?? 0;
    final numeric = RegExp(r'^\d+$').firstMatch(normalized);
    return numeric == null ? 0 : int.tryParse(numeric.group(0)!) ?? 0;
  }

  DubStatus _episodeDubStatus(String serverName) {
    final label = serverName.trim();
    if (label == 'مدبلج' || label == 'مدبلجة') return DubStatus.dubbed;
    if (label == 'مترجم' || label == 'مترجمة') return DubStatus.subbed;
    return DubStatus.none;
  }

  _EpisodeRecord _episodeRecord(
    Map<String, dynamic> source, {
    required String fallbackId,
    required int fallbackNumber,
  }) {
    var id = _text(source['doc_id'] ?? source['id'] ?? source['episode_id']);
    if (id.isEmpty) id = fallbackId;
    final serverName = _decodeHtml(
      source['name'] ?? source['episode_name'] ?? source['episodeName'],
    );
    final serverNumber = _serverEpisodeNumber(source);
    // AnimeWitcher's numeric field is authoritative, including an explicit 0
    // for movie/variant entries such as translated and dubbed versions. Never
    // replace an explicit server value with a list index, document id, or a
    // number parsed from the title. If the numeric field is genuinely absent,
    // the document id is the same server-side episode identity used by the
    // original AnimeWitcher implementation; use it only as a last resort.
    final number = serverNumber ?? _episodeNumberFromId(id);
    final image = _text(
      source['thumb_uri'] ?? source['image'] ?? source['image_url'] ?? source['poster'],
    );
    final isFiller = _isTruthy(
      source['filler'] ?? source['is_filler'] ?? source['isFiller'],
    );
    return _EpisodeRecord(
      id: id,
      number: number,
      sortOrder: (() {
        final sourceOrder = _episodeSortOrder(source);
        return sourceOrder > 0 ? sourceOrder : fallbackNumber;
      })(),
      title: _episodeTitle(source),
      serverName: serverName,
      image: image,
      isFiller: isFiller,
      isFinal: _hasFinalEpisodeSuffix(serverName),
      dubStatus: _episodeDubStatus(serverName),
    );
  }

  int? _serverEpisodeNumber(Map<String, dynamic> source) {
    for (final key in const <String>[
      'episode_number',
      'episodeNumber',
      'episode',
      'ep',
      'number',
    ]) {
      if (!source.containsKey(key)) continue;
      final raw = source[key];
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      final text = _normalizeDigits(_text(raw).trim());
      if (RegExp(r'^-?\d+$').hasMatch(text)) return int.tryParse(text);
    }
    return null;
  }

  int _episodeSortOrder(Map<String, dynamic> source) {
    for (final key in const <String>[
      'sortOrder',
      'sort_order',
      'sort',
    ]) {
      final value = _positiveInt(source[key]);
      if (value > 0) return value;
    }
    return 0;
  }

  Future<List<_EpisodeRecord>> _fetchEpisodeSummary(String animeId) async {
    final path = 'anime_list/$animeId/episodes_summery/summery';
    final result = await _getJsonResult(_firestoreUrl(path));
    if (!result.reachedServer) {
      throw StateError('AnimeWitcher episode summary request failed.');
    }
    final fields = _firestoreFields(result.json['fields']);
    if (fields.isEmpty) return const <_EpisodeRecord>[];
    final rawEpisodes = _list(fields['episodes']);
    if (rawEpisodes.isEmpty) return const <_EpisodeRecord>[];
    final output = <_EpisodeRecord>[];
    for (var i = 0; i < rawEpisodes.length; i++) {
      final source = _map(rawEpisodes[i]);
      output.add(
        _episodeRecord(
          source,
          fallbackId: '${i + 1}'.padLeft(3, '0'),
          fallbackNumber: i + 1,
        ),
      );
    }
    return output;
  }

  Future<({List<_EpisodeRecord> records, bool reachedServer})>
      _fetchEpisodeCollection(String animeId) async {
    final output = <_EpisodeRecord>[];
    String nextToken = '';
    final seenTokens = <String>{};
    var reachedServer = false;
    for (var page = 0; page < 20; page++) {
      var url = '${_firestoreUrl('anime_list/$animeId/episodes')}?pageSize=1000';
      if (nextToken.isNotEmpty) {
        url += '&pageToken=${Uri.encodeQueryComponent(nextToken)}';
      }
      final result = await _getJsonResult(url);
      if (!result.reachedServer) break;
      reachedServer = true;
      final documents = _list(result.json['documents']);
      for (final rawDocument in documents) {
        final document = _map(rawDocument);
        final fields = _firestoreFields(document['fields']);
        var id = _text(fields['doc_id']);
        if (id.isEmpty) {
          final name = _text(document['name']);
          if (name.isNotEmpty) id = name.split('/').last;
        }
        output.add(
          _episodeRecord(
            fields,
            fallbackId: id.isEmpty
                ? '${output.length + 1}'.padLeft(3, '0')
                : id,
            fallbackNumber: output.length + 1,
          ),
        );
      }
      final token = _text(result.json['nextPageToken']);
      if (token.isEmpty || !seenTokens.add(token)) break;
      nextToken = token;
    }
    return (records: output, reachedServer: reachedServer);
  }

  Future<List<_EpisodeRecord>> _episodeRecords(String animeId) async {
    final key = animeId.trim();
    if (key.isEmpty) return const <_EpisodeRecord>[];
    final cached = _episodeRecordCache[key];
    if (cached != null &&
        _episodeRecordExpiresAt[key]?.isAfter(DateTime.now()) == true) {
      return cached;
    }
    _episodeRecordCache.remove(key);
    _episodeRecordExpiresAt.remove(key);
    final inFlight = _episodeRecordRequests[key];
    if (inFlight != null) return inFlight;

    final request = () async {
      // AnimeWitcher uses the canonical episode collection as the source of
      // truth. The summary document is only a compatibility fallback because
      // it can contain stale or locally reset number values.
      final collection = await _fetchEpisodeCollection(key);
      var records = collection.records;
      if (records.isEmpty) {
        try {
          records = await _fetchEpisodeSummary(key);
        } catch (_) {
          if (!collection.reachedServer) rethrow;
        }
      }
      // Keep one record per AnimeWitcher identity: anime id + episode number.
      // This prevents a malformed duplicate document from producing two cards
      // for the same episode while preserving the first source record.
      final unique = <String, _EpisodeRecord>{};
      for (final record in records) {
        // Identity is the AnimeWitcher document, not the number. This preserves
        // separate number=0 movie variants such as translated/dubbed entries.
        unique.putIfAbsent(record.id, () => record);
      }

      final normalized = unique.values.toList(growable: false)
        ..sort((a, b) {
          final aOrder = a.sortOrder > 0 ? a.sortOrder : (a.number > 0 ? a.number : 0);
          final bOrder = b.sortOrder > 0 ? b.sortOrder : (b.number > 0 ? b.number : 0);
          return aOrder.compareTo(bOrder);
        });
      final cachedRecords = List<_EpisodeRecord>.unmodifiable(normalized);
      _episodeRecordCache[key] = cachedRecords;
      _episodeRecordExpiresAt[key] = DateTime.now().add(_episodeDataTtl);
      return cachedRecords;
    }();
    _episodeRecordRequests[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_episodeRecordRequests[key], request)) {
        _episodeRecordRequests.remove(key);
      }
    }
  }

  @override
  Future<List<Episode>> getEpisodes(String url) async {
    final route = _parseAnimeUrl(url);
    if (route.animeId.isEmpty) throw StateError('AnimeWitcher anime id is missing');
    final records = await _episodeRecords(route.animeId);
    return records
        .map(
          (record) => Episode(
            name: record.title,
            url: '${safeEncodeUriComponent(route.animeId)}|${safeEncodeUriComponent(record.id)}',
            season: 1,
            episode: record.number,
            posterUrl: record.image.isEmpty ? null : record.image,
            isFiller: record.isFiller,
            isFinal: record.isFinal,
            serverName: record.serverName,
            dubStatus: record.dubStatus,
          ),
        )
        .toList(growable: false);
  }

  Map<String, dynamic> _aniZipEpisodeFor(
    Map<String, dynamic> payload,
    int number,
  ) {
    if (number <= 0) return <String, dynamic>{};
    final episodes = _map(payload['episodes']);
    final direct = _map(episodes['$number']);
    if (direct.isNotEmpty) return direct;
    for (final raw in episodes.values) {
      final item = _map(raw);
      final absolute = _positiveInt(
        item['absoluteEpisodeNumber'] ?? item['absolute_episode_number'],
      );
      if (absolute == number) return item;
    }
    return <String, dynamic>{};
  }

  List<Episode> _animeWitcherEpisodeMetadata(
    _AnimeRoute route,
    List<_EpisodeRecord> records,
  ) {
    return records
        .map(
          (record) => Episode(
            name: record.title,
            url:
                safeEncodeUriComponent(route.animeId) +
                '|' +
                safeEncodeUriComponent(record.id),
            season: 1,
            episode: record.number,
            posterUrl: record.image.isEmpty ? null : record.image,
            isFiller: record.isFiller,
            isFinal: record.isFinal,
            serverName: record.serverName,
            dubStatus: record.dubStatus,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<Episode>> getEpisodeMetadata(String url) async {
    try {
      final route = _parseAnimeUrl(url);
      if (route.animeId.isEmpty) return const <Episode>[];
      final source = await _detailSource(url);
      final resolvedRecords = await _episodeRecords(route.animeId);
      if (resolvedRecords.isEmpty) return const <Episode>[];

      if (!_useAniZipEpisodeImages) {
        return _animeWitcherEpisodeMetadata(route, resolvedRecords);
      }

      final malId = _malId(source);
      if (malId <= 0) {
        return _animeWitcherEpisodeMetadata(route, resolvedRecords);
      }

      final payload = await _getJson(
        _aniZipUrl + '?mal_id=' + Uri.encodeQueryComponent('$malId'),
        timeout: _aniZipTimeout,
      );
      if (payload == null || _map(payload['episodes']).isEmpty) {
        return _animeWitcherEpisodeMetadata(route, resolvedRecords);
      }
      final output = <Episode>[];
      for (final record in resolvedRecords) {
        final aniZip = _aniZipEpisodeFor(payload, record.number);
        final image = _text(
          aniZip['image'] ??
              aniZip['imageUrl'] ??
              aniZip['image_url'] ??
              aniZip['thumbnail'],
        );
        output.add(Episode(
          name: record.title,
          url:
              safeEncodeUriComponent(route.animeId) +
              '|' +
              safeEncodeUriComponent(record.id),
          season: 1,
          episode: record.number,
          posterUrl: _useAniZipEpisodeImages && image.isNotEmpty
              ? image
              : (record.image.isEmpty ? null : record.image),
          isFiller: record.isFiller,
          isFinal: record.isFinal,
          serverName: record.serverName,
          dubStatus: record.dubStatus,
        ));
      }
      return output;
    } catch (_) {
      return const <Episode>[];
    }
  }

  _EpisodeRoute _parseEpisodeUrl(String data) {
    final parts = data.split('|');
    if (parts.length < 2) return const _EpisodeRoute('', '');
    String animeId = parts.first;
    String episodeId = parts.sublist(1).join('|');
    try {
      animeId = safeDecodeUriComponent(animeId);
    } catch (_) {}
    try {
      episodeId = safeDecodeUriComponent(episodeId);
    } catch (_) {}
    return _EpisodeRoute(animeId.trim(), episodeId.trim());
  }

  _ServerRecord _serverRecord(dynamic raw) {
    final source = _map(raw);
    return _ServerRecord(
      name: _text(source['name']),
      link: _text(source['link']),
      quality: _text(source['quality']),
      originalLink: _text(source['original_link'] ?? source['originalLink']),
      openBrowser: source['open_browser'] == true || source['openBrowser'] == true,
      directLink: source['direct_link'] == true || source['directLink'] == true,
      visible: source['visible'] == null ? true : source['visible'] == true,
    );
  }

  String _serverFamily(dynamic raw) {
    final value = raw is _ServerRecord ? raw.name : _text(raw);
    final name = value.trim().toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    if (name == 'PD' || name == 'PIXELDRAIN' || name == 'PIXEL DRAIN') return 'PD';
    if (name == 'ST' || name == 'STREAMTAPE' || name == 'STREAM TAPE') return 'ST';
    if (name == 'MF' ||
        name == 'MF2' ||
        name == 'MD' ||
        name == 'MEDIAFIRE' ||
        name == 'MEDIA FIRE' ||
        name == 'MEDIAFIRE 2' ||
        name == 'MEDIA FIRE 2') {
      return 'MF';
    }
    return '';
  }

  String _sourceQuality(String value) {
    final raw = value.trim();
    final text = raw.toLowerCase();
    if (text.contains('1080') || text.contains('fhd')) return '1080';
    if (text.contains('720') || RegExp(r'(^|[^a-z])hd([^a-z]|$)').hasMatch(text)) {
      return '720';
    }
    if (text.contains('480') || RegExp(r'(^|[^a-z])sd([^a-z]|$)').hasMatch(text)) {
      return '480';
    }
    if (raw.contains('متعدد') || text.contains('multi') || text.contains('auto')) {
      return 'متعدد';
    }
    final number = RegExp(r'\d{3,4}').firstMatch(raw)?.group(0);
    if (number != null && number.isNotEmpty) return number;
    return raw.isEmpty ? 'متعدد' : raw.replaceFirst(RegExp(r'[pP]$'), '');
  }

  Future<List<_ServerRecord>?> _serverSummary(String animeId, String episodeId) async {
    final path = 'anime_list/$animeId/episodes/$episodeId/servers2/all_servers';
    final fields = await _firestoreDocumentFields(
      path,
      timeout: _serverTimeout,
    );
    if (fields.isEmpty) return null;
    if (fields['servers'] is! List) return null;
    return _list(fields['servers'])
        .map<_ServerRecord>(_serverRecord)
        .where((server) =>
            server.visible && server.name.isNotEmpty && server.link.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<_ServerRecord>> _serverCollection(
    String animeId,
    String episodeId,
  ) async {

    final parent = 'anime_list/$animeId/episodes/$episodeId';
    final raw = await _firestoreRestRunQuery(
      <String, dynamic>{
        'from': const <Map<String, dynamic>>[
          <String, dynamic>{'collectionId': 'servers'},
        ],
        'where': <String, dynamic>{
          'compositeFilter': <String, dynamic>{
            'op': 'AND',
            'filters': <Map<String, dynamic>>[
              <String, dynamic>{
                'fieldFilter': <String, dynamic>{
                  'field': const <String, dynamic>{'fieldPath': 'name'},
                  'op': 'NOT_EQUAL',
                  'value': const <String, dynamic>{'stringValue': ''},
                },
              },
              <String, dynamic>{
                'fieldFilter': <String, dynamic>{
                  'field': const <String, dynamic>{'fieldPath': 'visible'},
                  'op': 'EQUAL',
                  'value': const <String, dynamic>{'booleanValue': true},
                },
              },
            ],
          },
        },
        'limit': 20,
      },
      parent: parent,
      timeout: _serverTimeout,
    );
    final output = <_ServerRecord>[];
    for (final rowRaw in raw) {
      final document = _map(_map(rowRaw)['document']);
      final server = _serverRecord(_firestoreFields(document['fields']));
      if (server.visible && server.name.isNotEmpty && server.link.isNotEmpty) {
        output.add(server);
      }
    }
    return output;
  }

  Future<List<_ServerRecord>> _fetchServers(String animeId, String episodeId) async {
    await _refreshRemoteConstants();
    List<_ServerRecord> servers;
    if (_serverLoadType == 'summary') {
      final summary = await _serverSummary(animeId, episodeId);
      servers = summary ?? await _serverCollection(animeId, episodeId);
    } else {
      servers = await _serverCollection(animeId, episodeId);
    }
    final seen = <String>{};
    return servers.where((server) {
      final key = '${server.name.toUpperCase()}|${server.quality}|${server.link}';
      return seen.add(key);
    }).toList(growable: false);
  }

  String _pixelDrainId(String url) {
    final first = RegExp(
      r'pixeldrain\.(?:com|net)/(?:u|api/file)/([A-Za-z0-9_-]+)',
      caseSensitive: false,
    ).firstMatch(url);
    if (first != null) return first.group(1)!;
    final second = RegExp(
      r'pd\.1drv\.eu\.org/([A-Za-z0-9_-]+)',
      caseSensitive: false,
    ).firstMatch(url);
    return second?.group(1) ?? '';
  }

  bool _isMediaFireSharePage(String value) {
    return RegExp(
      r'^https?://(?:www\.)?mediafire\.com/(?:file|file_premium|download)/',
      caseSensitive: false,
    ).hasMatch(value.trim());
  }

  bool _isMediaFireDirectHost(String value) {
    final uri = Uri.tryParse(value.trim());
    final host = uri?.host.toLowerCase() ?? '';
    return RegExp(r'^download[^.]*\.mediafire\.com$').hasMatch(host) ||
        host.endsWith('.mediafireusercontent.com') ||
        host == 'mediafireusercontent.com';
  }

  bool _isDirectMediaUrl(String url) {
    final lower = url.toLowerCase();
    if (RegExp(r'(?:streamtape|strtape|streamadblockplus)\.', caseSensitive: false)
            .hasMatch(lower) ||
        _isMediaFireSharePage(lower) ||
        RegExp(r'pixeldrain\.(?:com|net)/u/', caseSensitive: false).hasMatch(lower)) {
      return false;
    }
    return RegExp(
          r'\.(?:m3u8|mp4|mkv|webm|m4v|mov|ts|avi)(?:$|[?#])',
          caseSensitive: false,
        ).hasMatch(url) ||
        lower.contains('/api/file/');
  }

  String _absoluteUrl(String raw, String base) {
    final value = prepareExtractedMediaUrl(raw);
    if (value.isEmpty) return '';
    if (value.startsWith('//')) return 'https:$value';
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) return uri.toString();
    final baseUri = Uri.tryParse(base);
    if (baseUri == null) return value;
    try {
      return baseUri.resolve(value).toString();
    } catch (_) {
      return value;
    }
  }

  String _decodeFlexibleBase64(String raw) {
    var value = _text(raw)
        .replaceFirst(RegExp(r'^data:[^,]*;base64,', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    if (value.isEmpty) return '';
    while (value.length % 4 != 0) value += '=';
    try {
      return utf8.decode(base64.decode(value), allowMalformed: true).trim();
    } catch (_) {
      return '';
    }
  }

  String _mediaFireCandidate(String raw, String pageUrl) {
    final candidate = _absoluteUrl(raw, pageUrl);
    if (candidate.isEmpty || _isMediaFireSharePage(candidate)) return '';
    if (_isMediaFireDirectHost(candidate) ||
        RegExp(r'\.(?:mp4|mkv|webm|m4v|mov|avi|ts)(?:$|[?#])', caseSensitive: false)
            .hasMatch(candidate)) {
      return candidate;
    }
    return '';
  }

  String _responseCookieHeader(Headers headers) {
    final cookies = <String>[];
    for (final entry in headers.map.entries) {
      if (entry.key.toLowerCase() != 'set-cookie') continue;
      for (final value in entry.value) {
        final cookie = value.split(';').first.trim();
        if (cookie.isNotEmpty && cookie.contains('=')) cookies.add(cookie);
      }
    }
    return cookies.join('; ');
  }

  List<StreamResult> _mediaFireStreams(
    _ServerRecord server,
    String rawUrl, {
    required String baseUrl,
    required String referrer,
    Headers? responseHeaders,
  }) {
    final playable = _mediaFireCandidate(rawUrl, baseUrl);
    if (playable.isEmpty) return const <StreamResult>[];
    final headers = <String, String>{
      'User-Agent': _userAgent,
      'Referer': referrer,
      'Origin': 'https://www.mediafire.com',
      'Accept': '*/*',
      'Accept-Encoding': 'identity',
    };
    if (responseHeaders != null) {
      final cookie = _responseCookieHeader(responseHeaders);
      if (cookie.isNotEmpty) headers['Cookie'] = cookie;
    }
    return <StreamResult>[
      _serverStream(server, playable, headers: headers),
    ];
  }

  Future<List<StreamResult>> _extractMediaFire(_ServerRecord server) async {
    // Keep AnimeWitcher's MF2 `/file_premium/` route intact. Rewriting it to
    // `/file/` requests a different page and can yield a successful HTML
    // response instead of the premium download URL expected by the player.
    final pageUrl = mediaFirePageRequestUrl(server.link);
    if (pageUrl.isEmpty) return const <StreamResult>[];
    final response = await _getText(
      pageUrl,
      timeout: _mediaFireTimeout,
      headers: const <String, String>{
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Referer': 'https://www.mediafire.com/',
        'Origin': 'https://www.mediafire.com',
        'Accept-Language': 'en-US,en;q=0.9',
        'Cache-Control': 'no-cache',
      },
    );
    if (response == null) return const <StreamResult>[];
    final finalUrl = response.realUri.toString();
    var playable = _mediaFireCandidate(finalUrl, pageUrl);
    final body = normalizePageEscapes(response.data ?? '');
    if (playable.isEmpty) {
      final anchorPattern = RegExp(r'<a\b[^>]*>', caseSensitive: false);
      for (final match in anchorPattern.allMatches(body)) {
        final tag = match.group(0) ?? '';
        if (!RegExp(
          r'''\bid\s*=\s*["']downloadButton["']|\baria-label\s*=\s*["']Download file["']|\bclass\s*=\s*["'][^"']*\bpopsok\b''',
          caseSensitive: false,
        ).hasMatch(tag)) {
          continue;
        }
        final href = RegExp(
          r'''\bhref\s*=\s*(?:["']([^"']+)["']|([^\s>]+))''',
          caseSensitive: false,
        ).firstMatch(tag);
        playable = _mediaFireCandidate(href?.group(1) ?? href?.group(2) ?? '', finalUrl);
        if (playable.isNotEmpty) break;
      }
    }
    if (playable.isEmpty) {
      final scrambled = RegExp(
        r'''data-scrambled-url\s*=\s*["']([^"']+)["']''',
        caseSensitive: false,
      );
      for (final match in scrambled.allMatches(body)) {
        final decoded = _decodeFlexibleBase64(match.group(1) ?? '');
        playable = _mediaFireCandidate(decoded, finalUrl);
        if (playable.isNotEmpty) break;
      }
    }
    if (playable.isEmpty) {
      for (final pattern in <RegExp>[
        RegExp(r'''https?://download[^/\s"'<>\\]+\.mediafire\.com/[^\s"'<>\\]+''', caseSensitive: false),
        RegExp(r'''https?://[^/\s"'<>\\]+\.mediafireusercontent\.com/[^\s"'<>\\]+''', caseSensitive: false),
      ]) {
        final match = pattern.firstMatch(body);
        if (match != null) {
          playable = _mediaFireCandidate(match.group(0) ?? '', finalUrl);
          if (playable.isNotEmpty) break;
        }
      }
    }
    if (playable.isEmpty) return const <StreamResult>[];
    final shareReferrer = _isMediaFireSharePage(finalUrl) ? finalUrl : pageUrl;
    return _mediaFireStreams(
      server,
      playable,
      baseUrl: finalUrl.isEmpty ? pageUrl : finalUrl,
      referrer: shareReferrer,
      responseHeaders: response.headers,
    );
  }

  bool _streamTapeNoiseMatches(String value, String canonical) {
    return value.toLowerCase().replaceAll('g', '') ==
        canonical.toLowerCase().replaceAll('g', '');
  }

  String _canonicalStreamTapeUrl(String raw) {
    var value = prepareExtractedMediaUrl(raw);
    if (value.startsWith('//')) value = 'https:$value';
    if (value.startsWith('/')) value = 'https://streamtape.com$value';
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) return '';
    var host = uri.host.toLowerCase();
    var endpoint = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
    if (_streamTapeNoiseMatches(host, 'streamtape.com')) host = 'streamtape.com';
    if (_streamTapeNoiseMatches(endpoint, 'get_video')) endpoint = 'get_video';
    final params = <String>[];
    var hasId = false;
    uri.query.split('&').where((part) => part.isNotEmpty).forEach((part) {
      final index = part.indexOf('=');
      var key = index >= 0 ? part.substring(0, index) : part;
      final rest = index >= 0 ? part.substring(index + 1) : '';
      for (final canonical in const <String>['id', 'expires', 'ip', 'token']) {
        if (_streamTapeNoiseMatches(key, canonical)) {
          key = canonical;
          break;
        }
      }
      if (key.toLowerCase() == 'id' && rest.isNotEmpty) hasId = true;
      params.add(index >= 0 ? '$key=$rest' : key);
    });
    if (host != 'streamtape.com' || endpoint != 'get_video' || !hasId) return '';
    return '${uri.scheme.toLowerCase()}://$host/$endpoint?${params.join('&')}';
  }

  String _streamTapeConstructedUrl(String body) {
    final source = normalizePageEscapes(body);
    final constructed = RegExp(
      r'''innerHTML\s*=\s*["']([^"']+)["']\s*\+\s*\(\s*["']([^"']+)["']\s*\)''',
      caseSensitive: false,
    ).firstMatch(source);
    if (constructed != null) {
      final first = constructed.group(1) ?? '';
      final rawSecond = constructed.group(2) ?? '';
      final second = rawSecond.length > 3 ? rawSecond.substring(3) : rawSecond;
      final value = _canonicalStreamTapeUrl(first + second);
      if (value.isNotEmpty) return value;
    }
    for (final pattern in <RegExp>[
      RegExp(r'''id=["']ideoooolink["'][^>]*>([^<]+)<''', caseSensitive: false),
      RegExp(r'''id=["']robotlink["'][^>]*>([^<]+)<''', caseSensitive: false),
      RegExp(r'''id=["']norobotlink["'][^>]*>([^<]+)<''', caseSensitive: false),
      RegExp(r'''id=["']videolink["'][^>]*>([^<]+)<''', caseSensitive: false),
      RegExp(r'''(?:innerHTML|src)\s*=\s*["'](//[^"']*get[^"']*video[^"']+)["']''', caseSensitive: false),
      RegExp(r'''["'](https?://[^"']*get[^"']*video\?[^"']+)["']''', caseSensitive: false),
    ]) {
      final match = pattern.firstMatch(source);
      if (match == null) continue;
      final value = _canonicalStreamTapeUrl(match.group(1) ?? '');
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  Future<List<StreamResult>> _extractStreamTape(_ServerRecord server) async {
    final response = await _getText(
      server.link,
      timeout: _streamTimeout,
      headers: const <String, String>{
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Referer': 'https://streamtape.com/',
        'Origin': 'https://streamtape.com',
      },
    );
    if (response == null) return const <StreamResult>[];
    final tokenUrl = _streamTapeConstructedUrl(response.data ?? '');
    if (tokenUrl.isEmpty) return const <StreamResult>[];
    final playbackUrl = '$tokenUrl${tokenUrl.contains('?') ? '&' : '?'}dl=1';
    return <StreamResult>[
      _serverStream(
        server,
        playbackUrl,
        headers: <String, String>{
          'User-Agent': _userAgent,
          'Referer': response.realUri.toString(),
          'Origin': 'https://streamtape.com',
          'Accept-Encoding': 'identity',
        },
      ),
    ];
  }

  static const String _sourceTokenPrefix = 'animewitcher-source://';

  String _encodeServerSource(_ServerRecord server) {
    final payload = jsonEncode(<String, dynamic>{
      'name': server.name,
      'link': server.link,
      'quality': server.quality,
      'original_link': server.originalLink,
      'open_browser': server.openBrowser,
      'direct_link': server.directLink,
      'visible': server.visible,
    });
    final encoded = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
    return '$_sourceTokenPrefix$encoded';
  }

  _ServerRecord? _decodeServerSource(String value) {
    if (!value.startsWith(_sourceTokenPrefix)) return null;
    var encoded = value.substring(_sourceTokenPrefix.length);
    while (encoded.length % 4 != 0) encoded += '=';
    try {
      final decoded = utf8.decode(base64Url.decode(encoded));
      final payload = jsonDecode(decoded);
      if (payload is! Map) return null;
      return _serverRecord(Map<String, dynamic>.from(payload));
    } catch (_) {
      return null;
    }
  }

  Future<_ServerWords?> _serverWords(String serverName) async {
    final cleanName = serverName.trim();
    if (cleanName.isEmpty) return null;
    final fields = await _firestoreDocumentFields(
      'Settings/servers/servers/$cleanName',
      timeout: _serverTimeout,
    );
    if (fields.isEmpty) return null;
    final word1 = _text(fields['word1']);
    final word2 = _text(fields['word2']);
    if (word1.isEmpty || word2.isEmpty) return null;
    return _ServerWords(
      name: _text(fields['name']).isEmpty ? cleanName : _text(fields['name']),
      word1: word1,
      word2: word2,
      word3: _text(fields['word3']),
      word4: _text(fields['word4']),
    );
  }

  StreamResult _serverStream(
    _ServerRecord server,
    String url, {
    Map<String, String>? headers,
  }) {
    return StreamResult(
      url: url,
      source: server.name,
      quality: _sourceQuality(server.quality),
      headers: headers,
      refreshUrl: _encodeServerSource(server),
    );
  }

  Future<List<StreamResult>> _extractUsingAnimeWitcherWords(
    _ServerRecord server,
  ) async {
    final words = await _serverWords(server.name);
    if (words == null) return const <StreamResult>[];
    final response = await _getText(server.link, timeout: _streamTimeout);
    if (response == null) return const <StreamResult>[];
    final body = response.data ?? '';
    final rawName = server.name.trim().toUpperCase();

    try {
      if (rawName == 'MF') {
        final first = extractBetweenWords(body, words.word1, words.word2).trim();
        if (first.isEmpty) return const <StreamResult>[];
        var next = first;
        if (next.endsWith('/') || next.endsWith('"') || next.endsWith("'")) {
          next = next.substring(0, next.length - 1);
        }
        if (!next.startsWith('http://') && !next.startsWith('https://')) {
          next = 'https://$next';
        }
        final secondResponse = await _getText(next, timeout: _mediaFireTimeout);
        if (secondResponse == null || words.word3.isEmpty || words.word4.isEmpty) {
          return const <StreamResult>[];
        }
        final finalUrl = prepareExtractedMediaUrl(
          extractBetweenWords(secondResponse.data ?? '', words.word3, words.word4),
        );
        if (finalUrl.isEmpty) return const <StreamResult>[];
        final mediaFire = _mediaFireStreams(
          server,
          finalUrl,
          baseUrl: secondResponse.realUri.toString(),
          referrer: secondResponse.realUri.toString(),
          responseHeaders: secondResponse.headers,
        );
        if (mediaFire.isNotEmpty) return mediaFire;
        return const <StreamResult>[];
      }

      var finalUrl = rawName == 'GF'
          ? extractGenericServer(body, words.word1, words.word2)
          : prepareExtractedMediaUrl(
              extractBetweenWords(body, words.word1, words.word2),
            );
      // GF pages sometimes serialize the same payload as a plain word slice
      // instead of the generic marker-in-slice form. Try the other cut before
      // giving up, otherwise playback dies silently on a markup tweak.
      if (finalUrl.isEmpty && rawName == 'GF') {
        finalUrl = prepareExtractedMediaUrl(
          extractBetweenWords(body, words.word1, words.word2),
        );
      }
      if (finalUrl.isEmpty) return const <StreamResult>[];

      if (rawName == 'ST') {
        final equals = finalUrl.indexOf('=');
        if (equals >= 0 && equals + 1 < finalUrl.length) {
          finalUrl = finalUrl.substring(equals + 1).trim();
        }
        if (finalUrl.contains('+')) return const <StreamResult>[];
        if (words.name.trim().toUpperCase() == 'ST' &&
            !finalUrl.startsWith('http://') &&
            !finalUrl.startsWith('https://')) {
          finalUrl =
              'https://streamtape.com/get_video?id=${Uri.encodeQueryComponent(finalUrl)}&dl=1';
        }
      } else if (rawName == 'KF' &&
          !finalUrl.startsWith('http://') &&
          !finalUrl.startsWith('https://')) {
        finalUrl = 'https://$finalUrl';
      }

      if (finalUrl.isEmpty) return const <StreamResult>[];
      finalUrl = prepareExtractedMediaUrl(finalUrl);
      if (finalUrl.isEmpty || !looksLikeStreamUrl(finalUrl)) {
        return const <StreamResult>[];
      }

      if (_serverFamily(server) == 'MF') {
        final absolute = _absoluteUrl(finalUrl, response.realUri.toString());
        final direct = _mediaFireStreams(
          server,
          absolute,
          baseUrl: response.realUri.toString(),
          referrer: response.realUri.toString(),
          responseHeaders: response.headers,
        );
        if (direct.isNotEmpty) return direct;
        if (_isMediaFireSharePage(absolute)) {
          return _extractMediaFire(
            _ServerRecord(
              name: server.name,
              link: absolute,
              quality: server.quality,
              originalLink: server.originalLink,
              openBrowser: server.openBrowser,
              directLink: false,
              visible: server.visible,
            ),
          );
        }
        return const <StreamResult>[];
      }

      // AnimeWitcher's original generic GF path hands the extracted URL to
      // the player directly. Do not attach the GF page as Referer: AnimeWitcher
      // forwards provider headers to both playback and downloads, and that
      // extra Referer can make otherwise valid GF links reject the request.
      if (rawName == 'GF') {
        return <StreamResult>[_serverStream(server, finalUrl)];
      }

      return <StreamResult>[
        _serverStream(
          server,
          finalUrl,
          headers: <String, String>{
            'User-Agent': _userAgent,
            'Referer': response.realUri.toString(),
          },
        ),
      ];
    } catch (_) {
      return const <StreamResult>[];
    }
  }

  Future<List<StreamResult>> _resolveServer(_ServerRecord server) async {
    final family = _serverFamily(server);
    if (server.directLink || _isDirectMediaUrl(server.link)) {
      return <StreamResult>[
        _serverStream(
          server,
          server.link,
          headers: <String, String>{
            'User-Agent': _userAgent,
            'Referer': server.originalLink.isNotEmpty
                ? server.originalLink
                : server.link,
          },
        ),
      ];
    }

    if (family == 'PD') {
      final id = _pixelDrainId(server.link);
      if (id.isNotEmpty) {
        return <StreamResult>[
          _serverStream(
            server,
            'https://pixeldrain.com/api/file/${Uri.encodeComponent(id)}',
            headers: const <String, String>{
              'User-Agent': _userAgent,
              'Referer': 'https://pixeldrain.com/',
              'Origin': 'https://pixeldrain.com',
            },
          ),
        ];
      }
    }

    if (family == 'ST') {
      final extracted = await _extractStreamTape(server);
      if (extracted.isNotEmpty) return extracted;
    }
    if (family == 'MF') {
      final extracted = await _extractMediaFire(server);
      if (extracted.isNotEmpty) return extracted;
    }

    // AnimeWitcher's Android app resolves non-direct servers using the
    // server-specific word1..word4 document from Settings/servers/servers.
    return _extractUsingAnimeWitcherWords(server);
  }

  @override
  Future<List<StreamResult>> loadStreamSources(String url) async {
    final selected = _decodeServerSource(url);
    if (selected != null) {
      return <StreamResult>[
        StreamResult(
          url: url,
          source: selected.name,
          quality: _sourceQuality(selected.quality),
          requiresResolution: true,
        ),
      ];
    }

    final route = _parseEpisodeUrl(url);
    if (route.animeId.isEmpty || route.episodeId.isEmpty) {
      throw StateError('Invalid AnimeWitcher episode data');
    }
    final servers = await _fetchServers(route.animeId, route.episodeId);
    return servers
        .map(
          (server) => StreamResult(
            url: _encodeServerSource(server),
            source: server.name,
            quality: _sourceQuality(server.quality),
            requiresResolution: true,
          ),
        )
        .toList(growable: false);
  }

  @override
  bool isExplicitStreamSelection(String url) =>
      url.startsWith(_sourceTokenPrefix);

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    final selected = _decodeServerSource(url);
    if (selected != null) {
      return _resolveServer(selected);
    }

    final route = _parseEpisodeUrl(url);
    if (route.animeId.isEmpty || route.episodeId.isEmpty) {
      throw StateError('Invalid AnimeWitcher episode data');
    }
    final servers = await _fetchServers(route.animeId, route.episodeId);
    if (servers.isEmpty) return const <StreamResult>[];

    // No preferred server: legacy callers receive every server that resolves.
    final groups = await Future.wait(servers.map(_resolveServer));
    final seen = <String>{};
    final output = <StreamResult>[];
    for (final group in groups) {
      for (final stream in group) {
        if (stream.url.isEmpty || !seen.add(stream.url)) continue;
        output.add(stream);
      }
    }
    return output;
  }

}

class _AnimeRoute {
  const _AnimeRoute({required this.animeId, required this.hit});
  final String animeId;
  final Map<String, dynamic> hit;
}

class _EpisodeRoute {
  const _EpisodeRoute(this.animeId, this.episodeId);
  final String animeId;
  final String episodeId;
}

class _EpisodeRecord {
  const _EpisodeRecord({
    required this.id,
    required this.number,
    required this.sortOrder,
    required this.title,
    required this.serverName,
    required this.image,
    required this.isFiller,
    this.isFinal = false,
    this.dubStatus = DubStatus.none,
  });
  final String id;
  final int number;
  final int sortOrder;
  final String title;
  final String serverName;
  final String image;
  final bool isFiller;
  final bool isFinal;
  final DubStatus dubStatus;
}

class _AnimeWitcherCharacterRef {
  const _AnimeWitcherCharacterRef(this.id, this.role);
  final String id;
  final String role;
}

class _AnimeWitcherCharacter {
  const _AnimeWitcherCharacter({
    required this.actor,
    required this.role,
    required this.likes,
  });
  final Actor actor;
  final String role;
  final int likes;
}

class _RelatedCandidate {
  const _RelatedCandidate(this.malId, this.type, this.label);
  final int malId;
  final String type;
  final String label;
}

class _ServerRecord {
  const _ServerRecord({
    required this.name,
    required this.link,
    required this.quality,
    required this.originalLink,
    required this.openBrowser,
    required this.directLink,
    required this.visible,
  });
  final String name;
  final String link;
  final String quality;
  final String originalLink;
  final bool openBrowser;
  final bool directLink;
  final bool visible;
}

class _ServerWords {
  const _ServerWords({
    required this.name,
    required this.word1,
    required this.word2,
    required this.word3,
    required this.word4,
  });
  final String name;
  final String word1;
  final String word2;
  final String word3;
  final String word4;
}

class _OfficialHomeSection {
  const _OfficialHomeSection({
    required this.title,
    required this.type,
    required this.indexName,
    required this.searchText,
    required this.hitsPerPage,
    required this.order,
    required this.enabled,
    required this.autoScroll,
  });

  final String title;
  final String type;
  final String indexName;
  final String searchText;
  final int hitsPerPage;
  final int order;
  final bool enabled;
  final bool autoScroll;
}

class _HomePlan {
  const _HomePlan({
    required this.index,
    this.query = '',
    this.filters = '',
    this.recent = false,
  });
  final String index;
  final String query;
  final String filters;
  final bool recent;
}
