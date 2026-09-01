import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/core/account/firestore_rest_client.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/comments/presentation/animewitcher_comments_screen.dart';
import 'package:animewitcher/features/comments/presentation/animewitcher_my_comments_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAccountService extends AnimeWitcherAccountService {
  _FakeAccountService({required this.comments})
      : super(
          storage: StorageService(),
          secureStorage: SecureTokenStorage(StorageService()),
        );

  final List<AnimeWitcherComment> comments;

  @override
  bool get isSignedIn => true;

  @override
  AnimeWitcherAccountSnapshot get snapshot => const AnimeWitcherAccountSnapshot(
        profile: AnimeWitcherProfile(
          documentId: 'me',
          uid: 'me',
          signInMethod: AnimeWitcherSignInMethod.google,
          userName: 'Me',
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
    return AnimeWitcherCommentPage(
      items: comments,
      cursor: null,
      hasMore: false,
    );
  }

  @override
  Future<AnimeWitcherCommentPage> loadMyComments({
    AnimeWitcherCommentSort sort = AnimeWitcherCommentSort.newest,
    FirestoreDocument? cursor,
    int limit = 20,
  }) async {
    return AnimeWitcherCommentPage(
      items: comments,
      cursor: null,
      hasMore: false,
    );
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
  required String text,
  bool spoiler = false,
}) {
  return AnimeWitcherComment(
    id: id,
    path: 'anime_list/jigokuraku/comments/$id',
    text: text,
    userId: 'me',
    userName: 'فايز',
    likes: 1,
    replies: 0,
    spoiler: spoiler,
    date: DateTime.now().subtract(const Duration(hours: 2)),
  );
}

const _target = AnimeWitcherCommentTarget(
  collectionPath: 'anime_list/jigokuraku/comments',
  sourceDocumentPath: 'anime_list/jigokuraku',
  title: 'Jigokuraku',
);

Widget _app({
  required _FakeAccountService service,
  required Widget home,
}) {
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
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFEEC60A),
          surface: Color(0xFF000000),
          onSurface: Color(0xFFE5E7EB),
        ),
      ),
      home: home,
    ),
  );
}

Future<void> _openOwnEditor(WidgetTester tester) async {
  await tester.tap(find.byTooltip('إدارة التعليق'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('تعديل'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('comments composer still has the spoiler eye next to send', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(comments: const <AnimeWitcherComment>[]),
        home: const AnimeWitcherCommentsScreen(target: _target),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('التعليقات'), findsOneWidget);
    expect(find.byTooltip('نشر'), findsOneWidget);
    expect(find.byTooltip('يحتوي على حرق'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
  });

  testWidgets('comment edit dialog keeps تعديل التعليق and spoiler checkbox', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(
          comments: <AnimeWitcherComment>[
            _comment(id: 'c1', text: 'تعليقي', spoiler: true),
          ],
        ),
        home: const AnimeWitcherCommentsScreen(target: _target),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await _openOwnEditor(tester);

    expect(find.text('تعديل التعليق'), findsOneWidget);
    expect(find.text('تعديل المراجعة'), findsNothing);
    expect(find.text('يحتوي على حرق'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsOneWidget);
  });

  testWidgets('my comments edit dialog keeps spoiler checkbox', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(
          comments: <AnimeWitcherComment>[
            _comment(id: 'c1', text: 'تعليقي'),
          ],
        ),
        home: const AnimeWitcherMyCommentsScreen(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('تعليقاتي'), findsOneWidget);
    await _openOwnEditor(tester);

    expect(find.text('تعديل التعليق'), findsOneWidget);
    expect(find.text('يحتوي على حرق'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsOneWidget);
  });
}
