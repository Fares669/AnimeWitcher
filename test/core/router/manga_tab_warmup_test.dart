import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/navigation/app_layout_style.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/services/artwork_fallback_service.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:animewitcher/features/home/presentation/widgets/home_section_header.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/manga/presentation/manga_home_screen.dart';
import 'package:animewitcher/features/manga/presentation/manga_view_all_screen.dart';
import 'package:animewitcher/features/onboarding/first_run_setup_screen.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
// Match the app shell's Material compatibility API.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../support/memory_storage_service.dart';

MultimediaItem _item(String title) => MultimediaItem(
  title: title,
  url: 'https://example.test/manga/${Uri.encodeComponent(title)}',
  posterUrl: '',
  contentType: MultimediaContentType.manga,
);

class _Source extends AnimeWitcherNativeProvider {
  _Source(StorageService storage)
    : super(
        Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) => handler.reject(
                DioException(
                  requestOptions: options,
                  error: StateError('No external requests in the fixture'),
                ),
              ),
            ),
          ),
        SettingsRepository(storage),
      );

  int latestCalls = 0;
  int popularCalls = 0;
  Future<String>? nextLatest;
  Future<String>? nextPopular;

  @override
  Future<MangaLatestChapterPage> getLatestMangaPage({
    int offset = 0,
    int limit = 30,
  }) async {
    latestCalls++;
    final title = await nextLatest ?? 'Fixture latest';
    return MangaLatestChapterPage(
      items: [
        MangaLatestChapter(
          manga: _item(title),
          chapter: const MangaChapter(
            id: 'chapter-2',
            mangaId: 'fixture',
            url: '',
            name: 'الفصل 2',
            number: 2,
          ),
        ),
      ],
      nextOffset: 1,
      hasMore: false,
    );
  }

  @override
  Future<ProviderMediaPage> searchMangaPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async {
    popularCalls++;
    final title = await nextPopular ?? 'Fixture popular';
    return ProviderMediaPage(
      items: [_item(title)],
      nextOffset: 1,
      hasMore: false,
    );
  }
}

class _Extensions extends ExtensionManager {
  _Extensions(this._source);
  final _Source _source;
  @override
  List<AnimeWitcherProvider> build() => [_source];

  void replaceSource(_Source source) => state = [source];
}

class _Home extends HomeData {
  @override
  HomeState build() => const HomeSuccess({});
}

class _History extends ContinueWatchingNotifier {
  @override
  List<HistoryItem> build() => const [];
}

class _Account extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot();
}

class _Settings extends GeneralSettingsNotifier {
  @override
  GeneralSettings build() => const GeneralSettings(hiddenTaskbarItems: {});
}

class _NoArtwork extends ArtworkFallbackService {
  _NoArtwork(StorageService storage) : super(Dio(), storage);

  @override
  Future<({String? cover, String? banner})> mangaArtwork({
    int? malId,
    String title = '',
  }) async => (cover: null, banner: null);
}

Future<_Source> _pumpHome(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final visibility = VisibilityDetectorController.instance;
  final originalInterval = visibility.updateInterval;
  visibility.updateInterval = Duration.zero;
  addTearDown(() => visibility.updateInterval = originalInterval);
  final storage = MemoryStorageService()
    ..settings[FirstRunSetup.storageKey] = 'done'
    ..settings[AppLayoutStyleNotifier.storageKey] = AppLayoutStyle.dock.name;
  final source = _Source(storage);
  final router = GoRouter(
    initialLocation: '/home',
    navigatorKey: rootNavigatorKey,
    routes: $appRoutes,
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        deviceProfileProvider.overrideWith((_) async => const DeviceProfile()),
        extensionManagerProvider.overrideWith(() => _Extensions(source)),
        homeDataProvider.overrideWith(_Home.new),
        continueWatchingProvider.overrideWith(_History.new),
        animeWitcherAccountControllerProvider.overrideWith(_Account.new),
        generalSettingsProvider.overrideWith(_Settings.new),
        artworkFallbackServiceProvider.overrideWithValue(_NoArtwork(storage)),
        homeMalRankingPageProvider.overrideWith(
          (ref, ranking) async =>
              const ProviderMediaPage(items: [], nextOffset: 0, hasMore: false),
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
  await tester.pump();
  expect(find.byType(HomeScreen), findsOneWidget);
  return source;
}

Future<void> _openManga(WidgetTester tester) async {
  await tester.tap(find.byIcon(TaskbarDestination.manga.icon).hitTestable());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byType(MangaHomeScreen), findsOneWidget);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  testWidgets('first Manga tab entry before idle does not fetch twice', (
    tester,
  ) async {
    final source = await _pumpHome(tester);
    expect((source.latestCalls, source.popularCalls), (0, 0));
    await _openManga(tester);
    expect((source.latestCalls, source.popularCalls), (1, 1));
    expect(find.text('Fixture latest'), findsWidgets);
    expect(find.text('Fixture popular'), findsWidgets);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    // Home is retained offstage when Manga is opened via the real dock.
    expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);
    expect((source.latestCalls, source.popularCalls), (1, 1));
    await tester.tap(find.byIcon(TaskbarDestination.home.icon).hitTestable());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(HomeScreen), findsOneWidget);
    await _openManga(tester);
    expect(find.text('Fixture latest'), findsWidgets);
    expect((source.latestCalls, source.popularCalls), (1, 1));
    await _unmount(tester);
  });

  testWidgets('Manga adopts both pending rails and paints each on completion', (
    tester,
  ) async {
    final source = await _pumpHome(tester);
    final latest = Completer<String>();
    final popular = Completer<String>();
    source.nextLatest = latest.future;
    source.nextPopular = popular.future;
    await tester.pump(const Duration(seconds: 6));
    expect((source.latestCalls, source.popularCalls), (1, 1));

    await _openManga(tester);
    expect((source.latestCalls, source.popularCalls), (1, 1));
    latest.complete('Held latest');
    await tester.pump();
    expect(find.text('Held latest'), findsWidgets);
    expect(find.text('Held popular'), findsNothing);
    popular.complete('Held popular');
    await tester.pump();
    expect(find.text('Held popular'), findsWidgets);
    expect((source.latestCalls, source.popularCalls), (1, 1));

    // Pull refresh is an independent, explicitly requested request.
    source.nextLatest = null;
    source.nextPopular = null;
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    expect((source.latestCalls, source.popularCalls), (2, 2));
    expect(find.text('Fixture latest'), findsWidgets);
    expect(find.text('Fixture popular'), findsWidgets);

    // View All owns its own paged request; returning keeps the settled tab.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('manga-popular-header')),
        matching: find.byType(HomeViewAllButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MangaViewAllScreen<MultimediaItem>), findsOneWidget);
    expect(source.popularCalls, 3);
    Navigator.of(
      tester.element(find.byType(MangaViewAllScreen<MultimediaItem>)),
    ).pop();
    await tester.pumpAndSettle();
    expect(find.byType(MangaHomeScreen), findsOneWidget);
    expect(find.text('Fixture popular'), findsWidgets);
    await _unmount(tester);
  });

  testWidgets('a failed pending warm-up has a visible retry', (tester) async {
    final source = await _pumpHome(tester);
    final warmPopular = Completer<String>();
    source.nextPopular = warmPopular.future;
    await tester.pump(const Duration(seconds: 6));
    expect(source.popularCalls, 1);
    source.nextPopular = null;

    await _openManga(tester);
    expect(source.popularCalls, 1);
    warmPopular.completeError(StateError('speculative work failed'));
    await tester.pump();
    expect(source.popularCalls, 2);
    expect(find.text('Fixture popular'), findsWidgets);
    await _unmount(tester);
  });

  testWidgets('a settled prefetch is shown immediately and then refreshed', (
    tester,
  ) async {
    final source = await _pumpHome(tester);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect((source.latestCalls, source.popularCalls), (1, 1));

    final latest = Completer<String>();
    final popular = Completer<String>();
    source.nextLatest = latest.future;
    source.nextPopular = popular.future;
    await _openManga(tester);
    expect((source.latestCalls, source.popularCalls), (2, 2));
    expect(find.text('Fixture latest'), findsWidgets);
    expect(find.text('Fixture popular'), findsWidgets);

    latest.complete('Refreshed latest');
    popular.complete('Refreshed popular');
    await tester.pump();
    expect(find.text('Refreshed latest'), findsWidgets);
    expect(find.text('Refreshed popular'), findsWidgets);
    await _unmount(tester);
  });

  testWidgets('first entry adopts only the still-pending rail', (tester) async {
    final source = await _pumpHome(tester);
    final warmLatest = Completer<String>();
    final warmPopular = Completer<String>();
    source.nextLatest = warmLatest.future;
    source.nextPopular = warmPopular.future;
    await tester.pump(const Duration(seconds: 6));
    expect((source.latestCalls, source.popularCalls), (1, 1));
    warmLatest.complete('Partially settled latest');
    await tester.pump();

    final freshLatest = Completer<String>();
    source.nextLatest = freshLatest.future;
    await _openManga(tester);
    expect(find.text('Partially settled latest'), findsWidgets);
    expect((source.latestCalls, source.popularCalls), (2, 1));

    warmPopular.complete('Still held popular');
    await tester.pump();
    expect(find.text('Still held popular'), findsWidgets);
    expect(find.text('Partially settled latest'), findsWidgets);

    freshLatest.complete('Fresh latest after partial warmup');
    await tester.pump();
    expect(find.text('Fresh latest after partial warmup'), findsWidgets);
    expect((source.latestCalls, source.popularCalls), (2, 1));
    await _unmount(tester);
  });

  testWidgets('late adopted rails cannot override a newer visible refresh', (
    tester,
  ) async {
    final source = await _pumpHome(tester);
    final warmLatest = Completer<String>();
    final warmPopular = Completer<String>();
    source.nextLatest = warmLatest.future;
    source.nextPopular = warmPopular.future;
    await tester.pump(const Duration(seconds: 6));
    await _openManga(tester);
    expect((source.latestCalls, source.popularCalls), (1, 1));

    source.nextLatest = Future<String>.value('Refreshed while latest is held');
    source.nextPopular = Future<String>.value(
      'Refreshed while popular is held',
    );
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    expect((source.latestCalls, source.popularCalls), (2, 2));
    expect(find.text('Refreshed while latest is held'), findsWidgets);
    expect(find.text('Refreshed while popular is held'), findsWidgets);

    warmLatest.complete('Stale adopted latest');
    warmPopular.completeError(StateError('late failure of adopted popular'));
    await tester.pump();
    expect((source.latestCalls, source.popularCalls), (2, 2));
    expect(find.text('Stale adopted latest'), findsNothing);
    expect(find.text('Refreshed while latest is held'), findsWidgets);
    expect(find.text('Refreshed while popular is held'), findsWidgets);

    await tester.tap(find.byIcon(TaskbarDestination.home.icon).hitTestable());
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(HomeScreen), findsOneWidget);
    await _openManga(tester);
    expect(find.text('Refreshed while latest is held'), findsWidgets);
    expect(find.text('Refreshed while popular is held'), findsWidgets);
    expect((source.latestCalls, source.popularCalls), (2, 2));
    await _unmount(tester);
  });

  testWidgets('first entry rejects pending warmup from a replaced source', (
    tester,
  ) async {
    final source = await _pumpHome(tester);
    final warmLatest = Completer<String>();
    final warmPopular = Completer<String>();
    source.nextLatest = warmLatest.future;
    source.nextPopular = warmPopular.future;
    await tester.pump(const Duration(seconds: 6));
    expect((source.latestCalls, source.popularCalls), (1, 1));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
      listen: false,
    );
    final replacement = _Source(container.read(storageServiceProvider))
      ..nextLatest = Future<String>.value('Replacement latest')
      ..nextPopular = Future<String>.value('Replacement popular');
    final registry =
        container.read(extensionManagerProvider.notifier) as _Extensions;
    registry.replaceSource(replacement);
    await tester.pump();
    await _openManga(tester);
    expect((replacement.latestCalls, replacement.popularCalls), (1, 1));
    expect(find.text('Replacement latest'), findsWidgets);
    expect(find.text('Replacement popular'), findsWidgets);

    warmLatest.complete('Old source latest');
    warmPopular.complete('Old source popular');
    await tester.pump();
    expect((source.latestCalls, source.popularCalls), (1, 1));
    expect((replacement.latestCalls, replacement.popularCalls), (1, 1));
    expect(find.text('Old source latest'), findsNothing);
    expect(find.text('Old source popular'), findsNothing);
    expect(find.text('Replacement latest'), findsWidgets);
    expect(find.text('Replacement popular'), findsWidgets);
    await _unmount(tester);
  });
}
