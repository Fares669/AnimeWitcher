import 'dart:io';

import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Read-only protocol probe for real gateway data. Prints only schema keys,
/// response counts and statuses, never anime/user IDs, text or credentials.
/// CI secrets belong to the workflow environment, not to this test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real comment listing contract — opt-in read-only diagnostic', () async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final config = AnimeRiftConfig(
      firebaseApiKey: Platform.environment['ANIMERIFT_FIREBASE_API_KEY'] ?? '',
      firebaseAppId: Platform.environment['ANIMERIFT_FIREBASE_APP_ID'] ?? '',
      signingKey: Platform.environment['ANIMERIFT_JWT_SECRET'] ?? '',
    );
    expect(config.isConfigured, isTrue);
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)))
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () =>
            HttpClient()..findProxy = HttpClient.findProxyFromEnvironment,
      );
    addTearDown(() => dio.close(force: true));
    final client = AnimeRiftApiClient(config: config, dio: dio);
    final provider = AnimeRiftProvider(client: client);
    var tested = 0;
    for (final title in const ['Naruto', 'One Piece']) {
      final search = await provider.searchPage(
        title,
        const ProviderSearchFilters(),
      );
      expect(search.items, isNotEmpty);
      final id = Uri.parse(search.items.first.url).pathSegments.last;
      final detail = await client.request(
        'library/details/$id',
        'ANIME.LIBRARY.DETAILS',
      );
      final row = detail['item'];
      final knownCount = row is Map
          ? row['comments_count'] ??
                row['commentsCount'] ??
                row['comment_count']
          : null;
      final commentFlags = row is Map
          ? row.entries
                .where(
                  (e) =>
                      e.key.toString().toLowerCase().contains('comment') &&
                      (e.value is bool || e.value is num),
                )
                .map((e) => '${e.key}=${e.value}')
                .toList()
          : <String>[];
      print(
        'COMMENTS_DIAGNOSTIC title_index=$tested detail_comment_count=${knownCount is num ? knownCount : "absent"} flags=$commentFlags',
      );
      const variants = <String, Map<String, Object>>{
        'current': {'page': 0, 'level': 0, 'canReply': '1'},
        'no_level': {'page': 0, 'canReply': '1'},
        'level_one': {'page': 0, 'level': 1, 'canReply': '1'},
        'page_one': {'page': 1, 'level': 0, 'canReply': '1'},
        'no_can_reply': {'page': 0, 'level': 0},
      };
      final probes = <String, Map<String, Object>>{
        ...variants,
        if (tested == 0) ...{
          'bare_anime': {},
          'sort_date': {
            'page': 0,
            'level': 0,
            'canReply': '1',
            'sort_by': 'date',
          },
          'sort_created': {
            'page': 0,
            'level': 0,
            'canReply': '1',
            'sort_by': 'createdAt',
          },
          'sort_top': {
            'page': 0,
            'level': 0,
            'canReply': '1',
            'sort_by': 'top',
          },
          'event_target': {'page': 0, 'level': 0, 'canReply': '1'},
          'global': {'page': 0},
        },
      };
      for (final entry in probes.entries) {
        try {
          final response = await client.request(
            'comment/all',
            'COMMENTS.VIEW',
            query: {
              if (entry.key != 'global' && entry.key != 'event_target')
                'animeId': id,
              if (entry.key == 'event_target') 'eventId': id,
              ...entry.value,
            },
          );
          final outer = response['items'];
          final items = outer is List
              ? outer
              : outer is Map
              ? outer['items']
              : null;
          final keys = outer is Map
              ? outer.keys.map((e) => e.toString()).toList()
              : <String>[];
          print(
            'COMMENTS_DIAGNOSTIC variant=${entry.key} count=${items is List ? items.length : -1} root_keys=${response.keys.toList()} envelope_keys=$keys',
          );
        } on AnimeRiftAccessUnavailable catch (error) {
          print(
            'COMMENTS_DIAGNOSTIC variant=${entry.key} status=${error.statusCode} failure=${error.failure?.name}',
          );
        }
      }
      tested++;
    }
    expect(tested, 2);
  });
}
