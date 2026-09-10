import 'package:animewitcher/features/skip/data/aniskip_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures what AniSkip is actually asked, and answers with two submissions
/// of the same opening timed against different releases.
class _Capture {
  final List<RequestOptions> requests = <RequestOptions>[];

  Dio dio() {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add(options);
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'found': true,
                'results': <dynamic>[
                  <String, dynamic>{
                    'skipType': 'op',
                    'interval': <String, dynamic>{
                      'startTime': 100.0,
                      'endTime': 190.0,
                    },
                    'episodeLength': 1529,
                  },
                  <String, dynamic>{
                    'skipType': 'op',
                    'interval': <String, dynamic>{
                      'startTime': 60.0,
                      'endTime': 150.0,
                    },
                    'episodeLength': 1440,
                  },
                ],
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
  test('asks for every submission, not only ones timed to this file', () async {
    // episodeLength filters rather than scales. Sending this file's own
    // length asks AniSkip for submissions timed against exactly that release
    // and gets "not found" whenever the file differs — which is most of the
    // time, and is what made skipping look broken. Zero means "all of them",
    // and the closest one is chosen here instead.
    final api = _Capture();
    final service = AniSkipService(api.dio());

    await service.getSkipSegments(
      malId: 662001,
      season: 1,
      episode: 7,
      duration: 1440,
    );

    final sent = api.requests.single;
    expect(sent.path, endsWith('/v2/skip-times/662001/7'));
    expect(
      sent.queryParameters['episodeLength'],
      0,
      reason: 'a non-zero length filters the answer down to nothing',
    );
    expect(
      sent.queryParameters['types'],
      containsAll(<String>['op', 'ed']),
    );
  });

  test('picks the submission timed closest to the file being played', () async {
    final api = _Capture();
    final service = AniSkipService(api.dio());

    final segments = await service.getSkipSegments(
      malId: 662002,
      season: 1,
      episode: 7,
      duration: 1440,
    );

    // Both submissions are the same opening; the one timed against a
    // 1529-second release would start the skip a minute and a half late.
    expect(segments, hasLength(1));
    expect(segments.single.startTime, 60);
    expect(segments.single.endTime, 150);
  });

  test('a length we never learned still asks for everything', () async {
    final api = _Capture();
    final service = AniSkipService(api.dio());

    await service.getSkipSegments(malId: 662003, season: 1, episode: 1);

    expect(api.requests.single.queryParameters['episodeLength'], 0);
  });

  test('no MyAnimeList id means no request at all', () async {
    final api = _Capture();
    final service = AniSkipService(api.dio());

    expect(
      await service.getSkipSegments(season: 1, episode: 1, duration: 1440),
      isEmpty,
    );
    expect(
      await service.getSkipSegments(
        malId: 0,
        season: 1,
        episode: 1,
        duration: 1440,
      ),
      isEmpty,
    );
    expect(api.requests, isEmpty);
  });
}
