import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/navigation/app_layout_style.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/onboarding/first_run_setup_screen.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_scaffold.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../support/memory_storage_service.dart';

class _Storage extends MemoryStorageService {
  @override
  String? getString(String key) =>
      key == FirstRunSetup.storageKey ? 'done' : null;
}

class _HomeData extends HomeData {
  int calls = 0;
  final keepCurrentValues = <bool>[];
  Completer<void>? pending;

  @override
  HomeState build() => HomeSuccess({
    for (var i = 0; i < 10; i++)
      'Section $i': [
        MultimediaItem(title: 'Show $i', url: 'show-$i', posterUrl: ''),
      ],
  });

  @override
  Future<void> fetch({bool keepCurrent = false}) async {
    calls++;
    keepCurrentValues.add(keepCurrent);
    await pending?.future;
  }
}

class _ContinueWatching extends ContinueWatchingNotifier {
  int calls = 0;
  Completer<void>? pending;

  @override
  List<HistoryItem> build() => [];

  @override
  Future<void> refreshFromServer() async {
    calls++;
    await pending?.future;
  }
}

class _Settings extends GeneralSettingsNotifier {
  @override
  GeneralSettings build() => const GeneralSettings();
}

class _Account extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot();
}

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  for (final layout in <AppLayoutStyle?>[...AppLayoutStyle.values, null]) {
    testWidgets(
      '${layout?.name ?? 'phone dock'}: reselecting Home scrolls up and shares pull refresh',
      (tester) async {
        final phone = layout == null;
        debugDefaultTargetPlatformOverride = phone
            ? TargetPlatform.android
            : null;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.physicalSize = phone
            ? const Size(390, 844)
            : const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final storage = _Storage();
        final data = _HomeData();
        final history = _ContinueWatching();
        final container = ProviderContainer(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            generalSettingsProvider.overrideWith(_Settings.new),
            appLayoutStyleProvider.overrideWith(
              () => _Layout(layout ?? AppLayoutStyle.dock),
            ),
            activeProviderProvider.overrideWithValue(
              AnimeWitcherNativeProvider(Dio(), SettingsRepository(storage)),
            ),
            homeDataProvider.overrideWith(() => data),
            continueWatchingProvider.overrideWith(() => history),
            animeWitcherAccountControllerProvider.overrideWith(_Account.new),
            deviceProfileProvider.overrideWith(
              (ref) async => const DeviceProfile(),
            ),
            malRankingProvider.overrideWith((ref, ranking) async => []),
          ],
        );
        final router = GoRouter(
          initialLocation: '/home',
          routes: [
            StatefulShellRoute.indexedStack(
              builder: (context, state, shell) =>
                  AppScaffold(navigationShell: shell),
              branches: [
                StatefulShellBranch(
                  routes: [
                    GoRoute(
                      path: '/home',
                      builder: (context, state) => const HomeScreen(),
                    ),
                  ],
                ),
                StatefulShellBranch(
                  routes: [
                    GoRoute(
                      path: '/search',
                      builder: (context, state) =>
                          const Scaffold(body: Text('Search page')),
                    ),
                  ],
                ),
              ],
            ),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(router.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scroll = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!;
        final homeState = tester.state(find.byType(HomeScreen));
        scroll.jumpTo(500);
        await tester.pumpAndSettle();
        expect(scroll.offset, 500);
        data.pending = Completer<void>();
        history.pending = Completer<void>();

        await tester.tap(
          find.byIcon(TaskbarDestination.home.selectedIcon).hitTestable(),
        );
        await tester.pump();
        expect(scroll.offset, 0);
        expect(data.calls, 1);
        expect(history.calls, 1);
        expect(data.keepCurrentValues, [true]);
        expect(tester.state(find.byType(HomeScreen)), same(homeState));

        // A second tap and pull-refresh during the same request share its work.
        await tester.tap(
          find.byIcon(TaskbarDestination.home.selectedIcon).hitTestable(),
        );
        final refresh = tester.widget<RefreshIndicator>(
          find.byType(RefreshIndicator),
        );
        final overlappingPull = refresh.onRefresh();
        await tester.pump();
        expect(data.calls, 1);
        expect(history.calls, 1);
        data.pending!.complete();
        history.pending!.complete();
        await overlappingPull;
        await tester.pumpAndSettle();

        // A new actual pull uses the same refresh operations and lock.
        data.pending = Completer<void>();
        history.pending = Completer<void>();
        await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(data.calls, 2);
        expect(history.calls, 2);
        await tester.tap(
          find.byIcon(TaskbarDestination.home.selectedIcon).hitTestable(),
        );
        expect(data.calls, 2);
        expect(history.calls, 2);
        data.pending!.complete();
        history.pending!.complete();
        await tester.pumpAndSettle();

        // Selecting Home from another tab preserves the existing Home position.
        scroll.jumpTo(350);
        await tester.tap(
          find.byIcon(TaskbarDestination.search.icon).hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(find.text('Search page'), findsOneWidget);
        await tester.tap(
          find.byIcon(TaskbarDestination.home.icon).hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(HomeScreen)), same(homeState));
        expect(scroll.offset, 350);
        expect(data.calls, 2);
        expect(history.calls, 2);

        // A failed pull releases the shared lock, so Home can refresh again.
        data.pending = Completer<void>();
        history.pending = Completer<void>();
        final failedPull = refresh.onRefresh();
        final failure = expectLater(failedPull, throwsStateError);
        data.pending!.completeError(StateError('offline'));
        history.pending!.complete();
        await failure;
        expect(data.calls, 3);
        data.pending = Completer<void>();
        history.pending = Completer<void>();
        await tester.tap(
          find.byIcon(TaskbarDestination.home.selectedIcon).hitTestable(),
        );
        expect(scroll.offset, 0);
        expect(data.calls, 4);
        expect(history.calls, 4);
        data.pending!.complete();
        history.pending!.complete();
        await tester.pumpAndSettle();
        // Tab taps have no caller awaiting the refresh: network failures must
        // still be handled, and a later tap must be able to retry.
        data.pending = Completer<void>();
        history.pending = Completer<void>();
        await tester.tap(
          find.byIcon(TaskbarDestination.home.selectedIcon).hitTestable(),
        );
        data.pending!.complete();
        history.pending!.completeError(StateError('offline sync'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        data.pending = null;
        history.pending = null;
        await tester.tap(
          find.byIcon(TaskbarDestination.home.selectedIcon).hitTestable(),
        );
        await tester.pumpAndSettle();
        expect(data.calls, 6);
        expect(history.calls, 6);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}

class _Layout extends AppLayoutStyleNotifier {
  _Layout(this.layout);
  final AppLayoutStyle layout;

  @override
  AppLayoutStyle? build() => layout;
}
