import 'dart:convert';

import 'package:animewitcher/core/account/animewitcher_character_models.dart';
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

AnimeWitcherNativeProvider _provider(Dio dio) =>
    AnimeWitcherNativeProvider(dio, SettingsRepository(_TestStorageService()));

class _RecordedDio {
  _RecordedDio(this.dio, this.requests);

  final Dio dio;
  final List<RequestOptions> requests;
}

Map<String, dynamic> _searchServiceDocument({
  bool active = true,
  String appId = 'TESTAPPID',
  String browseKey = 'browse-key',
  String error = 'البحث متوقف حاليا',
}) {
  return <String, dynamic>{
    'name':
        'projects/animewitcher-1c66d/databases/(default)/documents/Settings/search_service',
    'fields': <String, dynamic>{
      'browseApiKey': <String, dynamic>{'stringValue': browseKey},
      'is_search_active': <String, dynamic>{'booleanValue': active},
      'app_id': <String, dynamic>{'stringValue': appId},
      'error_message': <String, dynamic>{'stringValue': error},
    },
  };
}

Map<String, dynamic> _constantsDocument() {
  return <String, dynamic>{
    'name':
        'projects/animewitcher-1c66d/databases/(default)/documents/Settings/constants',
    'fields': <String, dynamic>{
      'search_settings': <String, dynamic>{
        'mapValue': <String, dynamic>{
          'fields': <String, dynamic>{
            'app_id': <String, dynamic>{'stringValue': 'SEARCHAPP'},
            'api_key': <String, dynamic>{'stringValue': 'search-key'},
          },
        },
      },
    },
  };
}

Map<String, dynamic> _characterDocument() {
  return <String, dynamic>{
    'name':
        'projects/animewitcher-1c66d/databases/(default)/documents/characters_list/417',
    'fields': <String, dynamic>{
      'likes': <String, dynamic>{'integerValue': '42'},
      'data': <String, dynamic>{
        'mapValue': <String, dynamic>{
          'fields': <String, dynamic>{
            'name': <String, dynamic>{'stringValue': 'Lelouch Lamperouge'},
            'url': <String, dynamic>{
              'stringValue':
                  'https://myanimelist.net/character/417/Lelouch_Lamperouge',
            },
            'images': <String, dynamic>{
              'mapValue': <String, dynamic>{
                'fields': <String, dynamic>{
                  'jpg': <String, dynamic>{
                    'mapValue': <String, dynamic>{
                      'fields': <String, dynamic>{
                        'image_url': <String, dynamic>{
                          'stringValue':
                              'https://cdn.myanimelist.net/images/characters/8/l.jpg',
                        },
                      },
                    },
                  },
                },
              },
            },
            'anime': <String, dynamic>{
              'arrayValue': <String, dynamic>{
                'values': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'mapValue': <String, dynamic>{
                      'fields': <String, dynamic>{
                        'role': <String, dynamic>{'stringValue': 'Main'},
                        'anime': <String, dynamic>{
                          'mapValue': <String, dynamic>{
                            'fields': <String, dynamic>{
                              'mal_id': <String, dynamic>{
                                'integerValue': '1575',
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                  <String, dynamic>{
                    'mapValue': <String, dynamic>{
                      'fields': <String, dynamic>{
                        'role': <String, dynamic>{'stringValue': 'Supporting'},
                        'anime': <String, dynamic>{
                          'mapValue': <String, dynamic>{
                            'fields': <String, dynamic>{
                              'mal_id': <String, dynamic>{
                                'stringValue': '13759',
                              },
                            },
                          },
                        },
                      },
                    },
                  },
                ],
              },
            },
          },
        },
      },
    },
  };
}

Map<String, dynamic> _algoliaHits() {
  return <String, dynamic>{
    'hits': <Map<String, dynamic>>[
      <String, dynamic>{
        'objectID': '417',
        'name': 'Lelouch Lamperouge',
        'main_picture':
            'https://cdn.myanimelist.net/images/characters/8/l.jpg',
        'likes': 12,
      },
    ],
    'page': 0,
    'nbPages': 3,
  };
}

Map<String, dynamic> _animeListHit({
  required String documentId,
  required String title,
  required String malId,
  bool integerMalId = false,
}) {
  return <String, dynamic>{
    'document': <String, dynamic>{
      'name':
          'projects/animewitcher-1c66d/databases/(default)'
          '/documents/anime_list/$documentId',
      'fields': <String, dynamic>{
        'mal_id': integerMalId
            ? <String, dynamic>{'integerValue': malId}
            : <String, dynamic>{'stringValue': malId},
        'name': <String, dynamic>{'stringValue': title},
      },
    },
  };
}

const Map<String, Map<String, dynamic>> _animeListByMalId =
    <String, Map<String, dynamic>>{
  '1575': <String, dynamic>{
    'id': 'code-geass',
    'title': 'Code Geass',
    'integer': false,
  },
  '13759': <String, dynamic>{
    'id': 'akito',
    'title': 'Code Geass: Akito the Exiled',
    'integer': true,
  },
  '16498': <String, dynamic>{
    'id': 'Attack on Titan S01',
    'title': 'هجوم العمالقة',
    'integer': false,
  },
};

List<String> _malIdsFromQuery(Map<String, dynamic> query) {
  final where = Map<String, dynamic>.from(query['where'] as Map? ?? const {});
  final filter = Map<String, dynamic>.from(
    where['fieldFilter'] as Map? ?? const {},
  );
  final value = Map<String, dynamic>.from(filter['value'] as Map? ?? const {});
  final ids = <String>[];
  void add(dynamic raw) {
    if (raw is! Map) return;
    final id = '${raw['stringValue'] ?? raw['integerValue'] ?? ''}'.trim();
    if (id.isNotEmpty) ids.add(id);
  }

  final values = Map<String, dynamic>.from(
    value['arrayValue'] as Map? ?? const {},
  )['values'];
  if (values is List) {
    for (final item in values) {
      add(item);
    }
  } else {
    add(value);
  }
  return ids;
}

({int status, dynamic data}) _runQueryResponse(RequestOptions options) {
  final payload = options.data is Map
      ? Map<String, dynamic>.from(options.data as Map)
      : const <String, dynamic>{};
  final query = Map<String, dynamic>.from(
    payload['structuredQuery'] as Map? ?? const {},
  );
  final from = (query['from'] as List?)?.first;
  final collection = from is Map ? from['collectionId']?.toString() : '';
  if (collection == 'characters') {
    return (
      status: 200,
      data: <Map<String, dynamic>>[
        <String, dynamic>{
          'document': <String, dynamic>{
            'name':
                'projects/animewitcher-1c66d/databases/(default)'
                '/documents/anime_list/code-geass/characters/417',
            'fields': <String, dynamic>{
              'role': <String, dynamic>{'stringValue': 'Main'},
              'mal_id': <String, dynamic>{'stringValue': '1575'},
              'name': <String, dynamic>{'stringValue': 'Code Geass'},
            },
          },
        },
      ],
    );
  }
  if (collection == 'anime_list') {
    final filter = Map<String, dynamic>.from(
      Map<String, dynamic>.from(
        query['where'] as Map? ?? const {},
      )['fieldFilter'] as Map? ??
          const {},
    );
    if (filter['op'] == 'EQUAL') {
      return (
        status: 403,
        data: <Map<String, dynamic>>[
          <String, dynamic>{
            'error': <String, dynamic>{
              'code': 403,
              'message': 'Missing or insufficient permissions.',
              'status': 'PERMISSION_DENIED',
            },
          },
        ],
      );
    }
    final hits = <Map<String, dynamic>>[];
    for (final malId in _malIdsFromQuery(query)) {
      final meta = _animeListByMalId[malId];
      if (meta == null) continue;
      hits.add(
        _animeListHit(
          documentId: meta['id'] as String,
          title: meta['title'] as String,
          malId: malId,
          integerMalId: meta['integer'] as bool,
        ),
      );
    }
    return (status: 200, data: hits);
  }
  return (status: 200, data: const <Map<String, dynamic>>[]);
}

_RecordedDio _stubDio({
  Map<String, dynamic>? searchService,
  Map<String, dynamic>? characterDocument,
  Map<String, dynamic>? algoliaPayload,
  List<Map<String, dynamic>>? runQuery,
}) {
  final requests = <RequestOptions>[];
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        final path = options.uri.path;
        final host = options.uri.host;
        dynamic data = const <String, dynamic>{};
        var status = 200;
        if (path.contains('Settings/search_service')) {
          data = searchService ?? _searchServiceDocument();
        } else if (path.contains('Settings/constants')) {
          data = _constantsDocument();
        } else if (path.contains('characters_list/417')) {
          data = characterDocument ?? _characterDocument();
        } else if (host.contains('algolia.net')) {
          data = algoliaPayload ?? _algoliaHits();
        } else if (path.endsWith(':runQuery')) {
          if (runQuery != null) {
            data = runQuery;
          } else {
            final result = _runQueryResponse(options);
            status = result.status;
            data = result.data;
          }
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
  return _RecordedDio(dio, requests);
}

String _paramsOf(RequestOptions options) {
  final data = options.data;
  if (data is Map) {
    return data['params']?.toString() ?? '';
  }
  return data?.toString() ?? '';
}

void main() {
  test('character catalog browses the characters index with the browse key',
      () async {
    final stub = _stubDio();
    final page = await _provider(stub.dio).getCharactersPage();

    expect(page.items, hasLength(1));
    expect(page.items.single.id, '417');
    expect(page.items.single.name, 'Lelouch Lamperouge');
    expect(page.hasMore, isTrue);

    final browse = stub.requests.singleWhere(
      (request) => request.uri.host.contains('algolia.net'),
    );
    expect(browse.uri.path, endsWith('/indexes/characters/browse'));
    expect(browse.uri.host, startsWith('testappid-dsn.algolia.net'));
    expect(browse.headers['X-Algolia-API-Key'], 'browse-key');
    final params = Uri.splitQueryString(_paramsOf(browse), encoding: utf8);
    expect(params['hitsPerPage'], '20');
    expect(params['page'], '0');
    expect(params['attributesToRetrieve'], contains('main_picture'));
    expect(params['attributesToRetrieve'], contains('objectID'));
  });

  test('typed character search uses prefs keys and 500 hits per page', () async {
    final stub = _stubDio();
    await _provider(stub.dio).searchCharacters('lelouch');

    final search = stub.requests.singleWhere(
      (request) =>
          request.uri.host.contains('algolia.net') &&
          request.uri.path.endsWith('/indexes/characters/query'),
    );
    expect(search.uri.host, startsWith('searchapp-dsn.algolia.net'));
    expect(search.headers['X-Algolia-API-Key'], 'search-key');
    final params = Uri.splitQueryString(_paramsOf(search), encoding: utf8);
    expect(params['query'], 'lelouch');
    expect(params['hitsPerPage'], '500');
  });

  test('inactive search service surfaces error_message', () async {
    final stub = _stubDio(
      searchService: _searchServiceDocument(active: false),
    );
    await expectLater(
      _provider(stub.dio).getCharactersPage(),
      throwsA(
        isA<AnimeWitcherSearchDisabledException>().having(
          (error) => error.message,
          'message',
          'البحث متوقف حاليا',
        ),
      ),
    );
    expect(
      stub.requests.where((request) => request.uri.host.contains('algolia.net')),
      isEmpty,
    );
  });

  test('character details parse data.anime mal_ids from the REST document',
      () async {
    final stub = _stubDio();
    final document = await _provider(stub.dio).getCharacterDocument('417');

    expect(document, isNotNull);
    expect(document!.likes, 42);
    expect(
      document.url,
      'https://myanimelist.net/character/417/Lelouch_Lamperouge',
    );
    expect(document.animes, hasLength(2));
    expect(document.animes.first.malId, '1575');
    expect(document.animes.last.malId, '13759');
    expect(
      stub.requests.any(
        (request) => request.uri.path.contains('characters_list/417'),
      ),
      isTrue,
    );
  });

  test('anime cast queries Main/Supporting under anime_list/{id}/characters',
      () async {
    final stub = _stubDio();
    final cast = await _provider(stub.dio).getCast(
      'https://animewitcher.com/watch/code-geass',
    );

    expect(cast, isNotEmpty);
    expect(cast.first.id, '417');
    final queries = stub.requests.where(
      (request) => request.uri.path.contains('anime_list/code-geass:runQuery'),
    );
    expect(queries.length, greaterThanOrEqualTo(2));
    for (final request in queries) {
      final payload = Map<String, dynamic>.from(request.data as Map);
      final query = Map<String, dynamic>.from(
        payload['structuredQuery'] as Map,
      );
      expect(query['from'], <Map<String, dynamic>>[
        <String, dynamic>{'collectionId': 'characters'},
      ]);
      expect(query['limit'], 10);
    }
  });

  test('Eren-shaped integer mal_id resolves a catalog title via IN', () async {
    final stub = _stubDio();
    final document = AnimeWitcherCharacterDocument(
      id: '40882',
      name: 'Eren Yeager',
      likes: 40870,
      animes: const <AnimeWitcherCharacterAnimeRef>[
        AnimeWitcherCharacterAnimeRef(malId: '16498', role: 'Main'),
      ],
    );
    final shows = await _provider(stub.dio).getCharacterAnimes(document);
    expect(shows, hasLength(1));
    expect(shows.single.item.title, 'هجوم العمالقة');
    expect(shows.single.roleLabel, 'شخصية رئيسية');
    expect(
      _malIdsFromQuery(
        Map<String, dynamic>.from(
          (stub.requests.single.data as Map)['structuredQuery'] as Map,
        ),
      ),
      <String>['16498'],
    );
  });

  test('character animes resolve int and string mal_id via IN', () async {
    final stub = _stubDio();
    final document = await _provider(stub.dio).getCharacterDocument('417');
    final shows = await _provider(stub.dio).getCharacterAnimes(document!);

    expect(document.animes.map((item) => item.malId).toList(), <String>[
      '1575',
      '13759',
    ]);
    expect(shows, hasLength(2));
    expect(shows.first.item.title, 'Code Geass');
    expect(shows.first.roleLabel, 'شخصية رئيسية');
    expect(shows.last.item.title, 'Code Geass: Akito the Exiled');
    expect(shows.last.roleLabel, 'شخصية ثانوية');

    final malQueries = stub.requests
        .where((request) => request.uri.path.endsWith('/documents:runQuery'))
        .toList();
    expect(malQueries, hasLength(1));
    final payload = Map<String, dynamic>.from(malQueries.single.data as Map);
    final query = Map<String, dynamic>.from(payload['structuredQuery'] as Map);
    expect(query['from'], <Map<String, dynamic>>[
      <String, dynamic>{'collectionId': 'anime_list'},
    ]);
    final filter = Map<String, dynamic>.from(
      (query['where'] as Map)['fieldFilter'] as Map,
    );
    expect(filter['field'], <String, dynamic>{'fieldPath': 'mal_id'});
    expect(filter['op'], 'IN');
    expect(filter['op'], isNot('EQUAL'));
    expect(
      _malIdsFromQuery(query),
      <String>['1575', '13759'],
    );
    expect(
      filter['value'],
      <String, dynamic>{
        'arrayValue': <String, dynamic>{
          'values': <Map<String, dynamic>>[
            <String, dynamic>{'stringValue': '1575'},
            <String, dynamic>{'stringValue': '13759'},
          ],
        },
      },
    );
  });

  test('character animes batch mal_id IN queries by tens', () async {
    final stub = _stubDio();
    final document = AnimeWitcherCharacterDocument(
      id: '40882',
      name: 'Eren Yeager',
      likes: 40870,
      animes: <AnimeWitcherCharacterAnimeRef>[
        for (var index = 1; index <= 12; index++)
          AnimeWitcherCharacterAnimeRef(malId: '$index', role: 'Main'),
      ],
    );
    final shows = await _provider(stub.dio).getCharacterAnimes(document);
    expect(shows, isEmpty);

    final malQueries = stub.requests
        .where((request) => request.uri.path.endsWith('/documents:runQuery'))
        .toList();
    expect(malQueries, hasLength(2));
    expect(
      _malIdsFromQuery(
        Map<String, dynamic>.from(
          (malQueries.first.data as Map)['structuredQuery'] as Map,
        ),
      ),
      hasLength(10),
    );
    expect(
      _malIdsFromQuery(
        Map<String, dynamic>.from(
          (malQueries.last.data as Map)['structuredQuery'] as Map,
        ),
      ),
      <String>['11', '12'],
    );
  });
}
