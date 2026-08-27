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

({Dio dio, List<RequestOptions> requests}) _stubDio() {
  final requests = <RequestOptions>[];
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests.add(options);
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{
              'fields': <String, dynamic>{
                'name': const <String, dynamic>{'stringValue': 'Refresh Title'},
                'details': <String, dynamic>{
                  'mapValue': <String, dynamic>{
                    'fields': <String, dynamic>{
                      'state': const <String, dynamic>{'stringValue': 'مستمر'},
                    },
                  },
                },
              },
            },
          ),
        );
      },
    ),
  );
  return (dio: dio, requests: requests);
}

int _animeDocumentHits(List<RequestOptions> requests, String animeId) {
  return requests
      .where((options) => options.uri.path.contains('anime_list/$animeId'))
      .length;
}

void main() {
  const url = 'https://animewitcher.com/anime/refresh-title';

  test('detail cache is reused until pull-to-refresh invalidates it', () async {
    final stub = _stubDio();
    final provider = AnimeWitcherNativeProvider(
      stub.dio,
      SettingsRepository(_TestStorageService()),
    );

    final first = await provider.getDetails(url);
    final afterFirst = _animeDocumentHits(stub.requests, 'refresh-title');
    expect(first.title, 'Refresh Title');
    expect(afterFirst, greaterThan(0));

    await provider.getDetails(url);
    expect(
      _animeDocumentHits(stub.requests, 'refresh-title'),
      afterFirst,
      reason: 'A second details load should reuse the in-memory cache',
    );

    provider.invalidateDetailCaches(url);
    final refreshed = await provider.getDetails(url);
    expect(refreshed.title, 'Refresh Title');
    expect(
      _animeDocumentHits(stub.requests, 'refresh-title'),
      greaterThan(afterFirst),
      reason: 'Pull-to-refresh must hit the server again',
    );
  });
}
