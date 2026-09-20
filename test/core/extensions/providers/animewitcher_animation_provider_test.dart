import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _stringField(String value) =>
    <String, dynamic>{'stringValue': value};

Map<String, dynamic> _mapField(Map<String, dynamic> fields) =>
    <String, dynamic>{
      'mapValue': <String, dynamic>{'fields': fields},
    };

class _TestStorageService extends StorageService {
  @override
  bool isHighQualityPostersEnabled() => true;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;
}

void main() {
  test('animation search uses verified all_animation catalog', () async {
    final requests = <RequestOptions>[];
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            if (options.uri.host.contains('firestore') &&
                options.uri.path.contains('Settings/constants')) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'fields': <String, dynamic>{
                      'search_settings': _mapField(<String, dynamic>{
                        'app_id_v3': _stringField('ANIMATIONAPP'),
                        'api_key': _stringField('animation-search-key'),
                        'is_search_active': const <String, dynamic>{
                          'booleanValue': true,
                        },
                      }),
                    },
                  },
                ),
              );
              return;
            }
            if (options.uri.host.contains('algolia') &&
                options.uri.path.endsWith('/indexes/all_animation/query')) {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'hits': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'objectID': 'animation-hit-1',
                        'name': 'Animation One',
                        'type': 'فيلم',
                        'poster_uri': 'https://img.example/animation.webp',
                        'doc_ref': 'animation_list/a1',
                      },
                    ],
                    'page': 0,
                    'nbPages': 1,
                  },
                ),
              );
              return;
            }
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 404,
                data: const <String, dynamic>{},
              ),
            );
          },
        ),
      );

    final provider = AnimeWitcherNativeProvider(
      dio,
      SettingsRepository(_TestStorageService()),
    );
    final page = await provider.searchAnimationPage(
      'one',
      const ProviderSearchFilters(),
    );

    expect(page.items, hasLength(1));
    expect(page.items.single.title, 'Animation One');
    expect(page.items.single.contentType, MultimediaContentType.movie);
    expect(
      requests.any(
        (entry) => entry.uri.path.endsWith('/indexes/all_animation/query'),
      ),
      isTrue,
    );
  });
}
