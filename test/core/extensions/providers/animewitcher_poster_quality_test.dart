import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';

const String _smallPoster = 'https://cdn.animewitcher.com/small/one_piece.jpg';
const String _largePoster = 'https://cdn.animewitcher.com/large/one_piece.jpg';
const String _aniListPoster =
    'https://cdn.animewitcher.com/anilist/one_piece.jpg';
const String _episodeStill =
    'https://cdn.animewitcher.com/thumbs/one_piece_1100.jpg';
const String _latestSectionTitle = 'الحلقات الجديدة';

class _PosterQualitySettingsRepository extends SettingsRepository {
  _PosterQualitySettingsRepository({this.highQuality = true})
    : super(StorageService());

  final bool highQuality;

  @override
  bool isHighQualityPostersEnabled() => highQuality;
}

Map<String, dynamic> _algoliaHit({Map<String, dynamic>? poster}) {
  return <String, dynamic>{
    'hits': <Map<String, dynamic>>[
      <String, dynamic>{
        'objectID': 'one_piece',
        'anime_id': 'one_piece',
        'name': 'ون بيس',
        'poster_uri': _smallPoster,
        if (poster != null) 'poster': poster,
      },
    ],
    'nbPages': 1,
  };
}

List<Map<String, dynamic>> get _batchGetResponse => <Map<String, dynamic>>[
  <String, dynamic>{
    'found': <String, dynamic>{
      'name':
          'projects/animewitcher-1c66d/databases/(default)'
          '/documents/anime_list/one_piece',
      'fields': <String, dynamic>{
        'poster': <String, dynamic>{
          'mapValue': <String, dynamic>{
            'fields': <String, dynamic>{
              'large': <String, dynamic>{'stringValue': _largePoster},
              'medium': <String, dynamic>{'stringValue': _smallPoster},
            },
          },
        },
      },
    },
  },
];

Map<String, dynamic> _recentAlgoliaHit({
  String objectId = 'episode_doc_1100',
  String animeId = 'one_piece',
  String episodeName = 'حلقة 1100',
  String? aniListPoster = _aniListPoster,
}) {
  return <String, dynamic>{
    'hits': <Map<String, dynamic>>[
      <String, dynamic>{
        'objectID': objectId,
        'anime_id': animeId,
        'name': 'ون بيس',
        'episode_name': episodeName,
        'poster_uri': _smallPoster,
        if (aniListPoster != null) 'poster_url_aniList': aniListPoster,
        'thumb_uri': _episodeStill,
        'doc_ref': 'episodes/$objectId',
      },
    ],
    'nbPages': 1,
  };
}

Map<String, dynamic> _recentHomeSectionsDocument({
  String title = _latestSectionTitle,
  String type = 'recent',
  String indexName = 'recent',
}) {
  return <String, dynamic>{
    'name':
        'projects/animewitcher-1c66d/databases/(default)'
        '/documents/Settings/home_sections',
    'fields': <String, dynamic>{
      'sections': <String, dynamic>{
        'arrayValue': <String, dynamic>{
          'values': <Map<String, dynamic>>[
            <String, dynamic>{
              'mapValue': <String, dynamic>{
                'fields': <String, dynamic>{
                  'title': <String, dynamic>{'stringValue': title},
                  'type': <String, dynamic>{'stringValue': type},
                  'index_name': <String, dynamic>{'stringValue': indexName},
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

Map<String, String> _algoliaQueryParams(RequestOptions options) {
  final data = options.data;
  if (data is Map && data['params'] is String) {
    return Uri.splitQueryString(data['params'] as String, encoding: utf8);
  }
  return options.uri.queryParameters;
}

List<String> _batchGetDocumentIds(RequestOptions request) {
  final data = request.data;
  if (data is! Map) return const <String>[];
  final documents = data['documents'];
  if (documents is! List) return const <String>[];
  return documents.map((raw) => raw.toString()).toList(growable: false);
}

/// Dio that answers Algolia queries with [algoliaPayload] and Firestore
/// `batchGet` calls with the poster document, recording every request.
({Dio dio, List<RequestOptions> requests}) _stubDio(
  Map<String, dynamic> algoliaPayload, {
  Map<String, dynamic>? homeSections,
  List<Map<String, dynamic>>? batchGetResponse,
}) {
  final requests = <RequestOptions>[];
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        final url = options.uri.toString();
        final path = options.uri.path;
        dynamic data = <String, dynamic>{};
        if (url.contains('documents:batchGet')) {
          data = batchGetResponse ?? _batchGetResponse;
        } else if (path.contains('Settings/home_sections')) {
          data = homeSections ?? const <String, dynamic>{};
        } else if (url.contains('algolia.net')) {
          data = algoliaPayload;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return (dio: dio, requests: requests);
}

AnimeWitcherNativeProvider _provider(Dio dio, {bool highQuality = true}) =>
    AnimeWitcherNativeProvider(
      dio,
      _PosterQualitySettingsRepository(highQuality: highQuality),
    );

Iterable<RequestOptions> _batchGets(List<RequestOptions> requests) =>
    requests.where((r) => r.uri.toString().contains('documents:batchGet'));

void main() {
  test('latest episode badge retains the exact API episode name', () async {
    const episodeName = '  الحلقة ٠٠٢.٥ &amp; <special>  ';
    final stub = _stubDio(
      _recentAlgoliaHit(episodeName: episodeName),
      homeSections: _recentHomeSectionsDocument(),
    );
    final page = await _provider(
      stub.dio,
      highQuality: false,
    ).getHomeSectionPage(_latestSectionTitle);

    expect(page.items.single.episodeBadge, episodeName);
  });

  test('list hits render Algolia posters without Firestore hydrate', () async {
    final stub = _stubDio(_algoliaHit());
    final page = await _provider(
      stub.dio,
    ).searchPage('one piece', const ProviderSearchFilters());

    expect(page.items.single.posterUrl, _smallPoster);
    expect(page.items.single.fullPosterUrl, _smallPoster);
    expect(_batchGets(stub.requests), isEmpty);
    expect(
      stub.requests.any((r) => r.uri.path.contains(':runQuery')),
      isFalse,
    );
  });

  test('a hit that already carries a large poster is used as-is', () async {
    final stub = _stubDio(
      _algoliaHit(poster: <String, dynamic>{'large': _largePoster}),
    );
    final page = await _provider(
      stub.dio,
    ).searchPage('one piece', const ProviderSearchFilters());

    expect(page.items.single.posterUrl, _largePoster);
    expect(page.items.single.fullPosterUrl, _largePoster);
    expect(page.items.single.posterViewerUrl, _largePoster);
    expect(_batchGets(stub.requests), isEmpty);
  });

  test('catalog pages do not batchGet anime_list posters', () async {
    final stub = _stubDio(_algoliaHit());
    final provider = _provider(stub.dio);

    await provider.searchPage('one piece', const ProviderSearchFilters());
    await provider.searchPage(
      'one piece',
      const ProviderSearchFilters(),
      offset: 30,
    );

    expect(_batchGets(stub.requests), isEmpty);
  });

  test('items keep their Algolia poster when Firestore is down', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          final url = options.uri.toString();
          if (url.contains('documents:batchGet')) {
            handler.reject(
              DioException(requestOptions: options, error: 'offline'),
            );
            return;
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: url.contains('algolia.net')
                  ? _algoliaHit()
                  : <String, dynamic>{},
            ),
          );
        },
      ),
    );

    final page = await _provider(
      dio,
    ).searchPage('one piece', const ProviderSearchFilters());

    expect(page.items.single.posterUrl, _smallPoster);
    expect(_batchGets(requests), isEmpty);
  });

  test(
    'cards stay on the standard poster while the viewer keeps the large one',
    () async {
      final stub = _stubDio(
        _algoliaHit(poster: <String, dynamic>{'large': _largePoster}),
      );
      final page = await _provider(
        stub.dio,
        highQuality: false,
      ).searchPage('one piece', const ProviderSearchFilters());

      final item = page.items.single;
      expect(item.posterUrl, _smallPoster);
      expect(item.fullPosterUrl, _largePoster);
      expect(item.posterViewerUrl, _largePoster);
      expect(_batchGets(stub.requests), isEmpty);
    },
  );

  test(
    'a hit that already carries a large poster still keeps cards standard',
    () async {
      final stub = _stubDio(
        _algoliaHit(poster: <String, dynamic>{'large': _largePoster}),
      );
      final page = await _provider(
        stub.dio,
        highQuality: false,
      ).searchPage('one piece', const ProviderSearchFilters());

      final item = page.items.single;
      expect(item.posterUrl, _smallPoster);
      expect(item.fullPosterUrl, _largePoster);
      expect(item.posterViewerUrl, _largePoster);
      expect(_batchGets(stub.requests), isEmpty);
    },
  );

  test(
    'the viewer prefers original artwork over large when both exist',
    () async {
      const originalPoster =
          'https://cdn.animewitcher.com/original/one_piece.jpg';
      final stub = _stubDio(
        _algoliaHit(
          poster: <String, dynamic>{
            'original': originalPoster,
            'large': _largePoster,
          },
        ),
      );
      final page = await _provider(
        stub.dio,
        highQuality: false,
      ).searchPage('one piece', const ProviderSearchFilters());

      final item = page.items.single;
      expect(item.posterUrl, _smallPoster);
      expect(item.fullPosterUrl, originalPoster);
      expect(item.posterViewerUrl, originalPoster);
    },
  );

  test(
    'details request the large poster for the viewer when cards are standard',
    () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final path = options.uri.path;
            dynamic data = <String, dynamic>{'fields': <String, dynamic>{}};
            if (path.contains('anime_list/one_piece')) {
              data = <String, dynamic>{
                'fields': <String, dynamic>{
                  'name': <String, dynamic>{'stringValue': 'ون بيس'},
                  'poster_uri': <String, dynamic>{'stringValue': _smallPoster},
                  'poster': <String, dynamic>{
                    'mapValue': <String, dynamic>{
                      'fields': <String, dynamic>{
                        'large': <String, dynamic>{'stringValue': _largePoster},
                        'medium': <String, dynamic>{
                          'stringValue': _smallPoster,
                        },
                      },
                    },
                  },
                },
              };
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: data,
              ),
            );
          },
        ),
      );

      final item = await _provider(
        dio,
        highQuality: false,
      ).getDetails('https://animewitcher.com/anime/one_piece');

      expect(item.posterUrl, _smallPoster);
      expect(item.fullPosterUrl, _largePoster);
      expect(item.posterViewerUrl, _largePoster);
    },
  );

  test(
    'latest-episode pages batchGet anime_list posters when HQ is on',
    () async {
      final stub = _stubDio(
        _recentAlgoliaHit(),
        homeSections: _recentHomeSectionsDocument(),
      );
      final page = await _provider(stub.dio).getHomeSectionPage(
        _latestSectionTitle,
      );

      expect(page.items.single.posterUrl, _largePoster);
      expect(page.items.single.fullPosterUrl, _largePoster);
      expect(page.items.single.posterUrl, isNot(_episodeStill));
      expect(page.items.single.posterUrl, isNot(_aniListPoster));
      expect(page.items.single.posterUrl, isNot(_smallPoster));

      final batchGets = _batchGets(stub.requests).toList();
      expect(batchGets, isNotEmpty);
      final documents = _batchGetDocumentIds(batchGets.first);
      expect(
        documents.single,
        endsWith('/documents/anime_list/one_piece'),
      );
      expect(
        documents.join(),
        isNot(contains('episode_doc_1100')),
      );

      final query = stub.requests.singleWhere(
        (request) => request.uri.toString().contains('algolia.net'),
      );
      final attrs = jsonDecode(
        _algoliaQueryParams(query)['attributesToRetrieve'] ?? '[]',
      ) as List<dynamic>;
      expect(attrs, contains('poster_url_aniList'));
      expect(attrs, contains('poster_uri'));
      expect(attrs, contains('anime_id'));
    },
  );

  test(
    'latest-episode cards stay on poster_uri when HQ is off',
    () async {
      final stub = _stubDio(
        _recentAlgoliaHit(),
        homeSections: _recentHomeSectionsDocument(),
      );
      final page = await _provider(
        stub.dio,
        highQuality: false,
      ).getHomeSectionPage(_latestSectionTitle);

      expect(page.items.single.posterUrl, _smallPoster);
      expect(page.items.single.posterUrl, isNot(_episodeStill));
      expect(page.items.single.posterUrl, isNot(_aniListPoster));
      expect(_batchGets(stub.requests), isEmpty);
    },
  );

  test(
    'latest-episode HQ fill uses anime_id, not the episode objectID',
    () async {
      final stub = _stubDio(
        _recentAlgoliaHit(objectId: 'ep-still-id', animeId: 'one_piece'),
        homeSections: _recentHomeSectionsDocument(),
      );
      await _provider(stub.dio).getHomeSectionPage(_latestSectionTitle);

      final documents = _batchGetDocumentIds(
        _batchGets(stub.requests).single,
      );
      expect(documents, <String>[
        'projects/animewitcher-1c66d/databases/(default)'
            '/documents/anime_list/one_piece',
      ]);
    },
  );

  test(
    'latest-episode HQ prefers poster.large over poster_url_aniList',
    () async {
      final stub = _stubDio(
        _recentAlgoliaHit(),
        homeSections: _recentHomeSectionsDocument(),
      );
      final page = await _provider(stub.dio).getHomeSectionPage(
        _latestSectionTitle,
      );

      expect(page.items.single.posterUrl, _largePoster);
      expect(page.items.single.fullPosterUrl, _largePoster);
    },
  );

  test(
    'latest-episode HQ falls back to poster_url_aniList when large is missing',
    () async {
      final stub = _stubDio(
        _recentAlgoliaHit(),
        homeSections: _recentHomeSectionsDocument(),
        batchGetResponse: <Map<String, dynamic>>[
          <String, dynamic>{'missing': <String, dynamic>{}},
        ],
      );
      final page = await _provider(stub.dio).getHomeSectionPage(
        _latestSectionTitle,
      );

      expect(page.items.single.posterUrl, _aniListPoster);
      expect(page.items.single.posterUrl, isNot(_smallPoster));
      expect(page.items.single.posterUrl, isNot(_episodeStill));
    },
  );

  test(
    'latest-episode cards never use thumb_uri as the catalog poster',
    () async {
      final stub = _stubDio(
        _recentAlgoliaHit(aniListPoster: null),
        homeSections: _recentHomeSectionsDocument(),
        batchGetResponse: <Map<String, dynamic>>[
          <String, dynamic>{'missing': <String, dynamic>{}},
        ],
      );
      final hq = await _provider(stub.dio).getHomeSectionPage(
        _latestSectionTitle,
      );
      final standard = await _provider(
        stub.dio,
        highQuality: false,
      ).getHomeSectionPage(_latestSectionTitle);

      expect(hq.items.single.posterUrl, _smallPoster);
      expect(standard.items.single.posterUrl, _smallPoster);
      expect(hq.items.single.posterUrl, isNot(_episodeStill));
      expect(standard.items.single.posterUrl, isNot(_episodeStill));
    },
  );
}
