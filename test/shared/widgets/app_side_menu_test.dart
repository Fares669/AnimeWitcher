import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_side_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _SignedOutAccount extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    return const AnimeWitcherAccountSnapshot();
  }
}

final class _SignedInAccount extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async {
    return const AnimeWitcherAccountSnapshot(
      profile: AnimeWitcherProfile(
        documentId: 'profile-1',
        uid: 'user-1',
        signInMethod: AnimeWitcherSignInMethod.email,
        email: 'viewer@example.test',
        userName: 'Viewer',
        photoUrl: 'https://example.test/avatar.jpg',
        coverUrl: 'https://example.test/banner.jpg',
      ),
    );
  }
}

const _destinations = <TaskbarDestination>[
  TaskbarDestination.home,
  TaskbarDestination.search,
  TaskbarDestination.library,
  TaskbarDestination.settings,
];

final class _Harness {
  final picked = <TaskbarDestination>[];
  int accountOpened = 0;
  int backWhenClosed = 0;
  int settingsOpened = 0;
  bool canOpen = true;
}

Future<_Harness> _pump(WidgetTester tester, {bool signedIn = false}) async {
  final harness = _Harness();
  tester.view.physicalSize = const Size(400, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        animeWitcherAccountControllerProvider.overrideWith(
          signedIn ? _SignedInAccount.new : _SignedOutAccount.new,
        ),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppSideMenuShell(
          destinations: _destinations,
          currentBranchIndex: TaskbarDestination.home.branchIndex,
          onDestination: harness.picked.add,
          onAccount: () => harness.accountOpened++,
          canOpen: () => harness.canOpen,
          canPopWhenClosed: false,
          onBackWhenClosed: () => harness.backWhenClosed++,
          entries: [
            AppSideMenuEntry(
              id: 'settings',
              icon: Icons.settings_rounded,
              label: 'الإعدادات',
              onTap: () => harness.settingsOpened++,
            ),
          ],
          child: Scaffold(
            body: Stack(
              children: [
                const Positioned.fill(
                  child: ColoredBox(
                    key: ValueKey<String>('page'),
                    color: Colors.black,
                  ),
                ),
                Positioned(top: 20, left: 12, child: const AppSideMenuButton()),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return harness;
}

Finder get _menu =>
    find.byKey(const ValueKey<String>('app-side-menu'), skipOffstage: false);
Finder get _page => find.byKey(const ValueKey<String>('page'));

bool _menuShowing(WidgetTester tester) => !tester
    .widgetList<Offstage>(
      find.ancestor(
        of: _menu,
        matching: find.byType(Offstage, skipOffstage: false),
      ),
    )
    .first
    .offstage;

void main() {
  testWidgets('the menu button opens the menu: account on top, ✕ top left', (
    tester,
  ) async {
    await _pump(tester);
    expect(_menuShowing(tester), isFalse);

    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();

    expect(_menuShowing(tester), isTrue);
    // The page is pushed to the right, the menu on the left.
    expect(tester.getTopLeft(_page).dx, greaterThan(200));
    expect(tester.getTopLeft(_menu).dx, closeTo(0, 0.5));
    expect(find.text('تسجيل الدخول'), findsOneWidget);
    expect(find.text('الرئيسية'), findsOneWidget);
    expect(find.text('المزيد'), findsOneWidget);

    final close = tester.getCenter(
      find.byKey(const ValueKey('app-side-menu-close')),
    );
    final account = tester.getCenter(
      find.byKey(const ValueKey('app-side-menu-account')),
    );
    // ✕ in the top-left corner, above the pages.
    expect(close.dx, lessThan(account.dx));
    expect(close.dx, lessThan(80));
    expect(
      close.dy,
      lessThan(
        tester.getCenter(find.byKey(const ValueKey('app-side-menu-home'))).dy,
      ),
    );
  });

  testWidgets('signed-in menu uses banner, larger avatar, and no email', (
    tester,
  ) async {
    await _pump(tester, signedIn: true);
    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();

    expect(find.text('Viewer'), findsOneWidget);
    expect(find.text('viewer@example.test'), findsNothing);

    final banner = find.byKey(
      const ValueKey<String>('app-side-menu-account-banner'),
    );
    expect(banner, findsOneWidget);
    expect(tester.getRect(banner).height, greaterThanOrEqualTo(128));

    final avatar = find.byKey(const ValueKey<String>('account-avatar-button'));
    expect(tester.getRect(avatar).width, greaterThanOrEqualTo(68));

    final name = tester.widget<Text>(
      find.descendant(of: banner, matching: find.text('Viewer')),
    );
    expect(name.style?.fontSize, greaterThanOrEqualTo(20));

    final cover = tester.widget<Image>(
      find.byKey(const ValueKey<String>('app-side-menu-account-cover')),
    );
    expect((cover.image as NetworkImage).url, 'https://example.test/banner.jpg');
  });

  testWidgets('✕, a tap on the page and the back button all close it', (
    tester,
  ) async {
    final harness = await _pump(tester);
    Future<void> open() async {
      await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
      await tester.pumpAndSettle();
      expect(_menuShowing(tester), isTrue);
    }

    await open();
    await tester.tap(find.byKey(const ValueKey('app-side-menu-close')));
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);

    await open();
    await tester.tapAt(const Offset(380, 500));
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);

    await open();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);
    // Closing the menu is all the back button did.
    expect(harness.backWhenClosed, 0);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(harness.backWhenClosed, 1);
  });

  testWidgets('pulling the page right opens it, pulling left shuts it', (
    tester,
  ) async {
    await _pump(tester);

    await tester.timedDragFrom(
      const Offset(150, 500),
      const Offset(220, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isTrue);

    await tester.timedDragFrom(
      const Offset(380, 500),
      const Offset(-250, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);
  });

  testWidgets('a short pull springs back shut', (tester) async {
    await _pump(tester);

    await tester.timedDragFrom(
      const Offset(150, 500),
      const Offset(60, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);
  });

  testWidgets('no pull opens it over a page pushed inside a tab', (
    tester,
  ) async {
    final harness = await _pump(tester);
    // Opened and shut once first: shutting must leave it reading as shut.
    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-side-menu-close')));
    await tester.pumpAndSettle();
    harness.canOpen = false;

    await tester.timedDragFrom(
      const Offset(150, 500),
      const Offset(220, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(_menuShowing(tester), isFalse);
  });

  testWidgets('a page and the account open from the menu, which then shuts', (
    tester,
  ) async {
    final harness = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-side-menu-library')));
    await tester.pumpAndSettle();
    expect(harness.picked, [TaskbarDestination.library]);
    expect(_menuShowing(tester), isFalse);

    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-side-menu-account')));
    await tester.pumpAndSettle();
    expect(harness.accountOpened, 1);
    expect(_menuShowing(tester), isFalse);
  });

  testWidgets('outside the side-menu layout the button draws nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppSideMenuButton())),
    );
    expect(find.byKey(const ValueKey('app-side-menu-button')), findsNothing);
  });

  testWidgets('the More pages sit under the tabs and open from the menu', (
    tester,
  ) async {
    final harness = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('app-side-menu-button')));
    await tester.pumpAndSettle();

    final settings = find.byKey(const ValueKey('app-side-menu-page-settings'));
    expect(
      tester.getTopLeft(settings).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const ValueKey('app-side-menu-home'))).dy,
      ),
    );
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(harness.settingsOpened, 1);
    expect(_menuShowing(tester), isFalse);
  });
}
