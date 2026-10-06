import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_navigation_bars.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _destinations = <TaskbarDestination>[
  TaskbarDestination.home,
  TaskbarDestination.search,
  TaskbarDestination.manga,
  TaskbarDestination.library,
  TaskbarDestination.downloads,
  TaskbarDestination.settings,
];

Future<void> _pumpTopBar(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: AppTopBar(
              destinations: _destinations,
              currentBranchIndex: TaskbarDestination.home.branchIndex,
              overArtwork: false,
              onTap: (_) {},
              onNews: () {},
              onAccount: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a tablet held upright keeps every page on the top bar', (
    tester,
  ) async {
    await _pumpTopBar(tester, const Size(800, 400));

    final account = tester.getRect(
      find.byKey(const ValueKey('account-avatar-button')),
    );
    for (final destination in _destinations) {
      final icon = find.byIcon(
        destination == TaskbarDestination.home
            ? destination.selectedIcon
            : destination.icon,
      );
      expect(icon, findsOneWidget, reason: destination.name);
      final rect = tester.getRect(icon);
      // On the bar, and clear of the account in the corner.
      expect(rect.left, greaterThan(account.right), reason: destination.name);
      expect(rect.right, lessThanOrEqualTo(800), reason: destination.name);
    }
    // Sized for a finger: tests run as a tablet would, not a desktop.
    final library = tester.widget<Icon>(
      find.byIcon(TaskbarDestination.library.icon),
    );
    expect(library.size, 24);
    expect(
      tester.getSize(find.byIcon(TaskbarDestination.library.icon)).height,
      24,
    );
    // Only the page showing is named; the rest keep their icons.
    expect(find.text('الرئيسية'), findsOneWidget);
    expect(find.text('المكتبة'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide window names every page', (tester) async {
    await _pumpTopBar(tester, const Size(1600, 400));
    expect(find.text('الرئيسية'), findsOneWidget);
    expect(find.text('المكتبة'), findsOneWidget);
    expect(find.text('AnimeWitcher'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
