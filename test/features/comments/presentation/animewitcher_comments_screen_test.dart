import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:dio/dio.dart';
import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
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

class _SwitchSelection extends ActiveProvider {
  @override
  AnimeWitcherProvider? build() =>
      AnimeWitcherNativeProvider(Dio(), SettingsRepository(StorageService()));
  @override
  Future<void> set(AnimeWitcherProvider? provider) async => state = provider;
}

class _RiftSelection extends ActiveProvider {
  @override
  AnimeWitcherProvider? build() => AnimeRiftProvider();
}

class _NativeSelection extends ActiveProvider {
  @override
  AnimeWitcherProvider? build() =>
      AnimeWitcherNativeProvider(Dio(), SettingsRepository(StorageService()));
}

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
      signInMethod: AnimeWitcherSignInMethod.email,
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
  bool rift = false,
}) {
  return ProviderScope(
    overrides: [
      if (rift)
        activeProviderProvider.overrideWith(_RiftSelection.new)
      else
        activeProviderProvider.overrideWith(_NativeSelection.new),
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

  testWidgets('comments composer uses a flame for spoiler next to send', (
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
    expect(find.byIcon(Icons.local_fire_department_rounded), findsOneWidget);
    expect(find.byIcon(Icons.visibility_outlined), findsNothing);
  });

  testWidgets('hidden spoiler comment uses the same flame icon', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(
          comments: <AnimeWitcherComment>[
            _comment(id: 'spoiler', text: 'حرق', spoiler: true),
          ],
        ),
        home: const AnimeWitcherCommentsScreen(target: _target),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('تعليق يحتوي على حرق — إظهار'), findsOneWidget);
    expect(find.byIcon(Icons.local_fire_department_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.visibility_off_rounded), findsNothing);
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

  testWidgets('Rift does not display Witcher account comments', (tester) async {
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(
          comments: [_comment(id: 'c1', text: 'تعليق ويتشر')],
        ),
        home: const AnimeWitcherMyCommentsScreen(),
        rift: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('تعليق ويتشر'), findsNothing);
    expect(find.text('هذه الميزة غير متاحة للمزود المختار'), findsOneWidget);
  });

  testWidgets('switching providers hides and restores own comments', (
    tester,
  ) async {
    final service = _FakeAccountService(
      comments: [_comment(id: 'c1', text: 'تعليق ويتشر')],
    );
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWith(_SwitchSelection.new),
        animeWitcherAccountServiceProvider.overrideWithValue(service),
        animeWitcherAccountControllerProvider.overrideWith(
          _FixedAccountController.new,
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AnimeWitcherMyCommentsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('تعليق ويتشر'), findsOneWidget);
    await container
        .read(activeProviderProvider.notifier)
        .set(AnimeRiftProvider());
    await tester.pump();
    expect(find.text('تعليق ويتشر'), findsNothing);
    expect(find.text('هذه الميزة غير متاحة للمزود المختار'), findsOneWidget);
    await container
        .read(activeProviderProvider.notifier)
        .set(
          AnimeWitcherNativeProvider(
            Dio(),
            SettingsRepository(StorageService()),
          ),
        );
    await tester.pump();
    await tester.pump();
    expect(find.text('تعليق ويتشر'), findsOneWidget);
  });

  testWidgets('my comments edit dialog keeps spoiler checkbox', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        service: _FakeAccountService(
          comments: <AnimeWitcherComment>[_comment(id: 'c1', text: 'تعليقي')],
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
