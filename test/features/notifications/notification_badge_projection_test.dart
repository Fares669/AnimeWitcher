import 'dart:convert';
import 'dart:typed_data';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_config.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/features/notifications/presentation/animewitcher_notifications_screen.dart';
import 'package:animewitcher/shared/widgets/account_notifications_button.dart';
import 'package:dio/dio.dart';
// These production widgets use Flutter Material's types.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';

const _profileId = 'projection-profile';
const _token = 'local-projection-fixture';
const _field = 'statistics.not_seen_notif';
const _document =
    'projects/${AnimeWitcherAccountConfig.projectId}/databases/(default)/documents';
const _profile = AnimeWitcherProfile(
  documentId: _profileId,
  uid: 'projection-account',
  signInMethod: AnimeWitcherSignInMethod.email,
);

class _Secure extends SecureTokenStorage {
  _Secure(super.storage);

  @override
  Future<String?> read(String key) async => switch (key) {
    'animewitcher_account_session_v1' => jsonEncode(
      AnimeWitcherSession(
        uid: _profile.uid,
        idToken: _token,
        refreshToken: 'unused-local-fixture',
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        signInMethod: _profile.signInMethod,
      ).toJson(),
    ),
    'animewitcher_account_profile_v1' => jsonEncode(_profile.toJson()),
    _ => null,
  };
}

class _Account extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() =>
      ref.read(animeWitcherAccountServiceProvider).restoreCachedSession();
}

// Transport callbacks run outside the test's guarded pump zone.
void _checkWire(Object? actual, Object? expected, String label) {
  if (jsonEncode(actual) != jsonEncode(expected)) {
    throw StateError('Unexpected offline fixture $label');
  }
}

class _WireFirestore implements HttpClientAdapter {
  final issued = <(String method, List<String>? mask, int bytes)>[];
  int count = 7;
  int seen = 0;
  int inboxLoads = 0;

  Map<String, Object?> _profileFields(bool projected) {
    return {
      if (!projected) ...{
        'uid': _profile.uid,
        'user_name': 'حساب الاختبار',
        'email': 'profile@example.invalid',
        'bio': 'واجهة فهرس الإشعارات. ' * 12,
        'country': 'EG',
        'date_created': DateTime.utc(2025, 6, 1),
        'photo_uri': 'https://example.invalid/unused-avatar.png',
        'cover_uri': 'https://example.invalid/unused-cover.png',
        'privacy_settings': {
          'list_visibility': 'friends',
          'watch_history': 'private',
          'manga_history': 'private',
          'favorite_characters': 'friends',
        },
        'statistics_manga': {'chapters': 120, 'titles': 27},
        'favorite_genres': ['action', 'adventure', 'science fiction'],
      },
      'statistics': {
        if (!projected) ...{
          'anime_count': 51,
          'watched_episodes': 480,
          'reviews': 17,
          'comments': 20,
          'watch_time_seconds': 642550,
          'favorites': 28,
        },
        'not_seen_notif': count,
      },
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _checkWire(options.headers['Authorization'], 'Bearer $_token', 'auth');
    final path = options.uri.path;
    if (path.endsWith('/documents/users/$_profileId') &&
        options.method == 'GET') {
      _checkWire(requestStream == null, true, 'GET body');
      final query = options.uri.queryParametersAll;
      final mask = query['mask.fieldPaths'];
      _checkWire(query.keys.toList(), ['mask.fieldPaths'], 'GET query keys');
      _checkWire(mask, [_field], 'GET mask');
      final body = jsonEncode({
        'name': '$_document/users/$_profileId',
        'fields': FirestoreValueCodec.encodeFields(
          _profileFields(mask != null),
        ),
      });
      issued.add((options.method, mask, utf8.encode(body).length));
      return _body(body);
    }
    if (path.endsWith('/documents/users/$_profileId:runQuery') &&
        options.method == 'POST') {
      inboxLoads++;
      _checkWire(options.data['structuredQuery']['from'], [
        {'collectionId': 'notifications'},
      ], 'inbox collection');
      return _body(
        jsonEncode([
          {
            'document': {
              'name': '$_document/users/$_profileId/notifications/local',
              'fields': FirestoreValueCodec.encodeFields({
                'type': 'review_like',
                'date': DateTime.utc(2025, 12, 8),
                'user': {'name': 'سارة'},
              }),
            },
          },
        ]),
      );
    }
    if (path.endsWith('/documents/users/$_profileId') &&
        options.method == 'PATCH') {
      seen++;
      _checkWire(
        options.uri.queryParameters['currentDocument.exists'],
        'true',
        'seen precondition',
      );
      _checkWire(options.uri.queryParametersAll['updateMask.fieldPaths'], [
        _field,
      ], 'seen update mask');
      _checkWire(options.data['fields'], {
        'statistics': {
          'mapValue': {
            'fields': {
              'not_seen_notif': {'integerValue': '0'},
            },
          },
        },
      }, 'seen update fields');
      count = 0;
      return _body('{}');
    }
    throw StateError(
      'Unexpected offline fixture request: ${options.method} $path',
    );
  }

  static ResponseBody _body(String body) => ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  testWidgets('badge and inbox keep every refresh with only the count field', (
    tester,
  ) async {
    final storage = MemoryStorageService();
    final wire = _WireFirestore();
    final dio = Dio()..httpClientAdapter = wire;
    addTearDown(dio.close);
    final service = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: _Secure(storage),
      firestore: FirestoreRestClient(dio: dio),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeWitcherAccountServiceProvider.overrideWithValue(service),
          animeWitcherAccountControllerProvider.overrideWith(_Account.new),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: AccountNotificationsButton()),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AccountNotificationsButton)),
    );
    Future<void> settleBadge(String expected) async {
      // The authenticated response is scheduled through Dio's async stream
      // pipeline, so a single idle frame isn't proof that the badge is ready.
      for (var i = 0; i < 20 && find.text(expected).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(service.isSignedIn, isTrue);
      expect(
        find.text(expected),
        findsOneWidget,
        reason:
            'Badge state: ${container.read(accountNotificationCountProvider)}; '
            'profile reads: ${wire.issued.length}',
      );
    }

    await settleBadge('7');
    expect(wire.issued, hasLength(1));

    wire.count = 8;
    container.read(accountDataRevisionProvider.notifier).bump();
    await settleBadge('8');
    expect(wire.issued, hasLength(2));

    wire.count = 9;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await settleBadge('9');
    expect(wire.issued, hasLength(3));

    await tester.tap(find.byType(AccountNotificationsButton));
    await tester.pumpAndSettle();
    expect(find.byType(AnimeWitcherNotificationsScreen), findsOneWidget);
    expect(find.textContaining('سارة'), findsOneWidget);
    expect(wire.inboxLoads, 1);
    expect(wire.seen, 1);
    expect(wire.issued, hasLength(4));

    // A new notification after marking seen must still be fetched on return.
    wire.count = 2;
    navigator.currentState!.pop();
    await settleBadge('2');
    expect(find.byType(AnimeWitcherNotificationsScreen), findsNothing);
    expect(wire.issued, hasLength(5));

    final bytes = wire.issued.map((request) => request.$3).toList();
    expect(bytes, everyElement(lessThan(240)));
  });
}
