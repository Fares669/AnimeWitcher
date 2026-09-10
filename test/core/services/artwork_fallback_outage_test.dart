import 'package:animewitcher/core/services/artwork_fallback_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers AniList's GraphQL endpoint, either with a cover or with the kind of
/// failure an outage produces.
class _AniList {
  _AniList({required this.covers});

  final Map<int, String> covers;
  bool down = false;
  int requests = 0;

  Dio dio() {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests += 1;
          if (down) {
            handler.reject(
              DioException(
                requestOptions: options,
                response: Response<dynamic>(
                  requestOptions: options,
                  statusCode: 403,
                ),
                type: DioExceptionType.badResponse,
              ),
            );
            return;
          }
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'data': <String, dynamic>{
                  'Page': <String, dynamic>{
                    'media': <dynamic>[
                      for (final entry in covers.entries)
                        <String, dynamic>{
                          'idMal': entry.key,
                          'coverImage': <String, dynamic>{
                            'extraLarge': entry.value,
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
  test('an outage is not remembered as "this anime has no artwork"', () async {
    // AniList returned 403 for a spell while this app was being built, and a
    // phone losing signal for a second does the same thing. Every card on
    // screen asks in one batch, so one failure decides the answer for fifty
    // titles at once.
    const malId = 987001;
    final anilist = _AniList(covers: <int, String>{
      malId: 'https://anilist.test/cover-$malId.jpg',
    })..down = true;
    final service = ArtworkFallbackService(anilist.dio(), StorageService());

    expect(await service.posterFor(malId), isNull, reason: 'nothing to show');
    // AniList, then AniZip and Kitsu for what it did not answer — all of them
    // rejected while the connection is down.
    final duringOutage = anilist.requests;
    expect(duringOutage, greaterThanOrEqualTo(1));

    anilist.down = false;
    expect(
      await service.posterFor(malId),
      'https://anilist.test/cover-$malId.jpg',
      reason: 'the lookup never got an answer, so it must be asked again',
    );
    expect(
      anilist.requests,
      greaterThan(duringOutage),
      reason: 'a second look actually went out',
    );
  });

  test('a real "not found" is remembered, and asked only once', () async {
    // AniList answered and simply does not carry this one. That is a fact
    // worth keeping: without it every card showing the title asks again.
    const malId = 987002;
    final anilist = _AniList(covers: const <int, String>{});
    final service = ArtworkFallbackService(anilist.dio(), StorageService());

    expect(await service.posterFor(malId), isNull);
    expect(await service.posterFor(malId), isNull);
    // AniList answered once; AniZip and Kitsu are then asked for the few it
    // did not know, which is why this is not a strict equality on 1.
    final afterFirst = anilist.requests;
    expect(await service.posterFor(malId), isNull);
    expect(
      anilist.requests,
      afterFirst,
      reason: 'the miss was cached, so nothing was asked again',
    );
  });

  test('a title lookup that never completed is retried too', () async {
    const title = 'An Outage Title 987003';
    final anilist = _AniList(covers: const <int, String>{})..down = true;
    final service = ArtworkFallbackService(anilist.dio(), StorageService());

    expect(await service.posterForTitle(title), isNull);
    final afterOutage = anilist.requests;

    anilist.down = false;
    await service.posterForTitle(title);
    expect(
      anilist.requests,
      greaterThan(afterOutage),
      reason: 'the failed title batch must not count as a miss',
    );
  });
}
