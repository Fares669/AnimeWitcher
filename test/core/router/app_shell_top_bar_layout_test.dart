import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/navigation/app_layout_style.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/downloads_screen.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_screen.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/features/onboarding/first_run_setup_screen.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/features/search/presentation/search_domain.dart';
import 'package:animewitcher/features/search/presentation/search_screen.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/features/settings/presentation/settings_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_navigation_bars.dart';
import 'package:animewitcher/shared/widgets/app_scaffold.dart';
import 'package:animewitcher/shared/widgets/app_search_field.dart';
import 'package:animewitcher/shared/widgets/app_side_menu.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
// The app shell uses Flutter's MaterialApp and navigation widgets.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../support/memory_storage_service.dart';

MultimediaItem _item(String title) => MultimediaItem(
  title: title,
  url: 'https://example.test/series/${Uri.encodeComponent(title)}',
  posterUrl: '',
  contentType: MultimediaContentType.anime,
);

class _Home extends HomeData {
  @override
  HomeState build() => HomeSuccess({
    for (var row = 0; row < 14; row++)
      'Fixture catalogue rail $row': [
        for (var i = 0; i < 12; i++) _item('Home card $row:$i'),
      ],
  });
}

class _Account extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot();
}

class _Resume extends ContinueWatchingNotifier {
  @override
  List<HistoryItem> build() => const <HistoryItem>[];
}

class _History extends WatchHistory {
  @override
  List<HistoryItem> build() => const <HistoryItem>[];
}

class _Library extends Library {
  int refreshes = 0;
  final items = [for (var i = 0; i < 30; i++) _item('Library card $i')];

  @override
  LibraryState build() =>
      LibrarySuccess(items, LibraryCategory.watching, LibraryMediaKind.anime);

  @override
  List<MultimediaItem> itemsForCategory(
    LibraryMediaKind kind,
    LibraryCategory category,
  ) => kind == LibraryMediaKind.anime && category == LibraryCategory.watching
      ? items
      : const <MultimediaItem>[];

  @override
  Map<LibraryMediaKind, Map<LibraryCategory, int?>> categoryCounts({
    required bool witanimeAnime,
  }) => {
    LibraryMediaKind.anime: {LibraryCategory.watching: items.length},
  };

  @override
  Future<void> refreshVisibleFromServer({
    LibraryCategory? category,
    LibraryMediaKind? mediaKind,
  }) async {
    refreshes++;
  }
}

class _Downloads extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => [
    for (var i = 0; i < 12; i++)
      DownloadItem(
        task: DownloadTask(
          taskId: 'fixture-$i',
          url: 'https://example.test/file/$i',
          filename: '$i.mp4',
        ),
        status: TaskStatus.running,
        progress: 0.35,
        item: _item('Download card $i'),
        episode: Episode(
          name: 'Episode 1',
          url: 'https://example.test/series/$i/1',
          episode: 1,
        ),
        timestamp: i,
      ),
  ];
}

class _LayoutProbe extends SingleChildRenderObjectWidget {
  const _LayoutProbe({
    required super.key,
    required this.onLayout,
    required super.child,
  });

  final ValueChanged<BoxConstraints> onLayout;

  @override
  RenderProxyBox createRenderObject(BuildContext context) =>
      _RenderLayoutProbe(onLayout);
}

class _RenderLayoutProbe extends RenderProxyBox {
  _RenderLayoutProbe(this.onLayout);
  final ValueChanged<BoxConstraints> onLayout;

  @override
  void performLayout() {
    onLayout(constraints);
    super.performLayout();
  }
}

// The real Home carousel can keep requesting frames. Give each navigation
// transition the same number of frames instead of waiting for a quiet app.
Future<void> _pumpNavigation(WidgetTester tester) async {
  await tester.pump();
  for (var frame = 0; frame < 4; frame++) {
    await tester.pump(const Duration(milliseconds: 64));
  }
}

Future<void> _pumpDrawer(WidgetTester tester) async {
  await _pumpNavigation(tester);
  // The drawer transition lasts 280 ms and is separate from page navigation.
  await tester.pump(const Duration(milliseconds: 64));
}

const _measurementSwitches = 12;

void main() {
  for (final (layout, tablet) in <(AppLayoutStyle, bool)>[
    (AppLayoutStyle.topBar, false),
    (AppLayoutStyle.topBar, true),
    (AppLayoutStyle.sideRail, false),
    (AppLayoutStyle.dock, false),
  ]) {
    testWidgets('${layout.name}, ${tablet ? 'tablet notch' : 'desktop'} keeps '
        'warm branch viewports and offstage state on tab switches', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = tablet
          ? TargetPlatform.android
          : TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final visibility = VisibilityDetectorController.instance;
      final originalInterval = visibility.updateInterval;
      visibility.updateInterval = Duration.zero;
      addTearDown(() => visibility.updateInterval = originalInterval);

      final storage = MemoryStorageService()
        ..settings[FirstRunSetup.storageKey] = 'done'
        ..settings[AppLayoutStyleNotifier.storageKey] = layout.name;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.reject(
              DioException(
                requestOptions: options,
                error: StateError(
                  'No catalogue transport in the shell fixture',
                ),
              ),
            ),
          ),
        );
      final catalogue = AnimeWitcherNativeProvider(
        dio,
        SettingsRepository(storage),
      );
      final library = _Library();
      final layouts = <(String, BoxConstraints)>[];
      final pages = <String, Widget>{
        '/home': const HomeScreen(),
        '/search': const SearchScreen(),
        '/library': const LibraryScreen(),
        '/downloads': const DownloadsScreen(),
        '/settings': const SettingsScreen(),
      };
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          StatefulShellRoute(
            navigatorContainerBuilder:
                ($appShellRouteData as StatefulShellRoute)
                    .navigatorContainerBuilder,
            builder: const AppShellRouteData().builder,
            branches: [
              for (final MapEntry(:key, :value) in pages.entries)
                StatefulShellBranch(
                  routes: [
                    GoRoute(
                      path: key,
                      pageBuilder: (_, state) => NoTransitionPage<void>(
                        key: state.pageKey,
                        child: _LayoutProbe(
                          key: ValueKey(key),
                          onLayout: (constraints) =>
                              layouts.add((key, constraints)),
                          child: value,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          GoRoute(
            path: '/fixture-details',
            pageBuilder: (_, state) => const NoTransitionPage<void>(
              child: SizedBox.expand(key: ValueKey('full-page-route')),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      const notch = 28.0;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            generalSettingsProvider.overrideWithBuild(
              (_, _) => const GeneralSettings(),
            ),
            deviceProfileProvider.overrideWith(
              (_) async => const DeviceProfile(),
            ),
            animeWitcherAccountControllerProvider.overrideWith(_Account.new),
            activeProviderProvider.overrideWithValue(catalogue),
            extensionManagerProvider.overrideWithBuild((_, _) => [catalogue]),
            homeDataProvider.overrideWith(_Home.new),
            continueWatchingProvider.overrideWith(_Resume.new),
            watchHistoryProvider.overrideWith(_History.new),
            libraryProvider.overrideWith(() => library),
            downloadsProvider.overrideWith(_Downloads.new),
            homeMalRankingPageProvider.overrideWith(
              (_, _) async => const ProviderMediaPage(
                items: [],
                nextOffset: 0,
                hasMore: false,
              ),
            ),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) {
              const insets = EdgeInsets.only(top: notch);
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: tablet ? insets : EdgeInsets.zero,
                  viewPadding: tablet ? insets : EdgeInsets.zero,
                  disableAnimations: true,
                ),
                child: child!,
              );
            },
          ),
        ),
      );
      await _pumpNavigation(tester);

      final inset = layout == AppLayoutStyle.topBar
          ? AppTopBar.height + (tablet ? notch : 0)
          : 0;
      void expectPane(String path) {
        final pane = find.byKey(ValueKey(path)).hitTestable();
        expect(pane, findsOneWidget);
        final y = path == '/home' ? 0.0 : inset.toDouble();
        expect(tester.getTopLeft(pane).dy, y);
        if (path != '/home') {
          expect(tester.getSize(pane).height, 860 - y);
        }
      }

      expectPane('/home');
      final home = tester.state(find.byType(HomeScreen));
      final homeScroll = tester
          .widget<CustomScrollView>(
            find.descendant(
              of: find.byType(HomeScreen),
              matching: find.byType(CustomScrollView),
            ),
          )
          .controller!;
      homeScroll.jumpTo(250);
      await _pumpNavigation(tester);

      // Warm real app screens once. Branches not yet visited must remain lazy.
      expect(find.byType(SearchScreen, skipOffstage: false), findsNothing);
      for (final path in pages.keys.skip(1)) {
        router.go(path);
        await _pumpNavigation(tester);
        expectPane(path);
      }
      expect(library.refreshes, greaterThan(0));

      router.go('/home');
      await _pumpNavigation(tester);
      expectPane('/home');
      expect(tester.state(find.byType(HomeScreen)), same(home));
      expect(homeScroll.offset, 250);
      final libraryRefreshes = library.refreshes;
      layouts.clear();
      final layoutTags = <String, int>{};
      for (var i = 0; i < _measurementSwitches; i++) {
        final path = i.isEven ? '/search' : '/home';
        final destination = i.isEven
            ? TaskbarDestination.search
            : TaskbarDestination.home;
        final control = find.byIcon(destination.icon).hitTestable();
        await tester.tap(control.first);
        await _pumpNavigation(tester);
        expectPane(path);
      }
      expect(library.refreshes, libraryRefreshes);
      for (final (path, _) in layouts) {
        layoutTags.update(path, (count) => count + 1, ifAbsent: () => 1);
      }
      // Changing the visible page must not change any warm branch viewport.
      expect(layoutTags, isEmpty);
      for (final path in pages.keys) {
        final branch = find.byKey(ValueKey(path), skipOffstage: false);
        expect(branch, findsOneWidget);
        expect(
          TickerMode.valuesOf(tester.element(branch)).enabled,
          path == '/home',
        );
      }

      router.go('/search');
      await _pumpNavigation(tester);
      final search = tester.state(find.byType(SearchScreen));
      final field = find.byType(AppSearchField).hitTestable();
      final focus = tester.widget<AppSearchField>(field).focusNode!;
      focus.requestFocus();
      await _pumpNavigation(tester);
      expect(focus.hasFocus, isTrue);

      if (layout == AppLayoutStyle.topBar && tablet) {
        // The actual Search route owns focus as the Android tablet keyboard
        // opens and closes. Only the body should resize at each metrics tick.
        const keyboardInsets = <double>[40, 120, 226, 260, 194, 88, 24, 0];
        final topBar = find.byType(AppTopBar);
        final chrome = find.byType(AppSideMenuShell);
        final scaffold = find.byType(AppScaffold);
        final pane = find.byKey(const ValueKey('/search')).hitTestable();
        final topBarBounds = tester.getRect(topBar);
        expect(Directionality.of(tester.element(topBar)), TextDirection.rtl);
        var topBarReplacements = 0;
        var shellReplacements = 0;
        for (final bottom in keyboardInsets) {
          final oldTopBar = tester.widget<AppTopBar>(topBar);
          final oldShell = tester.widget<AppSideMenuShell>(chrome);
          tester.view.viewInsets = FakeViewPadding(bottom: bottom);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 48));
          if (!identical(oldTopBar, tester.widget<AppTopBar>(topBar))) {
            topBarReplacements++;
          }
          if (!identical(oldShell, tester.widget<AppSideMenuShell>(chrome))) {
            shellReplacements++;
          }
          expect(
            tester
                .element(scaffold)
                .getInheritedWidgetOfExactType<MediaQuery>()!
                .data
                .viewInsets
                .bottom,
            bottom,
          );
          expect(tester.getRect(topBar), topBarBounds);
          expect(tester.getSize(pane).height, 860 - inset - bottom);
          expect(tester.state(find.byType(SearchScreen)), same(search));
          expect(tester.widget<AppSearchField>(field).focusNode, same(focus));
          expect(focus.hasFocus, isTrue);
        }
        debugPrint(
          'C22_TABLET_IME steps=${keyboardInsets.length} '
          'topBar=$topBarReplacements shell=$shellReplacements',
        );
        expect((topBarReplacements, shellReplacements), (0, 0));
        tester.view.resetViewInsets();
        await _pumpNavigation(tester);
      }

      final container = ProviderScope.containerOf(tester.element(field));
      final domains = container.read(searchDomainProvider.notifier);
      final shell = find.byType(AppSideMenuShell);
      final panel = find.byType(AppSideMenuPanel, skipOffstage: false);
      final menuControl = find
          .byKey(const ValueKey<String>('app-side-menu-button'))
          .hitTestable()
          .first;
      final menu = find.byKey(const ValueKey<String>('app-side-menu'));
      expect(menu.hitTestable(), findsNothing);
      var shellConfigs = 0;
      var drawerConfigs = 0;
      var entryConfigs = 0;
      for (var i = 0; i < 16; i++) {
        final beforeShell = tester.widget<AppSideMenuShell>(shell);
        final beforePanel = tester.widget<AppSideMenuPanel>(panel);
        domains.set(i.isEven ? SearchDomain.manga : SearchDomain.animation);
        await _pumpNavigation(tester);
        final afterPanel = tester.widget<AppSideMenuPanel>(panel);
        if (!identical(beforeShell, tester.widget<AppSideMenuShell>(shell))) {
          shellConfigs++;
        }
        if (!identical(beforePanel, afterPanel)) drawerConfigs++;
        expect(afterPanel.entries.length, 14);
        for (var row = 0; row < afterPanel.entries.length; row++) {
          if (!identical(beforePanel.entries[row], afterPanel.entries[row])) {
            entryConfigs++;
          }
        }
        expect(tester.state(find.byType(SearchScreen)), same(search));
        expect(tester.widget<AppSearchField>(field).focusNode, same(focus));
        expect(focus.hasFocus, isTrue);
      }
      // Domain changes are frequent on Search. While the drawer is fully
      // closed, none of its rows or the surrounding shell should rebuild.
      expect((shellConfigs, drawerConfigs, entryConfigs), (0, 0, 0));

      bool entrySelected(String id) => tester
          .widget<AppSideMenuPanel>(panel)
          .entries
          .singleWhere((entry) => entry.id == id)
          .selected;
      final closeMenu = find.byKey(
        const ValueKey<String>('app-side-menu-close'),
      );
      await tester.tap(menuControl);
      await _pumpDrawer(tester);
      expect(menu.hitTestable(), findsOneWidget);
      expect(entrySelected('animation-search'), isTrue);
      expect(focus.hasFocus, isFalse); // Menu still dismisses the keyboard.

      final openShell = tester.widget<AppSideMenuShell>(shell);
      domains.set(SearchDomain.characters);
      await _pumpNavigation(tester);
      expect(entrySelected('characters-search'), isTrue);
      expect(tester.widget<AppSideMenuShell>(shell), same(openShell));

      final drawerScroll = tester.state<ScrollableState>(
        find.descendant(of: menu, matching: find.byType(Scrollable)).first,
      );
      expect(drawerScroll.position.maxScrollExtent, greaterThan(100));
      drawerScroll.position.jumpTo(100);
      await _pumpNavigation(tester);
      await tester.tap(closeMenu);
      await _pumpDrawer(tester);
      expect(menu.hitTestable(), findsNothing);

      // Exercise a background/resume and two genuine branch switches while
      // closed: keep the drawer's scroll and pick the latest domain on open.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      domains.set(SearchDomain.manga);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      router.go('/home');
      await _pumpNavigation(tester);
      expectPane('/home');
      expect(tester.state(find.byType(HomeScreen)), same(home));
      expect(homeScroll.offset, 250);
      router.go('/search');
      await _pumpNavigation(tester);
      expectPane('/search');
      expect(tester.state(find.byType(SearchScreen)), same(search));
      await tester.tap(menuControl);
      await _pumpDrawer(tester);
      expect(entrySelected('manga-search'), isTrue);
      expect(
        tester.state<ScrollableState>(
          find.descendant(of: menu, matching: find.byType(Scrollable)).first,
        ),
        same(drawerScroll),
      );
      expect(drawerScroll.position.pixels, 100);
      final animeRow = find
          .byKey(const ValueKey<String>('app-side-menu-page-anime-search'))
          .hitTestable();
      expect(animeRow, findsOneWidget);
      await tester.tap(animeRow);
      await _pumpDrawer(tester);
      expect(menu.hitTestable(), findsNothing);
      expect(container.read(searchDomainProvider), SearchDomain.anime);
      expectPane('/search');

      router.go('/home');
      await _pumpNavigation(tester);

      // Non-shell details must cover the top bar; Back reveals the same
      // scroll position and state, not a remounted Home.
      unawaited(router.push<void>('/fixture-details'));
      await _pumpNavigation(tester);
      final details = find.byKey(const ValueKey('full-page-route'));
      expect(tester.getTopLeft(details), Offset.zero);
      expect(tester.getSize(details), const Size(1280, 860));
      router.pop();
      await _pumpNavigation(tester);
      expect(tester.state(find.byType(HomeScreen)), same(home));
      expect(homeScroll.offset, 250);
      expectPane('/home');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
