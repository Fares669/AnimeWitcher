import 'dart:convert';

import 'package:animewitcher/core/account/animewitcher_character_models.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestStorageService extends StorageService {
  @override
  bool isHighQualityPostersEnabled() => false;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;
}

Map<String, dynamic> _stringField(String value) =>
    <String, dynamic>{'stringValue': value};

Map<String, dynamic> _mapField(Map<String, dynamic> fields) =>
    <String, dynamic>{
      'mapValue': <String, dynamic>{'fields': fields},
    };

Map<String, dynamic> _settingsDocument({bool searchActive = true}) {
  return <String, dynamic>{
    'name':
        'projects/animewitcher-1c66d/databases/(default)/documents/Settings/constants',
    'fields': <String, dynamic>{
      'search_settings': _mapField(<String, dynamic>{
        'app_id_v3': _stringField('SRCAPP'),
        'api_key': _stringField('search-key'),
        'browse_api_key': _stringField('browse-key'),
        'is_search_active': <String, dynamic>{'booleanValue': searchActive},
      }),
      'seasons': _mapField(<String, dynamic>{
        'past': _stringField('شتاء عام 2025'),
        'current': _stringField('ربيع عام 2026'),
        'next': _stringField('صيف عام 2026'),
      }),
    },
  };
}

Map<String, dynamic> _homeSectionsDocument() {
  return <String, dynamic>{
    'name':
        'projects/animewitcher-1c66d/databases/(default)/documents/Settings/home_sections',
    'fields': <String, dynamic>{
      'sections': <String, dynamic>{
        'arrayValue': <String, dynamic>{
          'values': <Map<String, dynamic>>[
            <String, dynamic>{
              'mapValue': <String, dynamic>{
                'fields': <String, dynamic>{
                  'title': const <String, dynamic>{'stringValue': 'Latest'},
                  'type': const <String, dynamic>{'stringValue': 'list'},
                  'index_name': const <String, dynamic>{
                    'stringValue': 'series',
                  },
                  'enabled': const <String, dynamic>{'booleanValue': true},
                  'order': const <String, dynamic>{'integerValue': '1'},
                  'hits_per_page': const <String, dynamic>{
                    'integerValue': '10',
                  },
                },
              },
            },
          ],
        },
      },
    },
  };
}

Map<String, dynamic> _algoliaHits({String title = 'Hit'}) {
  return <String, dynamic>{
    'hits': <Map<String, dynamic>>[
      <String, dynamic>{
        'objectID': 'hit-1',
        'anime_id': 'hit-1',
        'name': title,
        'tags': <String>['اكشن'],
        'poster_uri': 'https://cdn.example.test/hit.jpg',
      },
    ],
    'page': 0,
    'nbPages': 1,
  };
}

Map<String, dynamic> _algoliaObject() {
  return <String, dynamic>{
    'objectID': 'naruto',
    'name': 'ناروتو',
    'poster_uri': 'https://cdn.example.test/naruto.jpg',
    'tags': <String>['اكشن'],
  };
}

bool _isAlgolia(Uri uri) =>
    uri.host.contains('algolia.net') || uri.host.contains('algolianet.com');

({Dio dio, List<RequestOptions> requests}) _stubDio({
  bool searchActive = true,
  int Function(RequestOptions options)? statusFor,
}) {
  final requests = <RequestOptions>[];
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        final path = options.uri.path;
        final status = statusFor?.call(options) ?? 200;
        dynamic data = const <String, dynamic>{};
        if (path.contains('Settings/constants') &&
            options.uri.host.contains('firestore')) {
          data = _settingsDocument(searchActive: searchActive);
        } else if (path.contains('Settings/home_sections')) {
          data = _homeSectionsDocument();
        } else if (path.contains('anime_list/naruto') &&
            !path.contains(':runQuery')) {
          data = <String, dynamic>{
            'fields': <String, dynamic>{
              'name': _stringField('ناروتو FS'),
            },
          };
        } else if (path.contains(':runQuery')) {
          data = <Map<String, dynamic>>[
            <String, dynamic>{
              'document': <String, dynamic>{
                'name':
                    'projects/animewitcher-1c66d/databases/(default)/documents/anime_list/rank-1',
                'fields': <String, dynamic>{
                  'name': _stringField('Ranked'),
                  'details': _mapField(<String, dynamic>{
                    'mal_rank': <String, dynamic>{'integerValue': '1'},
                  }),
                },
              },
            },
          ];
        } else if (_isAlgolia(options.uri) &&
            path.contains('/indexes/series/naruto')) {
          data = _algoliaObject();
        } else if (_isAlgolia(options.uri)) {
          data = _algoliaHits();
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: status,
            data: data,
          ),
        );
      },
    ),
  );
  return (dio: dio, requests: requests);
}

AnimeWitcherNativeProvider _provider(Dio dio) =>
    AnimeWitcherNativeProvider(dio, SettingsRepository(_TestStorageService()));

Map<String, String> _queryParams(RequestOptions options) {
  if (options.uri.query.isNotEmpty) return options.uri.queryParameters;
  final data = options.data;
  if (data is Map && data['params'] is String) {
    return Uri.splitQueryString(data['params'] as String, encoding: utf8);
  }
  return const <String, String>{};
}

void main() {
  test('season tabs browse series with details.season and the browse key',
      () async {
    final stub = _stubDio();
    final page = await _provider(stub.dio).getSeasonPage('ربيع عام 2026');

    expect(page.items, isNotEmpty);
    final browse = stub.requests.singleWhere(
      (request) =>
          _isAlgolia(request.uri) &&
          request.uri.path.endsWith('/indexes/series/browse'),
    );
    expect(browse.method, 'GET');
    expect(browse.headers['X-Algolia-API-Key'], 'browse-key');
    final params = browse.uri.queryParameters;
    expect(params['filters'], contains('details.season:'));
    expect(params['filters'], contains('ربيع عام 2026'));
    expect(params['hitsPerPage'], '100');
    expect(
      stub.requests.any(
        (request) => request.uri.path.contains('/indexes/series/query'),
      ),
      isFalse,
    );
  });

  test('rankings query Firestore mal_rank at APK page size 24', () async {
    final stub = _stubDio();
    final page = await _provider(stub.dio).getGlobalRankingPage(
      AnimeWitcherGlobalRanking.all,
      limit: 30,
    );

    expect(page.items, isNotEmpty);
    expect(
      stub.requests.any((request) => _isAlgolia(request.uri)),
      isFalse,
    );
    final query = stub.requests.singleWhere(
      (request) => request.uri.path.contains(':runQuery'),
    );
    final payload = Map<String, dynamic>.from(query.data as Map);
    final structured = Map<String, dynamic>.from(
      payload['structuredQuery'] as Map,
    );
    expect(structured['from'], <Map<String, dynamic>>[
      <String, dynamic>{'collectionId': 'anime_list'},
    ]);
    expect(structured['limit'], animeWitcherRankingPageSize);
    expect(structured.containsKey('where'), isFalse);
    final order = (structured['orderBy'] as List).first as Map;
    expect(order['field'], <String, dynamic>{'fieldPath': 'details.mal_rank'});
    expect(order['direction'], 'ASCENDING');
  });

  test('continuing ranking filters details.state and still uses mal_rank',
      () async {
    final stub = _stubDio();
    await _provider(stub.dio).getGlobalRankingPage(
      AnimeWitcherGlobalRanking.continuing,
    );

    final query = stub.requests.singleWhere(
      (request) => request.uri.path.contains(':runQuery'),
    );
    final structured = Map<String, dynamic>.from(
      Map<String, dynamic>.from(query.data as Map)['structuredQuery'] as Map,
    );
    expect(structured['limit'], 24);
    final where = Map<String, dynamic>.from(structured['where'] as Map);
    final filter = Map<String, dynamic>.from(where['fieldFilter'] as Map);
    expect(filter['field'], <String, dynamic>{'fieldPath': 'details.state'});
    expect(filter['op'], 'EQUAL');
    expect(filter['value'], <String, dynamic>{'stringValue': 'مستمر'});
  });

  test('ranking Firestore 403 is a failure, not an empty category', () async {
    final stub = _stubDio(
      statusFor: (options) {
        if (options.uri.path.contains(':runQuery')) return 403;
        return 200;
      },
    );

    await expectLater(
      _provider(stub.dio).getGlobalRankingPage(AnimeWitcherGlobalRanking.all),
      throwsA(isA<StateError>()),
    );
    expect(
      stub.requests.any((request) => _isAlgolia(request.uri)),
      isFalse,
    );
  });

  test('anime details load Algolia series object then skip Firestore', () async {
    final stub = _stubDio();
    final item = await _provider(stub.dio).getDetails(
      'https://animewitcher.com/watch/naruto',
    );

    expect(item.title, 'ناروتو');
    final object = stub.requests.singleWhere(
      (request) =>
          _isAlgolia(request.uri) &&
          request.uri.path.contains('/indexes/series/naruto'),
    );
    expect(object.method, 'GET');
    expect(object.headers['X-Algolia-API-Key'], 'search-key');
    expect(
      stub.requests.any(
        (request) => request.uri.path.contains('anime_list/naruto'),
      ),
      isFalse,
    );
  });

  test('anime details fall back to Firestore when Algolia object fails',
      () async {
    final stub = _stubDio(
      statusFor: (options) {
        if (_isAlgolia(options.uri) &&
            options.uri.path.contains('/indexes/series/naruto')) {
          return 503;
        }
        return 200;
      },
    );
    final item = await _provider(stub.dio).getDetails(
      'https://animewitcher.com/watch/naruto',
    );

    expect(item.title, 'ناروتو FS');
    expect(
      stub.requests.any(
        (request) => request.uri.path.contains('anime_list/naruto'),
      ),
      isTrue,
    );
  });

  test('news list uses browse key + searchAsync page 0 at 1000 hits', () async {
    final stub = _stubDio();
    final page = await _provider(stub.dio).getNewsPage();

    expect(page.items, isNotEmpty);
    expect(page.hasMore, isFalse);
    final query = stub.requests.singleWhere(
      (request) =>
          _isAlgolia(request.uri) &&
          request.uri.path.endsWith('/indexes/news/query'),
    );
    expect(query.method, 'POST');
    expect(query.headers['X-Algolia-API-Key'], 'browse-key');
    final params = _queryParams(query);
    expect(params['hitsPerPage'], '1000');
    expect(params['page'], '0');
    expect(params['query'] ?? '', '');
  });

  test('home news rail uses the search key, not the browse key', () async {
    final stub = _stubDio();
    await _provider(stub.dio).getHomeNewsPage();

    final query = stub.requests.singleWhere(
      (request) =>
          _isAlgolia(request.uri) && request.uri.path.contains('/query'),
    );
    expect(query.headers['X-Algolia-API-Key'], 'search-key');
  });

  test('home view-more is searchAsync page 0 with 200 hits', () async {
    final stub = _stubDio();
    final page = await _provider(stub.dio).getHomeSectionPage('Latest');

    expect(page.items, isNotEmpty);
    expect(page.hasMore, isFalse);
    final query = stub.requests.singleWhere(
      (request) =>
          _isAlgolia(request.uri) &&
          request.uri.path.endsWith('/indexes/series/query'),
    );
    expect(query.method, 'POST');
    expect(query.headers['X-Algolia-API-Key'], 'search-key');
    final params = _queryParams(query);
    expect(params['hitsPerPage'], '200');
    expect(params['page'], '0');

    final extra = await _provider(stub.dio).getHomeSectionPage(
      'Latest',
      offset: 200,
    );
    expect(extra.items, isEmpty);
    expect(extra.hasMore, isFalse);
  });

  test('similar titles query series_similar with 11 hits and search key',
      () async {
    final stub = _stubDio();
    final provider = _provider(stub.dio);
    await provider.getDetails('https://animewitcher.com/watch/naruto');
    await provider.getRecommendations(
      'https://animewitcher.com/watch/naruto',
    );

    final similar = stub.requests.singleWhere(
      (request) =>
          _isAlgolia(request.uri) &&
          request.uri.path.endsWith('/indexes/series_similar/query'),
    );
    expect(similar.method, 'POST');
    expect(similar.headers['X-Algolia-API-Key'], 'search-key');
    final params = _queryParams(similar);
    expect(params['hitsPerPage'], '11');
    expect(params['query'], contains('اكشن'));
    final attrs = jsonDecode(params['attributesToRetrieve']!) as List<dynamic>;
    expect(
      attrs,
      <String>[
        'objectID',
        'name',
        'poster_uri',
        'order',
        'path',
        'type',
        'poster',
        'tags',
      ],
    );
  });

  test('home rails use Algolia search, not browse', () async {
    final stub = _stubDio();
    final home = await _provider(stub.dio).getHome();

    expect(home['Latest'], isNotEmpty);
    expect(
      stub.requests.any(
        (request) => request.uri.path.contains('Settings/home_sections'),
      ),
      isTrue,
    );
    expect(
      stub.requests.any(
        (request) =>
            _isAlgolia(request.uri) &&
            request.uri.path.endsWith('/indexes/series/query'),
      ),
      isTrue,
    );
    expect(
      stub.requests.any(
        (request) =>
            _isAlgolia(request.uri) && request.uri.path.contains('/browse'),
      ),
      isFalse,
    );
  });

  test('empty search uses series searchAsync, not series_name_asc browse',
      () async {
    final stub = _stubDio();
    await _provider(stub.dio).searchPage('', const ProviderSearchFilters());

    final query = stub.requests.singleWhere(
      (request) =>
          _isAlgolia(request.uri) && request.uri.path.contains('/query'),
    );
    expect(query.method, 'POST');
    expect(query.uri.path, endsWith('/indexes/series/query'));
    expect(query.headers['X-Algolia-API-Key'], 'search-key');
    expect(
      stub.requests.any(
        (request) => request.uri.path.contains('series_name_asc'),
      ),
      isFalse,
    );
    expect(
      stub.requests.any(
        (request) =>
            _isAlgolia(request.uri) && request.uri.path.contains('/browse'),
      ),
      isFalse,
    );
  });

  test('news list falls back to Firestore limit 5 when search is inactive',
      () async {
    final stub = _stubDio(searchActive: false);
    final page = await _provider(stub.dio).getNewsPage();

    expect(page.hasMore, isFalse);
    expect(
      stub.requests.any(
        (request) =>
            _isAlgolia(request.uri) && request.uri.path.contains('/indexes/news'),
      ),
      isFalse,
    );
    final query = stub.requests.singleWhere(
      (request) => request.uri.path.contains(':runQuery'),
    );
    final payload = Map<String, dynamic>.from(query.data as Map);
    final structured = Map<String, dynamic>.from(
      payload['structuredQuery'] as Map,
    );
    expect(structured['from'], <Map<String, dynamic>>[
      <String, dynamic>{'collectionId': 'news'},
    ]);
    expect(structured['limit'], 5);
    final order = (structured['orderBy'] as List).first as Map;
    expect(order['field'], <String, dynamic>{'fieldPath': 'date_created'});
    expect(order['direction'], 'DESCENDING');
  });

  test('anime details skip the is_search_active gate', () async {
    final stub = _stubDio(searchActive: false);
    final item = await _provider(stub.dio).getDetails(
      'https://animewitcher.com/watch/naruto',
    );

    expect(item.title, 'ناروتو');
    expect(
      stub.requests.any(
        (request) =>
            _isAlgolia(request.uri) &&
            request.uri.path.contains('/indexes/series/naruto'),
      ),
      isTrue,
    );
  });

  test('similar titles stay off Algolia when search is inactive', () async {
    final stub = _stubDio(searchActive: false);
    final provider = _provider(stub.dio);
    await provider.getDetails('https://animewitcher.com/watch/naruto');
    await expectLater(
      provider.getRecommendations('https://animewitcher.com/watch/naruto'),
      throwsA(
        isA<AnimeWitcherSearchDisabledException>().having(
          (error) => error.message,
          'message',
          animeWitcherSimilarSearchDisabledMessage,
        ),
      ),
    );
    expect(
      stub.requests.any(
        (request) => request.uri.path.contains('series_similar'),
      ),
      isFalse,
    );
  });
}
