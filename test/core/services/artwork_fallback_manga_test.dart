import 'package:animewitcher/core/services/artwork_fallback_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers AniList's GraphQL endpoint with one manga per alias, and keeps
/// what it was asked.
class _AniList {
  final List<Map<String, dynamic>> bodies = <Map<String, dynamic>>[];

  Dio dio() {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final body = Map<String, dynamic>.from(options.data as Map);
          bodies.add(body);
          final variables = Map<String, dynamic>.from(
            body['variables'] as Map,
          );
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'data': <String, dynamic>{
                  for (final alias in variables.keys)
                    alias: <String, dynamic>{
                      'media': <dynamic>[
                        <String, dynamic>{
                          'bannerImage':
                              'https://anilist.test/banner-${variables[alias]}.jpg',
                          'coverImage': <String, dynamic>{
                            'large':
                                'https://anilist.test/cover-${variables[alias]}.jpg',
                          },
                        },
                      ],
                    },
                },
              },
            ),
          );
        },
      ),
    );
    return dio;
  }
}

void main() {
  test('manga artwork is asked for as MANGA, by id, in one request', () async {
    final anilist = _AniList();
    final service = ArtworkFallbackService(anilist.dio(), StorageService());

    final results = await Future.wait([
      service.mangaArtwork(malId: 147217, title: 'The World After the Fall'),
      service.mangaArtwork(title: 'The Sword Saint Reincarnated'),
    ]);

    // MyAnimeList numbers manga apart from anime: asked as an anime, this
    // id would find some unrelated show.
    expect(anilist.bodies, hasLength(1));
    final query = anilist.bodies.single['query'] as String;
    expect(query, contains('type: MANGA'));
    expect(query, isNot(contains('type: ANIME')));
    expect(query, contains('idMal'));
    expect(query, contains('search'));

    expect(results[0].banner, 'https://anilist.test/banner-147217.jpg');
    expect(results[0].cover, 'https://anilist.test/cover-147217.jpg');
    expect(
      results[1].banner,
      'https://anilist.test/banner-The Sword Saint Reincarnated.jpg',
    );
  });

  test('an answer is remembered for the next card', () async {
    final anilist = _AniList();
    final service = ArtworkFallbackService(anilist.dio(), StorageService());

    await service.mangaArtwork(malId: 555001);
    expect(service.hasResolvedManga(555001, ''), isTrue);
    expect(
      service.cachedManga(555001, '')?.cover,
      'https://anilist.test/cover-555001.jpg',
    );

    await service.mangaArtwork(malId: 555001);
    expect(anilist.bodies, hasLength(1), reason: 'the second came from cache');
  });

  test('nothing to go on asks nothing', () async {
    final anilist = _AniList();
    final service = ArtworkFallbackService(anilist.dio(), StorageService());

    final art = await service.mangaArtwork();
    expect(art.cover, isNull);
    expect(art.banner, isNull);
    expect(anilist.bodies, isEmpty);
  });
}
