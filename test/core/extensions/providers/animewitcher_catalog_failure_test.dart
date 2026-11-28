import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestStorageService extends StorageService {
  @override
  bool isHighQualityPostersEnabled() => true;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;
}

AnimeWitcherNativeProvider _provider(Dio dio) =>
    AnimeWitcherNativeProvider(
      dio,
      SettingsRepository(_TestStorageService()),
      algoliaSearchApiKey: 'synthetic-catalog-failure-fixture',
    );

Dio _catalogDio({
  required int Function() homeSectionStatus,
  Map<String, dynamic>? homeSections,
  Map<String, dynamic>? algoliaPayload,
  int Function()? algoliaStatus,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final path = options.uri.path;
        if (path.contains('Settings/home_sections')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: homeSectionStatus(),
              data: homeSections ?? const <String, dynamic>{},
            ),
          );
          return;
        }
        if (options.uri.host.contains('algolia.net')) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode:
                  algoliaStatus?.call() ?? (algoliaPayload == null ? 503 : 200),
              data: algoliaPayload ?? const <String, dynamic>{},
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: options.method == 'POST' ? 503 : 200,
            data: const <String, dynamic>{},
          ),
        );
      },
    ),
  );
  return dio;
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

Map<String, dynamic> _algoliaHits() {
  return <String, dynamic>{
    'hits': <Map<String, dynamic>>[
      <String, dynamic>{
        'objectID': 'offline-retry',
        'anime_id': 'offline-retry',
        'name': 'Retry Anime',
      },
    ],
    'nbPages': 1,
  };
}

void main() {
  test(
    'search page reports catalog transport failure instead of empty results',
    () async {
      await expectLater(
        _provider(
          _catalogDio(homeSectionStatus: () => 200),
        ).searchPage('test', const ProviderSearchFilters()),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'home reports unavailable section configuration instead of blank success',
    () async {
      await expectLater(
        _provider(_catalogDio(homeSectionStatus: () => 200)).getHome(),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'failed home configuration is not cached so retry can succeed',
    () async {
      var homeSectionRequests = 0;
      final provider = _provider(
        _catalogDio(
          homeSectionStatus: () {
            homeSectionRequests += 1;
            return homeSectionRequests == 1 ? 503 : 200;
          },
          homeSections: _homeSectionsDocument(),
          algoliaPayload: _algoliaHits(),
        ),
      );

      await expectLater(provider.getHome(), throwsA(isA<StateError>()));

      final home = await provider.getHome();
      expect(homeSectionRequests, 2);
      expect(home['Latest'], isNotNull);
      expect(home['Latest']!.first.title, 'Retry Anime');
    },
  );

  test('failed search is not sticky so retry can succeed', () async {
    var algoliaCalls = 0;
    final provider = _provider(
      _catalogDio(
        homeSectionStatus: () => 200,
        algoliaPayload: _algoliaHits(),
        algoliaStatus: () {
          algoliaCalls += 1;
          return algoliaCalls == 1 ? 503 : 200;
        },
      ),
    );

    await expectLater(
      provider.searchPage('test', const ProviderSearchFilters()),
      throwsA(isA<StateError>()),
    );

    provider.prepareForNetworkRetry();
    final page = await provider.searchPage(
      'test',
      const ProviderSearchFilters(),
    );
    expect(algoliaCalls, 2);
    expect(page.items, isNotEmpty);
    expect(page.items.first.title, 'Retry Anime');
  });
}
