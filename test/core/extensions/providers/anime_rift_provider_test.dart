import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';

void main() {
  test(
    'missing build configuration fails before any network operation',
    () async {
      var calls = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (o, h) {
              calls++;
              h.reject(DioException(requestOptions: o));
            },
          ),
        );
      final provider = AnimeRiftProvider(
        client: AnimeRiftApiClient(
          config: const AnimeRiftConfig(
            firebaseApiKey: '',
            firebaseAppId: '',
            signingKey: '',
          ),
          dio: dio,
        ),
      );
      await expectLater(
        provider.getHome(),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
      await expectLater(
        provider.search('test'),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
      await expectLater(
        provider.getDetails('https://anime-rift.com/anime/42'),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
      expect(calls, 0);
    },
  );
  test(
    'Rift remains anime-only and unavailable playback is explicit',
    () async {
      final provider = AnimeRiftProvider();
      expect(provider.packageName, animeRiftProviderId);
      expect(provider.supportedTypes, {ProviderType.anime});
      await expectLater(
        provider.loadStreams('episode'),
        throwsA(isA<AnimeRiftPlaybackUnavailable>()),
      );
    },
  );
}
