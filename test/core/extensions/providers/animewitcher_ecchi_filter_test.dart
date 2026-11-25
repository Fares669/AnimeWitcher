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

Map<String, dynamic> _hit(
  String id, {
  required List<String> tags,
  bool isAdult = false,
  int? malId,
}) {
  return <String, dynamic>{
    'objectID': id,
    'anime_id': id,
    'name': 'Anime $id',
    'tags': tags,
    'isAdult': isAdult,
    'mal_id': ?malId,
    'poster': <String, dynamic>{'large': 'https://cdn.example.test/$id.jpg'},
  };
}

Map<String, dynamic> _animeDocument({
  required String name,
  List<String> tags = const <String>[],
  List<int> relatedMalIds = const <int>[],
}) {
  return <String, dynamic>{
    'fields': <String, dynamic>{
      'name': <String, dynamic>{'stringValue': name},
      'tags': <String, dynamic>{
        'arrayValue': <String, dynamic>{
          'values': <Map<String, dynamic>>[
            for (final tag in tags) <String, dynamic>{'stringValue': tag},
          ],
        },
      },
      'related_anime_ids': <String, dynamic>{
        'arrayValue': <String, dynamic>{
          'values': <Map<String, dynamic>>[
            for (final malId in relatedMalIds)
              <String, dynamic>{'integerValue': '$malId'},
          ],
        },
      },
    },
  };
}

Dio _stubDio({
  List<Map<String, dynamic>> searchHits = const <Map<String, dynamic>>[],
  List<Map<String, dynamic>> similarHits = const <Map<String, dynamic>>[],
  Map<String, dynamic>? animeDocument,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final uri = options.uri.toString();
        if (uri.contains('/documents/anime_list/')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data:
                  animeDocument ??
                  const <String, dynamic>{'fields': <String, dynamic>{}},
            ),
          );
          return;
        }
        if (uri.contains('series_similar')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{'hits': similarHits, 'nbPages': 1},
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{'hits': searchHits, 'nbPages': 2},
          ),
        );
      },
    ),
  );
  return dio;
}

final List<Map<String, dynamic>> _catalogHits = <Map<String, dynamic>>[
  _hit('ecchi-ar', tags: const <String>['إيتشي']),
  _hit('ecchi-en', tags: const <String>['ecchi']),
  _hit('ecchi-joined', tags: const <String>['أكشن, إيتشي']),
  _hit('adult-not-ecchi', tags: const <String>['دراما'], isAdult: true),
  _hit('normal', tags: const <String>['أكشن']),
];

AnimeWitcherNativeProvider _provider({
  required bool hideEcchi,
  Dio? dio,
  AnimeWitcherMalIdResolver? resolveAnimeByMalIds,
}) {
  return AnimeWitcherNativeProvider(
    dio ?? _stubDio(searchHits: _catalogHits),
    SettingsRepository(_TestStorageService()),
    algoliaSearchApiKey: 'synthetic-ecchi-filter-fixture',
    isEcchiHidden: () => hideEcchi,
    resolveAnimeByMalIds: resolveAnimeByMalIds,
  );
}

void main() {
  test(
    'ecchi preference filters only explicitly tagged catalog results',
    () async {
      final page = await _provider(
        hideEcchi: true,
      ).searchPage('', const ProviderSearchFilters(), limit: 10);

      expect(page.items.map((item) => item.title).toList(), <String>[
        'Anime adult-not-ecchi',
        'Anime normal',
      ]);
      expect(page.hasMore, isTrue);
      expect(page.nextOffset, 10);
    },
  );

  test('ecchi preference disabled preserves tagged catalog results', () async {
    final page = await _provider(
      hideEcchi: false,
    ).searchPage('', const ProviderSearchFilters(), limit: 10);

    expect(page.items, hasLength(5));
  });

  test('related titles honor the live ecchi preference', () async {
    final relatedHits = <int, Map<String, dynamic>>{
      11: _hit('sequel', tags: const <String>['أكشن'], malId: 11),
      12: _hit('ecchi-rel', tags: const <String>['إيتشي'], malId: 12),
      13: _hit('ecchi-en-rel', tags: const <String>['ecchi'], malId: 13),
    };
    final dio = _stubDio(
      animeDocument: _animeDocument(
        name: 'Source',
        relatedMalIds: const <int>[11, 12, 13],
      ),
    );

    Future<List<Map<String, dynamic>>> resolve(Iterable<int> ids) async {
      return [
        for (final id in ids)
          if (relatedHits.containsKey(id)) relatedHits[id]!,
      ];
    }

    final hidden = await _provider(
      hideEcchi: true,
      dio: dio,
      resolveAnimeByMalIds: resolve,
    ).getRelated('https://animewitcher.com/watch/source-anime');
    expect(hidden.map((item) => item.title).toList(), <String>['Anime sequel']);

    final visible = await _provider(
      hideEcchi: false,
      dio: dio,
      resolveAnimeByMalIds: resolve,
    ).getRelated('https://animewitcher.com/watch/source-anime');
    expect(visible.map((item) => item.title).toList(), <String>[
      'Anime sequel',
      'Anime ecchi-rel',
      'Anime ecchi-en-rel',
    ]);
  });

  test(
    'recommendations filter English and Arabic ecchi tags only when hidden',
    () async {
      final dio = _stubDio(
        animeDocument: _animeDocument(
          name: 'Source',
          tags: const <String>['أكشن'],
        ),
        similarHits: <Map<String, dynamic>>[
          _hit('source-anime', tags: const <String>['أكشن']),
          _hit('similar-ecchi', tags: const <String>['ايتشي']),
          _hit('similar-en', tags: const <String>['Ecchi']),
          _hit('similar-ok', tags: const <String>['دراما']),
        ],
      );

      final hidden = await _provider(
        hideEcchi: true,
        dio: dio,
      ).getRecommendations('https://animewitcher.com/watch/source-anime');
      expect(hidden.map((item) => item.title).toList(), <String>[
        'Anime similar-ok',
      ]);

      final visible = await _provider(
        hideEcchi: false,
        dio: dio,
      ).getRecommendations('https://animewitcher.com/watch/source-anime');
      expect(visible.map((item) => item.title).toList(), <String>[
        'Anime similar-ecchi',
        'Anime similar-en',
        'Anime similar-ok',
      ]);
    },
  );
}
