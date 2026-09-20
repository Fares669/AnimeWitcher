import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _LatestMangaFailsProvider extends AnimeWitcherProvider {
  @override
  String get packageName => 'home.latest.manga.fail';

  @override
  String get name => 'Fake';

  @override
  String get mainUrl => 'https://example.test';

  @override
  String get version => '1';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const <ProviderType>{
    ProviderType.anime,
    ProviderType.manga,
  };

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async =>
      <String, List<MultimediaItem>>{
        'الحلقات الجديدة': <MultimediaItem>[
          MultimediaItem(
            title: 'Anime survives',
            url: 'https://example.test/anime',
            posterUrl: '',
          ),
        ],
      };

  @override
  Future<MangaLatestChapterPage> getLatestMangaPage({
    int offset = 0,
    int limit = 30,
  }) async {
    throw StateError('latest manga unavailable');
  }

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const <MultimediaItem>[];

  @override
  Future<MultimediaItem> getDetails(String url) async =>
      MultimediaItem(title: 'Details', url: url, posterUrl: '');

  @override
  Future<List<StreamResult>> loadStreams(String url) async =>
      const <StreamResult>[];
}

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('latest manga failure does not fail anime home', () async {
    final provider = _LatestMangaFailsProvider();
    final container = ProviderContainer(
      overrides: [activeProviderProvider.overrideWithValue(provider)],
    );
    addTearDown(container.dispose);

    container.listen<HomeState>(homeDataProvider, (_, __) {});
    await _flush();

    final state = container.read(homeDataProvider);
    expect(state, isA<HomeSuccess>());
    final success = state as HomeSuccess;
    expect(success.data.values.expand((items) => items).single.title, 'Anime survives');
    expect(success.latestManga, isEmpty);
  });
}
