import 'package:animewitcher/core/account/witanime_account_models.dart';
import 'package:animewitcher/core/account/witanime_account_service.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/library_lists.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/widgets/library_phone_shelves.dart';
import 'package:animewitcher/features/library/presentation/widgets/library_side_list.dart';
import 'package:animewitcher/features/home/presentation/latest_episodes_provider.dart';
import 'package:animewitcher/features/settings/presentation/app_version_provider.dart';
import 'package:animewitcher/features/settings/presentation/settings_screen.dart';
import 'package:animewitcher/features/settings/presentation/widgets/witanime_account_section.dart';
import 'package:animewitcher/features/settings/presentation/widgets/witanime_auth_webview_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _MemoryTokenStorage extends SecureTokenStorage {
  _MemoryTokenStorage(super.fallback);

  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

class _FakeWitanimeAccountBackend implements WitanimeAccountBackend {
  final Map<String, WitanimeProfile> profilesByCookie =
      <String, WitanimeProfile>{};

  @override
  Future<WitanimeProfile?> fetchProfile(String sessionCookie) async =>
      profilesByCookie[sessionCookie];

  @override
  Future<void> signOut(String sessionCookie) async {}

  @override
  Future<void> updatePassword({
    required String sessionCookie,
    required String currentPassword,
    required String newPassword,
    required String confirmPassword,
  }) async {}

  @override
  Future<WitanimeProfile> updateProfile({
    required String sessionCookie,
    required String displayName,
    String? email,
    String? avatarUrl,
  }) async => profilesByCookie[sessionCookie]!;
}

void main() {
  testWidgets(
    'settings allows switching freely between AnimeWitcher and Witanime',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final storage = MemoryStorageService();
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            appVersionProvider.overrideWith((ref) async => 'test'),
            deviceProfileProvider.overrideWith(
              (ref) async => const DeviceProfile(),
            ),
          ],
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(
                locale: Locale('ar'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: SettingsScreen(),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final providerTile = find.byKey(
        const ValueKey('settings-active-anime-provider'),
      );
      expect(
        container.read(activeProviderProvider),
        isA<AnimeWitcherNativeProvider>(),
      );
      expect(
        find.descendant(
          of: providerTile,
          matching: find.widgetWithText(ChoiceChip, 'Witanime'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: providerTile,
          matching: find.widgetWithText(ChoiceChip, 'AnimeWitcher'),
        ),
        findsOneWidget,
      );

      final witSwitch = find.widgetWithText(
        ListTile,
        'أحدث الحلقات (Witanime)',
      );
      final nativeSwitch = find.widgetWithText(
        ListTile,
        'أحدث الحلقات (AnimeWitcher)',
      );
      Switch latestSwitch(Finder tile) => tester.widget(
        find.descendant(of: tile, matching: find.byType(Switch)),
      );
      expect(latestSwitch(nativeSwitch).value, isTrue);
      expect(latestSwitch(nativeSwitch).onChanged, isNull);
      expect(latestSwitch(witSwitch).value, isFalse);
      expect(latestSwitch(witSwitch).onChanged, isNotNull);
      await tester.tap(
        find.descendant(of: witSwitch, matching: find.byType(Switch)),
      );
      await tester.pumpAndSettle();
      container.invalidate(latestEpisodesSettingsProvider);
      await tester.pumpAndSettle();
      expect(latestSwitch(witSwitch).value, isTrue);

      final witChip = find.descendant(
        of: providerTile,
        matching: find.widgetWithText(ChoiceChip, 'Witanime'),
      );
      await tester.tap(witChip);
      await tester.pumpAndSettle();

      expect(container.read(activeProviderProvider), isA<WitanimeProvider>());
      expect(storage.getActiveProviderId(), WitanimeProvider.id);
      expect(latestSwitch(witSwitch).value, isTrue);
      expect(latestSwitch(witSwitch).onChanged, isNull);
      expect(latestSwitch(nativeSwitch).value, isFalse);
      expect(latestSwitch(nativeSwitch).onChanged, isNotNull);

      await tester.tap(
        find.descendant(
          of: providerTile,
          matching: find.widgetWithText(ChoiceChip, 'AnimeWitcher'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        container.read(activeProviderProvider),
        isA<AnimeWitcherNativeProvider>(),
      );
      expect(latestSwitch(witSwitch).value, isTrue);
      expect(latestSwitch(witSwitch).onChanged, isNotNull);
    },
  );

  test('tryCompleteBrowserAuth ignores unauthenticated cookies and activates valid ones', () async {
    final storage = MemoryStorageService();
    final backend = _FakeWitanimeAccountBackend()
      ..profilesByCookie['witanime_session=valid'] = const WitanimeProfile(
        accountId: 'user-1',
        displayName: 'فارس',
      );
    final service = WitanimeAccountService(
      tokenStorage: _MemoryTokenStorage(storage),
      backend: backend,
    );

      final unverified = await service.tryCompleteBrowserAuth(
        sessionCookie: 'witanime_session=guest',
      );
      expect(unverified, isNull);
      expect(service.isSignedIn, isFalse);

      service.recordPendingAuthReturnRoute('/anime/frieren');
      final verified = await service.tryCompleteBrowserAuth(
        sessionCookie: 'witanime_session=valid',
      );
      expect(verified, isNotNull);
      expect(verified!.profile.displayName, 'فارس');
      expect(verified.returnRoute, '/anime/frieren');
      expect(service.isSignedIn, isTrue);
    },
  );

  test('cookie and auth path helpers parse WebView results accurately', () {
    final parsed = parseWitanimeDocumentCookies(
      '"XSRF-TOKEN=abc%3D123; witanime_session=xyz"',
    );
    expect(parsed, {'XSRF-TOKEN': 'abc%3D123', 'witanime_session': 'xyz'});
    expect(
      formatWitanimeCookieHeader(parsed),
      'XSRF-TOKEN=abc%3D123; witanime_session=xyz',
    );
    expect(isWitanimeAuthFormPath('/login'), isTrue);
    expect(isWitanimeAuthFormPath('/register'), isTrue);
    expect(isWitanimeAuthFormPath('/forgot-password'), isTrue);
    expect(isWitanimeAuthFormPath('/profile'), isFalse);
    expect(isWitanimeAuthFormPath('/'), isFalse);
    expect(isWitanimeHostUri(Uri.parse('https://witanime.site/')), isTrue);
    expect(isWitanimeHostUri(Uri.parse('https://example.com/')), isFalse);
  });

  testWidgets(
    'WitanimeAccountSection uses in-app auth launcher without manual cookie dialog',
    (tester) async {
      final storage = MemoryStorageService();
      final backend = _FakeWitanimeAccountBackend()
        ..profilesByCookie['sess=ok'] = const WitanimeProfile(
          accountId: 'user-9',
          displayName: 'أحمد',
        );
      final service = WitanimeAccountService(
        tokenStorage: _MemoryTokenStorage(storage),
        backend: backend,
      );
      final launchedActions = <WitanimeAuthAction>[];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            witanimeAccountServiceProvider.overrideWithValue(service),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: WitanimeAccountSection(
                  returnRoute: '/anime/test',
                  inAppAuthLauncher: (context, action) async {
                    launchedActions.add(action);
                    return await service.tryCompleteBrowserAuth(
                      sessionCookie: 'sess=ok',
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('تسجيل الدخول إلى Witanime'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));

      expect(launchedActions, [WitanimeAuthAction.signIn]);
      expect(find.text('تأكيد جلسة Witanime'), findsNothing);
      expect(service.isSignedIn, isTrue);
      expect(find.text('أحمد'), findsOneWidget);
    },
  );

  testWidgets(
    'LibraryFilterPanel and LibrarySideList hide AnimeWitcher-only lists when Witanime is active for anime',
    (tester) async {
      final storage = MemoryStorageService();
      await storage.setActiveProviderId(WitanimeProvider.id);
      final prefs = LibraryShelfPrefs(storage);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [storageServiceProvider.overrideWithValue(storage)],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: LibraryFilterPanel(
                      prefs: prefs,
                      kind: LibraryMediaKind.anime,
                      phoneSection: LibraryPhoneSection.anime,
                    ),
                  ),
                  Expanded(
                    child: LibrarySideList(
                      kind: LibraryMediaKind.anime,
                      category: LibraryCategory.watching,
                      recentSelected: false,
                      witanimeAnime: true,
                      counts: const {},
                      recentCount: 0,
                      onRecent: () {},
                      onSelect: (_, _) {},
                      prefs: prefs,
                      onFilter: () {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('library-filter-onHold')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('library-filter-noWatching')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('library-side-anime-onHold')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('library-side-anime-noWatching')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('library-filter-watching')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('library-side-manga-onHold')),
        120,
        scrollable: find.descendant(
          of: find.byType(LibrarySideList),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.byKey(const ValueKey('library-side-manga-onHold')),
        findsOneWidget,
      );
    },
  );
}
