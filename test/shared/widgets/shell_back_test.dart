import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/onboarding/first_run_setup_screen.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_scaffold.dart';
import 'package:animewitcher/shared/widgets/custom_bottom_nav.dart';
// Match the Flutter Material widget types used by AppScaffold.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/memory_storage_service.dart';

class _Settings extends GeneralSettingsNotifier {
  @override
  GeneralSettings build() => const GeneralSettings();

  void toggleDownloadLog() {
    state = state.copyWith(downloadDiagnosticLog: !state.downloadDiagnosticLog);
  }

  void hideDownloads() {
    state = state.copyWith(
      hiddenTaskbarItems: {...state.hiddenTaskbarItems, 'downloads'},
    );
  }
}

void main() {
  group('a back press at the shell', () {
    test('never pops the last route on desktop', () {
      // There is nothing under it: the pop left an empty black window.
      expect(
        shellBackLeavesApp(isAtDefaultHome: true, isDesktopPlatform: true),
        isFalse,
      );
    });

    test('still backs out of the app on a handset', () {
      expect(
        shellBackLeavesApp(isAtDefaultHome: true, isDesktopPlatform: false),
        isTrue,
      );
    });

    test('is handled by the shell when away from the default tab', () {
      for (final desktop in <bool>[true, false]) {
        expect(
          shellBackLeavesApp(
            isAtDefaultHome: false,
            isDesktopPlatform: desktop,
          ),
          isFalse,
          reason: 'the shell switches branches instead',
        );
      }
    });
  });

  testWidgets('the shell rebuilds only for settings used by navigation', (
    tester,
  ) async {
    final settings = _Settings();
    final router = GoRouter(
      routes: [
        StatefulShellRoute(
          navigatorContainerBuilder: AppScaffold.buildBranchContainer,
          builder: (_, _, shell) => AppScaffold(navigationShell: shell),
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/', builder: (_, _) => const Text('home')),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          generalSettingsProvider.overrideWith(() => settings),
          storageServiceProvider.overrideWithValue(
            MemoryStorageService()..settings[FirstRunSetup.storageKey] = 'done',
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();

    CustomBottomNavBar dock() =>
        tester.widget<CustomBottomNavBar>(find.byType(CustomBottomNavBar));
    final initial = dock();
    expect(initial.destinations, contains(TaskbarDestination.downloads));

    settings.toggleDownloadLog();
    await tester.pumpAndSettle();
    expect(dock(), same(initial));

    settings.hideDownloads();
    await tester.pumpAndSettle();
    expect(dock().destinations, isNot(contains(TaskbarDestination.downloads)));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
