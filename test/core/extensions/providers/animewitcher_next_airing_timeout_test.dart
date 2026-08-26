import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/network/next_airing_timeout.dart';
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

AnimeWitcherNativeProvider _provider(Dio dio) =>
    AnimeWitcherNativeProvider(dio, SettingsRepository(_TestStorageService()));

Dio _hangingDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        // Never complete: this is the offline / dead-server hang.
      },
    ),
  );
  return dio;
}

Dio _airingDio({required int unixTime}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{
              'fields': <String, dynamic>{
                'name': const <String, dynamic>{'stringValue': 'Test Anime'},
                'nextEpTimeInSec': <String, dynamic>{
                  'integerValue': '$unixTime',
                },
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
  return dio;
}

void main() {
  test(
    'getNextAiring gives up after 2s when the server never answers',
    () async {
      final provider = _provider(_hangingDio());
      final stopwatch = Stopwatch()..start();
      final result = await provider.getNextAiring(
        'https://animewitcher.com/anime/offline-title',
      );
      stopwatch.stop();

      expect(result, isNull);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(
          nextAiringFetchTimeout - const Duration(milliseconds: 200),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 6)),
  );

  test('getNextAiring still returns a reachable countdown', () async {
    final unixTime =
        DateTime.now()
            .toUtc()
            .add(const Duration(hours: 6))
            .millisecondsSinceEpoch ~/
        1000;
    final provider = _provider(_airingDio(unixTime: unixTime));
    final result = await provider.getNextAiring(
      'https://animewitcher.com/anime/online-title',
    );

    expect(result, isNotNull);
    expect(result!.unixTime, unixTime);
  });
}
