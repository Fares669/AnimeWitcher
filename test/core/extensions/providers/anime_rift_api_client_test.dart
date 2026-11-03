import 'dart:async';
import 'dart:convert';

import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const fixtureConfig = AnimeRiftConfig(
  firebaseApiKey: 'fixture-firebase-key',
  firebaseAppId: '1:123456:android:fixture',
  signingKey: 'fixture-signing-key',
);

Dio fixtureDio(FutureOr<Response<dynamic>> Function(RequestOptions) respond) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (o, h) async {
        try {
          h.resolve(await respond(o));
        } catch (e) {
          h.reject(DioException(requestOptions: o, error: e));
        }
      },
    ),
  );
  return dio;
}

Response<dynamic> reply(RequestOptions o, dynamic data, [int status = 200]) =>
    Response(requestOptions: o, data: data, statusCode: status);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'concurrent catalog calls share registration and scoped signing',
    () async {
      var registrations = 0;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          if (o.uri.host.endsWith('googleapis.com')) {
            expect(o.headers.containsKey('integrity'), isFalse);
            expect(o.headers['x-goog-api-key'], fixtureConfig.firebaseApiKey);
            return reply(o, {'error': {}}, 400);
          }
          final jwt = (o.headers['integrity'] as String)
              .substring(7)
              .split('.');
          final payload = jsonDecode(
            utf8.decode(base64Url.decode(base64Url.normalize(jwt[1]))),
          ) as Map;
          final expected = base64Url
              .encode(
                Hmac(
                  sha256,
                  utf8.encode(fixtureConfig.signingKey),
                ).convert(utf8.encode('${jwt[0]}.${jwt[1]}')).bytes,
              )
              .replaceAll('=', '');
          expect(jwt[2], expected);
          expect((payload['exp'] as int) - (payload['iat'] as int), 60);
          expect(o.headers.containsKey('x-goog-api-key'), isFalse);
          expect(o.followRedirects, isFalse);
          if (o.uri.path.endsWith('/auth/register/device')) {
            registrations++;
            expect(payload['scope'], 'USER.AUTH.DEVICE.REGISTER');
            return reply(o, {'sessionKey': 'fixture-session'}, 201);
          }
          expect(payload['scope'], 'ANIME.LIBRARY.HOME_CONTENT');
          return reply(o, {'sections': []});
        }),
      );
      await Future.wait(
        List.generate(
          3,
          (_) => client.request(
            'library/home_content',
            'ANIME.LIBRARY.HOME_CONTENT',
          ),
        ),
      );
      expect(registrations, 1);
    },
  );

  test(
    'successful Firebase initialization selects only an allowed gateway',
    () async {
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          if (o.uri.host == 'firebaseinstallations.googleapis.com') {
            expect(o.uri.path, '/v1/projects/123456/installations');
            return reply(o, {
              'fid': 'real-fixture-installation',
              'authToken': {'token': 'fixture-fis-token'},
            });
          }
          if (o.uri.host == 'firebaseremoteconfig.googleapis.com') {
            expect(
              o.headers['X-Goog-Firebase-Installations-Auth'],
              'fixture-fis-token',
            );
            return reply(o, {
              'entries': {
                'anime_rift_android_gateway_base_url_v4':
                    'https://attacker.invalid/api/v4',
              },
            });
          }
          expect(o.uri.host, 'gateway.embrassme.top');
          expect(o.headers['x-firebase-id'], 'real-fixture-installation');
          return reply(
            o,
            o.uri.path.endsWith('/auth/register/device')
                ? {'sessionKey': 'fixture'}
                : {'items': []},
            o.uri.path.endsWith('/auth/register/device') ? 201 : 200,
          );
        }),
      );
      await client.request(
        'library/home_content',
        'ANIME.LIBRARY.HOME_CONTENT',
      );
    },
  );

  test(
    'restart reuses identity without persisting signing or session tokens',
    () async {
      final identities = <String>[];
      final dio = fixtureDio((o) {
        if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
        if (o.uri.path.endsWith('/auth/register/device')) {
          identities.add((o.data as Map)['deviceId'] as String);
          return reply(o, {'sessionKey': 'must-not-persist'}, 201);
        }
        return reply(o, {});
      });
      for (var i = 0; i < 2; i++) {
        await AnimeRiftApiClient(
          config: fixtureConfig,
          dio: dio,
        ).request('library/home_content', 'ANIME.LIBRARY.HOME_CONTENT');
      }
      expect(identities, hasLength(2));
      expect(identities.first, identities.last);
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getKeys().map((k) => prefs.get(k).toString()).join();
      expect(stored, isNot(contains('must-not-persist')));
      expect(stored, isNot(contains(fixtureConfig.signingKey)));
    },
  );

  test(
    'access errors are bounded and do not expose response or credentials',
    () async {
      var requests = 0;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
          requests++;
          return reply(o, {
            'errorCode': 'ACCESS_DENIED',
            'echo': 'sensitive-server-body',
          }, 403);
        }),
      );
      try {
        await client.request(
          'library/home_content',
          'ANIME.LIBRARY.HOME_CONTENT',
        );
        fail('must reject denied registration');
      } on AnimeRiftAccessUnavailable catch (e) {
        expect(e.toString(), isNot(contains('sensitive-server-body')));
        expect(e.toString(), isNot(contains(fixtureConfig.signingKey)));
      }
      expect(requests, 1);
    },
  );

  test(
    'canceled catalog and unsafe paths make no registration request',
    () async {
      var calls = 0;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          calls++;
          return reply(o, {});
        }),
      );
      final cancel = CancelToken()..cancel();
      await expectLater(
        client.request(
          'library/home_content',
          'ANIME.LIBRARY.HOME_CONTENT',
          cancelToken: cancel,
        ),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        client.request('https://attacker.invalid/', 'scope'),
        throwsArgumentError,
      );
      expect(calls, 0);
    },
  );
}
