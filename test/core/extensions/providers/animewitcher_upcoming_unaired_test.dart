import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorageService extends StorageService {
  final Map<String, String> values = <String, String>{};

  @override
  bool isHighQualityPostersEnabled() => false;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  String? getString(String key) => values[key];
}

AnimeWitcherNativeProvider _provider(
  Dio dio, {
  StorageService? storage,
}) =>
    AnimeWitcherNativeProvider(
      dio,
      SettingsRepository(storage ?? _MemoryStorageService()),
    );

const String _browseAppId = 'BROWSEAPPID';
const String _searchApiKey = 'search-api-key';
const String _browseApiKey = 'browse-api-key';
const String _fallbackAppId = 'FALLBACKAPP';
const String _fallbackApiKey = 'fallback-api-key';
const String _fallbackBrowseKey = 'fallback-browse-key';

Map<String, dynamic> _stringField(String value) =>
    <String, dynamic>{'stringValue': value};

Map<String, dynamic> _boolField(bool value) =>
    <String, dynamic>{'booleanValue': value};

Map<String, dynamic> _mapField(Map<String, dynamic> fields) =>
    <String, dynamic>{
      'mapValue': <String, dynamic>{'fields': fields},
    };

Map<String, dynamic> _settingsDocument({
  String appId = _browseAppId,
  String apiKey = _searchApiKey,
  String browseKey = _browseApiKey,
  String appId2 = _fallbackAppId,
  String apiKey2 = _fallbackApiKey,
}) {
  return <String, dynamic>{
    'name':
        'projects/animewitcher-1c66d/databases/(default)/documents/Settings/constants',
    'fields': <String, dynamic>{
      'search_settings': _mapField(<String, dynamic>{
        'app_id_v3': _stringField(appId),
        'api_key': _stringField(apiKey),
        'browse_api_key': _stringField(browseKey),
        'is_search_active': _boolField(true),
      }),
      'search_settings2': _mapField(<String, dynamic>{
        'app_id': _stringField(appId2),
        'api_key': _stringField(apiKey2),
      }),
    },
  };
}

Map<String, dynamic> _algoliaConstants({
  String appId = _browseAppId,
  String apiKey = _searchApiKey,
  String browseKey = _fallbackBrowseKey,
}) {
  return <String, dynamic>{
    'objectID': 'constants',
    'search_settings': <String, dynamic>{
      'app_id_v3': appId,
      'api_key': apiKey,
      'browse_api_key': browseKey,
      'is_search_active': true,
    },
    'search_settings2': <String, dynamic>{
      'app_id': _fallbackAppId,
      'api_key': _fallbackApiKey,
    },
  };
}

Map<String, dynamic> _unairedHit(String id, {String title = ''}) {
  return <String, dynamic>{
    'objectID': id,
    'name': title.isEmpty ? 'قادم $id' : title,
    'path': '/anime/$id',
    'details': <String, dynamic>{
      'state': 'لم يتم بثه بعد',
      'season': 'شتاء عام 2027',
    },
    'poster': <String, dynamic>{
      'large': 'https://cdn.example.test/$id.jpg',
    },
  };
}

String? _header(RequestOptions options, String name) {
  final expected = name.toLowerCase();
  for (final entry in options.headers.entries) {
    if (entry.key.toString().toLowerCase() == expected) {
      return entry.value?.toString();
    }
  }
  return null;
}

bool _isAlgoliaHost(Uri uri) =>
    uri.host.contains('algolia.net') || uri.host.contains('algolianet.com');

bool _isSettingsConstants(Uri uri) =>
    uri.path.contains('Settings/constants') &&
    uri.host.contains('firestore.googleapis.com');

bool _isAlgoliaSettingsObject(Uri uri) =>
    uri.path.contains('/indexes/Settings/constants');

bool _isBrowse(Uri uri) => uri.path.contains('/indexes/series/browse');

({Dio dio, List<RequestOptions> requests}) _stubDio({
  required List<Map<String, dynamic>> hits,
  int nbPages = 3,
  int Function()? firestoreSettingsStatus,
  Map<String, dynamic>? firestoreSettings,
  int Function()? algoliaSettingsStatus,
  Map<String, dynamic>? algoliaSettings,
  int Function()? browseStatus,
}) {
  final requests = <RequestOptions>[];
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        final uri = options.uri;
        if (_isSettingsConstants(uri)) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: firestoreSettingsStatus?.call() ?? 200,
              data: firestoreSettings ?? _settingsDocument(),
            ),
          );
          return;
        }
        if (_isAlgoliaSettingsObject(uri)) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: algoliaSettingsStatus?.call() ?? 200,
              data: algoliaSettings ?? _algoliaConstants(),
            ),
          );
          return;
        }
        if (_isAlgoliaHost(uri) && _isBrowse(uri)) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: browseStatus?.call() ?? 200,
              data: <String, dynamic>{'hits': hits, 'nbPages': nbPages},
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: const <String, dynamic>{},
          ),
        );
      },
    ),
  );
  return (dio: dio, requests: requests);
}

void main() {
  test('coming soon browses unaired titles, not the next season', () async {
    final stub = _stubDio(
      hits: <Map<String, dynamic>>[
        _unairedHit('soon-1', title: 'عمل لم يُبث'),
        _unairedHit('soon-2'),
      ],
    );

    final page = await _provider(stub.dio).getUpcomingPage();

    final browse = stub.requests.where(
      (request) => _isAlgoliaHost(request.uri) && _isBrowse(request.uri),
    );
    expect(browse, isNotEmpty);
    expect(
      stub.requests.any(
        (request) => request.uri.path.contains('/indexes/series/query'),
      ),
      isFalse,
      reason: 'coming soon must use Index.browse, not /query',
    );
    expect(
      stub.requests.any(
        (request) => request.uri.path.contains('home_sections'),
      ),
      isFalse,
      reason: 'coming soon must not load the next-season home rail',
    );
    expect(
      stub.requests.any(
        (request) => request.uri.path.contains(':runQuery'),
      ),
      isFalse,
      reason: 'coming soon must not fall back to Firestore anime_list',
    );

    final query = browse.first;
    expect(query.method, 'GET');
    expect(query.data, isNull);
    expect(query.uri.path, contains('/indexes/series/browse'));
    expect(
      query.uri.host.toLowerCase(),
      '${_browseAppId.toLowerCase()}-dsn.algolia.net',
    );
    expect(_header(query, 'X-Algolia-Application-Id'), _browseAppId);
    expect(_header(query, 'X-Algolia-API-Key'), _browseApiKey);
    expect(_header(query, 'X-Algolia-API-Key'), isNot(_searchApiKey));

    final params = query.uri.queryParameters;
    expect(params['filters'], contains('details.state:'));
    expect(params['filters'], contains('لم يتم بثه بعد'));
    expect(params['filters'], isNot(contains('details.season')));
    expect(params['filters'], isNot(contains('الموسم القادم')));
    expect(params['hitsPerPage'], '100');
    expect(params['page'], '0');
    expect(params.containsKey('query'), isFalse);
    final attributes =
        jsonDecode(params['attributesToRetrieve'] ?? '[]') as List<dynamic>;
    expect(
      attributes,
      <String>[
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
      ],
    );

    expect(page.items, hasLength(2));
    expect(page.items.first.title, 'عمل لم يُبث');
    expect(
      page.items.every((item) => item.status == ShowStatus.upcoming),
      isTrue,
    );
    expect(page.hasMore, isTrue);
    expect(page.nextOffset, 100);

    final artifacts = Directory('/opt/cursor/artifacts');
    if (artifacts.existsSync()) {
      File('${artifacts.path}/coming_soon_algolia_browse.txt').writeAsStringSync(
        'method: ${query.method}\n'
        'host: ${query.uri.host}\n'
        'path: ${query.uri.path}\n'
        'filters: ${params['filters']}\n'
        'hitsPerPage: ${params['hitsPerPage']}\n'
        'page: ${params['page']}\n'
        'apiKeyHeader: ${query.headers['X-Algolia-API-Key']}\n',
      );
    }
  });

  test('coming soon pagination asks Algolia browse for the next unaired page',
      () async {
    final stub = _stubDio(hits: <Map<String, dynamic>>[_unairedHit('p2')]);

    await _provider(stub.dio).getUpcomingPage(offset: 100);

    final query = stub.requests.firstWhere(
      (request) => _isAlgoliaHost(request.uri) && _isBrowse(request.uri),
    );
    expect(query.method, 'GET');
    expect(query.uri.queryParameters['page'], '1');
    expect(
      query.uri.queryParameters['filters'],
      contains('لم يتم بثه بعد'),
    );
    expect(query.uri.queryParameters['hitsPerPage'], '100');
  });

  test('coming soon does not fall back to Firestore when browse fails',
      () async {
    final stub = _stubDio(
      hits: <Map<String, dynamic>>[_unairedHit('nope')],
      browseStatus: () => 503,
    );

    await expectLater(
      _provider(stub.dio).getUpcomingPage(),
      throwsA(isA<StateError>()),
    );
    expect(
      stub.requests.any((request) => request.uri.path.contains(':runQuery')),
      isFalse,
    );
    expect(
      stub.requests.any(
        (request) => request.uri.path.contains('/indexes/series/query'),
      ),
      isFalse,
    );
  });

  test(
      'when Firestore Settings is down, coming soon loads constants from Algolia then browses',
      () async {
    final storage = _MemoryStorageService();
    final settings = SettingsRepository(storage);

    final warm = _stubDio(hits: <Map<String, dynamic>>[_unairedHit('warm')]);
    await _provider(warm.dio, storage: storage).getUpcomingPage();
    expect(settings.getAnimeWitcherSearchSettings2(), isNotEmpty);

    var firestoreCalls = 0;
    var algoliaSettingsCalls = 0;
    final stub = _stubDio(
      hits: <Map<String, dynamic>>[_unairedHit('offline-1')],
      firestoreSettingsStatus: () {
        firestoreCalls += 1;
        return 503;
      },
      algoliaSettingsStatus: () {
        algoliaSettingsCalls += 1;
        return 200;
      },
      algoliaSettings: _algoliaConstants(browseKey: _fallbackBrowseKey),
    );

    final page = await _provider(stub.dio, storage: storage).getUpcomingPage();

    expect(firestoreCalls, greaterThan(0));
    expect(algoliaSettingsCalls, 1);
    final constants = stub.requests.firstWhere(
      (request) => _isAlgoliaSettingsObject(request.uri),
    );
    expect(constants.method, 'GET');
    expect(constants.data, isNull);
    expect(constants.uri.host.toLowerCase(),
        '${_fallbackAppId.toLowerCase()}-dsn.algolia.net');
    expect(constants.uri.path, contains('/indexes/Settings/constants'));
    expect(_header(constants, 'X-Algolia-Application-Id'), _fallbackAppId);
    expect(_header(constants, 'X-Algolia-API-Key'), _fallbackApiKey);

    final browse = stub.requests.firstWhere(
      (request) => _isAlgoliaHost(request.uri) && _isBrowse(request.uri),
    );
    expect(_header(browse, 'X-Algolia-API-Key'), _fallbackBrowseKey);
    expect(page.items, hasLength(1));
    expect(page.items.first.title, 'قادم offline-1');
  });

  test(
      'coming soon errors when Firestore Settings is down and no search_settings2 cache exists',
      () async {
    final stub = _stubDio(
      hits: <Map<String, dynamic>>[_unairedHit('unused')],
      firestoreSettingsStatus: () => 503,
    );

    await expectLater(
      _provider(stub.dio).getUpcomingPage(),
      throwsA(isA<StateError>()),
    );
    expect(
      stub.requests.any((request) => _isAlgoliaSettingsObject(request.uri)),
      isFalse,
    );
    expect(
      stub.requests.any(
        (request) => _isAlgoliaHost(request.uri) && _isBrowse(request.uri),
      ),
      isFalse,
    );
  });
}
