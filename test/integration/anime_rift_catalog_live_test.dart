import 'dart:io';

import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'guest secure storage fixture restores without a native keychain',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final api = AnimeRiftApiClient(config: const AnimeRiftConfig());
      expect(await api.restoreAccountSession(), isFalse);
    },
  );

  test(
    'authorized live Rift catalog (explicit opt-in only)',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      SharedPreferences.setMockInitialValues({});
      // Widget-test runners have no platform keychain. Keep this a guest test:
      // the empty mock session exercises the real authentication gate without
      // mistaking a missing OS secure-storage plugin for a CDN failure.
      FlutterSecureStorage.setMockInitialValues({});
      final config = AnimeRiftConfig(
        firebaseApiKey:
            Platform.environment['ANIMERIFT_FIREBASE_API_KEY'] ?? '',
        firebaseAppId: Platform.environment['ANIMERIFT_FIREBASE_APP_ID'] ?? '',
        signingKey: Platform.environment['ANIMERIFT_JWT_SECRET'] ?? '',
      );
      expect(
        config.isConfigured,
        isTrue,
        reason: 'Live test configuration is required.',
      );
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () =>
            HttpClient()..findProxy = HttpClient.findProxyFromEnvironment,
      );
      addTearDown(() => dio.close(force: true));
      final api = AnimeRiftApiClient(config: config, dio: dio);
      final provider = AnimeRiftProvider(client: api);
      final homeResponse = await api.request(
        'library/home_content',
        'ANIME.LIBRARY.HOME_CONTENT',
        query: {'with_genres': true},
      );
      expect(homeResponse['sections'], isA<List>());
      for (final section
          in (homeResponse['sections'] as List).whereType<Map>()) {
        // Public catalog descriptors only: no item values, URLs or headers.
        // These identify the actual section contract before adding pagination.
        final keys = section.keys.map((key) => key.toString()).toList()..sort();
        final descriptors = <String, Object>{};
        for (final key in const [
          'sectionTitle',
          'sectionId',
          'sectionType',
          'type',
          'id',
          'sort_by',
          'sort_direction',
          'hasNext',
          'page',
          'limit',
        ]) {
          final value = section[key];
          if (value is num ||
              value is bool ||
              (value is String &&
                  value.length <= 120 &&
                  !value.contains('://'))) {
            descriptors[key] = value as Object;
          }
        }
        print('Live home section schema: keys=$keys descriptors=$descriptors');
      }
      for (final filter in {
        'multi_content_types': ['tv', 'movie', 'ova', 'ona', 'special'],
        'multi_release_status': ['on_going', 'finished'],
        'multi_age_rating': ['g', 'pg_13', 'r'],
        'multi_seasons': ['winter', 'spring', 'summer', 'fall'],
      }.entries) {
        final field = {
          'multi_content_types': 'content_type',
          'multi_release_status': 'release_status',
          'multi_age_rating': 'ageRating',
          'multi_seasons': 'realease_season',
        }[filter.key]!;
        for (final value in filter.value) {
          final response = await api.request(
            'library/search',
            'ANIME.LIBRARY.SEARCH',
            method: 'POST',
            body: {
              'query': '',
              filter.key: [value],
            },
            query: {
              'page': 0,
              'sort_by': 'release_year',
              'sort_direction': -1,
              'text_direction': 'jp',
            },
          );
          final rows = response['items'] as List;
          expect(
            rows,
            isNotEmpty,
            reason: '${filter.key}=$value must have verifiable results',
          );
          expect(
            rows.every((dynamic row) => row[field] == value),
            isTrue,
            reason: '${filter.key}=$value must actually filter results',
          );
        }
      }
      final home = await provider.getHome();
      final items = home.values.expand((items) => items).toList();
      expect(items, isNotEmpty);
      final details = await provider.getDetails(items.first.url);
      expect(details.provider, provider.packageName);
      final episodes = await provider.getEpisodes(details.url);
      final search = await provider.searchPage(
        'Naruto',
        const ProviderSearchFilters(sort: 'year_asc'),
      );
      expect(search.items, isNotEmpty);
      final second = await provider.searchPage(
        'Naruto',
        const ProviderSearchFilters(sort: 'year_desc'),
      );
      expect(second.items, isNotEmpty);
      final ascendingYears = search.items
          .map((item) => item.year)
          .whereType<int>()
          .toList();
      final descendingYears = second.items
          .map((item) => item.year)
          .whereType<int>()
          .toList();
      final sortedAscending = [...ascendingYears]..sort();
      final sortedDescending = [...descendingYears]
        ..sort((a, b) => b.compareTo(a));
      expect(
        ascendingYears,
        sortedAscending,
        reason: 'Verify server ascending year order',
      );
      expect(
        descendingYears,
        sortedDescending,
        reason: 'Verify server descending year order',
      );
      final schedule = await provider.getBroadcastSchedulePage('الثلاثاء');
      expect(schedule.items, isNotEmpty);
      expect(
        schedule.items.every((item) => item.provider == provider.packageName),
        isTrue,
      );
      final season = await provider.getSeasonPage('شتاء عام 2024');
      expect(season.items, isNotEmpty);
      expect(season.items.every((item) => item.year == 2024), isTrue);
      expect(await provider.getCast(search.items.first.url), isNotEmpty);
      expect(await provider.getRelated(search.items.first.url), isNotEmpty);
      final scheduleData = await api.request(
        'library/schedule',
        'ANIME.LIBRARY.SCHEDULE',
      );
      final futureRows = <Map<String, dynamic>>[];
      for (final dynamic day in scheduleData['schedule'] as List) {
        for (final dynamic row in day['animes'] as List) {
          final date = DateTime.tryParse(row['airingDate'] as String);
          if (date != null && date.isAfter(DateTime.now()))
            futureRows.add(Map<String, dynamic>.from(row as Map));
        }
      }
      futureRows.sort(
        (a, b) =>
            (a['airingDate'] as String).compareTo(b['airingDate'] as String),
      );
      expect(futureRows, isNotEmpty);
      final futureRow = futureRows.first;
      final next = await provider.getNextAiring(
        'https://anime-rift.com/anime/${(futureRow['anime'] as Map)['_id']}',
      );
      expect(next?.episode, futureRow['episodeNumber']);
      expect(
        next?.unixTime,
        DateTime.parse(futureRow['airingDate'] as String)
                .millisecondsSinceEpoch ~/
            1000,
      );
      final genreRows =
          (await api.request(
                'library/genres',
                'ANIME.LIBRARY.FILTERS.GENRES',
              ))['items']
              as List;
      final chosenGenre = genreRows.first as Map;
      final genrePage = await provider.searchPage(
        '',
        ProviderSearchFilters(genres: {chosenGenre['label'] as String}),
      );
      expect(genrePage.items, isNotEmpty);
      final genreDetails = await api.request(
        'library/details/${Uri.parse(genrePage.items.first.url).pathSegments.last}',
        'ANIME.LIBRARY.DETAILS',
      );
      final assignedGenres =
          (genreDetails['item'] as Map)['genreLabels'] as List;
      expect(
        assignedGenres.any((dynamic genre) => genre['id'] == chosenGenre['id']),
        isTrue,
        reason: 'The genre identifier must constrain the returned catalog, not just appear in the request.',
      );
      final tagRows =
          (await api.request(
                'library/tags',
                'ANIME.LIBRARY.FILTERS.TAGS',
              ))['items']
              as List;
      final chosenTag = tagRows.first as Map<dynamic, dynamic>;
      final tagPage = await provider.searchPage(
        '',
        ProviderSearchFilters(tags: {chosenTag['label'] as String}),
      );
      expect(tagPage.items, isNotEmpty);
      final tagDetails = await api.request(
        'library/details/${Uri.parse(tagPage.items.first.url).pathSegments.last}',
        'ANIME.LIBRARY.DETAILS',
      );
      final assignedTags =
          (tagDetails['item'] as Map<dynamic, dynamic>)['tagsLabels'] as List;
      expect(
        assignedTags.any((dynamic tag) => tag['id'] == chosenTag['id']),
        isTrue,
        reason: 'The tag filter must constrain the returned catalog.',
      );
      final options = await provider.getSearchFilterOptions();
      expect(options.genres, isNotEmpty);
      expect(options.tags, isNotEmpty);
      final characterResponse = await api.request(
        'character/all',
        'CHARACTERS.ALL',
        query: {'searchText': 'Naruto'},
      );
      final characterRows = characterResponse['items'];
      expect(characterRows, isA<List>());
      expect(characterRows as List, isNotEmpty);
      final firstCharacter = Map<String, dynamic>.from(
        characterRows.first as Map,
      );
      final characterResponseKeys = characterResponse.keys.toList()..sort();
      final characterKeys = firstCharacter.keys.toList()..sort();
      // Schema names are safe diagnostics; never log row values or headers.
      print(
        'Live character schema: response=$characterResponseKeys item=$characterKeys',
      );
      final characterId = firstCharacter['_id'];
      expect(characterId, isA<String>());
      final characterDetailsResponse = await api.request(
        'character/details/$characterId',
        'CHARACTERS.DETAILS',
      );
      final characterDetailsResponseKeys =
          characterDetailsResponse.keys.toList()..sort();
      final characterDetailsNestedKeys = <String, List<String>>{};
      for (final entry in characterDetailsResponse.entries) {
        final value = entry.value;
        if (value is Map<dynamic, dynamic>) {
          characterDetailsNestedKeys[entry.key] =
              value.keys.map((key) => key.toString()).toList(growable: false)
                ..sort();
        }
      }
      // Schema names are safe diagnostics; never log row values or headers.
      print(
        'Live character details schema: response=$characterDetailsResponseKeys nested=$characterDetailsNestedKeys',
      );
      expect(characterDetailsResponse, isNotEmpty);
      final filtered = await provider.searchPage(
        '',
        const ProviderSearchFilters(years: {'2024'}),
      );
      expect(filtered.items, isNotEmpty);
      expect(filtered.items.every((item) => item.year == 2024), isTrue);
      final naruto = search.items.first;
      final narutoEpisodes = await provider.getEpisodes(naruto.url);
      expect(narutoEpisodes, isNotEmpty);
      final sources = await provider.loadStreamSources(
        narutoEpisodes.first.url,
      );
      expect(sources, isNotEmpty);
      final selected = sources.firstWhere(
        (s) => s.source.toLowerCase().contains('cr2'),
      );
      final streams = await provider.loadStreams(selected.url);
      expect(streams, hasLength(1));
      expect(streams.single.requiresResolution, isFalse);
      expect(streams.single.refreshUrl, selected.url);
      final media = await dio.get<ResponseBody>(
        streams.single.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {...?streams.single.headers, 'Range': 'bytes=0-1023'},
          receiveTimeout: const Duration(seconds: 20),
          followRedirects: false,
        ),
      );
      expect(media.statusCode, 206);
      var sampled = 0;
      await for (final chunk in media.data!.stream) {
        sampled += chunk.length;
        if (sampled >= 1024) break;
      }
      expect(sampled, 1024);
      expect(media.headers.value('content-type'), contains('video/'));
      final downloadSources = await provider.loadDownloadStreamSources(
        narutoEpisodes.first.url,
      );
      expect(downloadSources, isNotEmpty);
      await expectLater(
        provider.loadDownloadStreams(downloadSources.first.url),
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
        reason: 'Anonymous download access currently requires Rift sign-in.',
      );
      print(
        'Live source resolution and CDN Range verified; download sign-in gate verified.',
      );
      // Diagnostic counts only. Never print request headers, identity, or tokens.
      print(
        'Live catalog: ${home.length} sections, ${items.length} cards, ${episodes.length} episodes, ${search.items.length} search results.',
      );
    },
    skip: Platform.environment['ANIMERIFT_LIVE_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
