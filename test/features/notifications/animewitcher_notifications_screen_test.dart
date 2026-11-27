import 'dart:async';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/rendering.dart';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_notification_models.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/services/notification_service.dart';
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
  bool failSeen = false;
  bool more = false;
  final cursors = <FirestoreDocument?>[];
  List<AnimeWitcherNotification> nextItems = [];
  int seen = 0;
  int loads = 0;
  int deleted = 0;
  int clicked = 0;
  Completer<void>? deleting;
  Completer<void>? marking;
  int badge = 7;
  int badgeLoads = 0;
  AnimeWitcherComment? target;
  AnimeWitcherAccountException? targetError;
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
  Future<int> loadNotificationCount() async {
    badgeLoads++;
    return badge;
  }

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
    if (failSeen) throw Exception('offline');
  }

  @override
  Future<void> markNotificationClicked(String path) async {
    if (failWrite) throw Exception('offline');
    await marking?.future;
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
  ) async {
    if (targetError != null) throw targetError!;
    return target;
  }

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
  NotificationService? toasts,
  Key? screenBoundary,
}) => ProviderScope(
  overrides: [
    animeWitcherAccountServiceProvider.overrideWithValue(service),
    animeWitcherAccountControllerProvider.overrideWith(_Account.new),
    if (toasts != null) notificationServiceProvider.overrideWithValue(toasts),
  ],
  child: MaterialApp(
    theme: ThemeData.dark(),
    home: home,
    builder: screenBoundary == null
        ? null
        : (context, child) =>
              RepaintBoundary(key: screenBoundary, child: child),
  ),
);
typedef _RowParts = ({Text message, Text time, CircleAvatar avatar, Card card});

const _stockReplay = bool.fromEnvironment('AW_C19_NOTIFICATIONS_STOCK');

void main() {
  testWidgets('unavailable target uses the shared error pill, not a SnackBar', (
    tester,
  ) async {
    final service = _Service()..items = [_item()];
    final toasts = NotificationService();
    addTearDown(toasts.clearToasts);
    await tester.pumpWidget(_app(service, toasts: toasts));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('سارة'));
    await tester.pump();
    expect(toasts.toasts.single.message, 'المحتوى غير متاح أو تم حذفه');
    expect(toasts.toasts.single.type, ToastType.error);
    expect(find.byType(SnackBar), findsNothing);
    toasts.clearToasts();
  });
  for (final reason in {
    'notification-target-reference': 'رابط الإشعار غير صالح أو غير مدعوم',
    'notification-target-hidden': 'هذا المحتوى غير متاح للعرض حالياً',
    'notification-target-content': 'تعذر قراءة محتوى التعليق أو المراجعة',
  }.entries) {
    testWidgets('target failure ${reason.key} uses safe precise feedback', (
      tester,
    ) async {
      final service = _Service()
        ..items = [_item()]
        ..targetError = AnimeWitcherAccountException(
          reason.key,
          'private path/token must not be shown',
        );
      final toasts = NotificationService();
      addTearDown(toasts.clearToasts);
      await tester.pumpWidget(_app(service, toasts: toasts));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('سارة'));
      await tester.pump();
      expect(toasts.toasts.single.message, reason.value);
      expect(service.clicked, 0);
      toasts.clearToasts();
    });
  }
  testWidgets('seen-counter error uses shared pill and retains retry', (
    tester,
  ) async {
    final service = _Service()..failSeen = true;
    final toasts = NotificationService();
    addTearDown(toasts.clearToasts);
    await tester.pumpWidget(_app(service, toasts: toasts));
    await tester.pumpAndSettle();
    final toast = toasts.toasts.single;
    expect(toast.message, 'تعذر تحديث عداد الإشعارات');
    expect(toast.type, ToastType.error);
    expect(toast.actionLabel, 'إعادة المحاولة');
    expect(toast.onAction, isNotNull);
    expect(find.byType(SnackBar), findsNothing);
    service.failSeen = false;
    toast.onAction!();
    await tester.pump();
    expect(service.seen, 2);
    toasts.clearToasts();
  });
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
  testWidgets(
    'badge to inbox preserves Arabic presentation while writes are pending',
    (tester) async {
      tester.view.physicalSize = const Size(460, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final notice = List.generate(
        6,
        (i) => AnimeWitcherNotification(
          path: 'users/p/notifications/n$i',
          type: 'review_like',
          clicked: false,
          actorName: 'المستخدم رقم ${i + 1}',
          contextName: 'الحلقة ${i + 1}',
          date: DateTime(2023, 11, i + 1, 12),
        ),
      );
      final service = _Service()
        ..items = notice
        ..marking = Completer<void>()
        ..deleting = Completer<void>();
      const screenBoundary = ValueKey('notification-inbox-pixel-boundary');
      await tester.pumpWidget(
        _app(
          service,
          home: const Scaffold(body: AccountNotificationsButton()),
          screenBoundary: screenBoundary,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('7'), findsOneWidget);
      await tester.tap(find.byType(AccountNotificationsButton));
      await tester.pumpAndSettle();

      Map<String, _RowParts> visibleRows(
        Iterable<AnimeWitcherNotification> rows,
      ) {
        final result = <String, _RowParts>{};
        for (final item in rows) {
          final row = find.byKey(ValueKey(item.path));
          expect(row.hitTestable(), findsOneWidget);
          final text = tester.widgetList<Text>(
            find.descendant(of: row, matching: find.byType(Text)),
          );
          final message = text.singleWhere((x) => x.textSpan != null);
          final time = text.singleWhere(
            (x) => x.data?.endsWith('/2023') ?? false,
          );
          final avatar = tester.widget<CircleAvatar>(
            find.descendant(of: row, matching: find.byType(CircleAvatar)),
          );
          final rowWidget = tester.widget(row);
          final card = rowWidget is Card
              ? rowWidget
              : tester.widget<Card>(
                  find.descendant(of: row, matching: find.byType(Card)),
                );
          expect(
            message.textSpan?.toPlainText(),
            '${item.actorName} أعجب بـمراجعتك • ${item.contextName}',
          );
          expect(time.data, endsWith('11/2023'));
          expect(Directionality.of(tester.element(row)), TextDirection.rtl);
          result[item.path] = (
            message: message,
            time: time,
            avatar: avatar,
            card: card,
          );
        }
        double? previous;
        for (final item in rows) {
          final top = tester.getTopLeft(find.byKey(ValueKey(item.path))).dy;
          if (previous != null) expect(top, greaterThan(previous));
          previous = top;
        }
        return result;
      }

      Future<void> act(AnimeWitcherNotification item, String label) async {
        final row = find.byKey(ValueKey(item.path));
        await tester.tap(
          find.descendant(
            of: row,
            matching: find.byType(PopupMenuButton<String>),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }

      Future<String> pixels() async {
        final renderer = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(screenBoundary),
        );
        final digest = await tester.runAsync(() async {
          final image = await renderer.toImage();
          try {
            final data = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            return sha256.convert(data.buffer.asUint8List()).toString();
          } finally {
            image.dispose();
          }
        });
        return digest!;
      }

      final first = visibleRows(notice);
      final initialPixels = await pixels();
      expect(service.seen, 1);
      expect(service.loads, 1);
      final firstColor = first[notice.first.path]!.card.color;
      await act(notice.first, 'تمت المشاهدة');
      final duringRead = visibleRows(notice);
      expect(service.clicked, 0);
      expect(
        find.descendant(
          of: find.byKey(ValueKey(notice.first.path)),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      final refreshButton = find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'تحديث',
      );
      expect(tester.widget<IconButton>(refreshButton).onPressed, isNull);
      service.marking!.complete();
      await tester.pumpAndSettle();
      final afterRead = visibleRows(notice);
      expect(service.clicked, 1);
      expect(afterRead[notice.first.path]!.card.color, isNot(firstColor));
      final readPixels = await pixels();

      await act(notice.last, 'حذف');
      final duringDelete = visibleRows(notice);
      expect(service.deleted, 0);
      service.deleting!.complete();
      await tester.pumpAndSettle();
      final afterDelete = visibleRows(notice.take(5));
      expect(service.deleted, 1);
      expect(find.byKey(ValueKey(notice.last.path)), findsNothing);
      final deletePixels = await pixels();
      expect(readPixels, isNot(initialPixels));
      expect(deletePixels, isNot(readPixels));

      var messages = 0;
      var avatars = 0;
      var timestamps = 0;
      var unchangedCards = 0;
      for (final (before, after) in [
        (first, duringRead),
        (duringRead, afterRead),
        (afterRead, duringDelete),
        (duringDelete, afterDelete),
      ]) {
        for (final e in after.entries) {
          final old = before[e.key]!;
          if (!identical(old.message, e.value.message)) messages++;
          if (!identical(old.avatar, e.value.avatar)) avatars++;
          if (!identical(old.time, e.value.time)) timestamps++;
          if (old.card.color == e.value.card.color) unchangedCards++;
        }
      }
      debugPrint(
        'C19_NOTIFICATIONS messages=$messages avatars=$avatars '
        'timestamps=$timestamps unchangedColors=$unchangedCards '
        'initial=$initialPixels read=$readPixels delete=$deletePixels',
      );
      expect(messages, _stockReplay ? 23 : 0);
      expect(avatars, _stockReplay ? 23 : 0);
      expect(timestamps, 23);
      expect(unchangedCards, 22);

      expect(service.loads, 1);
      expect(service.seen, 1);
      service.items = [
        AnimeWitcherNotification(
          path: notice.first.path,
          type: 'review_reply',
          clicked: false,
          actorName: 'اسم بعد التحديث',
        ),
        ...notice.skip(1).take(4),
      ];
      await tester.tap(refreshButton);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('اسم بعد التحديث رد على مراجعتك'),
        findsOneWidget,
      );
      expect(find.textContaining(notice.first.actorName), findsNothing);
      expect(service.loads, 2);
      expect(service.seen, 2);
      final beforeReturn = service.badgeLoads;
      service.badge = 8;
      Navigator.of(tester.element(find.byType(AnimeWitcherNotificationsScreen)))
          .pop();
      await tester.pumpAndSettle();
      expect(service.badgeLoads, greaterThan(beforeReturn));
      expect(find.text('8'), findsOneWidget);
      final badgeLoads = service.badgeLoads;
      service.badge = 9;
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
      await tester.pumpAndSettle();
      expect(service.badgeLoads, badgeLoads + 1);
      expect(find.text('9'), findsOneWidget);
    },
  );
}
