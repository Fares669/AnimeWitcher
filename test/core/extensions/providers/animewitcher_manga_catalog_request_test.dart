import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Storage extends StorageService {
  @override
  bool isHighQualityPostersEnabled() => false;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;
}

/// Stands in for the catalog: settings documents answer empty, the manga
/// index answers two records, and every search's parameters are kept.
Dio _server(
  List<String> searches, {
  List<Map<String, dynamic>> Function()? mangaHits,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final url = options.uri.toString();
        if (url.contains('algolia')) {
          final body = options.data;
          final params = body is Map ? '${body['params'] ?? ''}' : '$body';
          searches.add(Uri.decodeQueryComponent(params));
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'hits':
                    mangaHits?.call() ??
                    <Map<String, dynamic>>[
                      {
                        'objectID': 'b',
                        'name': 'Beta',
                        'details': {'year': '2020', 'status': 'مستمر'},
                      },
                      {
                        'objectID': 'a',
                        'name': 'Alpha',
                        'details': {'year': '2023', 'status': 'مكتمل'},
                      },
                    ],
                'nbPages': 1,
              },
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{},
          ),
        );
      },
    ),
  );
  return dio;
}

class _ReadCountingName {
  int reads = 0;

  @override
  String toString() {
    reads++;
    return 'ZZZ';
  }
}

void main() {
  test('a sorted manga search reads the catalog lean, and sorts it', () async {
    final searches = <String>[];
    final provider = AnimeWitcherNativeProvider(
      _server(searches),
      SettingsRepository(_Storage()),
      algoliaSearchApiKey: 'synthetic-catalog-fixture',
    );

    final page = await provider.searchMangaPage(
      '',
      const ProviderSearchFilters(sort: 'name_asc'),
    );

    expect(page.items.map((item) => item.title), <String>['Alpha', 'Beta']);
    final catalogRead = searches.lastWhere((s) => s.contains('hitsPerPage'));
    // Only the card's fields, and no highlighted copies of them: about a
    // seventh of the full records' size.
    expect(catalogRead, contains('attributesToHighlight=[]'));
    expect(catalogRead, contains('attributesToRetrieve='));
    expect(catalogRead, isNot(contains('story')));
    for (final field in <String>['name', 'poster', 'tags', 'details', 'type']) {
      expect(
        AnimeWitcherNativeProvider.mangaCatalogAttributes,
        contains(field),
      );
    }

    // Paging through the same search reads nothing more.
    final before = searches.length;
    await provider.searchMangaPage(
      '',
      const ProviderSearchFilters(sort: 'name_asc'),
      offset: 1,
    );
    expect(searches.length, before);
  });

  test(
    'warm pages only prepare their catalog once and still map new items',
    () async {
      final name = _ReadCountingName();
      var hits = <Map<String, dynamic>>[
        for (var i = 24; i >= 0; i--)
          {
            'objectID': '$i',
            'name': 'Manga ${i.toString().padLeft(2, '0')}',
            'tags': <String>['أكشن'],
          },
        {
          'objectID': 'z',
          'name': name,
          'tags': <String>['أكشن'],
        },
        {
          'objectID': 'h',
          'name': 'Horror',
          'tags': <String>['رعب'],
        },
      ];
      final searches = <String>[];
      final provider = AnimeWitcherNativeProvider(
        _server(searches, mangaHits: () => hits),
        SettingsRepository(_Storage()),
        algoliaSearchApiKey: 'synthetic-catalog-fixture',
      );
      final genres = <String>{'اكشن'};
      final filters = ProviderSearchFilters(sort: 'name_asc', genres: genres);
      final first = await provider.searchMangaPage(
        'sample',
        filters,
        limit: 10,
      );
      final before = searches.length;
      final preparedReads = name.reads;
      expect(preparedReads, greaterThan(0));
      expect(first.items.first.title, 'Manga 00');
      expect(first.items.last.title, 'Manga 09');
      expect(first.nextOffset, 10);
      expect(first.hasMore, isTrue);

      final next = await provider.searchMangaPage(
        'sample',
        const ProviderSearchFilters(sort: 'name_asc', genres: <String>{'أكشن'}),
        offset: first.nextOffset,
        limit: 10,
      );
      final again = await provider.searchMangaPage(
        ' SAMPLE ',
        filters,
        limit: 10,
      );
      expect(next.items.first.title, 'Manga 10');
      expect(next.items.last.title, 'Manga 19');
      expect(next.nextOffset, 20);
      expect(again.items.first.url, first.items.first.url);
      expect(identical(again.items.first, first.items.first), isFalse);
      expect(name.reads, preparedReads, reason: 'off-page keys are not reread');
      expect(searches.length, before);

      genres
        ..clear()
        ..add('رعب');
      final changed = await provider.searchMangaPage(
        'sample',
        filters,
        limit: 10,
      );
      expect(changed.items.single.title, 'Horror');
      expect(changed.nextOffset, 1);
      expect(changed.hasMore, isFalse);
      expect(searches.length, before);

      // The existing four raw-catalog entries fill and evict sample. Its old
      // prepared view must never be served for the next snapshot of that query.
      for (var i = 0; i < 4; i++) {
        await provider.searchMangaPage('separate-$i', filters, limit: 10);
      }
      hits = <Map<String, dynamic>>[
        {
          'objectID': 'new',
          'name': 'New data',
          'tags': <String>['رعب'],
        },
      ];
      final replaced = await provider.searchMangaPage(
        'sample',
        filters,
        limit: 10,
      );
      expect(replaced.items.single.title, 'New data');
    },
  );
}
