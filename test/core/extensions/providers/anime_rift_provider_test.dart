import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Rift is identifiable and does not claim manga support', () {
    final provider = AnimeRiftProvider();
    expect(provider.packageName, animeRiftProviderId);
    expect(provider.supportedTypes, {ProviderType.anime});
  });

  test(
    'unavailable authorization fails closed for catalog and playback',
    () async {
      final provider = AnimeRiftProvider();
      await expectLater(
        provider.getHome(),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
      await expectLater(
        provider.search('test'),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
      await expectLater(
        provider.getDetails('id'),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
      await expectLater(
        provider.loadStreams('episode'),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
    },
  );
}
