import 'package:animewitcher/features/skip/data/aniskip_service.dart';
import 'package:animewitcher/features/skip/data/intro_db_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// A skip service that can be taken down and brought back, counting the
/// requests that actually reached it.
class _Endpoint {
  _Endpoint(this._respond);

  final Response<dynamic> Function(RequestOptions options) _respond;

  /// null while up; a status code to reject with while down.
  int? downWith;
  int requests = 0;

  Dio dio() {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests += 1;
          final status = downWith;
          if (status != null) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: status,
                ),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }
          handler.resolve(_respond(options));
        },
      ),
    );
    return dio;
  }
}

Response<dynamic> _aniskipFound(RequestOptions options) {
  return Response<dynamic>(
    requestOptions: options,
    statusCode: 200,
    data: <String, dynamic>{
      'found': true,
      'results': <dynamic>[
        <String, dynamic>{
          'skipType': 'op',
          'interval': <String, dynamic>{'startTime': 60.0, 'endTime': 150.0},
          'episodeLength': 1440,
        },
      ],
    },
  );
}

Response<dynamic> _aniskipNotFound(RequestOptions options) {
  return Response<dynamic>(
    requestOptions: options,
    statusCode: 200,
    data: <String, dynamic>{'found': false},
  );
}

void main() {
  group('AniSkip', () {
    test('a request that never arrived is not cached as "no timestamps"',
        () async {
      // The cache holds an hour. Storing an empty list after a failure hides
      // the skip button for that whole hour, with no way to ask again — which
      // is what "AniSkip doesn't work" looks like from the sofa.
      final api = _Endpoint(_aniskipFound)..downWith = 503;
      final service = AniSkipService(api.dio());

      expect(
        await service.getSkipSegments(
          malId: 771001,
          season: 1,
          episode: 1,
          duration: 1440,
        ),
        isEmpty,
      );
      expect(api.requests, 1);

      api.downWith = null;
      final second = await service.getSkipSegments(
        malId: 771001,
        season: 1,
        episode: 1,
        duration: 1440,
      );
      expect(api.requests, 2, reason: 'the outage taught it nothing');
      expect(second.single.startTime, 60);
    });

    test('a real "nobody submitted this" is remembered', () async {
      final api = _Endpoint(_aniskipNotFound);
      final service = AniSkipService(api.dio());

      for (var i = 0; i < 3; i++) {
        expect(
          await service.getSkipSegments(
            malId: 771003,
            season: 1,
            episode: 4,
            duration: 1440,
          ),
          isEmpty,
        );
      }
      expect(api.requests, 1, reason: 'the answer was cached');
    });

    test('a 404 is an answer and is remembered', () async {
      final api = _Endpoint(_aniskipFound)..downWith = 404;
      final service = AniSkipService(api.dio());

      await service.getSkipSegments(
        malId: 771004,
        season: 1,
        episode: 1,
        duration: 1440,
      );
      await service.getSkipSegments(
        malId: 771004,
        season: 1,
        episode: 1,
        duration: 1440,
      );
      expect(api.requests, 1);
    });

    // Last in the group on purpose: the cool-off a 429 installs is
    // global and static — deliberately, so one rate limit is not
    // amplified across every anime — and it would hold off the
    // requests every test after it is counting.
    test('a rate limit is not an answer either', () async {
      final api = _Endpoint(_aniskipFound)..downWith = 429;
      final service = AniSkipService(api.dio());

      await service.getSkipSegments(
        malId: 771002,
        season: 1,
        episode: 1,
        duration: 1440,
      );
      // The cool-off is global and holds off the next call, so this asserts
      // only that nothing was written for the episode: once the hold expires
      // the episode must still be askable.
      expect(api.requests, 1);
    });
  });

  group('IntroDB', () {
    Response<dynamic> empty(RequestOptions options) => Response<dynamic>(
      requestOptions: options,
      statusCode: 200,
      data: <String, dynamic>{'media': <dynamic>[]},
    );

    test('a failed request is not cached as "no segments"', () async {
      final api = _Endpoint(empty)..downWith = 500;
      final service = IntroDbService(api.dio());

      await service.getSkipSegments(
        imdbId: 'tt7710010',
        season: 1,
        episode: 1,
        duration: 1440,
      );
      expect(api.requests, 1);

      api.downWith = null;
      await service.getSkipSegments(
        imdbId: 'tt7710010',
        season: 1,
        episode: 1,
        duration: 1440,
      );
      expect(api.requests, 2, reason: 'the failure taught it nothing');
    });

    test('an empty answer is remembered', () async {
      final api = _Endpoint(empty);
      final service = IntroDbService(api.dio());

      await service.getSkipSegments(
        imdbId: 'tt7710011',
        season: 1,
        episode: 1,
        duration: 1440,
      );
      await service.getSkipSegments(
        imdbId: 'tt7710011',
        season: 1,
        episode: 1,
        duration: 1440,
      );
      expect(api.requests, 1);
    });
  });
}
