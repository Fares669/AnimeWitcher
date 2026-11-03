import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:dio/dio.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:flutter_test/flutter_test.dart';

class CatalogFixture extends AnimeRiftApiClient {
  CatalogFixture()
    : super(
        config: const AnimeRiftConfig(
          firebaseApiKey: 'fixture',
          firebaseAppId: 'fixture',
          signingKey: 'fixture',
        ),
      );
  final calls = <String>[];
  Map<String, dynamic>? lastQuery;
  @override
  Future<Map<String, dynamic>> request(
    String path,
    String scope, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    calls.add(path);
    lastQuery = query;
    if (path == 'library/home_content')
      return {
        'sections': [
          {
            'sectionTitle': 'الأحدث',
            'items': [anime],
          },
        ],
      };
    if (path == 'library/search')
      return {
        'items': [anime],
        'hasNext': query?['page'] == 0,
      };
    if (path == 'library/details/42')
      return {
        'item': {
          ...anime,
          'synopsis': 'Description',
          'genreLabels': [
            {'label': 'Action'},
          ],
        },
        'others': {
          'recommendations': [anime],
        },
      };
    if (path == 'library/episodes/42')
      return {
        'items': [
          {'_id': 'ep2', 'episode_number': 2},
          {'_id': 'ep1', 'episode_number': 1},
        ],
      };
    throw StateError('Unexpected path');
  }

  static const anime = {
    '_id': '42',
    'title': 'Fixture anime',
    'main_picture': 'https://images.example/42.jpg',
    'release_year': 2026,
    'myAnimeList_rating': 8.5,
  };
}

void main() {
  test(
    'configured home uses gateway data with source-qualified catalog URLs',
    () async {
      final api = CatalogFixture();
      final home = await AnimeRiftProvider(client: api).getHome();
      expect(home['الأحدث']!.single.provider, animeRiftProviderId);
      expect(home['الأحدث']!.single.url, 'https://anime-rift.com/anime/42');
      expect(api.calls, ['library/home_content']);
    },
  );
  test(
    'search uses backend page cursor rather than assuming a page size',
    () async {
      final api = CatalogFixture();
      final provider = AnimeRiftProvider(client: api);
      final first = await provider.searchPage(
        'fixture',
        const ProviderSearchFilters(),
      );
      expect(first.items.single.title, 'Fixture anime');
      expect(first.nextOffset, 1);
      expect(first.hasMore, isTrue);
      final next = await provider.searchPage(
        'fixture',
        const ProviderSearchFilters(),
        offset: first.nextOffset,
      );
      expect(api.lastQuery!['page'], 1);
      expect(next.hasMore, isFalse);
    },
  );
  test(
    'details and lazy episodes resolve catalog identity and stable ordering',
    () async {
      final api = CatalogFixture();
      final provider = AnimeRiftProvider(client: api);
      final details = await provider.getDetails(
        'https://anime-rift.com/anime/42',
      );
      expect(details.description, 'Description');
      expect(details.tags, ['Action']);
      expect(details.episodes, isNull);
      final episodes = await provider.getEpisodes(details.url);
      expect(episodes.map((e) => e.episode), [1, 2]);
      expect(episodes.first.url, 'https://anime-rift.com/anime/42/episode/ep1');
      expect(
        (await provider.getRecommendations(details.url)).single.provider,
        animeRiftProviderId,
      );
      final count = api.calls.length;
      await expectLater(
        provider.getDetails('https://attacker.invalid/anime/42'),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
      expect(api.calls.length, count);
    },
  );
}
