import 'dart:io';

import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'authorized live character metadata schema (diagnostic, no user values)',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previous);
      SharedPreferences.setMockInitialValues({});

      final config = AnimeRiftConfig(
        firebaseApiKey: Platform.environment['ANIMERIFT_FIREBASE_API_KEY'] ?? '',
        firebaseAppId: Platform.environment['ANIMERIFT_FIREBASE_APP_ID'] ?? '',
        signingKey: Platform.environment['ANIMERIFT_JWT_SECRET'] ?? '',
      );
      expect(config.isConfigured, isTrue);
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () =>
            HttpClient()..findProxy = HttpClient.findProxyFromEnvironment,
      );
      addTearDown(() => dio.close(force: true));
      final api = AnimeRiftApiClient(config: config, dio: dio);
      final list = await api.request(
        'character/all',
        'CHARACTERS.ALL',
        query: {'searchText': 'Naruto'},
      );
      final rows = list['items'];
      expect(rows, isA<List>());
      expect(rows as List, isNotEmpty);
      final row = rows.first;
      expect(row, isA<Map>());
      final id = (row as Map)['_id'];
      expect(id, isA<String>());
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id as String), isTrue);
      final details = await api.request(
        'character/details/$id',
        'CHARACTERS.DETAILS',
      );
      expect(details, isNotEmpty);
      final nested = <String, List<String>>{};
      for (final entry in details.entries) {
        if (entry.value is Map) {
          nested[entry.key] =
              (entry.value as Map).keys.map((value) => '$value').toList()
                ..sort();
        }
      }
      final keys = details.keys.toList()..sort();
      print('Rift character details schema keys=$keys nested=$nested');
    },
    skip: Platform.environment['ANIMERIFT_LIVE_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
