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
  String? airingOverride;
  final airing = DateTime.now().toUtc().add(const Duration(days: 1));
  Map<String, dynamic>? lastQuery;
  Map<String, dynamic>? lastBody;
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
    lastBody = body;
    if (path == 'library/tags')
      return {
        'items': [
          {'id': 'tag42', 'label': 'بطل مضاد'},
        ],
      };
    if (path == 'library/genres')
      return {
        'items': [
          {'id': 'genre42', 'label': 'أكشن'},
        ],
      };
    if (path == 'library/schedule')
      return {
        'schedule': [
          {
            'dayName': 'monday',
            'animes': [
              {
                'anime': anime,
                'localBroadcastTime': '18:30',
                'localBroadcastTimeInt': 1830,
                'episodeNumber': 7,
                'airingDate': airingOverride ?? airing.toIso8601String(),
              },
            ],
          },
        ],
      };
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
          '_related': [
            {'_anime': '42', 'relation_type': 'sequel'},
          ],
          'genreLabels': [
            {'label': 'Action'},
          ],
        },
        'others': {
          'recommendations': [anime],
          'related': [anime],
          'characters': [
            {
              '_id': 'char1',
              'name': 'Naruto',
              'image_jpg_url': 'https://images.example/char.jpg',
              'likes': 12,
            },
          ],
        },
      };
    if (path == 'library/episodes/42')
      return {
        'items': [
          {'_id': 'ep2', 'episode_number': 2},
          {
            '_id': 'ep1',
            'episode_number': 1,
            'is_filler': true,
            'title_translations': {'ar': 'البداية'},
          },
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
    'tags use their own backend IDs and share bounded filter metadata requests',
    () async {
      final api = CatalogFixture();
      final provider = AnimeRiftProvider(client: api);
      final options = await Future.wait([
        provider.getSearchFilterOptions(),
        provider.getSearchFilterOptions(),
      ]);
      expect(options.first.tags, ['بطل مضاد']);
      expect(api.calls.where((p) => p == 'library/tags'), hasLength(1));
      expect(api.calls.where((p) => p == 'library/genres'), hasLength(1));
      await provider.searchPage(
        '',
        const ProviderSearchFilters(tags: {'بطل مضاد'}),
      );
      expect(api.lastBody!['multi_tags'], ['tag42']);
      expect(api.lastBody!.containsKey('multi_genres'), isFalse);
      await expectLater(
        provider.searchPage(
          '',
          const ProviderSearchFilters(tags: {'وسم مجهول'}),
        ),
        throwsUnsupportedError,
      );
    },
  );

  for (final date in [
    '2000-01-01T00:00:00Z',
    '2099-01-01T00:00:00',
    'invalid-date',
  ]) {
    test('next airing omits past or ambiguous server date: $date', () async {
      final api = CatalogFixture()..airingOverride = date;
      expect(
        await AnimeRiftProvider(client: api)
            .getNextAiring('https://anime-rift.com/anime/42'),
        isNull,
      );
    });
  }

  test(
    'next airing uses the matching title and an explicit server UTC date',
    () async {
      final api = CatalogFixture();
      final provider = AnimeRiftProvider(client: api);
      final next = await provider.getNextAiring(
        'https://anime-rift.com/anime/42',
      );
      expect(next?.episode, 7);
      expect(next?.unixTime, api.airing.millisecondsSinceEpoch ~/ 1000);
      expect(
        await provider.getNextAiring('https://anime-rift.com/anime/other'),
        isNull,
      );
      expect(api.calls.where((p) => p == 'library/schedule'), hasLength(1));
    },
  );
  test(
    'related title keeps the server relationship without changing its identity',
    () async {
      final provider = AnimeRiftProvider(client: CatalogFixture());
      final related = (await provider.getRelated(
        'https://anime-rift.com/anime/42',
      )).single;
      expect(related.relationType, 'SEQUEL');
      expect(related.relationLabel, 'التالي');
      expect(related.url, 'https://anime-rift.com/anime/42');
    },
  );

  test(
    'schedule maps actual backend weekday and retains source identity',
    () async {
      final api = CatalogFixture();
      final provider = AnimeRiftProvider(client: api);
      expect(provider.supportsBroadcastSchedule, isTrue);
      final page = await provider.getBroadcastSchedulePage('الإثنين', limit: 1);
      expect(page.items.single.provider, animeRiftProviderId);
      expect(page.items.single.episodeBadge, contains('18:30'));
      expect(page.items.single.episodeBadge, contains('7'));
      expect(page.hasMore, isFalse);
      expect((await provider.getBroadcastSchedulePage('الأحد')).items, isEmpty);
      expect(api.calls.where((p) => p == 'library/schedule'), hasLength(1));
    },
  );
  test(
    'season browser uses server-side year and season filters with page cursors',
    () async {
      final api = CatalogFixture();
      final provider = AnimeRiftProvider(client: api);
      expect(provider.supportsSeasons, isTrue);
      final config = await provider.getSeasonConfig();
      expect(
        config.current,
        matches(RegExp(r'^(شتاء|ربيع|صيف|خريف) عام \d{4}$')),
      );
      final page = await provider.getSeasonPage('شتاء عام 2024', offset: 2);
      expect(api.lastBody!['multi_seasons'], ['winter']);
      expect(api.lastBody!['multi_release_year'], ['2024']);
      expect(api.lastQuery!['page'], 2);
      expect(page.nextOffset, 3);
    },
  );
  test('filters map UI labels to backend enums and genre identities', () async {
    final api = CatalogFixture();
    final provider = AnimeRiftProvider(client: api);
    final options = await provider.getSearchFilterOptions();
    expect(options.genres, ['أكشن']);
    expect(options.seasons, contains('شتاء'));
    await provider.searchPage(
      '',
      const ProviderSearchFilters(
        genres: {'أكشن'},
        years: {'2024'},
        seasons: {'شتاء'},
        statuses: {'مستمر'},
        types: {'فيلم'},
        ageRatings: {'+13'},
        sort: 'year_desc',
      ),
    );
    expect(api.lastBody, {
      'query': '',
      'multi_genres': ['genre42'],
      'multi_release_year': ['2024'],
      'multi_seasons': ['winter'],
      'multi_release_status': ['on_going'],
      'multi_content_types': ['movie'],
      'multi_age_rating': ['pg_13'],
    });
    expect(api.lastQuery!['sort_direction'], -1);
    expect(api.calls.where((p) => p == 'library/genres'), hasLength(1));
    await expectLater(
      provider.searchPage(
        '',
        const ProviderSearchFilters(genres: {'غير موجود'}),
      ),
      throwsUnsupportedError,
    );
  });

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
      expect((await provider.getCast(details.url)).single.name, 'Naruto');
      expect(
        (await provider.getRelated(details.url)).single.provider,
        animeRiftProviderId,
      );
      expect(episodes.first.name, 'البداية');
      expect(episodes.first.isFiller, isTrue);
      expect(api.calls.where((p) => p == 'library/details/42'), hasLength(1));
      final count = api.calls.length;
      await expectLater(
        provider.getDetails('https://attacker.invalid/anime/42'),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
      expect(api.calls.length, count);
    },
  );
}
