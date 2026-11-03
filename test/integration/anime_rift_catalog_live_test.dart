import 'dart:io';

import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'authorized live Rift catalog (explicit opt-in only)',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      SharedPreferences.setMockInitialValues({});
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
      final provider = AnimeRiftProvider(
        client: AnimeRiftApiClient(config: config, dio: dio),
      );
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
      // Diagnostic counts only. Never print request headers, identity, or tokens.
      print(
        'Live catalog: ${home.length} sections, ${items.length} cards, ${episodes.length} episodes, ${search.items.length} search results.',
      );
    },
    skip: Platform.environment['ANIMERIFT_LIVE_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
