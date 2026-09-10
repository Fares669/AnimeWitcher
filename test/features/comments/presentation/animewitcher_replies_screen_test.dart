import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/comments/presentation/animewitcher_comments_screen.dart';
import 'package:animewitcher/features/comments/presentation/animewitcher_replies_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';
import '../../../support/debug_shots.dart';

class _FakeAccountService extends AnimeWitcherAccountService {
  _FakeAccountService({
    required this.comments,
    required this.replies,
    this.signedIn = true,
  }) : super(
         storage: StorageService(),
         secureStorage: SecureTokenStorage(StorageService()),
       );

  final List<AnimeWitcherComment> comments;
  final List<AnimeWitcherComment> replies;
  final bool signedIn;
  final String myUserId = 'me';

  int loadCommentsCalls = 0;
  int loadRepliesCalls = 0;
  AnimeWitcherCommentSort? lastRepliesSort;
  String? lastPublishedText;
  String? lastPublishedUserTagId;

  @override
  bool get isSignedIn => signedIn;

  @override
  AnimeWitcherAccountSnapshot get snapshot => AnimeWitcherAccountSnapshot(
    profile: signedIn
        ? AnimeWitcherProfile(
            documentId: myUserId,
            uid: myUserId,
            signInMethod: AnimeWitcherSignInMethod.google,
            userName: 'Me',
          )
        : null,
  );

  @override
  bool ownsComment(AnimeWitcherComment comment) {
    return signedIn && comment.userId == myUserId;
  }

  @override
  Future<AnimeWitcherCommentPage> loadComments(
    AnimeWitcherCommentTarget target, {
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async {
    loadCommentsCalls += 1;
    return AnimeWitcherCommentPage(
      items: comments,
      cursor: null,
      hasMore: false,
    );
  }

  @override
  Future<AnimeWitcherCommentPage> loadReplies(
    AnimeWitcherComment parent, {
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async {
    loadRepliesCalls += 1;
    lastRepliesSort = sort;
    return AnimeWitcherCommentPage(
      items: replies,
      cursor: null,
      hasMore: false,
    );
  }

  @override
  Future<void> publishReply(
    AnimeWitcherComment parent,
    String rawReply, {
    String? userTagId,
  }) async {
    lastPublishedText = rawReply.trim();
    lastPublishedUserTagId = userTagId;
  }

  @override
  Future<AnimeWitcherComment> toggleCommentLike(
    AnimeWitcherComment comment,
  ) async {
    return comment;
  }
}

class _FixedAccountController extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    return ref.read(animeWitcherAccountServiceProvider).snapshot;
  }
}

AnimeWitcherComment _comment({
  required String id,
  required String userId,
  required String userName,
  String text = 'تعليق',
  int replies = 1,
  String collection = 'anime_list/a/comments',
}) {
  return AnimeWitcherComment(
    id: id,
    path: '$collection/$id',
    text: text,
    userId: userId,
    userName: userName,
    likes: 0,
    replies: replies,
    spoiler: false,
    date: DateTime.now().subtract(const Duration(hours: 6)),
  );
}

const _target = AnimeWitcherCommentTarget(
  collectionPath: 'anime_list/a/comments',
  sourceDocumentPath: 'anime_list/a',
  title: 'Hunter x Hunter',
);

Widget _app({
  required _FakeAccountService service,
  required Widget home,
  Key? shotKey,
}) {
  Widget child = home;
  if (shotKey != null) {
    child = RepaintBoundary(key: shotKey, child: home);
  }
  return ProviderScope(
    overrides: [
      animeWitcherAccountServiceProvider.overrideWithValue(service),
      animeWitcherAccountControllerProvider.overrideWith(
        _FixedAccountController.new,
      ),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'NotoSansArabic',
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFEEC60A),
          surface: Color(0xFF000000),
          onSurface: Color(0xFFE5E7EB),
        ),
      ),
      home: child,
    ),
  );
}

Future<void> _writeShot(WidgetTester tester, String filename, Key key) async {
  final artifacts = debugShotDirectory();
  if (artifacts == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(key),
    );
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('${artifacts.path}/$filename')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final parent = _comment(
    id: 'c1',
    userId: 'author',
    userName: 'Author',
    text: 'من هذا؟',
  );
  final otherReply = _comment(
    id: 'r1',
    userId: 'user-2',
    userName: 'حمزة سان 7amza san يوتيوب',
    text: 'انا فكرتها كيلوا',
    replies: 0,
    collection: parent.repliesCollectionPath,
  );
  final ownReply = _comment(
    id: 'r2',
    userId: 'me',
    userName: 'Me',
    text: 'ردي',
    replies: 0,
    collection: parent.repliesCollectionPath,
  );
  final secondReply = _comment(
    id: 'r3',
    userId: 'user-3',
    userName: 'Killua',
    text: 'ثاني',
    replies: 0,
    collection: parent.repliesCollectionPath,
  );

  testWidgets(
    'replies load oldest first and place mention start-side of likes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(TestFonts.loadWalkthroughFonts);

      final service = _FakeAccountService(
        comments: <AnimeWitcherComment>[parent],
        replies: <AnimeWitcherComment>[otherReply],
      );
      const shotKey = ValueKey<String>('replies-shot');

      await tester.pumpWidget(
        _app(
          service: service,
          shotKey: shotKey,
          home: AnimeWitcherRepliesScreen(parentComment: parent),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('الردود'), findsOneWidget);
      expect(find.text('اكتب رداً...'), findsOneWidget);
      expect(find.byTooltip('ترتيب الردود'), findsOneWidget);
      expect(service.lastRepliesSort, AnimeWitcherCommentSort.oldest);

      await _writeShot(tester, 'replies_mention_and_sort.png', shotKey);

      final mention = tester.getRect(
        find.byKey(ValueKey<String>('reply-mention-${otherReply.path}')),
      );
      final heart = tester.getRect(find.byIcon(Icons.favorite_border_rounded));
      expect(
        mention.center.dx,
        greaterThan(heart.center.dx),
        reason: 'RTL: mention sits on the start-side (right) of the like row',
      );

      await tester.tap(find.byTooltip('ترتيب الردود'));
      await tester.pumpAndSettle();
      expect(find.text('الأحدث'), findsWidgets);
      expect(find.text('الأقدم'), findsWidgets);
      expect(find.text('الأكثر اعجابا'), findsWidgets);
      await _writeShot(tester, 'replies_sort_menu.png', shotKey);
    },
  );

  testWidgets('mention button inserts @name and blocks a second tag', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

    final service = _FakeAccountService(
      comments: <AnimeWitcherComment>[parent],
      replies: <AnimeWitcherComment>[otherReply, secondReply, ownReply],
    );
    const shotKey = ValueKey<String>('replies-mention-shot');

    await tester.pumpWidget(
      _app(
        service: service,
        shotKey: shotKey,
        home: AnimeWitcherRepliesScreen(parentComment: parent),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(
      find.byKey(ValueKey<String>('reply-mention-${ownReply.path}')),
    );
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );

    await tester.tap(
      find.byKey(ValueKey<String>('reply-mention-${otherReply.path}')),
    );
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '@حمزة سان 7amza san يوتيوب ',
    );
    await _writeShot(tester, 'replies_mention_inserted.png', shotKey);

    await tester.tap(
      find.byKey(ValueKey<String>('reply-mention-${secondReply.path}')),
    );
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '@حمزة سان 7amza san يوتيوب ',
    );
    final notifications = ProviderScope.containerOf(
      tester.element(find.byType(AnimeWitcherRepliesScreen)),
    ).read(notificationServiceProvider);
    expect(
      notifications.toasts.map((toast) => toast.message),
      contains('لا يمكن اضافة اكثر من تاج'),
    );

    await tester.enterText(find.byType(TextField), 'no at sign');
    await tester.pump();
    await tester.tap(
      find.byKey(ValueKey<String>('reply-mention-${secondReply.path}')),
    );
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'no at sign@Killua ',
    );

    await tester.tap(find.byTooltip('إرسال'));
    await tester.pump();
    expect(service.lastPublishedText, 'no at sign@Killua');
    expect(service.lastPublishedUserTagId, 'user-3');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('returning from replies does not refetch comments', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _FakeAccountService(
      comments: <AnimeWitcherComment>[parent],
      replies: <AnimeWitcherComment>[otherReply],
    );

    await tester.pumpWidget(
      _app(
        service: service,
        home: const AnimeWitcherCommentsScreen(target: _target),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('من هذا؟'), findsOneWidget);
    expect(service.loadCommentsCalls, 1);

    await tester.tap(find.byTooltip('الردود'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('الردود'), findsOneWidget);
    expect(find.text('انا فكرتها كيلوا'), findsOneWidget);

    Navigator.of(tester.element(find.text('انا فكرتها كيلوا'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('من هذا؟'), findsOneWidget);
    expect(find.text('التعليقات'), findsOneWidget);
    expect(service.loadCommentsCalls, 1);
    expect(service.loadRepliesCalls, 1);
  });

  testWidgets('signed out, the composer is replaced by a sign-in notice', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

    final service = _FakeAccountService(
      comments: <AnimeWitcherComment>[parent],
      replies: <AnimeWitcherComment>[otherReply],
      signedIn: false,
    );

    await tester.pumpWidget(
      _app(
        service: service,
        home: AnimeWitcherRepliesScreen(parentComment: parent),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The replies themselves stay readable — signing in is only required to
    // add one.
    expect(find.text('انا فكرتها كيلوا'), findsOneWidget);

    expect(
      find.text('سجّل الدخول إلى حساب AnimeWitcher لإضافة رد.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('إرسال'), findsNothing);
  });
}
