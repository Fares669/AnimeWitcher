import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/services/artwork_fallback_service.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/theme/app_theme.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/details_screen.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:animewitcher/features/home/presentation/view_all_screen.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_controller.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_screen.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_state.dart';
import 'package:animewitcher/features/manga/presentation/manga_home_screen.dart';
import 'package:animewitcher/features/manga/presentation/manga_view_all_screen.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_cover_provider.dart';
import 'package:animewitcher/features/news/presentation/news_list_screen.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/taskbar_visibility.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/memory_storage_service.dart';

final _anime = MultimediaItem(
  title: 'Anime title',
  url: 'https://example.test/anime',
  posterUrl: '',
  contentType: MultimediaContentType.anime,
);
final _manga = MultimediaItem(
  title: 'Manga title',
  url: 'https://example.test/manga',
  posterUrl: '',
  contentType: MultimediaContentType.manga,
);

class _Storage extends MemoryStorageService {
  @override
  String? getString(String key) =>
      key == 'first_run_setup_v8' ? 'done' : settings[key] as String?;

  @override
  int getPosition(String url) => 0;
}

class _EmptyExtensions extends ExtensionManager {
  @override
  List<AnimeWitcherProvider> build() => [];
}

class _EmptyHome extends HomeData {
  @override
  HomeState build() => const HomeNoProvider();
}

class _EmptyHistory extends ContinueWatchingNotifier {
  @override
  List<HistoryItem> build() => [];
}

class _SignedOut extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot();
}

class _EmptyLibrary extends Library {
  @override
  LibraryState build() =>
      const LibraryEmpty(LibraryCategory.favorite, LibraryMediaKind.anime);

  @override
  bool isFavorite(String url) => false;

  @override
  LibraryCategory? itemCategory(String url) => null;
}

class _EmptyDownloads extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => [];
}

class _EmptyCovers extends MangaReaderCustomCoversNotifier {
  @override
  Map<String, String> build() => {};
}

class _ReadyAnime extends DetailsController {
  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncData<MultimediaItem?>(_anime),
    episodes: const AsyncData<List<Episode>>([]),
    cast: const AsyncData<List<Actor>>([]),
    trailers: const AsyncData<List<Trailer>>([]),
    related: const AsyncData<List<MultimediaItem>>([]),
    recommendations: const AsyncData<List<MultimediaItem>>([]),
    item: _anime,
    basicDetailsResolved: true,
    nextAiringResolved: true,
  );

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
  }) async {}
}

class _ReadyManga extends MangaDetailsController {
  @override
  MangaDetailsState build(String itemUrl) => MangaDetailsState(
    details: AsyncData<MultimediaItem?>(_manga),
    chapters: const AsyncData<List<MangaChapter>>([]),
    item: _manga,
  );

  @override
  Future<void> load(MultimediaItem item) async {}
}

class _NoArtwork extends ArtworkFallbackService {
  _NoArtwork() : super(Dio(), StorageService());

  @override
  Future<({String? cover, String? banner})> mangaArtwork({
    int? malId,
    String title = '',
  }) async => (cover: null, banner: null);
}

Future<GoRouter> _pumpApp(WidgetTester tester, {bool mangaTab = false}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: mangaTab ? '/manga' : '/home',
    navigatorKey: rootNavigatorKey,
    routes: $appRoutes,
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storageServiceProvider.overrideWithValue(_Storage()),
        extensionManagerProvider.overrideWith(_EmptyExtensions.new),
        homeDataProvider.overrideWith(_EmptyHome.new),
        continueWatchingProvider.overrideWith(_EmptyHistory.new),
        animeWitcherAccountControllerProvider.overrideWith(_SignedOut.new),
        libraryProvider.overrideWith(_EmptyLibrary.new),
        downloadsProvider.overrideWith(_EmptyDownloads.new),
        artworkFallbackServiceProvider.overrideWithValue(_NoArtwork()),
        mangaReaderCustomCoversProvider.overrideWith(_EmptyCovers.new),
        malRankingProvider.overrideWith((ref, ranking) async => []),
        detailsControllerProvider(_anime.url).overrideWith(_ReadyAnime.new),
        mangaDetailsControllerProvider(_manga.url)
            .overrideWith(_ReadyManga.new),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.createDarkTheme(null),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _swipeBack(WidgetTester tester, Finder screen) async {
  final route = ModalRoute.of(tester.element(screen))!;
  expect(route.popGestureEnabled, isTrue);
  expect(Directionality.of(tester.element(screen)), TextDirection.rtl);
  final gesture = await tester.startGesture(const Offset(1, 400));
  await gesture.moveBy(const Offset(25, 0));
  await gesture.moveBy(const Offset(85, 0));
  await tester.pump();
  // A real interactive Cupertino transition tracks the finger before release.
  expect(route.popGestureInProgress, isTrue);
  expect(route.animation!.value, inExclusiveRange(0, 1));
  await gesture.moveBy(const Offset(210, 0));
  await gesture.up();
  await tester.pumpAndSettle();
}

void _testIos(String description, WidgetTesterCallback body) => testWidgets(
  description,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.iOS),
);

void main() {
  for (final (manga, mangaTab) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    _testIos(
      'iOS left-edge swipe returns from ${manga ? 'manga' : 'anime'} details'
      '${mangaTab ? ' on Manga tab' : ''}',
      (tester) async {
        final router = await _pumpApp(tester, mangaTab: mangaTab);
        final originScreen = find.byType(
          mangaTab ? MangaHomeScreen : HomeScreen,
        );
        final origin = tester.element(originScreen);
        Future<void> open() => manga
            ? MangaDetailsRoute($extra: MangaDetailsRouteExtra(item: _manga))
                  .push<void>(origin)
            : DetailsRoute($extra: DetailsRouteExtra(item: _anime))
                  .push<void>(origin);
        unawaited(open());
        unawaited(open()); // Rapid taps must still create only one page.
        await tester.pumpAndSettle();
        final screen = find.byType(manga ? MangaDetailsScreen : DetailsScreen);
        expect(screen, findsOneWidget);
        await _swipeBack(tester, screen);
        expect(screen, findsNothing);
        expect(originScreen, findsOneWidget);
        expect(router.canPop(), isFalse);
        // Completing a swipe must release the origin's duplicate-tap guard.
        unawaited(open());
        await tester.pumpAndSettle();
        expect(screen, findsOneWidget);
        await _swipeBack(tester, screen);
        expect(router.canPop(), isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final title in ['رائج الآن', 'الأفضل', 'الأكثر مشاهدة']) {
    _testIos('iOS left-edge swipe returns from Home View All: $title', (
      tester,
    ) async {
      final router = await _pumpApp(tester);
      unawaited(
        ViewAllRoute(
          $extra: ViewAllRouteExtra(
            title: title,
            initialMediaList: const [],
            category: ViewAllCategory.providerContent,
          ),
        ).push<void>(tester.element(find.byType(HomeScreen))),
      );
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      await _swipeBack(tester, find.byType(ViewAllScreen));
      expect(find.byType(ViewAllScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(router.canPop(), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  _testIos('a short iOS back swipe cancels without losing the page', (
    tester,
  ) async {
    final router = await _pumpApp(tester);
    unawaited(
      const ViewAllRoute(
        $extra: ViewAllRouteExtra(
          title: 'الأفضل',
          initialMediaList: [],
          category: ViewAllCategory.providerContent,
        ),
      ).push<void>(tester.element(find.byType(HomeScreen))),
    );
    await tester.pumpAndSettle();
    await tester.timedDragFrom(
      const Offset(1, 400),
      const Offset(65, 0),
      const Duration(milliseconds: 500),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ViewAllScreen), findsOneWidget);
    expect(router.canPop(), isTrue);
    await _swipeBack(tester, find.byType(ViewAllScreen));
    expect(router.canPop(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  _testIos('news keeps its working native iOS left-edge back swipe', (
    tester,
  ) async {
    final router = await _pumpApp(tester);
    unawaited(
      pushOverTaskbar<void>(
        tester.element(find.byType(HomeScreen)),
        MaterialPageRoute<void>(
          builder: (_) => NewsListScreen(
            initialItems: const [],
            loadPage: (offset, limit) async => const ProviderNewsPage(
              items: [],
              nextOffset: 0,
              hasMore: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _swipeBack(tester, find.byType(NewsListScreen));
    expect(find.byType(NewsListScreen), findsNothing);
    expect(router.canPop(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  _testIos('manga View All keeps its branch-native iOS back swipe', (
    tester,
  ) async {
    final router = await _pumpApp(tester, mangaTab: true);
    unawaited(
      Navigator.of(tester.element(find.byType(MangaHomeScreen))).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => MangaViewAllScreen<int>(
            title: 'الأكثر قراءة',
            load: (offset) async =>
                (items: <int>[], nextOffset: 0, hasMore: false),
            itemKey: (item) => '$item',
            itemBuilder: (_, item, index) => Text('$item'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _swipeBack(tester, find.byType(MangaViewAllScreen<int>));
    expect(find.byType(MangaViewAllScreen<int>), findsNothing);
    expect(find.byType(MangaHomeScreen), findsOneWidget);
    expect(router.canPop(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
