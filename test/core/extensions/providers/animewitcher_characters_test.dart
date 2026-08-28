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
          data = runQuery ??
              <Map<String, dynamic>>[
                <String, dynamic>{
                  'document': <String, dynamic>{
                    'name':
                        'projects/animewitcher-1c66d/databases/(default)'
                        '/documents/anime_list/code-geass/characters/417',
                    'fields': <String, dynamic>{
                      'role': <String, dynamic>{'stringValue': 'Main'},
                      'mal_id': <String, dynamic>{'stringValue': '1575'},
                      'name': <String, dynamic>{
                        'stringValue': 'Code Geass',
                      },
                    },
                  },
                },
              ];
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

  test('character details read characters_list/{id}', () async {
    final stub = _stubDio();
    final document = await _provider(stub.dio).getCharacterDocument('417');

    expect(document, isNotNull);
    expect(document!.likes, 42);
    expect(
      document.url,
      'https://myanimelist.net/character/417/Lelouch_Lamperouge',
    );
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

  test('character animes query anime_list by equal mal_id strings', () async {
    final stub = _stubDio(
      runQuery: <Map<String, dynamic>>[
        <String, dynamic>{
          'document': <String, dynamic>{
            'name':
                'projects/animewitcher-1c66d/databases/(default)'
                '/documents/anime_list/code-geass',
            'fields': <String, dynamic>{
              'mal_id': <String, dynamic>{'stringValue': '1575'},
              'name': <String, dynamic>{'stringValue': 'Code Geass'},
            },
          },
        },
      ],
    );
    final document = await _provider(stub.dio).getCharacterDocument('417');
    final shows = await _provider(stub.dio).getCharacterAnimes(document!);

    expect(shows, isNotEmpty);
    expect(shows.first.roleLabel, 'شخصية رئيسية');
    final malQuery = stub.requests.lastWhere(
      (request) => request.uri.path.endsWith('/documents:runQuery'),
    );
    final payload = Map<String, dynamic>.from(malQuery.data as Map);
    final query = Map<String, dynamic>.from(payload['structuredQuery'] as Map);
    expect(query['from'], <Map<String, dynamic>>[
      <String, dynamic>{'collectionId': 'anime_list'},
    ]);
    final filter = Map<String, dynamic>.from(
      (query['where'] as Map)['fieldFilter'] as Map,
    );
    expect(filter['field'], <String, dynamic>{'fieldPath': 'mal_id'});
    expect(filter['op'], 'EQUAL');
    expect(filter['value'], <String, dynamic>{'stringValue': '1575'});
  });
}
