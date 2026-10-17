import 'package:animewitcher/features/skip/data/intro_db_service.dart';
import 'package:animewitcher/features/skip/data/skip_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses v4 and reads TVDB-keyed segments with a TMDB request', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'tvdb_id': 121361,
                'type': 'tv',
                'season': 2,
                'episode': 3,
                'intro': [
                  {'start_ms': 1000, 'end_ms': 91000},
                ],
                'credits': [
                  {'start_ms': 1300000, 'end_ms': null},
                ],
              },
            ),
          );
        },
      ),
    );

    final segments = await IntroDbService(dio)
        .getSkipSegments(tmdbId: 880001, season: 2, episode: 3, duration: 1400);

    expect(requests.single.uri.origin, 'https://api.theintrodb.org');
    expect(requests.single.uri.path, '/v4/media');
    expect(requests.single.queryParameters, {
      'tmdb_id': 880001,
      'season': 2,
      'episode': 3,
    });
    expect(segments.map((s) => s.type), [SkipType.intro, SkipType.outro]);
    expect(segments.first.startTime, 1);
    expect(segments.first.endTime, 91);
    expect(segments.last.endTime, 1400);
  });

  test(
    'movies omit TV coordinates and do not reuse a TV cache entry',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(options);
            final movie = !options.queryParameters.containsKey('season');
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'tvdb_id': 169,
                  'type': movie ? 'movie' : 'tv',
                  'intro': [
                    {'start_ms': 0, 'end_ms': movie ? 23000 : 90000},
                  ],
                },
              ),
            );
          },
        ),
      );
      final service = IntroDbService(dio);
      await service.getSkipSegments(tmdbId: 880002, season: 1, episode: 1);
      final List<SkipSegment> movie = await service.getSkipSegments(
        tmdbId: 880002,
        season: null,
        episode: null,
      );
      await service.getSkipSegments(
        tmdbId: 880002,
        season: null,
        episode: null,
      );
      expect(
        requests.length,
        2,
        reason: 'movie and TV have separate cache entries',
      );
      expect(requests.last.queryParameters, {'tmdb_id': 880002});
      expect(movie.single.endTime, 23);
    },
  );

  test('IMDb requests preserve specials numbering', () async {
    RequestOptions? request;
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          request = options;
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {'tvdb_id': 71663, 'type': 'tv', 'episodes': <dynamic>[]},
            ),
          );
        },
      ),
    );
    final segments = await IntroDbService(dio)
        .getSkipSegments(imdbId: 'tt8800003', season: 0, episode: 0);
    expect(request!.queryParameters, {
      'imdb_id': 'tt8800003',
      'season': 0,
      'episode': 0,
    });
    expect(segments, isEmpty);
  });

  test('incomplete TV coordinates never turn into a movie request', () async {
    final requests = <RequestOptions>[];
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<Map<String, dynamic>>(
              requestOptions: options,
              statusCode: 200,
              data: {},
            ),
          );
        },
      ),
    );
    final service = IntroDbService(dio);
    expect(
      await service.getSkipSegments(tmdbId: 880004, season: null, episode: 1),
      isEmpty,
    );
    expect(
      await service.getSkipSegments(tmdbId: 880004, season: 1, episode: null),
      isEmpty,
    );
    expect(requests, isEmpty);
  });
}
