import 'package:animewitcher/core/account/animewitcher_character_models.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _configuredTestKey = 'synthetic-configured-search-only';
const _savedTestKey = 'synthetic-saved-catalog-key';
const _runtimeTestKey = 'synthetic-runtime-catalog-key';

class _Settings extends SettingsRepository {
  _Settings(this.saved) : super(StorageService());
  final Map<String, dynamic> saved;
  final writes = <Map<String, dynamic>>[];

  @override
  Map<String, dynamic> getAnimeWitcherSearchSettings() => saved;

  @override
  bool isHighQualityPostersEnabled() => false;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;

  @override
  Future<void> saveAnimeWitcherSearchSettings(
    Map<String, dynamic> value,
  ) async {
    writes.add(value);
  }
}

class _CatalogFixture {
  _CatalogFixture({
    String configuredKey = _configuredTestKey,
    Map<String, String> remote = const {},
    Map<String, dynamic> saved = const {},
  }) : settings = _Settings(saved) {
    provider = AnimeWitcherNativeProvider(
      dio,
      settings,
      algoliaSearchApiKey: configuredKey,
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final Map<String, Object?> body;
          if (options.uri.path.endsWith('/Settings/constants')) {
            body = {
              if (remote.isNotEmpty)
                'fields': {
                  'search_settings': {
                    'mapValue': {
                      'fields': {
                        for (final field in remote.entries)
                          field.key: {'stringValue': field.value},
                      },
                    },
                  },
                },
            };
          } else if (options.uri.path.endsWith('/anime_list/sample-anime')) {
            detailRequests++;
            body = {
              'fields': {
                'name': {'stringValue': 'Sample Anime'},
              },
            };
          } else if (options.uri.path.endsWith(
            '/$animeWitcherSearchServicePath',
          )) {
            body = const {};
          } else {
            expect(options.uri.host, contains('algolia'));
            requests.add(options);
            body = {
              'page': 0,
              'nbPages': 3,
              'hits': [
                if (options.uri.path.contains('/characters/'))
                  {
                    'objectID': 'sample-character',
                    'name': 'Sample Character',
                    'likes': 12,
                  }
                else
                  {'objectID': 'sample-manga', 'name': 'Sample Manga'},
              ],
            };
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: body,
            ),
          );
        },
      ),
    );
  }

  final SettingsRepository settings;
  final dio = Dio();
  late final AnimeWitcherNativeProvider provider;
  final requests = <RequestOptions>[];
  int detailRequests = 0;
}

void main() {
  _CatalogFixture fixture({
    String configured = _configuredTestKey,
    Map<String, String> remote = const {},
    Map<String, dynamic> saved = const {},
  }) {
    final f = _CatalogFixture(
      configuredKey: configured,
      remote: remote,
      saved: saved,
    );
    addTearDown(() => f.dio.close(force: true));
    return f;
  }

  test(
    'fresh service configuration wins over saved and configured keys',
    () async {
      final f = fixture(
        remote: const {'app_id': 'SYNTHAPP1', 'api_key': _runtimeTestKey},
        saved: const {'app_id': 'SYNTHAPP2', 'api_key': _savedTestKey},
      );
      final page = await f.provider.searchMangaPage(
        '',
        const ProviderSearchFilters(),
      );
      expect(page.items.single.title, 'Sample Manga');
      expect(
        f.requests.single.headers['X-Algolia-Application-Id'],
        'SYNTHAPP1',
      );
      expect(f.requests.single.headers['X-Algolia-API-Key'], _runtimeTestKey);
    },
  );

  test(
    'a saved app/key pair is used if the service has no configuration',
    () async {
      final f = fixture(
        saved: const {'app_id': 'SYNTHAPP2', 'api_key': _savedTestKey},
      );
      await f.provider.searchMangaPage('', const ProviderSearchFilters());
      expect(
        f.requests.single.headers['X-Algolia-Application-Id'],
        'SYNTHAPP2',
      );
      expect(f.requests.single.headers['X-Algolia-API-Key'], _savedTestKey);
    },
  );

  test('a key without a saved app ID does not override the fallback', () async {
    final f = fixture(saved: const {'api_key': _savedTestKey});
    await f.provider.searchMangaPage('', const ProviderSearchFilters());
    expect(f.requests.single.headers['X-Algolia-API-Key'], _configuredTestKey);
    expect((f.settings as _Settings).writes, isEmpty);
  });

  test(
    'missing or mismatched credentials fail without an Algolia request',
    () async {
      final cases = [
        fixture(configured: ' '),
        fixture(remote: const {'app_id': 'SYNTHAPP2'}),
        fixture(
          remote: const {
            'app_id': 'invalid.example',
            'api_key': _runtimeTestKey,
          },
        ),
      ];
      for (final f in cases) {
        await expectLater(
          f.provider.searchMangaPage('', const ProviderSearchFilters()),
          throwsStateError,
        );
        await expectLater(
          f.provider.searchCharacterPage('Sample'),
          throwsStateError,
        );
        expect(f.requests, isEmpty);
      }
    },
  );

  test(
    'configured search-only key retrieves a character page through query',
    () async {
      final f = fixture();
      final first = await f.provider.searchCharacterPage('  Sample  ');
      final request = f.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.path, endsWith('/indexes/characters/query'));
      expect(request.headers['X-Algolia-API-Key'], _configuredTestKey);
      final params = Uri.splitQueryString(
        (request.data as Map<String, dynamic>)['params'] as String,
      );
      expect(params['query'], 'Sample');
      expect(params['page'], '0');
      expect(params['hitsPerPage'], '$animeWitcherCharacterSearchHitsPerPage');
      expect(params['attributesToRetrieve'], contains('main_picture'));
      expect(first.items.single.id, 'sample-character');
      expect(first.items.single.name, 'Sample Character');
      expect(first.page, 0);
      expect(first.hasMore, isFalse);
      final second = await f.provider.searchCharacterPage('Sample', page: 1);
      expect(second.items, isEmpty);
      expect(second.hasMore, isFalse);
      expect(f.requests, hasLength(1));
    },
  );

  test('legacy character browse still uses the service-provided key', () async {
    final f = fixture(
      remote: const {'app_id': 'SYNTHAPP1', 'api_key': _runtimeTestKey},
    );
    final page = await f.provider.searchCharacterPage('Sample');
    expect(page.items.single.id, 'sample-character');
    final request = f.requests.single;
    expect(request.method, 'GET');
    expect(request.uri.path, endsWith('/indexes/characters/browse'));
    expect(request.headers['X-Algolia-API-Key'], _runtimeTestKey);
  });

  test('without a key, details can still load from Firestore', () async {
    final f = fixture(configured: '');
    final details = await f.provider.getDetails(
      'https://animewitcher.com/anime/sample-anime',
    );
    expect(details.title, 'Sample Anime');
    expect(f.detailRequests, 1);
    expect(f.requests, isEmpty);
  });

  test(
    'a search-only fallback is not used for an empty character browse',
    () async {
      final f = fixture();
      await expectLater(f.provider.searchCharacterPage(' '), throwsStateError);
      expect(f.requests, isEmpty);
    },
  );
}
