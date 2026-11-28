import 'dart:async';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/animewitcher_notification_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
import 'package:animewitcher/features/notifications/presentation/animewitcher_notifications_screen.dart';
import 'package:animewitcher/features/settings/presentation/account_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_storage_service.dart';
import '../../support/test_fonts.dart';

const _boundary = ValueKey('inbox-route-frame');
const _bell = ValueKey('account-notifications-button');
const _signedIn = AnimeWitcherProfile(
  documentId: 'fixture-profile',
  uid: 'fixture-owner',
  signInMethod: AnimeWitcherSignInMethod.email,
  userName: 'المستخدم المحلي',
  email: 'reader@example.invalid',
);
const _replacement = AnimeWitcherProfile(
  documentId: 'fixture-profile',
  uid: 'replacement-owner',
  signInMethod: AnimeWitcherSignInMethod.email,
  userName: 'الحساب البديل',
  email: 'replacement@example.invalid',
);
String _name(int n) => 'اسم الحساب ${(n + 1).toString().padLeft(3, '0')}';
const _wrongName = 'مكرر غير مقبول';
const _newName = 'صاحب الإشعار الجديد';
const _staleName = 'إشعار متأخر من الحساب الأول';

class _Secure extends SecureTokenStorage {
  _Secure(super.storage);

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) async {
    throw StateError('The offline fixture must not write credentials');
  }
}

class _Controller extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot(profile: _signedIn);

  void publish(AnimeWitcherAccountSnapshot snapshot) {
    state = AsyncData(snapshot);
    ref.read(accountDataRevisionProvider.notifier).bump();
  }
}

AnimeWitcherNotification _row(int id, [String? name]) =>
    AnimeWitcherNotification(
      path: 'users/fixture-profile/notifications/$id',
      type: id.isEven ? 'review_like' : 'anime_comment_reply',
      clicked: false,
      actorName: name ?? _name(id),
      date: DateTime(2023, 5, 22, 12),
      contextName: 'عنوان الحلقة',
    );

class _Service extends AnimeWitcherAccountService {
  _Service(StorageService storage, SecureTokenStorage secure)
    : super(storage: storage, secureStorage: secure);

  AnimeWitcherProfile owner = _signedIn;
  final calls = <(String, String?)>[];
  final seen = <(String, String)>[];
  final clicked = <String>[];
  final deleted = <String>[];
  final opened = <String>[];
  Completer<AnimeWitcherNotificationPage>? delayInitial;

  static const pageSize = 20;
  static const pageCount = 6;

  @override
  AnimeWitcherAccountSnapshot get snapshot =>
      AnimeWitcherAccountSnapshot(profile: owner);

  @override
  Future<int> loadNotificationCount() async =>
      seen.any((event) => event.$1 == owner.uid) ? 0 : 7;

  @override
  Future<AnimeWitcherNotificationPage> loadNotifications({
    FirestoreDocument? cursor,
  }) async {
    calls.add((owner.uid, cursor?.id));
    if (cursor == null && delayInitial != null) {
      final result = delayInitial!;
      delayInitial = null;
      return result.future;
    }
    if (owner.uid == _replacement.uid) {
      return AnimeWitcherNotificationPage(
        items: [_row(666, _newName)],
        cursor: null,
        hasMore: false,
      );
    }
    final index = cursor == null ? 0 : int.parse(cursor.id) + 1;
    final newCount = index == 0 ? pageSize : pageSize - 2;
    final first = index == 0 ? 0 : pageSize + (index - 1) * newCount;
    final page = <AnimeWitcherNotification>[
      if (index > 0) _row(index == 1 ? 0 : first - newCount, _wrongName),
      for (var i = first; i < first + newCount; i++) _row(i),
      if (index > 0) _row(first, _wrongName),
    ];
    return AnimeWitcherNotificationPage(
      items: List.unmodifiable(page),
      cursor: FirestoreDocument(
        id: '$index',
        path: 'users/fixture-profile/notifications/cursor-$index',
        fields: {},
      ),
      hasMore: index < pageCount - 1,
    );
  }

  @override
  Future<void> markNotificationsSeen(String profileId) async {
    seen.add((owner.uid, profileId));
  }

  @override
  Future<void> markNotificationClicked(String path) async {
    clicked.add(path);
  }

  @override
  Future<void> deleteNotification(String path) async {
    deleted.add(path);
  }

  @override
  Future<AnimeWitcherComment?> loadNotificationTarget(
    AnimeWitcherNotification notification,
  ) async {
    opened.add(notification.path);
    return const AnimeWitcherComment(
      id: 'reply-target',
      path: 'anime_list/local/comments/reply-target',
      text: 'نص التعليق الأصلي',
      userId: 'writer',
      userName: 'الكاتب',
      likes: 0,
      replies: 0,
      spoiler: false,
    );
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

Future<String> _rgba(
  WidgetTester tester,
) async => (await tester.runAsync(() async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  final image = await boundary.toImage();
  try {
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return sha256
        .convert(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        )
        .toString();
  } finally {
    image.dispose();
  }
}))!;

const _stock = bool.fromEnvironment('AW_C27_NOTIFICATIONS_STOCK');

void main() {
  testWidgets('Arabic More opens a stable paged notification inbox', (
    tester,
  ) async {
    const size = Size(420, 850);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(
      () => TestFonts.loadFamily('Readex Pro', [
        'assets/fonts/readex_pro/ReadexPro-Regular.ttf',
        'assets/fonts/readex_pro/ReadexPro-Bold.ttf',
      ]),
    );
    final memory = MemoryStorageService();
    final secure = _Secure(memory);
    final account = _Controller();
    final service = _Service(memory, secure);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(memory),
          secureTokenStorageProvider.overrideWithValue(secure),
          animeWitcherAccountControllerProvider.overrideWith(() => account),
          animeWitcherAccountServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'Readex Pro',
            ),
          ),
          builder: (_, child) => RepaintBoundary(key: _boundary, child: child),
          home: const MoreScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(_signedIn.userName!));
    await tester.pumpAndSettle();
    expect(find.byType(AnimeWitcherAccountScreen), findsOneWidget);
    expect(find.byTooltip('الإشعارات، 7 غير مشاهدة'), findsOneWidget);
    await tester.tap(find.byKey(_bell));
    await tester.pumpAndSettle();

    final inbox = find.byType(AnimeWitcherNotificationsScreen);
    Finder inside(Finder item) => find.descendant(of: inbox, matching: item);
    Finder rowText(String text) => inside(find.textContaining(text));
    final first = rowText(_name(0));
    final menu = inside(find.byTooltip('خيارات الإشعار'));
    expect(inbox, findsOneWidget);
    expect(Directionality.of(tester.element(inbox)), TextDirection.rtl);
    expect(first, findsOneWidget);
    expect(service.calls, [(_signedIn.uid, null)]);
    expect(service.seen, [(_signedIn.uid, _signedIn.documentId)]);
    expect(service.clicked, isEmpty);

    final frames = <String>[await _rgba(tester)];
    var inboxRebuilds = 0;
    final previousHook = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, built) {
      previousHook?.call(element, built);
      if (element.widget is AnimeWitcherNotificationsScreen) inboxRebuilds++;
    };
    var cardReplacements = 0;
    final card = find.ancestor(of: first, matching: find.byType(Card)).first;
    try {
      for (var i = 0; i < 12; i++) {
        final before = tester.widget<Card>(card);
        account.publish(
          AnimeWitcherAccountSnapshot(
            profile: _signedIn,
            lastSyncAt: DateTime.utc(2026, 1, 1, 0, i),
          ),
        );
        await tester.pumpAndSettle();
        if (!identical(before, tester.widget<Card>(card))) cardReplacements++;
      }
    } finally {
      debugOnRebuildDirtyWidget = previousHook;
    }
    expect(inboxRebuilds, _stock ? 12 : 0);
    expect(cardReplacements, _stock ? 12 : 0);
    expect(service.calls, [(_signedIn.uid, null)]);
    expect(service.seen, hasLength(1));
    frames.add(await _rgba(tester));
    expect(frames[1], frames[0]);

    final scroll = tester
        .state<ScrollableState>(inside(find.byType(Scrollable)))
        .position;
    for (var page = 1; page < _Service.pageCount; page++) {
      expect(service.calls, hasLength(page));
      // A builder-backed scroll position estimates the tail until it
      // lays out the new last viewport; keep scrolling to the real tail.
      for (
        var attempt = 0;
        attempt < 8 && service.calls.length == page;
        attempt++
      ) {
        scroll.jumpTo(scroll.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      expect(service.calls.last, (_signedIn.uid, '${page - 1}'));
      expect(service.calls, hasLength(page + 1));
    }
    for (
      var attempt = 0;
      attempt < 8 && rowText(_name(109)).evaluate().isEmpty;
      attempt++
    ) {
      scroll.jumpTo(scroll.maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(rowText(_name(109)), findsOneWidget);
    expect(rowText(_wrongName), findsNothing);
    frames.add(await _rgba(tester));
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(first, findsOneWidget);
    expect(rowText(_wrongName), findsNothing);
    frames.add(await _rgba(tester));
    expect(frames.last, frames[0]);
    // Walk the actual viewport to the first new item of the first append:
    // its first payload, not the duplicate at the tail, must survive.
    await tester.scrollUntilVisible(
      rowText(_name(20)),
      330,
      maxScrolls: 14,
      scrollable: inside(find.byType(Scrollable)),
    );
    await tester.pumpAndSettle();
    expect(rowText(_name(20)), findsOneWidget);
    expect(rowText(_wrongName), findsNothing);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();

    // Run the public menu operation and then confirm a real open/Back
    // round trip keeps the saved clicked state and the other rows.
    await tester.tap(menu.first);
    await tester.pumpAndSettle();
    expect(find.text('تمت المشاهدة'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.text('تمت المشاهدة'), findsOneWidget);
    await tester.tap(find.text('تمت المشاهدة'));
    await tester.pumpAndSettle();
    expect(service.clicked, [_row(0).path]);
    frames.add(await _rgba(tester));

    await tester.tap(first);
    await tester.pumpAndSettle();
    expect(find.text('نص التعليق الأصلي'), findsOneWidget);
    expect(service.opened, [_row(0).path]);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(first, findsOneWidget);

    await tester.tap(menu.first);
    await tester.pumpAndSettle();
    expect(find.text('تمت المشاهدة'), findsNothing);
    await tester.tap(find.text('حذف'));
    await tester.pumpAndSettle();
    expect(service.deleted, [_row(0).path]);
    expect(first, findsNothing);
    expect(rowText(_name(1)), findsOneWidget);
    frames.add(await _rgba(tester));

    // The older response has the same Firestore document ID but a former
    // login UID. It must never replace or mark the new inbox as seen.
    final stale = Completer<AnimeWitcherNotificationPage>();
    service.delayInitial = stale;
    await tester.tap(inside(find.byTooltip('تحديث')));
    await tester.pump();
    expect(service.calls.last, (_signedIn.uid, null));
    service.owner = _replacement;
    account.publish(const AnimeWitcherAccountSnapshot(profile: _replacement));
    await tester.pumpAndSettle();
    expect(rowText(_newName), findsOneWidget);
    stale.complete(
      AnimeWitcherNotificationPage(
        items: [_row(666, _staleName)],
        cursor: null,
        hasMore: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(rowText(_newName), findsOneWidget);
    expect(rowText(_staleName), findsNothing);
    expect(service.seen, [
      (_signedIn.uid, _signedIn.documentId),
      (_replacement.uid, _replacement.documentId),
    ]);
    expect(service.calls, [
      (_signedIn.uid, null),
      for (var i = 0; i < 5; i++) (_signedIn.uid, '$i'),
      (_signedIn.uid, null),
      (_replacement.uid, null),
    ]);
    frames.add(await _rgba(tester));

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(AnimeWitcherAccountScreen), findsOneWidget);
    expect(find.byTooltip('الإشعارات'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugPrint('C27_NOTIFY_REBUILDS $inboxRebuilds $cardReplacements');
    debugPrint('C27_NOTIFY_RGBA ${frames.join(',')}');
  });
}
