import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
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
  int? malId,
}) {
  return <String, dynamic>{
    'objectID': id,
    'anime_id': id,
    'name': 'Anime $id',
    'tags': tags,
    'mal_id': ?malId,
    'poster': <String, dynamic>{'large': 'https://cdn.example.test/$id.jpg'},
  };
}

Map<String, dynamic> _relatedMapValue({
  required int malId,
  required String relationType,
  bool integerMalId = true,
}) {
  return <String, dynamic>{
    'mapValue': <String, dynamic>{
      'fields': <String, dynamic>{
        'mal_id': integerMalId
            ? <String, dynamic>{'integerValue': '$malId'}
            : <String, dynamic>{'stringValue': '$malId'},
        'relation_type': <String, dynamic>{'stringValue': relationType},
      },
    },
  };
}

Map<String, dynamic> _animeDocument({
  required String name,
  required List<Map<String, dynamic>> relatedEntries,
}) {
  return <String, dynamic>{
    'fields': <String, dynamic>{
      'name': <String, dynamic>{'stringValue': name},
      'tags': <String, dynamic>{
        'arrayValue': <String, dynamic>{
          'values': <Map<String, dynamic>>[
            <String, dynamic>{'stringValue': 'أكشن'},
          ],
        },
      },
      'related_anime_ids': <String, dynamic>{
        'arrayValue': <String, dynamic>{'values': relatedEntries},
      },
    },
  };
}

Dio _stubDio(Map<String, dynamic> animeDocument) {
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
              data: animeDocument,
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: const <String, dynamic>{'hits': <dynamic>[], 'nbPages': 1},
          ),
        );
      },
    ),
  );
  return dio;
}

AnimeWitcherNativeProvider _provider({
  required Dio dio,
  required AnimeWitcherMalIdResolver resolveAnimeByMalIds,
}) {
  return AnimeWitcherNativeProvider(
    dio,
    SettingsRepository(_TestStorageService()),
    isEcchiHidden: () => false,
    resolveAnimeByMalIds: resolveAnimeByMalIds,
  );
}

void main() {
  test('related preview hydrates 10 mal_ids and keeps a المزيد page', () async {
    final requested = <List<int>>[];
    Future<List<Map<String, dynamic>>> resolve(Iterable<int> ids) async {
      requested.add(ids.toList());
      return [
        for (final id in ids)
          _hit('rel-$id', tags: const <String>['أكشن'], malId: id),
      ];
    }

    final entries = <Map<String, dynamic>>[
      for (var index = 1; index <= 12; index++)
        _relatedMapValue(
          malId: index,
          relationType: index.isOdd ? 'sequel' : 'other',
          integerMalId: index.isOdd,
        ),
    ];
    final dio = _stubDio(
      _animeDocument(name: 'Source', relatedEntries: entries),
    );

    final preview = await _provider(
      dio: dio,
      resolveAnimeByMalIds: resolve,
    ).getRelatedPage('https://animewitcher.com/watch/source-anime');
    expect(preview.items, hasLength(10));
    expect(preview.hasMore, isTrue);
    expect(requested, hasLength(1));
    expect(requested.single, hasLength(10));

    requested.clear();
    final all = await _provider(
      dio: dio,
      resolveAnimeByMalIds: resolve,
    ).getRelatedPage(
      'https://animewitcher.com/watch/source-anime',
      includeAll: true,
    );
    expect(all.hasMore, isFalse);
    expect(all.items, hasLength(12));
    expect(requested.expand((batch) => batch).toSet(), hasLength(12));
    for (final batch in requested) {
      expect(batch.length, lessThanOrEqualTo(10));
    }
  });

  test('related posters keep APK relation labels including اخري', () async {
    Future<List<Map<String, dynamic>>> resolve(Iterable<int> ids) async {
      return [
        for (final id in ids)
          _hit('rel-$id', tags: const <String>['أكشن'], malId: id),
      ];
    }

    final dio = _stubDio(
      _animeDocument(
        name: 'Source',
        relatedEntries: <Map<String, dynamic>>[
          _relatedMapValue(malId: 1, relationType: 'prequel'),
          _relatedMapValue(malId: 2, relationType: 'sequel'),
          _relatedMapValue(malId: 3, relationType: 'parent_story'),
          _relatedMapValue(malId: 4, relationType: 'full_story'),
          _relatedMapValue(malId: 5, relationType: 'side_story'),
          _relatedMapValue(malId: 6, relationType: 'summary'),
          _relatedMapValue(malId: 7, relationType: 'other'),
        ],
      ),
    );

    final items = await _provider(
      dio: dio,
      resolveAnimeByMalIds: resolve,
    ).getRelated('https://animewitcher.com/watch/source-anime');

    expect(
      items.map((item) => item.relationLabel).toList(),
      <String>[
        'السابق',
        'التالي',
        'القصة الرئيسية',
        'القصة الرئيسية',
        'قصة جانبية',
        'ملخص',
        'اخري',
      ],
    );
  });
}
