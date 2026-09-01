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
import 'package:animewitcher/features/comments/presentation/animewitcher_my_comments_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_fonts.dart';

class _FakeAccountService extends AnimeWitcherAccountService {
  _FakeAccountService({
    required this.reviews,
    this.signedIn = true,
    this.myUserId = 'me',
  }) : super(
          storage: StorageService(),
          secureStorage: SecureTokenStorage(StorageService()),
        );

  final List<AnimeWitcherComment> reviews;
  final bool signedIn;
  final String myUserId;
  int? lastLimit;
  String? lastPublishedText;
  bool lastPublishedWasReview = false;
  bool lastPublishedSpoiler = false;

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
    lastLimit = limit;
    return AnimeWitcherCommentPage(
      items: reviews,
      cursor: null,
      hasMore: false,
    );
  }

  @override
  Future<AnimeWitcherCommentPage> loadMyReviews({
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = kAnimeWitcherReviewsPageSize,
  }) async {
    lastLimit = limit;
    return AnimeWitcherCommentPage(
      items: reviews,
      cursor: null,
      hasMore: false,
    );
  }

  @override
  Future<void> publishComment(
    AnimeWitcherCommentTarget target,
    String rawComment, {
    bool spoiler = false,
  }) async {
    lastPublishedText = rawComment.trim();
    lastPublishedWasReview = target.isReviews;
    lastPublishedSpoiler = spoiler;
  }
}

class _FixedAccountController extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    return ref.read(animeWitcherAccountServiceProvider).snapshot;
  }
}

AnimeWitcherComment _review({
  required String id,
  required String text,
  bool published = true,
  String userId = 'author',
}) {
  return AnimeWitcherComment(
    id: id,
    path: 'anime_list/jigokuraku/reviews/$id',
    text: text,
    userId: userId,
    userName: 'فايز',
    likes: 3,
    replies: 1,
    spoiler: false,
    published: published,
    date: DateTime.now().subtract(const Duration(hours: 2)),
  );
}

const _target = AnimeWitcherCommentTarget(
  collectionPath: 'anime_list/jigokuraku/reviews',
  sourceDocumentPath: 'anime_list/jigokuraku',
  title: 'Jigokuraku',
  kind: AnimeWitcherSocialKind.reviews,
  animeId: 'jigokuraku',
);

Widget _app({
  required _FakeAccountService service,
  required Widget home,
  String? fontFamily,
  Key? shotKey,
}) {
  Widget app = MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: ThemeData(
      brightness: Brightness.dark,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: Colors.black,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFFEEC60A),
        surface: Color(0xFF000000),
        onSurface: Color(0xFFE5E7EB),
      ),
    ),
    home: home,
  );
  if (shotKey != null) {
    app = RepaintBoundary(key: shotKey, child: app);
  }
  return ProviderScope(
    overrides: [
      animeWitcherAccountServiceProvider.overrideWithValue(service),
      animeWitcherAccountControllerProvider.overrideWith(
        _FixedAccountController.new,
      ),
    ],
    child: app,
  );
}

Future<void> _openOwnReviewEditor(WidgetTester tester) async {
  await tester.tap(find.byTooltip('إدارة التعليق'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('تعديل'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('published reviews list review_text with page size 10', (
    tester,
  ) async {
    final service = _FakeAccountService(
      reviews: <AnimeWitcherComment>[_review(id: 'r1', text: 'مراجعة منشورة')],
    );
    await tester.pumpWidget(
      _app(
        service: service,
        home: const AnimeWitcherCommentsScreen(target: _target),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('المراجعات'), findsOneWidget);
    expect(find.text('مراجعة منشورة'), findsOneWidget);
    expect(find.text('اكتب مراجعة...'), findsOneWidget);
    expect(find.text('لا توجد مراجعات منشورة بعد.'), findsNothing);
    expect(service.lastLimit, kAnimeWitcherReviewsPageSize);
  });

  testWidgets('empty published reviews show the APK empty copy', (tester) async {
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(reviews: const <AnimeWitcherComment>[]),
        home: const AnimeWitcherCommentsScreen(target: _target),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('لا توجد مراجعات منشورة بعد.'), findsOneWidget);
  });

  testWidgets('posting a review toasts moderation copy', (tester) async {
    final service = _FakeAccountService(reviews: const <AnimeWitcherComment>[]);
    await tester.pumpWidget(
      _app(
        service: service,
        home: const AnimeWitcherCommentsScreen(target: _target),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.enterText(find.byType(TextField), 'مراجعة جديدة');
    await tester.tap(find.byTooltip('نشر'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(service.lastPublishedWasReview, isTrue);
    expect(service.lastPublishedText, 'مراجعة جديدة');
    expect(service.lastPublishedSpoiler, isFalse);
    final notifications = ProviderScope.containerOf(
      tester.element(find.byType(AnimeWitcherCommentsScreen)),
    ).read(notificationServiceProvider);
    expect(
      notifications.toasts.map((toast) => toast.message),
      contains('جاري مراجعته.'),
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('my reviews screen lists unpublished review_text', (tester) async {
    final service = _FakeAccountService(
      reviews: <AnimeWitcherComment>[
        _review(
          id: 'mine',
          text: 'مراجعتي قيد الفحص',
          published: false,
          userId: 'me',
        ),
      ],
    );
    await tester.pumpWidget(
      _app(
        service: service,
        home: const AnimeWitcherMyCommentsScreen(isReviews: true),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('مراجعاتي'), findsOneWidget);
    expect(find.text('مراجعتي قيد الفحص'), findsOneWidget);
    expect(find.text('جاري مراجعته'), findsOneWidget);
    expect(service.lastLimit, kAnimeWitcherReviewsPageSize);
  });

  testWidgets('reviews composer keeps send and hides the spoiler eye', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(reviews: const <AnimeWitcherComment>[]),
        home: const AnimeWitcherCommentsScreen(target: _target),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('المراجعات'), findsOneWidget);
    expect(find.byTooltip('نشر'), findsOneWidget);
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    expect(find.byTooltip('يحتوي على حرق'), findsNothing);
    expect(find.byIcon(Icons.visibility_outlined), findsNothing);
    expect(find.byIcon(Icons.visibility_off_rounded), findsNothing);
  });

  testWidgets('editing a published review uses the review title without spoiler', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(
          reviews: <AnimeWitcherComment>[
            _review(id: 'mine', text: 'زمان', userId: 'me'),
          ],
        ),
        home: const AnimeWitcherCommentsScreen(target: _target),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await _openOwnReviewEditor(tester);

    expect(find.text('تعديل المراجعة'), findsOneWidget);
    expect(find.text('تعديل التعليق'), findsNothing);
    expect(find.text('يحتوي على حرق'), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.text('حفظ'), findsOneWidget);
  });

  testWidgets('my reviews edit dialog uses تعديل المراجعة without spoiler', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(
          reviews: <AnimeWitcherComment>[
            _review(
              id: 'mine',
              text: 'زمان',
              published: false,
              userId: 'me',
            ),
          ],
        ),
        home: const AnimeWitcherMyCommentsScreen(isReviews: true),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('مراجعاتي'), findsOneWidget);
    await _openOwnReviewEditor(tester);

    expect(find.text('تعديل المراجعة'), findsOneWidget);
    expect(find.text('تعديل التعليق'), findsNothing);
    expect(find.text('يحتوي على حرق'), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('reviews screenshots', (tester) async {
    final loaded = await tester.runAsync(TestFonts.loadWalkthroughFonts);
    if (loaded != true) return;
    final artifacts = Directory('/opt/cursor/artifacts');
    if (!artifacts.existsSync()) {
      artifacts.createSync(recursive: true);
    }

    Future<void> shot(String name, Widget home, _FakeAccountService service) async {
      final key = ValueKey(name);
      await tester.pumpWidget(
        _app(
          service: service,
          home: home,
          fontFamily: 'NotoSansArabic',
          shotKey: key,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${artifacts.path}/$name.png').writeAsBytesSync(
          bytes!.buffer.asUint8List(),
        );
      });
    }

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await shot(
      'reviews_published_list',
      const AnimeWitcherCommentsScreen(target: _target),
      _FakeAccountService(
        reviews: <AnimeWitcherComment>[_review(id: 'r1', text: 'مراجعة منشورة')],
      ),
    );
    await shot(
      'reviews_empty_published',
      const AnimeWitcherCommentsScreen(target: _target),
      _FakeAccountService(reviews: const <AnimeWitcherComment>[]),
    );
    await shot(
      'account_my_reviews',
      const AnimeWitcherMyCommentsScreen(isReviews: true),
      _FakeAccountService(
        reviews: <AnimeWitcherComment>[
          _review(
            id: 'mine',
            text: 'مراجعتي قيد الفحص',
            published: false,
            userId: 'me',
          ),
        ],
      ),
    );
    const editShot = ValueKey('review_edit_dialog');
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(
          reviews: <AnimeWitcherComment>[
            _review(
              id: 'mine',
              text: 'زمان',
              published: false,
              userId: 'me',
            ),
          ],
        ),
        home: const AnimeWitcherMyCommentsScreen(isReviews: true),
        fontFamily: 'NotoSansArabic',
        shotKey: editShot,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await _openOwnReviewEditor(tester);
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(editShot),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${artifacts.path}/review_edit_dialog.png').writeAsBytesSync(
        bytes!.buffer.asUint8List(),
      );
    });
  });
}
