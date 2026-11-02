import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/features/details/presentation/stream_source_prefetch.dart';
import 'package:animewitcher/features/player/presentation/player_controller_base.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Source extends AnimeWitcherProvider {
  _Source(this.id);

  final String id;
  final requestedEpisodes = <String>[];

  @override
  String get packageName => id;
  @override
  String get name => id;
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};
  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const [];
  @override
  Future<MultimediaItem> getDetails(String url) async =>
      MultimediaItem(title: 'Show', url: url, posterUrl: '');
  @override
  Future<List<StreamResult>> loadStreamSources(String url) async {
    requestedEpisodes.add(url);
    return const [];
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async => const [];
}

MultimediaItem _item(String? provider) => MultimediaItem(
  title: 'Saved Anime Rift show',
  url: 'https://rift.test/show',
  posterUrl: '',
  provider: provider,
);

void main() {
  test(
    'player resolves an Anime Rift item even with AnimeWitcher active',
    () async {
      final witcher = _Source('com.animewitcher.provider');
      final rift = _Source(animeRiftProviderId);

      final selected = resolvePlaybackItemProvider(_item(animeRiftProviderId), [
        witcher,
        rift,
      ], witcher);
      expect(selected, same(rift));

      // Next-episode prefetch must use this item-bound provider too.
      final prefetch = StreamSourcePrefetch();
      await prefetch.sources(selected!, 'https://rift.test/episode-2');
      expect(rift.requestedEpisodes, ['https://rift.test/episode-2']);
      expect(witcher.requestedEpisodes, isEmpty);
    },
  );

  test(
    'missing explicit Anime Rift provider never falls back to AnimeWitcher',
    () {
      final witcher = _Source('com.animewitcher.provider');

      expect(
        resolvePlaybackItemProvider(_item(animeRiftProviderId), [
          witcher,
        ], witcher),
        isNull,
      );
    },
  );

  test('legacy untagged media still uses the active provider', () {
    final witcher = _Source('com.animewitcher.provider');
    expect(
      resolvePlaybackItemProvider(_item(null), [witcher], witcher),
      same(witcher),
    );
  });
}
