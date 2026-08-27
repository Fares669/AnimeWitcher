import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _hit(
  String id, {
  required List<String> tags,
  bool isAdult = false,
}) {
  return <String, dynamic>{
    'objectID': id,
    'anime_id': id,
    'name': 'Anime $id',
    'tags': tags,
    'isAdult': isAdult,
    'poster': <String, dynamic>{
      'large': 'https://cdn.example.test/$id.jpg',
    },
  };
}

Dio _stubDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{
              'hits': <Map<String, dynamic>>[
                _hit('ecchi-ar', tags: const <String>['إيتشي']),
                _hit('ecchi-en', tags: const <String>['ecchi']),
                _hit('adult-not-ecchi', tags: const <String>['دراما'], isAdult: true),
                _hit('normal', tags: const <String>['أكشن']),
              ],
              'nbPages': 2,
            },
          ),
        );
      },
    ),
  );
  return dio;
}

AnimeWitcherNativeProvider _provider({required bool hideEcchi}) {
  return AnimeWitcherNativeProvider(
    _stubDio(),
    SettingsRepository(StorageService()),
    isEcchiHidden: () => hideEcchi,
  );
}

void main() {
  test('ecchi preference filters only explicitly tagged catalog results',
      () async {
    final page = await _provider(hideEcchi: true).searchPage(
      '',
      const ProviderSearchFilters(),
      limit: 10,
    );

    expect(page.items.map((item) => item.title).toList(), <String>[
      'Anime adult-not-ecchi',
      'Anime normal',
    ]);
    expect(page.hasMore, isTrue);
    expect(page.nextOffset, 10);
  });

  test('ecchi preference disabled preserves tagged catalog results', () async {
    final page = await _provider(hideEcchi: false).searchPage(
      '',
      const ProviderSearchFilters(),
      limit: 10,
    );

    expect(page.items, hasLength(4));
  });
}
