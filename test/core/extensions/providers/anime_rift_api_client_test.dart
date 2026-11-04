import 'dart:async';
import 'dart:convert';

import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
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
  Completer<void>? delayedSecureRead;
  Completer<void>? delayedSecureWrite;
  Completer<void>? secureWriteStarted;
  Completer<void>? delayedSecureDelete;
  Completer<void>? secureDeleteStarted;

  setUp(() {
    AnimeRiftLocalAccountScope.reset();
    SharedPreferences.setMockInitialValues({});
    secureValues.clear();
    secureCalls.clear();
    rejectSecureWrites = false;
    rejectNextSecureRead = false;
    delayedSecureRead = null;
    delayedSecureWrite = null;
    secureWriteStarted = null;
    delayedSecureDelete = null;
    secureDeleteStarted = null;
    messenger.setMockMethodCallHandler(secureChannel, (call) async {
      secureCalls.add(call);
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      final key = arguments['key'] as String?;
      switch (call.method) {
        case 'read':
          final delay = delayedSecureRead;
          if (delay != null) await delay.future;
          if (rejectNextSecureRead) {
            rejectNextSecureRead = false;
            throw PlatformException(code: 'SECURE_READ_FAILED');
          }
          return secureValues[key];
        case 'write':
          if (secureWriteStarted != null && !secureWriteStarted!.isCompleted) {
            secureWriteStarted!.complete();
          }
          final writeGate = delayedSecureWrite;
          if (writeGate != null) await writeGate.future;
          if (rejectSecureWrites) {
            throw PlatformException(code: 'SECURE_WRITE_FAILED');
          }
          secureValues[key!] = arguments['value']! as String;
          return null;
        case 'delete':
          if (secureDeleteStarted != null && !secureDeleteStarted!.isCompleted) {
            secureDeleteStarted!.complete();
          }
          final deleteGate = delayedSecureDelete;
          if (deleteGate != null) await deleteGate.future;
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

  test('AOT overview items counters retain the seven recovered keys', () {
    expect(
      parseMyListOverviewCounts({
        'items': <String, dynamic>{
          'my_list_favorites': 4,
          'my_list_currently_watching': '12',
          'my_list_plan_to_watch': 0,
          'my_list_finished_watching': 3,
          'my_list_on_hold': 2,
          'my_list_dropped': 1,
          'favorite_characters_count': 8,
          'unrecognized_metric': 99,
        },
      }),
      {
        'my_list_favorites': 4,
        'my_list_currently_watching': 12,
        'my_list_plan_to_watch': 0,
        'my_list_finished_watching': 3,
        'my_list_on_hold': 2,
        'my_list_dropped': 1,
        'favorite_characters_count': 8,
      },
    );
  });

  test('overview counts omit missing, malformed and negative counters', () {
    expect(parseMyListOverviewCounts(<String, dynamic>{}), isEmpty);
    expect(parseMyListOverviewCounts({'items': <String>[]}), isEmpty);
    expect(parseMyListOverviewCounts({'items': 'not-a-map'}), isEmpty);
    expect(
      parseMyListOverviewCounts({
        'items': <String, dynamic>{
          'my_list_favorites': -1,
          'my_list_currently_watching': true,
          'my_list_plan_to_watch': '1.5',
          'my_list_finished_watching': 'five',
          'my_list_on_hold': 3.4,
          'my_list_dropped': null,
          'favorite_characters_count': '2',
        },
      }),
      {'favorite_characters_count': 2},
    );
  });

  test(
    'cloud account reads require Rift sign-in before any network request',
    () async {
      var requests = 0;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          requests++;
          return reply(o, <String, dynamic>{});
        }),
      );
      final attempts = <Future<Map<String, dynamic>>>[
        client.fetchFavoriteAnime(),
        client.fetchMyList('favorite'),
        client.fetchMyListOverview(),
        client.fetchWatchHistoryLatest(),
        client.fetchWatchHistoryFull(),
      ];
      for (final attempt in attempts) {
        await expectLater(
          attempt,
          throwsA(isA<AnimeRiftAuthenticationRequired>()),
        );
      }
      expect(requests, 0);
      for (final invalid in [
        '',
        'finished',
        'COMPLETED',
        '../favorites',
        'favorite?user=other',
      ]) {
        expect(() => client.fetchMyList(invalid), throwsArgumentError);
      }
      expect(requests, 0);
    },
  );

  test(
    'Rift account GETs use only the recovered paths/scopes and raw response',
    () async {
      const routes = <String, String>{
        '/api/v4/favorite/anime/all': 'USER.FAVORITES.ANIME.ALL',
        '/api/v4/my_list/all': 'USER.MY_LIST.GET_ALL',
        '/api/v4/my_list/overview': 'USER.MY_LIST.OVERVIEW',
        '/api/v4/watch_history/latest': 'USER.WATCH_HISTORY.VIEW.LATEST',
        '/api/v4/watch_history/full': 'USER.WATCH_HISTORY.VIEW.FULL',
      };
      final requested = <String>[];
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
          if (o.uri.path.endsWith('/auth/register/device')) {
            return reply(o, {'sessionKey': 'fixture'}, 201);
          }
          if (o.uri.path.endsWith('/auth/sign-in/with-code')) {
            return reply(o, {
              'items': {
                'profile': {'_id': 'rift-user'},
                'token': 'rift-user-token',
              },
            });
          }
          expect(o.uri.host, 'gateway.embrassme.top');
          expect(o.method, 'GET');
          expect(o.data, isNull);
          expect(o.headers['authorization'], 'Bearer rift-user-token');
          expect(routes[o.uri.path], isNotNull);
          final jwt = (o.headers['integrity'] as String)
              .substring(7)
              .split('.');
          final payload = jsonDecode(
            utf8.decode(base64Url.decode(base64Url.normalize(jwt[1]))),
          ) as Map;
          expect(payload['scope'], routes[o.uri.path]);
          if (o.uri.path == '/api/v4/my_list/all') {
            expect(o.uri.queryParameters, {'my_list': 'want_to'});
          } else {
            expect(o.uri.queryParameters, isEmpty);
          }
          requested.add(o.uri.path);
          return reply(o, {
            'arbitrary': <String, dynamic>{'value': 'opaque'},
          });
        }),
      );
      await client.signInWithCode('owner-issued-code');
      final response = await client.fetchFavoriteAnime();
      expect(response, {
        'arbitrary': {'value': 'opaque'},
      });
      await client.fetchMyList('want_to');
      await client.fetchMyListOverview();
      await client.fetchWatchHistoryLatest();
      await client.fetchWatchHistoryFull();
      expect(requested, routes.keys);
      await expectLater(
        client.request('my_list/all', 'USER.MY_LIST.GET_ALL'),
        throwsArgumentError,
      );
    },
  );

  test(
    'account read reports expired credentials without silently retrying',
    () async {
      var reads = 0;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
          if (o.uri.path.endsWith('/auth/register/device')) {
            return reply(o, {'sessionKey': 'fixture'}, 201);
          }
          if (o.uri.path.endsWith('/auth/sign-in/with-code')) {
            return reply(o, {
              'items': {
                'profile': {'_id': 'rift-user'},
                'token': 'expired-token',
              },
            });
          }
          reads++;
          return reply(o, {'error': 'must-not-leak'}, 401);
        }),
      );
      await client.signInWithCode('owner-code');
      await expectLater(
        client.fetchFavoriteAnime(),
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(reads, 1);
      expect(client.isAccountLinked, isTrue);
    },
  );

  test('an account read cannot publish data after unlinking Rift', () async {
    final started = Completer<void>();
    final replyLater = Completer<Response<dynamic>>();
    final client = AnimeRiftApiClient(
      config: fixtureConfig,
      dio: fixtureDio((o) {
        if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
        if (o.uri.path.endsWith('/auth/register/device')) {
          return reply(o, {'sessionKey': 'fixture'}, 201);
        }
        if (o.uri.path.endsWith('/auth/sign-in/with-code')) {
          return reply(o, {
            'items': {
              'profile': {'_id': 'account-a'},
              'token': 'token-a',
            },
          });
        }
        expect(o.uri.path, '/api/v4/my_list/all');
        started.complete();
        return replyLater.future;
      }),
    );
    await client.signInWithCode('account-a-code');
    final pending = client.fetchMyList('currently');
    await started.future;
    await client.signOut();
    replyLater.complete(
      reply(RequestOptions(path: '/api/v4/my_list/all'), {
        'items': <Object>[
          {'_id': 'private-anime'},
        ],
      }),
    );
    await expectLater(pending, throwsA(isA<AnimeRiftAuthenticationRequired>()));
    expect(client.isAccountLinked, isFalse);
  });

  test(
    'Rift local account partition follows sign-in, restart and unlink',
    () async {
      final dio = fixtureDio((o) {
        if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
        if (o.uri.path.endsWith('/auth/register/device')) {
          return reply(o, {'sessionKey': 'fixture'}, 201);
        }
        if (o.uri.path.endsWith('/auth/sign-in/with-code')) {
          final code = (o.data as Map)['code'];
          return reply(o, {
            'items': {
              'profile': {'_id': 'user-$code', 'username': 'Name $code'},
              'token': 'token-$code',
            },
          });
        }
        return reply(o, {'items': []});
      });
      final client = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
      expect(AnimeRiftLocalAccountScope.accountHash, isNull);

      await client.signInWithCode('one');
      expect(client.accountIdentity?.id, 'user-one');
      expect(client.accountIdentity?.displayName, 'Name one');
      final firstScope = AnimeRiftLocalAccountScope.accountHash;
      expect(firstScope, isNotNull);
      expect(firstScope, isNot(contains('user-one')));

      await client.signInWithCode('two');
      expect(client.accountIdentity?.id, 'user-two');
      final secondScope = AnimeRiftLocalAccountScope.accountHash;
      expect(secondScope, isNot(firstScope));

      AnimeRiftLocalAccountScope.reset();
      final restarted = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
      expect(await restarted.restoreAccountSession(), isTrue);
      expect(restarted.accountIdentity?.id, 'user-two');
      expect(AnimeRiftLocalAccountScope.accountHash, secondScope);

      await restarted.signOut();
      expect(restarted.accountIdentity, isNull);
      expect(AnimeRiftLocalAccountScope.accountHash, isNull);
      expect(
        await AnimeRiftApiClient(
          config: fixtureConfig,
          dio: dio,
        ).restoreAccountSession(),
        isFalse,
      );
    },
  );

  test(
    'valid Rift profile without a recognized ID still authenticates safely',
    () async {
      final dio = fixtureDio((o) {
        if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
        if (o.uri.path.endsWith('/auth/register/device')) {
          return reply(o, {'sessionKey': 'fixture'}, 201);
        }
        if (o.uri.path.endsWith('/auth/sign-in/with-code')) {
          return reply(o, {
            'items': {
              'profile': <String, dynamic>{'unrecognized_field': 'value'},
              'token': 'no-profile-id-token',
            },
          });
        }
        expect(o.headers['authorization'], 'Bearer no-profile-id-token');
        return reply(o, {'items': <Object>[]});
      });
      final client = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
      await client.signInWithCode('owner-code');
      expect(client.isAccountLinked, isTrue);
      expect(client.accountIdentity?.isVerified, isFalse);
      final scope = AnimeRiftLocalAccountScope.accountHash;
      expect(scope, isNotNull);
      await client.request(
        'library/home_content',
        'ANIME.LIBRARY.HOME_CONTENT',
      );

      AnimeRiftLocalAccountScope.reset();
      final restarted = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
      expect(await restarted.restoreAccountSession(), isTrue);
      expect(restarted.accountIdentity?.isVerified, isFalse);
      expect(AnimeRiftLocalAccountScope.accountHash, scope);
    },
  );

  test('overlapping restore calls share the secure read', () async {
    final client = AnimeRiftApiClient(config: fixtureConfig);
    final results = await Future.wait([
      client.restoreAccountSession(),
      client.restoreAccountSession(),
      client.restoreAccountSession(),
    ]);
    expect(results, [false, false, false]);
    expect(secureCalls.where((call) => call.method == 'read'), hasLength(1));
  });

  test(
    'sign-out cancels a delayed sign-in without restoring its token',
    () async {
      final signInResponse = Completer<Response<dynamic>>();
      final started = Completer<void>();
      final dio = fixtureDio((o) {
        if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
        if (o.uri.path.endsWith('/auth/register/device')) {
          return reply(o, {'sessionKey': 'fixture'}, 201);
        }
        if (o.uri.path.endsWith('/auth/sign-in/with-code')) {
          started.complete();
          return signInResponse.future;
        }
        return reply(o, {'items': []});
      });
      final client = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
      final signingIn = client.signInWithCode('one');
      await started.future;
      await client.signOut();
      signInResponse.complete(
        reply(RequestOptions(path: '/auth/sign-in/with-code'), {
          'items': {
            'profile': {'_id': 'late-user'},
            'token': 'late-token',
          },
        }),
      );
      await expectLater(signingIn, throwsA(isA<AnimeRiftAccessUnavailable>()));
      expect(client.isAccountLinked, isFalse);
      expect(AnimeRiftLocalAccountScope.accountHash, isNull);
      expect(secureValues, isEmpty);
    },
  );

  test(
    'a delayed catalog response cannot cross Rift account switches',
    () async {
      final pendingCatalog = Completer<Response<dynamic>>();
      final catalogStarted = Completer<void>();
      final dio = fixtureDio((o) {
        if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
        if (o.uri.path.endsWith('/auth/register/device')) {
          return reply(o, {'sessionKey': 'fixture'}, 201);
        }
        if (o.uri.path.endsWith('/auth/sign-in/with-code')) {
          final code = (o.data as Map)['code'];
          return reply(o, {
            'items': {
              'profile': {'_id': 'user-$code'},
              'token': 'token-$code',
            },
          });
        }
        if (o.uri.path.endsWith('/library/home_content')) {
          catalogStarted.complete();
          return pendingCatalog.future;
        }
        return reply(o, {'items': <Object>[]});
      });
      final client = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
      await client.signInWithCode('one');
      final oldAccountRequest = client.request(
        'library/home_content',
        'ANIME.LIBRARY.HOME_CONTENT',
      );
      await catalogStarted.future;
      await client.signInWithCode('two');
      pendingCatalog.complete(
        reply(RequestOptions(path: '/library/home_content'), {
          'items': <String, Object>{'secret': 'user-one'},
        }),
      );
      await expectLater(
        oldAccountRequest,
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(client.accountIdentity?.id, 'user-two');
    },
  );

  test('legacy credential remains linked in its own token-derived partition', () async {
    final client = AnimeRiftApiClient(config: fixtureConfig);
    expect(await client.restoreAccountSession(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    final device =
        jsonDecode(prefs.getString('animerift.api.installation.v1')!) as Map;
    // Older installations only stored a token and device ID in secure storage.
    secureValues['animerift.user.session.v1'] = jsonEncode({
      'version': 1,
      'deviceId': device['deviceId'],
      'token': 'legacy-token',
    });
    final restarted = AnimeRiftApiClient(config: fixtureConfig);
    expect(await restarted.restoreAccountSession(), isTrue);
    expect(restarted.isAccountLinked, isTrue);
    expect(restarted.accountIdentity?.isVerified, isFalse);
    expect(restarted.accountIdentity?.displayName, isNull);
    final scope = AnimeRiftLocalAccountScope.accountHash;
    expect(scope, isNotNull);
    expect(scope, isNot(contains('legacy-token')));
    expect(secureValues, hasLength(1));
    AnimeRiftLocalAccountScope.reset();
    final anotherRestart = AnimeRiftApiClient(config: fixtureConfig);
    expect(await anotherRestart.restoreAccountSession(), isTrue);
    expect(AnimeRiftLocalAccountScope.accountHash, scope);
    await anotherRestart.signOut();
    expect(secureValues, isEmpty);
    expect(AnimeRiftLocalAccountScope.accountHash, isNull);
  });

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
    'missing build configuration is distinct from a gateway outage',
    () async {
      var calls = 0;
      final client = AnimeRiftApiClient(
        config: const AnimeRiftConfig(
          firebaseApiKey: '',
          firebaseAppId: '',
          signingKey: '',
        ),
        dio: fixtureDio((o) {
          calls++;
          return reply(o, {});
        }),
      );
      await expectLater(
        client.request(
          'library/episode/sources',
          'ANIME.LIBRARY.EPISODES.SOURCES.ALL',
        ),
        throwsA(
          isA<AnimeRiftAccessUnavailable>().having(
            (e) => e.toString(),
            'safe configuration diagnosis',
            contains('إعدادات الربط غير مكتملة'),
          ),
        ),
      );
      expect(calls, 0);
    },
  );

  test(
    'malformed source response identifies the phase without raw data',
    () async {
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
          if (o.uri.path.endsWith('/auth/register/device')) {
            return reply(o, {'sessionKey': 'fixture'}, 201);
          }
          return reply(o, 'private-malformed-response');
        }),
      );
      await expectLater(
        client.request(
          'library/episode/sources',
          'ANIME.LIBRARY.EPISODES.SOURCES.ALL',
        ),
        throwsA(
          isA<AnimeRiftAccessUnavailable>().having(
            (e) => e.toString(),
            'safe invalid response diagnosis',
            allOf(
              contains('قائمة مصادر الحلقة'),
              contains('استجابة غير صالحة'),
              isNot(contains('private-malformed-response')),
            ),
          ),
        ),
      );
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
      await expectLater(
        client.request('character/../../user/view', 'scope'),
        throwsArgumentError,
      );
      expect(calls, 0);
    },
  );

  test(
    'character read endpoints are allowed with their own scoped request',
    () async {
      var characterCalls = 0;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
          if (o.uri.path.endsWith('/auth/register/device')) {
            return reply(o, {'sessionKey': 'fixture'}, 201);
          }
          characterCalls++;
          final jwt = (o.headers['integrity'] as String)
              .substring(7)
              .split('.');
          final payload = jsonDecode(
            utf8.decode(base64Url.decode(base64Url.normalize(jwt[1]))),
          ) as Map;
          if (o.uri.path.endsWith('/character/all')) {
            expect(payload['scope'], 'CHARACTERS.ALL');
            expect(o.queryParameters['searchText'], 'Naruto');
            return reply(o, {'items': []});
          }
          expect(o.uri.path, endsWith('/character/details/char_1'));
          expect(payload['scope'], 'CHARACTERS.DETAILS');
          return reply(o, {'item': {}});
        }),
      );

      await client.request(
        'character/all',
        'CHARACTERS.ALL',
        query: {'searchText': 'Naruto'},
      );
      await client.request('character/details/char_1', 'CHARACTERS.DETAILS');
      expect(characterCalls, 2);
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
    'source entitlement denial does not re-register or replay a POST',
    () async {
      var registrations = 0;
      var entitlementChecks = 0;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((request) {
          if (request.uri.host.endsWith('googleapis.com')) {
            return reply(request, {}, 400);
          }
          if (request.uri.path.endsWith('/auth/register/device')) {
            registrations++;
            return reply(request, {'sessionKey': 'fixture'}, 201);
          }
          entitlementChecks++;
          expect(request.uri.path, endsWith('/source/can_play'));
          return reply(request, {'error': 'must-not-leak'}, 403);
        }),
      );

      await expectLater(
        client.request(
          'library/episode/source/can_play',
          'ANIME.LIBRARY.EPISODES.SOURCES.CHECK_AVAILABILITY',
          method: 'POST',
          body: {'is_download': true},
        ),
        throwsA(
          isA<AnimeRiftAccessUnavailable>()
              .having((e) => e.statusCode, 'status code', 403)
              .having(
                (e) => e.toString(),
                'safe diagnostic',
                allOf(
                  contains('HTTP 403'),
                  contains('صلاحية التشغيل'),
                  isNot(contains('must-not-leak')),
                ),
              ),
        ),
      );
      expect(registrations, 1);
      expect(entitlementChecks, 1);
    },
  );

  test(
    'guest source HTTP 401 is surfaced without replaying the entitlement',
    () async {
      var entitlementChecks = 0;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((request) {
          if (request.uri.host.endsWith('googleapis.com')) {
            return reply(request, {}, 400);
          }
          if (request.uri.path.endsWith('/auth/register/device')) {
            return reply(request, {'sessionKey': 'fixture'}, 201);
          }
          entitlementChecks++;
          expect(request.uri.path, endsWith('/source/can_play'));
          return reply(request, {'error': 'private'}, 401);
        }),
      );
      await expectLater(
        client.request(
          'library/episode/source/can_play',
          'ANIME.LIBRARY.EPISODES.SOURCES.CHECK_AVAILABILITY',
          method: 'POST',
          body: {'is_download': true},
        ),
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(entitlementChecks, 1);
    },
  );

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
        expect(error.toString(), isNot(contains(privateCode)));
        expect(error.toString(), isNot(contains('private')));
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
    expect(restarted.isAccountLinked, isFalse);
    expect(AnimeRiftLocalAccountScope.accountHash, isNull);
    expect(await restarted.restoreAccountSession(), isTrue);
    expect(restarted.isAccountLinked, isTrue);
    expect(AnimeRiftLocalAccountScope.accountHash, isNotNull);
  });

  test('concurrent account restores wait for the same secure read', () async {
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
    secureCalls.clear();

    final readGate = Completer<void>();
    delayedSecureRead = readGate;
    final restarted = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
    final first = restarted.restoreAccountSession();
    final second = restarted.restoreAccountSession();
    readGate.complete();

    expect(await Future.wait([first, second]), [true, true]);
    expect(
      secureCalls.where((call) => call.method == 'read'),
      hasLength(1),
    );
    expect(restarted.isAccountLinked, isTrue);
  });

  test('unlink cancels a pending secure sign-in write before deleting', () async {
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
    final client = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
    delayedSecureWrite = Completer<void>();
    secureWriteStarted = Completer<void>();
    final linking = client.signInWithCode('valid-code');
    await secureWriteStarted!.future;

    final unlinking = client.signOut();
    delayedSecureWrite!.complete();
    await expectLater(linking, throwsA(isA<AnimeRiftAccessUnavailable>()));
    await unlinking;

    expect(client.isAccountLinked, isFalse);
    expect(secureValues, isEmpty);
    final writes = secureCalls.where((call) => call.method == 'write');
    final deletes = secureCalls.where((call) => call.method == 'delete');
    expect(writes, hasLength(1));
    expect(deletes, hasLength(1));
  });

  test('link waits for in-flight unlink to complete before storing a token', () async {
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
    final client = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
    await client.signInWithCode('valid-code');
    delayedSecureDelete = Completer<void>();
    secureDeleteStarted = Completer<void>();

    final unlinking = client.signOut();
    await secureDeleteStarted!.future;
    final linking = client.signInWithCode('valid-code');
    delayedSecureDelete!.complete();
    await Future.wait([unlinking, linking]);

    expect(client.isAccountLinked, isTrue);
    expect(secureValues.values.single, contains('fixture-user-token'));
  });
}
