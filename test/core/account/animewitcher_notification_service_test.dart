import 'dart:async';
import 'dart:convert';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_notification_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/account/firebase_auth_rest_client.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

class _Storage extends MemoryStorageService {
  @override
  String? getString(String key) => null;
}

class _Secure extends SecureTokenStorage {
  _Secure(super.storage);
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _Auth extends FirebaseAuthRestClient {
  final started = Completer<void>();
  final refreshed = Completer<AnimeWitcherSession>();
  @override
  Future<AnimeWitcherSession> refresh(AnimeWitcherSession previous) {
    started.complete();
    return refreshed.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AnimeWitcherAccountService service;
  late _Secure secure;
  late _Auth auth;
  late List<RequestOptions> requests;
  late dynamic response;
  late int status;
  late Future<void> Function()? beforeResponse;
  Future<void> restore(String id) async {
    secure.values['animewitcher_account_session_v1'] = jsonEncode(
      AnimeWitcherSession(
        uid: 'uid-$id',
        idToken: 'token-$id',
        refreshToken: 'refresh',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        signInMethod: AnimeWitcherSignInMethod.email,
      ).toJson(),
    );
    secure.values['animewitcher_account_profile_v1'] = jsonEncode(
      AnimeWitcherProfile(
        documentId: id,
        uid: 'uid-$id',
        signInMethod: AnimeWitcherSignInMethod.email,
      ).toJson(),
    );
    await service.restoreCachedSession();
  }

  setUp(() async {
    auth = _Auth();
    requests = [];
    response = <dynamic>[];
    status = 200;
    beforeResponse = null;
    final storage = _Storage();
    secure = _Secure(storage);
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requests.add(options);
          await beforeResponse?.call();
          if (status != 200) {
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
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: response,
            ),
          );
        },
      ),
    );
    service = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: secure,
      auth: auth,
      firestore: FirestoreRestClient(dio: dio),
    );
    await restore('profile');
  });
  test(
    'loads 20 descending by date using profile id, without seen write',
    () async {
      final page = await service.loadNotifications();
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
      expect(requests, hasLength(1));
      expect(
        requests.single.path,
        endsWith('/documents/users/profile:runQuery'),
      );
      expect(requests.single.headers['Authorization'], 'Bearer token-profile');
      final query = requests.single.data['structuredQuery'] as Map;
      expect(query['limit'], 20);
      expect(query['from'], [
        {'collectionId': 'notifications'},
      ]);
      expect(query['orderBy'][0], {
        'field': {'fieldPath': 'date'},
        'direction': 'DESCENDING',
      });
    },
  );
  test('uses last document cursor and preserves full pages', () async {
    response = List.generate(
      20,
      (i) => {
        'document': {
          'name':
              'projects/animewitcher-1c66d/databases/(default)/documents/users/profile/notifications/n$i',
          'fields': {
            'date': {'timestampValue': '2026-01-01T00:00:00Z'},
          },
        },
      },
    );
    final page = await service.loadNotifications();
    expect(page.hasMore, isTrue);
    expect(page.cursor?.id, 'n19');
    response = <dynamic>[];
    await service.loadNotifications(cursor: page.cursor);
    expect(requests.last.data['structuredQuery']['startAt']['before'], isFalse);
    expect(
      requests
          .last
          .data['structuredQuery']['startAt']['values'][1]['referenceValue'],
      endsWith('/notifications/n19'),
    );
  });
  test('seen and clicked writes patch separate existing fields', () async {
    response = <String, dynamic>{};
    await service.markNotificationsSeen('profile');
    expect(requests.single.queryParameters['currentDocument.exists'], isTrue);
    expect(requests.single.queryParameters['updateMask.fieldPaths'], [
      'statistics.not_seen_notif',
    ]);
    expect(requests.single.data['fields'], {
      'statistics': {
        'mapValue': {
          'fields': {
            'not_seen_notif': {'integerValue': '0'},
          },
        },
      },
    });
    await service.markNotificationClicked('users/profile/notifications/n');
    expect(requests.last.queryParameters['updateMask.fieldPaths'], ['clicked']);
    expect(requests.last.data['fields'], {
      'clicked': {'booleanValue': true},
    });
    expect(requests.last.queryParameters['currentDocument.exists'], isTrue);
  });
  test(
    'rejects foreign notification mutations and cursor before network',
    () async {
      await expectLater(
        service.markNotificationClicked('users/other/notifications/n'),
        throwsA(isA<AnimeWitcherAccountException>()),
      );
      await expectLater(
        service.deleteNotification('users/other/notifications/n'),
        throwsA(isA<AnimeWitcherAccountException>()),
      );
      await expectLater(
        service.markNotificationsSeen('other'),
        throwsA(isA<AnimeWitcherAccountException>()),
      );
      await expectLater(
        service.loadNotifications(
          cursor: const FirestoreDocument(
            id: 'n',
            path: 'users/other/notifications/n',
            fields: {},
          ),
        ),
        throwsA(isA<AnimeWitcherAccountException>()),
      );
      expect(requests, isEmpty);
    },
  );
  test('delete only removes the selected owned notification', () async {
    response = <String, dynamic>{};
    await service.deleteNotification('users/profile/notifications/n');
    expect(requests.single.method, 'DELETE');
    expect(
      requests.single.path,
      endsWith('/documents/users/profile/notifications/n'),
    );
  });
  test('badge reads statistics, not count of unclicked rows', () async {
    response = {
      'name': 'projects/animewitcher-1c66d/databases/(default)/documents/users/profile',
      'fields': {
        'statistics': {
          'mapValue': {
            'fields': {
              'not_seen_notif': {'integerValue': '7'},
            },
          },
        },
      },
    };
    expect(await service.loadNotificationCount(), 7);
    expect(requests.single.method, 'GET');
  });
  test('account switch discards an in-flight notification page', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    beforeResponse = () async {
      started.complete();
      await release.future;
    };
    final result = service.loadNotifications();
    final assertion = expectLater(
      result,
      throwsA(isA<AnimeWitcherAccountException>()),
    );
    await started.future;
    await restore('other');
    release.complete();
    await assertion;
    expect(requests, hasLength(1));
  });
  test(
    'replacing even the same account session rejects stale badge result',
    () async {
      response = {
        'name': 'projects/animewitcher-1c66d/databases/(default)/documents/users/profile',
        'fields': {
          'statistics': {
            'mapValue': {
              'fields': {
                'not_seen_notif': {'integerValue': '7'},
              },
            },
          },
        },
      };
      final started = Completer<void>();
      final release = Completer<void>();
      beforeResponse = () async {
        started.complete();
        await release.future;
      };
      final assertion = expectLater(
        service.loadNotificationCount(),
        throwsA(isA<AnimeWitcherAccountException>()),
      );
      await started.future;
      await restore('profile');
      release.complete();
      await assertion;
    },
  );
  test(
    'account replacement during token refresh sends no notification write',
    () async {
      final original = AnimeWitcherSession.fromJson(
        jsonDecode(secure.values['animewitcher_account_session_v1']!)
            as Map<String, dynamic>,
      );
      secure.values['animewitcher_account_session_v1'] = jsonEncode(
        original.copyWith(expiresAt: DateTime.utc(2000)).toJson(),
      );
      await service.restoreCachedSession();
      final assertion = expectLater(
        service.markNotificationsSeen('profile'),
        throwsA(isA<AnimeWitcherAccountException>()),
      );
      await auth.started.future;
      await restore('other');
      auth.refreshed.complete(original);
      await assertion;
      expect(requests, isEmpty);
    },
  );
  test(
    'target resolution loads comment and review parents with correct text',
    () async {
      for (final review in [false, true]) {
        final path = 'anime_list/a/${review ? 'reviews' : 'comments'}/c';
        response = {
          'name':
              'projects/animewitcher-1c66d/databases/(default)/documents/$path',
          'fields': {
            review ? 'review_text' : 'comment': {'stringValue': 'parent text'},
          },
        };
        final item = AnimeWitcherNotification.fromDocument(
          FirestoreDocument(
            id: 'n',
            path: 'users/profile/notifications/n',
            fields: {
              'type': review ? 'review_reply' : 'anime_comment_reply',
              review ? 'review_doc_ref' : 'comment_doc_ref': path,
            },
          ),
        );
        final target = await service.loadNotificationTarget(item);
        expect(target?.text, 'parent text');
        expect(target?.isReview, review);
        expect(requests.last.path, endsWith('/documents/$path'));
      }
    },
  );
  for (final reference in [
    'anime_list/Anime Title/episodes/الحلقة 1/comments/c',
    'anime_list/Anime Title %2F #1?/comments/c',
    '/anime_list/a/comments/c/',
    'projects/animewitcher-1c66d/databases/(default)/documents/anime_list/a/comments/c',
  ]) {
    test('opens supported comment reference $reference', () async {
      final expectedPath = reference.contains('Anime Title')
          ? reference
          : 'anime_list/a/comments/c';
      final fields = FirestoreValueCodec.decodeFields({
        'type': {'stringValue': 'episode_comment_reply'},
        'comment_doc_ref': {'stringValue': reference},
      });
      final item = AnimeWitcherNotification.fromDocument(
        FirestoreDocument(
          id: 'n',
          path: 'users/profile/notifications/n',
          fields: fields,
        ),
      );
      response = {
        'name':
            'projects/animewitcher-1c66d/databases/(default)/documents/$expectedPath',
        'fields': {
          'comment': {'stringValue': 'existing comment'},
        },
      };
      final target = await service.loadNotificationTarget(item);
      expect(target?.text, 'existing comment');
      expect(target?.path, expectedPath);
      expect(requests.single.method, 'GET');
      if (reference.contains('%2F')) {
        expect(requests.single.path, contains('%252F'));
        expect(requests.single.queryParameters, isEmpty);
      }
      expect(
        Uri.decodeComponent(requests.single.path),
        endsWith('/documents/$expectedPath'),
      );
    });
  }
  test(
    'new notification type still opens its validated comment reference',
    () async {
      final item = AnimeWitcherNotification.fromDocument(
        const FirestoreDocument(
          id: 'n',
          path: 'users/profile/notifications/n',
          fields: {
            'type': 'future_comment_action',
            'comment_doc_ref': 'anime_list/a/comments/c',
          },
        ),
      );
      response = {
        'name': 'projects/animewitcher-1c66d/databases/(default)/documents/anime_list/a/comments/c',
        'fields': {
          'comment': {'stringValue': 'existing comment'},
        },
      };
      expect(
        (await service.loadNotificationTarget(item))?.text,
        'existing comment',
      );
    },
  );

  test(
    'deleted target returns no route while network errors remain errors',
    () async {
      final item = AnimeWitcherNotification.fromDocument(
        const FirestoreDocument(
          id: 'n',
          path: 'users/profile/notifications/n',
          fields: {
            'type': 'review_reply',
            'review_doc_ref': 'anime_list/a/reviews/r',
          },
        ),
      );
      status = 404;
      expect(await service.loadNotificationTarget(item), isNull);
      status = 503;
      await expectLater(
        service.loadNotificationTarget(item),
        throwsA(isA<AnimeWitcherAccountException>()),
      );
    },
  );
  for (final project in ['foreign', 'animewitcher-1c66d']) {
    test('referenceValue preserves project identity for $project', () async {
      final fields = FirestoreValueCodec.decodeFields({
        'type': {'stringValue': 'anime_comment_reply'},
        'comment_doc_ref': {
          'referenceValue':
              'projects/$project/databases/(default)/documents/anime_list/a/comments/c',
        },
      });
      final item = AnimeWitcherNotification.fromDocument(
        FirestoreDocument(
          id: 'n',
          path: 'users/profile/notifications/n',
          fields: fields,
        ),
      );
      response = {
        'name': 'projects/animewitcher-1c66d/databases/(default)/documents/anime_list/a/comments/c',
        'fields': {
          'comment': {'stringValue': 'existing comment'},
        },
      };
      if (project == 'foreign') {
        await expectLater(
          service.loadNotificationTarget(item),
          throwsA(
            isA<AnimeWitcherAccountException>().having(
              (e) => e.code,
              'code',
              'notification-target-reference',
            ),
          ),
        );
        expect(requests, isEmpty);
      } else {
        expect(
          (await service.loadNotificationTarget(item))?.text,
          'existing comment',
        );
      }
    });
  }
  test('existing empty target is invalid response, not deleted', () async {
    final item = AnimeWitcherNotification.fromDocument(
      const FirestoreDocument(
        id: 'n',
        path: 'users/profile/notifications/n',
        fields: {
          'type': 'anime_comment_like',
          'comment_doc_ref': 'anime_list/a/comments/c',
        },
      ),
    );
    response = {
      'name': 'projects/animewitcher-1c66d/databases/(default)/documents/anime_list/a/comments/c',
      'fields': <String, dynamic>{},
    };
    await expectLater(
      service.loadNotificationTarget(item),
      throwsA(
        isA<AnimeWitcherAccountException>().having(
          (e) => e.code,
          'code',
          'notification-target-content',
        ),
      ),
    );
  });
  test('unpublished target remains unavailable', () async {
    final item = AnimeWitcherNotification.fromDocument(
      const FirestoreDocument(
        id: 'n',
        path: 'users/profile/notifications/n',
        fields: {
          'type': 'anime_comment_like',
          'comment_doc_ref': 'anime_list/a/comments/c',
        },
      ),
    );
    response = {
      'name': 'projects/animewitcher-1c66d/databases/(default)/documents/anime_list/a/comments/c',
      'fields': {
        'comment': {'stringValue': 'hidden comment'},
        'published': {'booleanValue': false},
      },
    };
    await expectLater(
      service.loadNotificationTarget(item),
      throwsA(
        isA<AnimeWitcherAccountException>().having(
          (e) => e.code,
          'code',
          'notification-target-hidden',
        ),
      ),
    );
  });
  test(
    'target resolution rejects arbitrary references before network',
    () async {
      final item = AnimeWitcherNotification.fromDocument(
        const FirestoreDocument(
          id: 'n',
          path: 'users/profile/notifications/n',
          fields: {'type': 'review_reply', 'review_doc_ref': 'users/private'},
        ),
      );
      await expectLater(
        service.loadNotificationTarget(item),
        throwsA(
          isA<AnimeWitcherAccountException>().having(
            (e) => e.code,
            'code',
            'notification-target-reference',
          ),
        ),
      );
      expect(requests, isEmpty);
    },
  );
}
