import 'package:animewitcher/features/skip/data/mal_id_resolver.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reading a MyAnimeList id out of each service', () {
    test('AniList answers with idMal', () {
      expect(
        MalIdParsers.aniList({
          'data': {
            'Media': {'idMal': 21},
          },
        }),
        21,
      );
    });

    test('AniList being disabled is not an id', () {
      // What the service actually returned the day this was written.
      expect(
        MalIdParsers.aniList({
          'errors': [
            {'message': 'The AniList API has been temporarily disabled'},
          ],
          'data': null,
        }),
        isNull,
      );
    });

    test('Kitsu mappings are searched for the MAL one', () {
      // Kitsu lists several sites and its ids are strings, so the right
      // entry has to be picked by name and parsed.
      expect(
        MalIdParsers.kitsuMappings({
          'data': [
            {
              'attributes': {'externalSite': 'anidb', 'externalId': '69'},
            },
            {
              'attributes': {
                'externalSite': 'myanimelist/anime',
                'externalId': '21',
              },
            },
          ],
        }),
        21,
      );
    });

    test('Kitsu without a MAL mapping is not an id', () {
      expect(
        MalIdParsers.kitsuMappings({
          'data': [
            {
              'attributes': {'externalSite': 'thetvdb', 'externalId': '81797'},
            },
          ],
        }),
        isNull,
      );
    });

    test('the Kitsu hit is the one whose title matches', () {
      // Kitsu's own answer to "Mao": five unrelated shows, none of them the
      // anime. Taking the first would resolve another anime's id and skip
      // into the episode with its timings.
      const body = {
        'data': [
          {
            'id': '45412',
            'attributes': {'canonicalTitle': 'Mao Zhi Ming'},
          },
          {
            'id': '5956',
            'attributes': {'canonicalTitle': 'Lan Mao'},
          },
          {
            'id': '50035',
            'attributes': {'canonicalTitle': 'MAO'},
          },
        ],
      };
      expect(MalIdParsers.kitsuMatchingId(body, 'Mao'), '50035');
      expect(MalIdParsers.kitsuMatchingId(body, 'Frieren'), isNull);
      expect(
        MalIdParsers.kitsuMatchingId({'data': <dynamic>[]}, 'Mao'),
        isNull,
      );
    });

    test('a long enough prefix is a match, a short one is not', () {
      const body = {
        'data': [
          {
            'id': '49689',
            'attributes': {
              'canonicalTitle':
                  'Futsutsuka na Akujo de wa Gozaimasu ga Hinamiya Chou '
                  'Nezumi Torikae Den',
            },
          },
          {
            'id': '45412',
            'attributes': {'canonicalTitle': 'Mao Zhi Ming'},
          },
        ],
      };
      // The series name is enough of a prefix to identify the show.
      expect(
        MalIdParsers.kitsuMatchingId(
          body,
          'Futsutsuka na Akujo dewa '
          'Gozaimasu ga',
        ),
        '49689',
      );
      // Three letters are not, however well they line up.
      expect(MalIdParsers.kitsuMatchingId(body, 'Mao'), isNull);
    });

    test('a match ignores case, spacing and punctuation', () {
      const body = {
        'data': [
          {
            'id': '1',
            'attributes': {
              'canonicalTitle': 'Re:Zero kara Hajimeru',
              'titles': {'en': 'Re Zero Kara Hajimeru'},
            },
          },
        ],
      };
      expect(MalIdParsers.kitsuMatchingId(body, 're zero kara hajimeru'), '1');
    });

    test('Kitsu answers with an AniList id when it has no MAL one', () {
      // Newer shows are mapped to AniList but not to MyAnimeList, and
      // ani.zip bridges the two.
      const body = {
        'data': [
          {
            'attributes': {
              'externalSite': 'anilist/anime',
              'externalId': '196012',
            },
          },
        ],
      };
      expect(MalIdParsers.kitsuMappings(body), isNull);
      expect(MalIdParsers.kitsuAniListId(body), 196012);
    });

    test('ani.zip answers with mal_id', () {
      expect(
        MalIdParsers.aniZip({
          'mappings': {'anilist_id': 196012, 'mal_id': 62048},
        }),
        62048,
      );
      expect(MalIdParsers.aniZip({'mappings': <String, dynamic>{}}), isNull);
    });

    test('Jikan answers with mal_id', () {
      expect(
        MalIdParsers.jikan({
          'data': [
            {'mal_id': 21, 'title': 'One Piece'},
          ],
        }),
        21,
      );
    });

    test('a Jikan outage is not an id', () {
      // Jikan reports MyAnimeList being unreachable as a 504 body.
      expect(
        MalIdParsers.jikan({
          'status': 504,
          'message': 'Jikan failed to connect to MyAnimeList',
        }),
        isNull,
      );
    });

    test('zero and rubbish are not ids', () {
      for (final body in <Object>[
        {
          'data': {
            'Media': {'idMal': 0},
          },
        },
        {
          'data': {'Media': null},
        },
        <String, dynamic>{},
      ]) {
        expect(MalIdParsers.aniList(body), isNull);
      }
    });
  });

  group('the titles a search tries', () {
    test('starts with the title as given', () {
      expect(MalIdResolver.titleVariants('One Piece').first, 'One Piece');
    });

    test('falls back to the part before a subtitle', () {
      // The services spell the second half differently often enough that the
      // whole string finds nothing while the series name finds the series.
      expect(
        MalIdResolver.titleVariants(
          'Futsutsuka na Akujo dewa Gozaimasu ga: Suuguu Chouso Torikae Den',
        ),
        contains('Futsutsuka na Akujo dewa Gozaimasu ga'),
      );
    });

    test('drops a trailing season marker', () {
      expect(
        MalIdResolver.titleVariants('Mushoku Tensei III'),
        contains('Mushoku Tensei'),
      );
      expect(
        MalIdResolver.titleVariants('Spy x Family Season 2'),
        contains('Spy x Family'),
      );
      expect(
        MalIdResolver.titleVariants('Bleach 2nd Season'),
        contains('Bleach'),
      );
    });

    test('never repeats a variant', () {
      final variants = MalIdResolver.titleVariants('Frieren');
      expect(variants, ['Frieren']);
    });

    test('keeps variants long enough to search with', () {
      // "Re:Zero" must not be cut down to "Re".
      expect(MalIdResolver.titleVariants('Re:Zero'), ['Re:Zero']);
    });
  });

  group('normalising a catalog title', () {
    test('drops the release noise in brackets', () {
      expect(
        MalIdResolver.normalizeTitle('One Piece (TV) [1080p]'),
        'One Piece',
      );
    });

    test('leaves a clean title alone', () {
      expect(MalIdResolver.normalizeTitle('  Frieren  '), 'Frieren');
    });
  });

  group('resolveForItem and AniDB fallback', () {
    test('prefers direct malId, then resolves anidbId via ani.zip, then alternative title', () async {
      final requestedPaths = <String>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestedPaths.add('${options.uri.host}${options.path}?${options.queryParameters}');
            if (options.uri.host == 'api.ani.zip' &&
                options.queryParameters['anidb_id'] == 69) {
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'mappings': <String, dynamic>{'mal_id': 21},
                  },
                ),
              );
              return;
            }
            if (options.uri.host == 'graphql.anilist.co') {
              final search = (options.data as Map)['variables']['search'];
              handler.resolve(
                Response<Map<String, dynamic>>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'data': <String, dynamic>{
                      'Media': search == 'Overgeared'
                          ? <String, dynamic>{'idMal': 59999}
                          : null,
                    },
                  },
                ),
              );
              return;
            }
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{'data': <dynamic>[]},
              ),
            );
          },
        ),
      );

      final resolver = MalIdResolver(dio);

      expect(
        await resolver.resolveForItem(
          syncData: const {'malId': '21', 'anidbId': '69'},
          title: 'ون بيس',
        ),
        21,
      );
      expect(requestedPaths, isEmpty);

      expect(
        await resolver.resolveForItem(
          syncData: const {'anidbId': '69'},
          title: 'ون بيس',
        ),
        21,
      );
      expect(requestedPaths.single, contains('anidb_id: 69'));

      expect(
        await resolver.resolveForItem(
          title: 'العنوان العربي غير المعروف',
          alternativeTitles: const ['Overgeared'],
        ),
        59999,
      );
    });
  });
}
