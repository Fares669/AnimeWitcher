import 'dart:async';
import 'dart:convert';

import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_device_descriptor.dart';
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
          if (secureDeleteStarted != null &&
              !secureDeleteStarted!.isCompleted) {
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

  test(
    'Rift comment creation sends only eventId and authenticated comment',
    () async {
      final writes = <RequestOptions>[];
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((options) {
          if (options.uri.host.endsWith('googleapis.com')) {
            return reply(options, <String, dynamic>{}, 400);
          }
          if (options.uri.path.endsWith('/auth/register/device')) {
            return reply(options, {'sessionKey': 'fixture'}, 201);
          }
          if (options.uri.path.endsWith('/auth/sign-in/with-code')) {
            return reply(options, {
              'items': {
                'profile': {'_id': 'rift-comment-user'},
                'token': 'rift-comment-token',
              },
            });
          }
          writes.add(options);
          return reply(options, {'success': true}, 201);
        }),
      );
      await client.signInWithCode('test-only-code');
      await client.createComment(
        animeId: 'anime42',
        episodeId: 'episode7',
        parentId: 'parent1',
        text: ' hello ',
      );
      expect(writes, hasLength(1));
      expect(writes.single.uri.path, '/api/v4/comment/create');
      expect(writes.single.method, 'POST');
      expect(writes.single.data, {
        'eventId': 'episode7',
        'parentId': 'parent1',
        'comment': 'hello',
      });
      expect(
        writes.single.headers['authorization'],
        'Bearer rift-comment-token',
      );
    },
  );

  test('Rift watched/unwatched and five-part rating send authenticated native PUTs', () async {
    final writes = <RequestOptions>[];
    final client = AnimeRiftApiClient(
      config: fixtureConfig,
      dio: fixtureDio((options) {
        if (options.uri.host.endsWith('googleapis.com')) {
          return reply(options, <String, dynamic>{}, 400);
        }
        if (options.uri.path.endsWith('/auth/register/device')) {
          return reply(options, {'sessionKey': 'fixture'}, 201);
        }
        if (options.uri.path.endsWith('/auth/sign-in/with-code')) {
          return reply(options, {
            'items': {
              'profile': {'_id': 'rift-user'},
              'token': 'rift-user-token',
            },
          });
        }
        writes.add(options);
        return reply(options, {'success': true}, 202);
      }),
    );
    await client.signInWithCode('owner-issued-code');
    final account = AnimeRiftLocalAccountScope.accountHash!;
    await client.setEpisodeViewed('anime-42', 3, true, accountHash: account);
    await client.setEpisodeViewed('anime-42', 3, false, accountHash: account);
    await client.rateAnime(
      'anime-42',
      general: 8,
      story: 9,
      characters: 7,
      animation: 8,
      music: 6,
      accountHash: account,
    );
    expect(writes.map((o) => o.uri.path), [
      '/api/v4/watch_history/watch',
      '/api/v4/watch_history/watch',
      '/api/v4/my_list/rate',
    ]);
    expect(writes[0].data, {
      'animeId': 'anime-42',
      'viewed': true,
      'episode_number': 3,
      'useLastInteractedEpisode': false,
    });
    expect(writes[1].data, {
      'animeId': 'anime-42',
      'viewed': false,
      'episode_number': 3,
      'useLastInteractedEpisode': false,
    });
    expect(writes[2].data, {
      'animeId': 'anime-42',
      'general_rating': 8.0,
      'story_rating': 9.0,
      'characters_rating': 7.0,
      'animation_rating': 8.0,
      'music_rating': 6.0,
    });
    for (final options in writes) {
      expect(options.method, 'PUT');
      expect(options.headers['authorization'], 'Bearer rift-user-token');
    }
    for (final (index, scope) in const [
      'USER.WATCH_HISTORY.WATCHED',
      'USER.WATCH_HISTORY.WATCHED',
      'USER.MY_LIST.RATE',
    ].indexed) {
      final jwt = (writes[index].headers['integrity'] as String)
          .substring(7)
          .split('.');
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(jwt[1]))),
      ) as Map;
      expect(payload['scope'], scope);
    }
    await expectLater(
      client.setEpisodeViewed('anime-42', 3, true, accountHash: 'other'),
      throwsA(isA<AnimeRiftAuthenticationRequired>()),
    );
    expect(
      () => client.rateAnime(
        'anime-42',
        general: -1,
        story: 8,
        characters: 8,
        animation: 8,
        music: 8,
        accountHash: account,
      ),
      throwsArgumentError,
    );
    expect(writes, hasLength(3));
  });

  test(
    'Rift history deletion uses record IDs and the two original PUT scopes',
    () async {
      final writes = <RequestOptions>[];
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((options) {
          if (options.uri.host.endsWith('googleapis.com')) {
            return reply(options, <String, dynamic>{}, 400);
          }
          if (options.uri.path.endsWith('/auth/register/device')) {
            return reply(options, {'sessionKey': 'fixture'}, 201);
          }
          if (options.uri.path.endsWith('/auth/sign-in/with-code')) {
            return reply(options, {
              'items': {
                'profile': {'_id': 'rift-user'},
                'token': 'rift-user-token',
              },
            });
          }
          writes.add(options);
          return reply(options, const <String, dynamic>{}, 202);
        }),
      );
      await client.signInWithCode('owner-issued-code');
      final account = AnimeRiftLocalAccountScope.accountHash!;
      await client.removeWatchHistoryRecord(
        'history-row-12',
        'anime-7',
        accountHash: account,
      );
      await client.removeWatchHistoryMany([
        'history-row-13',
        'history-row-14',
      ], accountHash: account);
      expect(writes.map((request) => request.uri.path), [
        '/api/v4/watch_history/clear/one',
        '/api/v4/watch_history/clear/multi',
      ]);
      expect(writes[0].data, {
        'id': 'history-row-12',
        'animeId': 'anime-7',
        'check_last_episode': true,
      });
      expect(writes[1].data, {
        'ids': ['history-row-13', 'history-row-14'],
      });
      for (final (index, scope) in const [
        'USER.WATCH_HISTORY.CLEAR_ONE',
        'USER.WATCH_HISTORY.CLEAR_MANY',
      ].indexed) {
        final request = writes[index];
        expect(request.method, 'PUT');
        expect(request.headers['authorization'], 'Bearer rift-user-token');
        final token = (request.headers['integrity'] as String)
            .substring(7)
            .split('.');
        final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(token[1]))),
        ) as Map;
        expect(payload['scope'], scope);
      }
      await expectLater(
        client.removeWatchHistoryRecord(
          'history-row-12',
          'anime-7',
          accountHash: 'another-account',
        ),
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(
        () =>
            client.removeWatchHistoryMany(['../unsafe'], accountHash: account),
        throwsArgumentError,
      );
      expect(writes, hasLength(2));
    },
  );

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
        client.fetchMyList('finished'),
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
        'unknown-list',
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
    'favorite writes use the native PUT contract and bind the account',
    () async {
      final writes = <RequestOptions>[];
      var writeStatus = 202;
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
          writes.add(o);
          return reply(o, {'success': true}, writeStatus);
        }),
      );
      await client.signInWithCode('owner-issued-code');
      final account = AnimeRiftLocalAccountScope.accountHash!;
      final writer = client;
      for (final favorite in [true, false]) {
        await writer.setFavoriteAnime(
          'anime-id',
          favorite,
          accountHash: account,
        );
      }
      expect(writes.map((o) => o.uri.path), [
        '/api/v4/favorite/anime/follow',
        '/api/v4/favorite/anime/un_follow',
      ]);
      for (final request in writes) {
        expect(request.method, 'PUT');
        expect(request.data, {'animeId': 'anime-id'});
        expect(request.headers['authorization'], 'Bearer rift-user-token');
        final jwt = (request.headers['integrity'] as String)
            .substring(7)
            .split('.');
        final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(jwt[1]))),
        ) as Map;
        expect(payload['scope'], 'USER.FAVORITES.ANIME.FOLLOW');
      }
      await expectLater(
        writer.setFavoriteAnime(
          'anime-id',
          true,
          accountHash: 'another-account',
        ),
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(writes, hasLength(2));
      writeStatus = 200;
      await expectLater(
        writer.setFavoriteAnime('anime-id', true, accountHash: account),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
      writeStatus = 401;
      await expectLater(
        writer.setFavoriteAnime('anime-id', true, accountHash: account),
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(
        writes,
        hasLength(4),
        reason: 'Account writes must not replay on 401',
      );
      await client.signOut();
      await expectLater(
        writer.setFavoriteAnime('anime-id', true, accountHash: account),
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(writes, hasLength(4));
    },
  );

  test('built-in list writes use scoped native bookmark PUT', () async {
    final writes = <RequestOptions>[];
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
        writes.add(o);
        return reply(o, {}, 202);
      }),
    );
    await client.signInWithCode('owner-issued-code');
    final account = AnimeRiftLocalAccountScope.accountHash!;
    for (final category in <String?>[
      'currently',
      'want_to',
      'finished',
      'later',
      'dropped',
      null,
    ]) {
      await client.setMyListCategory(
        'anime-42',
        category,
        accountHash: account,
      );
    }
    expect(writes, hasLength(6));
    for (var index = 0; index < writes.length; index++) {
      final request = writes[index];
      expect(request.method, 'PUT');
      expect(request.uri.path, '/api/v4/my_list/bookmark');
      expect(request.data, {
        'animeId': 'anime-42',
        'is_my_list': <String?>[
          'currently',
          'want_to',
          'finished',
          'later',
          'dropped',
          null,
        ][index],
        'custom_list_id': null,
      });
      final jwt = (request.headers['integrity'] as String)
          .substring(7)
          .split('.');
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(jwt[1]))),
      ) as Map;
      expect(payload['scope'], 'USER.MY_LIST.BOOKMARK');
      expect(request.headers['authorization'], 'Bearer rift-user-token');
    }
    await expectLater(
      client.setMyListCategory(
        'anime-42',
        'currently',
        accountHash: 'other-account',
      ),
      throwsA(isA<AnimeRiftAuthenticationRequired>()),
    );
    expect(
      () => client.setMyListCategory(
        '../unsafe',
        'currently',
        accountHash: account,
      ),
      throwsArgumentError,
    );
    expect(
      () =>
          client.setMyListCategory('anime-42', 'unknown', accountHash: account),
      throwsArgumentError,
    );
    expect(writes, hasLength(6));
  });

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
    'registers actual Android and iOS devices, and synthetic desktop',
    () async {
      final profiles = [
        const AnimeRiftDeviceDescriptor(
          os: 'android',
          osId: 'actual-android-build',
          details: {'model': 'Samsung Galaxy S24', 'androidVersion': '16'},
        ),
        const AnimeRiftDeviceDescriptor(
          os: 'ios',
          osId: '26.1',
          installSource: 'IS_INSTALLED_FROM_APP_STORE',
          details: {
            'model': 'iPhone 12 Pro Max',
            'device': 'iPhone13,4',
            'systemVersion': '26.1',
          },
        ),
        AnimeRiftDeviceDescriptor.emulatedAndroid('desktop-build'),
      ];
      for (final descriptor in profiles) {
        SharedPreferences.setMockInitialValues({});
        final registeredIds = <String>[];
        final dio = fixtureDio((o) {
          if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
          if (o.uri.path.endsWith('/auth/register/device')) {
            final data = o.data as Map;
            registeredIds.add(data['deviceId'] as String);
            expect(o.headers['x-os'], descriptor.os);
            expect(o.headers['x-device-os-id'], descriptor.osId);
            expect(data['device_os'], descriptor.os);
            expect(data['deviceOsId'], descriptor.osId);
            expect(
              jsonDecode(data['device_info'] as String),
              descriptor.details,
            );
            if (descriptor.installSource == null) {
              expect(data.containsKey('install_source'), isFalse);
              expect(o.headers.containsKey('x-installation-source'), isFalse);
            } else {
              expect(data['install_source'], descriptor.installSource);
            }
            return reply(o, {'sessionKey': 'fixture'}, 201);
          }
          return reply(o, {});
        });
        for (var i = 0; i < 2; i++) {
          await AnimeRiftApiClient(
            config: fixtureConfig,
            dio: dio,
            deviceDescriptorLoader: (_) async => descriptor,
          ).request('library/home_content', 'ANIME.LIBRARY.HOME_CONTENT');
        }
        expect(
          registeredIds,
          hasLength(1),
          reason: 'A second client must reuse a recent successful registration',
        );
      }
    },
  );

  test(
    'iOS App Store rejection retries legacy Android descriptor once',
    () async {
      final diagnostics = <AnimeRiftAuthDiagnostic>[];
      final registers = <RequestOptions>[];
      var signInCalls = 0;
      final dio = fixtureDio((o) {
        if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
        if (o.uri.path.endsWith('/auth/register/device')) {
          registers.add(o);
          return reply(
            o,
            registers.length == 1
                ? {'error': 'INSTALL_SOURCE_NOT_SUPPORTED'}
                : {'sessionKey': 'fixture'},
            registers.length == 1 ? 422 : 201,
          );
        }
        if (o.uri.path.endsWith('/auth/sign-in/with-code')) {
          signInCalls++;
          expect(o.headers['x-os'], 'android');
          return reply(o, {
            'items': {
              'profile': {'_id': 'account-1'},
              'token': 'secret-session-token',
            },
          });
        }
        return reply(o, {'items': []});
      });
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: dio,
        onAuthDiagnostic: diagnostics.add,
        deviceDescriptorLoader: (_) async => const AnimeRiftDeviceDescriptor(
          os: 'ios',
          osId: '26.1',
          installSource: 'IS_INSTALLED_FROM_APP_STORE',
          details: {'model': 'iPhone 12 Pro Max'},
        ),
      );
      await client.signInWithCode('secret-one-time-code');
      expect(client.isAccountLinked, isTrue);
      expect(signInCalls, 1);
      expect(registers, hasLength(2));
      final ios = registers.first;
      final android = registers.last;
      expect(ios.headers['x-os'], 'ios');
      expect(
        ios.headers['x-installation-source'],
        'IS_INSTALLED_FROM_APP_STORE',
      );
      expect(
        (ios.data as Map)['install_source'],
        'IS_INSTALLED_FROM_APP_STORE',
      );
      expect(android.headers['x-os'], 'android');
      expect(
        (android.data as Map)['install_source'],
        'IS_INSTALLED_FROM_PLAY_PACKAGE_INSTALLER',
      );
      expect((android.data as Map)['device_os'], 'android');
      expect(
        jsonDecode((android.data as Map)['device_info'] as String)['model'],
        'Pixel 8 Pro',
      );
      expect((ios.data as Map)['deviceId'], (android.data as Map)['deviceId']);
      expect(
        (ios.data as Map)['firebaseInstallationId'],
        (android.data as Map)['firebaseInstallationId'],
      );
      expect(
        diagnostics.map((d) => d.event),
        containsAllInOrder([
          AnimeRiftAuthEvent.registrationStart,
          AnimeRiftAuthEvent.registrationRejected,
          AnimeRiftAuthEvent.compatibilityRetry,
          AnimeRiftAuthEvent.compatibilityAccepted,
          AnimeRiftAuthEvent.codeSignInAccepted,
        ]),
      );
      expect(diagnostics.any((d) => d.statusCode == 422), isTrue);
      expect(
        diagnostics.any(
          (d) =>
              d.knownReason == AnimeRiftServerReason.installSourceNotSupported,
        ),
        isTrue,
      );
      expect(diagnostics.join(' | '), isNot(contains('secret-one-time-code')));
      expect(diagnostics.join(' | '), isNot(contains('secret-session-token')));
      expect(diagnostics.join(' | '), isNot(contains('not logged')));
      expect(
        diagnostics.join(' | '),
        isNot(contains('firebaseInstallationId')),
      );
    },
  );

  test('native iOS success never retries Android', () async {
    final registers = <RequestOptions>[];
    final client = AnimeRiftApiClient(
      config: fixtureConfig,
      dio: fixtureDio((o) {
        if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
        if (o.uri.path.endsWith('/auth/register/device')) {
          registers.add(o);
          return reply(o, {}, 201);
        }
        return reply(o, {'items': []});
      }),
      deviceDescriptorLoader: (_) async => const AnimeRiftDeviceDescriptor(
        os: 'ios',
        osId: '26.1',
        installSource: 'IS_INSTALLED_FROM_APP_STORE',
        details: {'model': 'iPhone 12 Pro Max'},
      ),
    );
    await client.request('library/home_content', 'ANIME.LIBRARY.HOME_CONTENT');
    expect(registers, hasLength(1));
    expect(registers.single.headers['x-os'], 'ios');
  });

  test(
    'new iOS account session diagnoses Pixel fallback and server session name',
    () async {
      final diagnostics = <AnimeRiftAuthDiagnostic>[];
      final sessionChecked = Completer<void>();
      var registrations = 0;
      var sessionReads = 0;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((request) {
          if (request.uri.host.endsWith('googleapis.com')) {
            return reply(request, {}, 400);
          }
          if (request.uri.path.endsWith('/auth/register/device')) {
            registrations++;
            return registrations == 1
                ? reply(request, {'error': 'INSTALL_SOURCE_NOT_SUPPORTED'}, 422)
                : reply(request, {'sessionKey': 'fixture'}, 201);
          }
          if (request.uri.path.endsWith('/auth/sign-in/with-code')) {
            return reply(request, {
              'items': {
                'profile': {'_id': 'account-1'},
                'token': 'private-user-token',
              },
            });
          }
          if (request.uri.path.endsWith('/sessions/all')) {
            sessionReads++;
            expect(request.method, 'GET');
            expect(
              request.headers['authorization'],
              'Bearer private-user-token',
            );
            final integrity = (request.headers['integrity'] as String).split(
              '.',
            );
            final scope = jsonDecode(
              utf8.decode(base64Url.decode(base64Url.normalize(integrity[1]))),
            ) as Map;
            expect(scope['scope'], 'SETTINGS.SESSIONS.ALL');
            return reply(request, {
              'items': [
                {'deviceInfo': 'Pixel 8 Pro', 'id': 'private-session-id'},
              ],
            });
          }
          return reply(request, {});
        }),
        onAuthDiagnostic: (event) {
          diagnostics.add(event);
          if (event.event == AnimeRiftAuthEvent.serverSessionsChecked &&
              !sessionChecked.isCompleted) {
            sessionChecked.complete();
          }
        },
        deviceDescriptorLoader: (_) async => const AnimeRiftDeviceDescriptor(
          os: 'ios',
          osId: 'private-ios-id',
          installSource: 'IS_INSTALLED_FROM_APP_STORE',
          details: {'model': 'iPhone 12 Pro Max', 'device': 'iPhone13,4'},
        ),
      );
      await client.signInWithCode('private-login-code');
      await sessionChecked.future;
      expect(registrations, 2);
      expect(sessionReads, 1);
      final identity = diagnostics.firstWhere(
        (e) => e.event == AnimeRiftAuthEvent.sessionIdentityChecked,
      );
      expect(identity.nativeMode, AnimeRiftRegistrationMode.nativeIos);
      expect(identity.mode, AnimeRiftRegistrationMode.androidFallback);
      expect(identity.localModel, AnimeRiftDeviceModelKind.iphone);
      expect(identity.advertisedModel, AnimeRiftDeviceModelKind.pixel8Pro);
      expect(identity.deviceMismatch, true);
      final server = diagnostics.lastWhere(
        (e) => e.event == AnimeRiftAuthEvent.serverSessionsChecked,
      );
      expect(server.serverSessionCount, 1);
      expect(server.serverPixel8ProCount, 1);
      expect(server.serverIphoneCount, 0);
      expect(diagnostics.join(), isNot(contains('private-login-code')));
      expect(diagnostics.join(), isNot(contains('private-session-id')));
      expect(diagnostics.join(), isNot(contains('private-user-token')));
      expect(client.isAccountLinked, true);
    },
  );

  test(
    'iOS session check is read-only and failure never cancels sign-in',
    () async {
      final diagnostics = <AnimeRiftAuthDiagnostic>[];
      final checked = Completer<void>();
      var registrations = 0;
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
          if (request.uri.path.endsWith('/auth/sign-in/with-code')) {
            return reply(request, {
              'items': {
                'profile': {'_id': 'account-2'},
                'token': 'private-user-token',
              },
            });
          }
          if (request.uri.path.endsWith('/sessions/all')) {
            expect(request.method, 'GET');
            return reply(request, {'error': 'ACCESS_DENIED'}, 403);
          }
          return reply(request, {});
        }),
        onAuthDiagnostic: (event) {
          diagnostics.add(event);
          if (event.event == AnimeRiftAuthEvent.serverSessionsCheckFailed &&
              !checked.isCompleted)
            checked.complete();
        },
        deviceDescriptorLoader: (_) async => const AnimeRiftDeviceDescriptor(
          os: 'ios',
          osId: 'private-ios-id',
          installSource: 'IS_INSTALLED_FROM_APP_STORE',
          details: {'model': 'iPhone 12 Pro Max'},
        ),
      );
      await client.signInWithCode('private-login-code');
      await checked.future;
      expect(client.isAccountLinked, true);
      expect(registrations, 1);
      final identity = diagnostics.firstWhere(
        (e) => e.event == AnimeRiftAuthEvent.sessionIdentityChecked,
      );
      expect(identity.deviceMismatch, false);
      expect(identity.advertisedModel, AnimeRiftDeviceModelKind.iphone);
      final failure = diagnostics.last;
      expect(failure.statusCode, 403);
      expect(failure.knownReason, AnimeRiftServerReason.accessDenied);
    },
  );

  test('device suspension does not trigger Android fallback and cools down across restarts', () async {
    var time = DateTime.utc(2026, 11, 5, 12);
    var registrations = 0;
    final diagnostics = <AnimeRiftAuthDiagnostic>[];
    final dio = fixtureDio((options) {
      if (options.uri.host.endsWith('googleapis.com')) {
        return reply(options, {}, 400);
      }
      if (options.uri.path.endsWith('/auth/register/device')) {
        registrations++;
        return Response<dynamic>(
          requestOptions: options,
          statusCode: 403,
          headers: Headers.fromMap({
            'server': ['cloudflare'],
          }),
          data: {
            'error': {'error_code': 'DEVICE_SUSPENDED'},
            'message': 'Bearer secret-server-payload',
          },
        );
      }
      return reply(options, {});
    });
    AnimeRiftApiClient client() => AnimeRiftApiClient(
      config: fixtureConfig,
      dio: dio,
      clock: () => time,
      onAuthDiagnostic: diagnostics.add,
      deviceDescriptorLoader: (_) async => const AnimeRiftDeviceDescriptor(
        os: 'ios',
        osId: 'private-id',
        installSource: 'IS_INSTALLED_FROM_APP_STORE',
        details: {'model': 'iPhone'},
      ),
    );
    Future<void> read(AnimeRiftApiClient api) async {
      await api.request('library/home_content', 'ANIME.LIBRARY.HOME_CONTENT');
    }

    await expectLater(
      read(client()),
      throwsA(
        isA<AnimeRiftAccessUnavailable>()
            .having((e) => e.statusCode, 'status', 403)
            .having(
              (e) => e.knownReason,
              'code',
              AnimeRiftServerReason.deviceSuspended,
            ),
      ),
    );
    expect(registrations, 1);
    final rejected = diagnostics.firstWhere(
      (d) => d.event == AnimeRiftAuthEvent.registrationRejected,
    );
    expect(rejected.serverCode, 'DEVICE_SUSPENDED');
    expect(rejected.responseKind, AnimeRiftResponseKind.json);
    expect(rejected.edgeRejected, true);
    expect(rejected.mode, AnimeRiftRegistrationMode.nativeIos);
    expect(rejected.attempt, 1);
    expect(diagnostics.last.cooldownSeconds, 600);
    expect(diagnostics.join(), isNot(contains('secret-server-payload')));
    expect(
      diagnostics.any((d) => d.event == AnimeRiftAuthEvent.compatibilityRetry),
      isFalse,
    );

    time = time.add(const Duration(minutes: 1));
    await expectLater(
      read(client()),
      throwsA(
        isA<AnimeRiftAccessUnavailable>().having(
          (e) => e.failure,
          'failure',
          AnimeRiftFailureKind.registrationCooldown,
        ),
      ),
    );
    expect(
      registrations,
      1,
      reason: 'cold restart must not bypass persistent cooldown',
    );
    expect(diagnostics.last.event, AnimeRiftAuthEvent.registrationDeferred);

    time = time.add(const Duration(minutes: 10));
    await expectLater(
      read(client()),
      throwsA(isA<AnimeRiftAccessUnavailable>()),
    );
    expect(registrations, 2);
    expect(
      diagnostics.last.cooldownSeconds,
      1200,
      reason: 'repeated failures use exponential cooldown',
    );
  });

  test(
    'independent concurrent clients do not duplicate device registration',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final reused = <AnimeRiftAuthDiagnostic>[];
      var registrations = 0;
      final dio = fixtureDio((request) async {
        if (request.uri.host.endsWith('googleapis.com')) {
          return reply(request, {}, 400);
        }
        if (request.uri.path.endsWith('/auth/register/device')) {
          registrations++;
          if (!started.isCompleted) started.complete();
          await release.future;
          return reply(request, {'sessionKey': 'fixture'}, 201);
        }
        return reply(request, {'items': []});
      });
      final first = AnimeRiftApiClient(config: fixtureConfig, dio: dio);
      final second = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: dio,
        onAuthDiagnostic: reused.add,
      );
      final firstRequest = first.request(
        'library/home_content',
        'ANIME.LIBRARY.HOME_CONTENT',
      );
      await started.future;
      final secondRequest = second.request(
        'library/home_content',
        'ANIME.LIBRARY.HOME_CONTENT',
      );
      release.complete();
      await Future.wait([firstRequest, secondRequest]);
      expect(registrations, 1);
      expect(
        reused.any((d) => d.event == AnimeRiftAuthEvent.registrationReused),
        isTrue,
      );
    },
  );

  test(
    'fallback rejection surfaces its own status and cannot sign in',
    () async {
      final diagnostics = <AnimeRiftAuthDiagnostic>[];
      var registrations = 0;
      var signInCalls = 0;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
          if (o.uri.path.endsWith('/auth/register/device')) {
            registrations++;
            return reply(
              o,
              registrations == 1
                  ? {'error': 'INSTALL_SOURCE_NOT_SUPPORTED'}
                  : {},
              registrations == 1 ? 422 : 403,
            );
          }
          if (o.uri.path.endsWith('/auth/sign-in/with-code')) signInCalls++;
          return reply(o, {});
        }),
        onAuthDiagnostic: diagnostics.add,
        deviceDescriptorLoader: (_) async => const AnimeRiftDeviceDescriptor(
          os: 'ios',
          osId: '26.1',
          details: {'model': 'iPhone'},
        ),
      );
      await expectLater(
        client.signInWithCode('one-time-code'),
        throwsA(
          isA<AnimeRiftAccessUnavailable>()
              .having((e) => e.statusCode, 'final HTTP status', 403)
              .having(
                (e) => e.stage,
                'stage',
                AnimeRiftRequestStage.deviceRegistration,
              ),
        ),
      );
      expect(registrations, 2);
      expect(signInCalls, 0);
      expect(client.isAccountLinked, isFalse);
      expect(
        diagnostics[diagnostics.length - 2].event,
        AnimeRiftAuthEvent.compatibilityRejected,
      );
      expect(diagnostics.last.event, AnimeRiftAuthEvent.registrationFailed);
      expect(diagnostics.last.statusCode, 403);
    },
  );

  test(
    'never retries Android on 503, 429, 401, or native Android rejection',
    () async {
      for (final (os, status) in [
        ('ios', 503),
        ('ios', 429),
        ('ios', 401),
        ('android', 400),
      ]) {
        SharedPreferences.setMockInitialValues({});
        var registrationCalls = 0;
        final client = AnimeRiftApiClient(
          config: fixtureConfig,
          dio: fixtureDio((o) {
            if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
            if (o.uri.path.endsWith('/auth/register/device')) {
              registrationCalls++;
              return reply(o, {}, status);
            }
            return reply(o, {});
          }),
          deviceDescriptorLoader: (_) async => AnimeRiftDeviceDescriptor(
            os: os,
            osId: 'fixture',
            details: {'model': 'device'},
          ),
        );
        await expectLater(
          client.request('library/home_content', 'ANIME.LIBRARY.HOME_CONTENT'),
          throwsA(
            isA<AnimeRiftAccessUnavailable>().having(
              (e) => e.statusCode,
              'status',
              status,
            ),
          ),
        );
        expect(registrationCalls, 1);
      }
    },
  );

  test(
    'sign-in code HTTP errors are logged without retrying registration',
    () async {
      final diagnostics = <AnimeRiftAuthDiagnostic>[];
      var registrations = 0;
      var signInCalls = 0;
      final client = AnimeRiftApiClient(
        config: fixtureConfig,
        dio: fixtureDio((o) {
          if (o.uri.host.endsWith('googleapis.com')) return reply(o, {}, 400);
          if (o.uri.path.endsWith('/auth/register/device')) {
            registrations++;
            return reply(o, {}, 201);
          }
          if (o.uri.path.endsWith('/auth/sign-in/with-code')) {
            signInCalls++;
            return reply(o, {'error': 'private-body'}, 400);
          }
          return reply(o, {});
        }),
        onAuthDiagnostic: diagnostics.add,
        deviceDescriptorLoader: (_) async => const AnimeRiftDeviceDescriptor(
          os: 'ios',
          osId: '26.1',
          details: {'model': 'iPhone'},
        ),
      );
      await expectLater(
        client.signInWithCode('private-auth-code'),
        throwsA(
          isA<AnimeRiftAccessUnavailable>()
              .having((e) => e.stage, 'stage', AnimeRiftRequestStage.codeSignIn)
              .having((e) => e.statusCode, 'HTTP status', 400),
        ),
      );
      expect(registrations, 1);
      expect(signInCalls, 1);
      expect(diagnostics.last.event, AnimeRiftAuthEvent.codeSignInRejected);
      expect(diagnostics.last.statusCode, 400);
      expect(diagnostics.join(' | '), isNot(contains('private-auth-code')));
      expect(diagnostics.join(' | '), isNot(contains('private-body')));
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
          clock: () => DateTime.utc(2026, 11, 5, 11, i * 6),
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
    'expired guest registration renews read-only catalog pagination',
    () async {
      var registrations = 0;
      var pages = 0;
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
          expect(request.uri.path, endsWith('/library/all'));
          expect(request.method, 'POST');
          expect(request.queryParameters, {'page': '1'});
          expect(request.data, {'release_year': '2026'});
          pages++;
          return pages == 1
              ? reply(request, {}, 401)
              : reply(request, {'items': [], 'hasNext': false});
        }),
      );
      final response = await client.request(
        'library/all',
        'ANIME.LIBRARY.ALL',
        method: 'POST',
        query: {'page': '1'},
        body: {'release_year': '2026'},
      );
      expect(response['items'], isEmpty);
      expect(registrations, 2);
      expect(pages, 2);
    },
  );

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
    expect(secureCalls.where((call) => call.method == 'read'), hasLength(1));
    expect(restarted.isAccountLinked, isTrue);
  });

  test(
    'unlink cancels a pending secure sign-in write before deleting',
    () async {
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
    },
  );

  test(
    'link waits for in-flight unlink to complete before storing a token',
    () async {
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
    },
  );
}
