import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/comments/presentation/animewitcher_comments_screen.dart';
import 'package:animewitcher/features/comments/presentation/animewitcher_replies_screen.dart';
import 'package:animewitcher/features/comments/presentation/widgets/animewitcher_comment_sort_control.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _target = AnimeWitcherCommentTarget(
  collectionPath: 'anime_list/offline/comments',
  sourceDocumentPath: 'anime_list/offline',
  title: 'قائمة محلية',
);
const _pageCount = 7;
const _batch = 18;
const _expectedPriorReads = 18;

class _PathProbe {
  int page = 0;
  bool active = false;
  int prior = 0;
  int incoming = 0;

  void read(int creationPage) {
    if (!active ||
        !StackTrace.current.toString().contains('CommentPager.loadMore')) {
      return;
    }
    if (creationPage == page) {
      incoming++;
    } else {
      prior++;
    }
  }
}

class _Row extends AnimeWitcherComment {
  _Row(this.probe, this.creationPage, int ordinal, {String? body})
    : super(
        id: '$ordinal',
        path: '${_target.collectionPath}/$ordinal',
        text: body ?? 'التعليق رقم $ordinal',
        userId: ordinal == 0 ? 'me' : 'guest',
        userName: 'قارئ',
        likes: 1,
        replies: ordinal == 0 ? 1 : 0,
        spoiler: false,
      );

  final _PathProbe probe;
  final int creationPage;

  @override
  String get path {
    probe.read(creationPage);
    return super.path;
  }
}

class _AccountController extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      ref.read(animeWitcherAccountServiceProvider).snapshot;
}

class _Pages extends AnimeWitcherAccountService {
  _Pages()
    : super(
        storage: StorageService(),
        secureStorage: SecureTokenStorage(StorageService()),
      );

  final _PathProbe probe = _PathProbe();
  final List<String?> cursors = [];
  final List<AnimeWitcherCommentSort> sorts = [];
  var replyLoads = 0;
  var posted = false;

  @override
  bool get isSignedIn => true;

  @override
  AnimeWitcherAccountSnapshot get snapshot => const AnimeWitcherAccountSnapshot(
    profile: AnimeWitcherProfile(
      documentId: 'me',
      uid: 'me',
      signInMethod: AnimeWitcherSignInMethod.email,
      userName: 'قارئ',
    ),
  );

  @override
  bool ownsComment(AnimeWitcherComment comment) => comment.userId == 'me';

  @override
  Future<AnimeWitcherCommentPage> loadComments(
    AnimeWitcherCommentTarget target, {
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async {
    expect(target, _target);
    expect(limit, 20);
    cursors.add(cursor?.id);
    sorts.add(sort);
    if (posted || sort == AnimeWitcherCommentSort.oldest) {
      return AnimeWitcherCommentPage(
        items: [
          _Row(probe, 0, 200, body: posted ? 'نص بعد النشر' : 'ترتيب معكوس'),
        ],
        cursor: null,
        hasMore: false,
      );
    }
    final page = cursor == null ? 0 : int.parse(cursor.id) + 1;
    probe.page = page;
    final hasMore = page + 1 < _pageCount;
    return AnimeWitcherCommentPage(
      items: [
        if (page > 0)
          _Row(probe, page, page * _batch - 1, body: 'نسخة من الصفحة السابقة'),
        for (var i = 0; i < _batch; i++) _Row(probe, page, page * _batch + i),
        if (page > 0)
          _Row(probe, page, page * _batch, body: 'نسخة من الصفحة نفسها'),
      ],
      cursor: FirestoreDocument(id: '$page', path: 'offline/$page', fields: {}),
      hasMore: hasMore,
    );
  }

  @override
  Future<AnimeWitcherCommentPage> loadReplies(
    AnimeWitcherComment parent, {
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.oldest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async {
    expect(parent.id, '0');
    replyLoads++;
    return AnimeWitcherCommentPage(
      items: [_Row(probe, 0, 500, body: 'رد من الاختبار')],
      cursor: null,
      hasMore: false,
    );
  }

  @override
  Future<void> deleteOwnComment(AnimeWitcherComment comment) async {
    expect(comment.id, '0');
  }

  @override
  Future<AnimeWitcherComment> toggleCommentLike(
    AnimeWitcherComment comment,
  ) async {
    expect(comment.id, '1');
    return comment.copyWith(likes: 2, likedByMe: true);
  }

  @override
  Future<void> publishComment(
    AnimeWitcherCommentTarget target,
    String rawComment, {
    bool spoiler = false,
  }) async {
    expect(rawComment, 'نشر محلي');
    expect(spoiler, isFalse);
    posted = true;
  }
}

Finder _list() => find.byWidgetPredicate(
  (widget) => widget is ListView && widget.controller != null,
);

ScrollableState _scroll(WidgetTester tester) => tester.state(
  find.descendant(of: _list(), matching: find.byType(Scrollable)),
);

Future<void> _step(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 220));
  await tester.pump();
}

void main() {
  testWidgets('Arabic Comments appends without revisiting prior paths', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final account = _Pages();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          animeWitcherAccountServiceProvider.overrideWithValue(account),
          animeWitcherAccountControllerProvider.overrideWith(
            _AccountController.new,
          ),
        ],
        child: const MaterialApp(
          locale: Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AnimeWitcherCommentsScreen(target: _target),
        ),
      ),
    );
    await _step(tester);
    expect(find.text('التعليقات'), findsOneWidget);
    expect(find.text('التعليق رقم 0'), findsOneWidget);
    expect(account.cursors, [null]);
    account.probe.active = true;
    for (
      var jump = 0;
      account.cursors.length < _pageCount && jump < 30;
      jump++
    ) {
      final position = _scroll(tester).position;
      position.jumpTo(position.maxScrollExtent);
      await _step(tester);
    }
    account.probe.active = false;
    expect(account.cursors, [null, '0', '1', '2', '3', '4', '5']);
    final list = tester.widget<ListView>(_list());
    expect(
      list.childrenDelegate.estimatedChildCount,
      2 * _pageCount * _batch - 1,
    );
    expect(account.probe.incoming, 6 * 20);
    expect(account.probe.prior, _expectedPriorReads);
    debugPrint(
      'comments route pager path reads: prior=${account.probe.prior} '
      'incoming=${account.probe.incoming} rows=${_pageCount * _batch}',
    );

    final position = _scroll(tester).position;
    position.jumpTo(position.maxScrollExtent);
    await _step(tester);
    position.jumpTo(position.maxScrollExtent);
    await _step(tester);
    expect(find.text('التعليق رقم 125').hitTestable(), findsOneWidget);
    expect(find.text('نسخة من الصفحة السابقة'), findsNothing);
    expect(find.text('نسخة من الصفحة نفسها'), findsNothing);
    position.jumpTo(0);
    await _step(tester);
    await tester.tap(find.byTooltip('الردود').hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.byType(AnimeWitcherRepliesScreen), findsOneWidget);
    expect(find.text('رد من الاختبار'), findsOneWidget);
    expect(account.replyLoads, 1);
    Navigator.of(tester.element(find.byType(AnimeWitcherRepliesScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.text('التعليق رقم 0').hitTestable(), findsOneWidget);
    expect(account.cursors.length, 7);
    final like = find.byTooltip('إعجاب').hitTestable().at(1);
    await tester.tap(like);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    // Actual delete and publish interactions use only local fixture writes.
    await tester.tap(find.byTooltip('إدارة التعليق').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف'));
    await tester.pumpAndSettle();
    final confirm = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('حذف'),
    );
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(find.text('التعليق رقم 0'), findsNothing);
    final sort = tester.widget<AnimeWitcherCommentSortControl>(
      find.byType(AnimeWitcherCommentSortControl),
    );
    sort.onSelected(AnimeWitcherCommentSort.oldest.name);
    await tester.pumpAndSettle();
    expect(account.sorts.last, AnimeWitcherCommentSort.oldest);
    expect(find.text('ترتيب معكوس').hitTestable(), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'نشر محلي');
    await tester.tap(find.byTooltip('نشر'));
    await tester.pumpAndSettle();
    expect(account.posted, isTrue);
    expect(account.cursors.last, isNull);
    expect(find.text('نص بعد النشر').hitTestable(), findsOneWidget);
    // The product success toast has a delayed removal even after settling.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
