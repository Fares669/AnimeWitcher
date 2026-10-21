import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_notification_models.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/notifications/presentation/animewitcher_notifications_screen.dart';
import 'package:animewitcher/shared/widgets/account_notifications_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Service extends AnimeWitcherAccountService {
  _Service()
    : super(
        storage: StorageService(),
        secureStorage: SecureTokenStorage(StorageService()),
      );
  bool fail = false;
  bool failWrite = false;
  bool more = false;
  final cursors = <FirestoreDocument?>[];
  List<AnimeWitcherNotification> nextItems = [];
  int seen = 0;
  int loads = 0;
  int deleted = 0;
  int clicked = 0;
  Completer<void>? deleting;
  AnimeWitcherComment? target;
  String user = 'p';
  Completer<AnimeWitcherNotificationPage>? pending;
  List<AnimeWitcherNotification> items = [];
  @override
  AnimeWitcherAccountSnapshot get snapshot => AnimeWitcherAccountSnapshot(
    profile: AnimeWitcherProfile(
      documentId: user,
      uid: user,
      signInMethod: AnimeWitcherSignInMethod.email,
    ),
  );
  @override
  Future<int> loadNotificationCount() async => 7;
  @override
  Future<AnimeWitcherNotificationPage> loadNotifications({
    FirestoreDocument? cursor,
  }) async {
    loads++;
    cursors.add(cursor);
    if (fail) throw Exception('offline');
    if (pending != null) return pending!.future;
    return AnimeWitcherNotificationPage(
      items: cursor == null ? items : nextItems,
      cursor: const FirestoreDocument(
        id: 'n',
        path: 'users/p/notifications/n',
        fields: {},
      ),
      hasMore: cursor == null && more,
    );
  }

  @override
  Future<void> markNotificationsSeen(String profileId) async {
    seen++;
  }

  @override
  Future<void> markNotificationClicked(String path) async {
    if (failWrite) throw Exception('offline');
    clicked++;
  }

  @override
  Future<void> deleteNotification(String path) async {
    if (failWrite) throw Exception('offline');
    await deleting?.future;
    deleted++;
  }

  @override
  Future<AnimeWitcherComment?> loadNotificationTarget(
    AnimeWitcherNotification notification,
  ) async => target;
  @override
  Future<AnimeWitcherCommentPage> loadReplies(
    AnimeWitcherComment parent, {
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async =>
      const AnimeWitcherCommentPage(items: [], cursor: null, hasMore: false);
}

class _Account extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      ref.read(animeWitcherAccountServiceProvider).snapshot;
}

AnimeWitcherNotification _item() => AnimeWitcherNotification.fromDocument(
  const FirestoreDocument(
    id: 'n',
    path: 'users/p/notifications/n',
    fields: {
      'type': 'review_like',
      'user': {'name': 'سارة'},
    },
  ),
);
Widget _app(
  _Service service, {
  Widget home = const AnimeWitcherNotificationsScreen(),
}) => ProviderScope(
  overrides: [
    animeWitcherAccountServiceProvider.overrideWithValue(service),
    animeWitcherAccountControllerProvider.overrideWith(_Account.new),
  ],
  child: MaterialApp(theme: ThemeData.dark(), home: home),
);
void main() {
  testWidgets('initial error does not reset seen; retry displays empty inbox', (
    tester,
  ) async {
    final service = _Service()..fail = true;
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    expect(service.seen, 0);
    expect(find.text('إعادة المحاولة'), findsOneWidget);
    service.fail = false;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(find.text('لا يوجد إشعارات'), findsOneWidget);
    expect(service.seen, 1);
  });
  testWidgets(
    'seen resets after displayed results without marking rows clicked',
    (tester) async {
      final service = _Service()..items = [_item()];
      await tester.pumpWidget(_app(service));
      await tester.pumpAndSettle();
      expect(find.textContaining('سارة'), findsOneWidget);
      expect(service.seen, 1);
      expect(service.clicked, 0);
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تمت المشاهدة'));
      await tester.pumpAndSettle();
      expect(service.clicked, 1);
      expect(find.textContaining('سارة'), findsOneWidget);
    },
  );
  testWidgets('failed deletion leaves notification and shows retryable error', (
    tester,
  ) async {
    final service = _Service()
      ..items = [_item()]
      ..failWrite = true;
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف'));
    await tester.pumpAndSettle();
    expect(find.textContaining('سارة'), findsOneWidget);
    expect(service.deleted, 0);
    service.failWrite = false;
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف'));
    await tester.pumpAndSettle();
    expect(find.text('لا يوجد إشعارات'), findsOneWidget);
    expect(service.deleted, 1);
  });
  testWidgets('pagination appends and refresh restarts the cursor', (
    tester,
  ) async {
    final second = AnimeWitcherNotification.fromDocument(
      const FirestoreDocument(
        id: 'n2',
        path: 'users/p/notifications/n2',
        fields: {
          'type': 'review_reply',
          'user': {'name': 'ثان'},
        },
      ),
    );
    final service = _Service()
      ..items = [_item()]
      ..more = true
      ..nextItems = [second];
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تحميل المزيد'));
    await tester.pumpAndSettle();
    expect(find.textContaining('سارة'), findsOneWidget);
    expect(find.textContaining('ثان'), findsOneWidget);
    expect(service.cursors.last, isNotNull);
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();
    expect(service.cursors.last, isNull);
    expect(find.textContaining('ثان'), findsNothing);
  });
  for (final review in [false, true]) {
    testWidgets(
      'opening ${review ? 'review' : 'comment'} shows parent even without replies',
      (tester) async {
        final service = _Service()
          ..items = [_item()]
          ..target = AnimeWitcherComment(
            id: 'c',
            path: 'anime_list/a/${review ? 'reviews' : 'comments'}/c',
            text: 'النص الأصلي',
            userId: 'actor',
            userName: 'الكاتب',
            likes: 0,
            replies: 0,
            spoiler: false,
          );
        await tester.pumpWidget(_app(service));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('سارة'));
        await tester.pumpAndSettle();
        expect(find.text('النص الأصلي'), findsOneWidget);
        expect(find.text('لا توجد ردود بعد.'), findsOneWidget);
        expect(service.clicked, 1);
      },
    );
  }
  testWidgets(
    'notification parent spoiler stays hidden until explicitly revealed',
    (tester) async {
      final service = _Service()
        ..items = [_item()]
        ..target = const AnimeWitcherComment(
          id: 'c',
          path: 'anime_list/a/comments/c',
          text: 'نص حرق مخفي',
          userId: 'actor',
          userName: 'الكاتب',
          likes: 0,
          replies: 0,
          spoiler: true,
        );
      await tester.pumpWidget(_app(service));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('سارة'));
      await tester.pumpAndSettle();
      expect(find.text('نص حرق مخفي'), findsNothing);
      await tester.tap(find.text('تعليق يحتوي على حرق — اضغط للعرض'));
      await tester.pumpAndSettle();
      expect(find.text('نص حرق مخفي'), findsOneWidget);
    },
  );
  testWidgets('refresh cannot race an unfinished deletion', (tester) async {
    final service = _Service()
      ..items = [_item()]
      ..deleting = Completer<void>();
    await tester.pumpWidget(_app(service));
    await tester.pumpAndSettle();
    final loads = service.loads;
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester
        .widget<MouseDragRefreshIndicator>(
          find.byType(MouseDragRefreshIndicator),
        )
        .onRefresh();
    expect(service.loads, loads);
    service.deleting!.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('سارة'), findsNothing);
    expect(find.text('لا يوجد إشعارات'), findsOneWidget);
  });
  testWidgets(
    'badge opens the shared inbox and refreshes its count on return',
    (tester) async {
      final service = _Service();
      await tester.pumpWidget(
        _app(service, home: const Scaffold(body: AccountNotificationsButton())),
      );
      await tester.pumpAndSettle();
      expect(find.text('7'), findsOneWidget);
      await tester.tap(find.byType(AccountNotificationsButton));
      await tester.pumpAndSettle();
      expect(find.byType(AnimeWitcherNotificationsScreen), findsOneWidget);
    },
  );
  testWidgets(
    'account change cannot show old results or reset new account badge',
    (tester) async {
      final service = _Service()
        ..pending = Completer<AnimeWitcherNotificationPage>();
      await tester.pumpWidget(_app(service));
      await tester.pump();
      service.user = 'other';
      service.pending!.complete(
        AnimeWitcherNotificationPage(
          items: [_item()],
          cursor: null,
          hasMore: false,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('سارة'), findsNothing);
      expect(service.seen, 0);
    },
  );
}
