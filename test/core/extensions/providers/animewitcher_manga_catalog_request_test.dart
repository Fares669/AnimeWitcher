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

  @override
  Map<String, dynamic> getAnimeWitcherSearchSettings2() =>
      const <String, dynamic>{};

  @override
  Future<void> saveAnimeWitcherSearchSettings(
    Map<String, dynamic> settings,
  ) async {}

  @override
  Future<void> saveAnimeWitcherSearchSettings2(
    Map<String, dynamic> settings,
  ) async {}
}

/// Stands in for the catalog: settings documents answer empty, the manga
/// index answers two records, and every search's parameters are kept.
Dio _server(List<String> searches) {
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
                'hits': <Map<String, dynamic>>[
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

void main() {
  test('a sorted manga search reads the catalog lean, and sorts it', () async {
    final searches = <String>[];
    final provider = AnimeWitcherNativeProvider(
      _server(searches),
      SettingsRepository(_Storage()),
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
}
