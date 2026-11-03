import 'dart:async';
import 'dart:convert';

import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
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
  const secureChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final secureValues = <String, String>{};
  final secureCalls = <MethodCall>[];
  var rejectSecureWrites = false;
  var rejectNextSecureRead = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureValues.clear();
    secureCalls.clear();
    rejectSecureWrites = false;
    rejectNextSecureRead = false;
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      secureCalls.add(call);
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      final key = arguments['key'] as String?;
      switch (call.method) {
        case 'read':
          if (rejectNextSecureRead) {
            rejectNextSecureRead = false;
            throw PlatformException(code: 'SECURE_READ_FAILED');
          }
          return secureValues[key];
        case 'write':
          if (rejectSecureWrites) {
            throw PlatformException(code: 'SECURE_WRITE_FAILED');
          }
          secureValues[key!] = arguments['value']! as String;
          return null;
        case 'delete':
          secureValues.remove(key);
          return null;
        case 'deleteAll':
          secureValues.clear();
          return null;
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(secureChannel, null));

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

  test('code sign-in persists securely and authenticates download requests after restart', () async {
    var signIns = 0;
    var authenticatedDownloads = 0;
    var guestDownloads = 0;
    final dio = fixtureDio((o) {
      if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
      if (o.uri.path.endsWith('/auth/register/device')) {
        return reply(o, {'sessionKey': 'fixture'}, 201);
      }
      final jwt = (o.headers['integrity'] as String).substring(7).split('.');
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(jwt[1]))),
      ) as Map;
      if (o.uri.path.endsWith('/auth/sign-in/with-code')) {
        signIns++;
        expect(o.method, 'POST');
        expect(o.data, {'code': 'owner-issued-code'});
        expect(payload['scope'], 'USER.AUTH.SIGN_IN_WITH_CODE');
        expect(o.headers['authorization'], 'Bearer null');
        return reply(o, {
          'items': {
            'profile': {'_id': 'rift-user-1'},
            'token': 'fixture-user-token',
          },
        });
      }
      expect(o.uri.path, endsWith('/library/episode/source/can_play'));
      expect(o.method, 'POST');
      expect((o.data as Map)['is_download'], isTrue);
      if (o.headers['authorization'] == 'Bearer fixture-user-token') {
        authenticatedDownloads++;
      } else if (o.headers['authorization'] == 'Bearer null') {
        guestDownloads++;
      } else {
        fail('unexpected Rift authorization header');
      }
      return reply(o, {'sessionId': 'download-session'});
    });

    final first = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
    await first.signInWithCode('  owner-issued-code  ');
    expect(first.isAccountLinked, isTrue);
    await first.request(
      'library/episode/source/can_play',
      'ANIME.LIBRARY.EPISODES.SOURCES.CHECK_AVAILABILITY',
      method: 'POST',
      body: {'is_download': true},
    );

    final restarted = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
    expect(restarted.isAccountLinked, isFalse);
    expect(await restarted.restoreAccountSession(), isTrue);
    await restarted.request(
      'library/episode/source/can_play',
      'ANIME.LIBRARY.EPISODES.SOURCES.CHECK_AVAILABILITY',
      method: 'POST',
      body: {'is_download': true},
    );
    expect(secureValues.values.single, contains('fixture-user-token'));

    await restarted.signOut();
    await restarted.request(
      'library/episode/source/can_play',
      'ANIME.LIBRARY.EPISODES.SOURCES.CHECK_AVAILABILITY',
      method: 'POST',
      body: {'is_download': true},
    );

    expect(signIns, 1);
    expect(authenticatedDownloads, 2);
    expect(guestDownloads, 1);
    expect(secureValues, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    final plainValues = prefs
        .getKeys()
        .map((key) => prefs.get(key).toString())
        .join();
    expect(plainValues, isNot(contains('fixture-user-token')));
  });

  test(
    'invalid sign-in input is rejected before any network request',
    () async {
      var calls = 0;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          calls++;
          return reply(o, {});
        }),
      );

      for (final code in [
        '',
        '   ',
        'bad\ncode',
        List.filled(257, 'x').join(),
      ]) {
        await expectLater(client.signInWithCode(code), throwsArgumentError);
      }
      const privateCode = 'private\n-code';
      try {
        await client.signInWithCode(privateCode);
        fail('invalid code must be rejected');
      } on ArgumentError catch (error) {
        expect(error.toString(), isNot(contains('private-code')));
      }
      expect(calls, 0);
      expect(secureValues, isEmpty);
    },
  );

  test(
    'malformed sign-in response never persists or activates a token',
    () async {
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
          if (o.uri.path.endsWith('/auth/register/device')) {
            return reply(o, {}, 201);
          }
          return reply(o, {
            'items': {'profile': <String, dynamic>{}},
          });
        }),
      );

      await expectLater(
        client.signInWithCode('valid-code'),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
      expect(client.isAccountLinked, isFalse);
      expect(secureValues, isEmpty);
      expect(secureCalls.where((call) => call.method == 'write'), isEmpty);
    },
  );

  test(
    'secure write failure does not leave an in-memory or plaintext session',
    () async {
      rejectSecureWrites = true;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
          if (o.uri.path.endsWith('/auth/register/device')) {
            return reply(o, {}, 201);
          }
          return reply(o, {
            'items': {
              'profile': {'_id': 'rift-user-1'},
              'token': 'must-not-survive',
            },
          });
        }),
      );

      await expectLater(
        client.signInWithCode('valid-code'),
        throwsA(isA<AnimeRiftSecureStorageUnavailable>()),
      );
      expect(client.isAccountLinked, isFalse);
      expect(secureValues, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().map((key) => prefs.get(key).toString()).join(),
        isNot(contains('must-not-survive')),
      );
    },
  );

  test('sign-out deletes only the Rift credential key', () async {
    final client = AnimeRiftApiClient(
      config: fixtureConfig,
      dio: fixtureDio((o) {
        if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
        if (o.uri.path.endsWith('/auth/register/device')) {
          return reply(o, {}, 201);
        }
        return reply(o, {
          'items': {
            'profile': {'_id': 'rift-user-1'},
            'token': 'fixture-user-token',
          },
        });
      }),
    );
    await client.signInWithCode('valid-code');
    secureCalls.clear();

    await client.signOut();

    expect(client.isAccountLinked, isFalse);
    expect(secureValues, isEmpty);
    expect(secureCalls.map((call) => call.method), ['delete']);
    final arguments = Map<Object?, Object?>.from(
      secureCalls.single.arguments as Map,
    );
    expect(arguments['key'], 'animerift.user.session.v1');
  });

  test('a transient secure read failure can be retried explicitly', () async {
    final dio = fixtureDio((o) {
      if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
      if (o.uri.path.endsWith('/auth/register/device')) {
        return reply(o, {}, 201);
      }
      return reply(o, {
        'items': {
          'profile': {'_id': 'rift-user-1'},
          'token': 'fixture-user-token',
        },
      });
    });
    await AnimeRiftApiClient(
      config: fixtureConfig,
      dio: dio,
    ).signInWithCode('valid-code');
    final restarted = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
    rejectNextSecureRead = true;

    await expectLater(
      restarted.restoreAccountSession(),
      throwsA(isA<AnimeRiftSecureStorageUnavailable>()),
    );
    expect(await restarted.restoreAccountSession(), isTrue);
    expect(restarted.isAccountLinked, isTrue);
  });
}
