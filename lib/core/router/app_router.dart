import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';

import '../../features/home/presentation/home_screen.dart';
import '../../features/search/presentation/search_screen.dart';
import '../../features/library/presentation/library_screen.dart';
import '../../features/library/presentation/downloads_screen.dart';
import '../../features/more/presentation/more_screen.dart';
import '../../features/details/presentation/details_screen.dart';
import '../../features/manga/presentation/manga_details_screen.dart';
import '../../features/manga/presentation/manga_home_screen.dart';
import '../../features/manga/reader/manga_reader_screen.dart';
import '../../features/player/presentation/player_screen.dart';
import '../../features/home/presentation/view_all_screen.dart';
import '../domain/entity/manga.dart';
import '../domain/entity/multimedia_item.dart';
import '../../shared/widgets/app_scaffold.dart';
import '../storage/settings_repository.dart';
import '../extensions/base_provider.dart';
import '../navigation/taskbar_destination.dart';

part 'app_router.g.dart';

// GoRouter 18 detects material_ui.MaterialApp, while this app uses Flutter's
// MaterialApp. Explicit pages retain our themed transitions and iOS back swipe.
MaterialPage<void> _materialPage(GoRouterState state, Widget child) =>
    MaterialPage<void>(
      key: state.pageKey,
      name: state.name ?? state.path,
      arguments: <String, String>{
        ...state.pathParameters,
        ...state.uri.queryParameters,
      },
      restorationId: state.pageKey.value,
      child: child,
    );

abstract class _AppGoRouteData extends GoRouteData {
  const _AppGoRouteData();

  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      _materialPage(
        state,
        Builder(builder: (context) => build(context, state)),
      );
}

@TypedStatefulShellRoute<AppShellRouteData>(
  branches: <TypedStatefulShellBranch<StatefulShellBranchData>>[
    TypedStatefulShellBranch<HomeBranchData>(
      routes: <TypedRoute<RouteData>>[TypedGoRoute<HomeRoute>(path: '/home')],
    ),
    TypedStatefulShellBranch<SearchBranchData>(
      routes: <TypedRoute<RouteData>>[
        TypedGoRoute<SearchRoute>(path: '/search'),
      ],
    ),
    TypedStatefulShellBranch<LibraryBranchData>(
      routes: <TypedRoute<RouteData>>[
        TypedGoRoute<LibraryRoute>(path: '/library'),
      ],
    ),
    TypedStatefulShellBranch<DownloadsBranchData>(
      routes: <TypedRoute<RouteData>>[
        TypedGoRoute<DownloadsRoute>(path: '/downloads'),
      ],
    ),
    TypedStatefulShellBranch<SettingsBranchData>(
      routes: <TypedRoute<RouteData>>[
        TypedGoRoute<SettingsRoute>(path: '/settings'),
      ],
    ),
    // Last, so the branches before it keep their numbers.
    TypedStatefulShellBranch<MangaBranchData>(
      routes: <TypedRoute<RouteData>>[
        TypedGoRoute<MangaHomeRoute>(path: '/manga'),
      ],
    ),
  ],
)
class AppShellRouteData extends StatefulShellRouteData {
  const AppShellRouteData();

  static final GlobalKey<NavigatorState> $navigatorKey = rootNavigatorKey;

  @override
  Page<void> pageBuilder(
    BuildContext context,
    GoRouterState state,
    StatefulNavigationShell navigationShell,
  ) => _materialPage(
    state,
    Builder(builder: (context) => builder(context, state, navigationShell)),
  );

  @override
  Widget builder(
    BuildContext context,
    GoRouterState state,
    StatefulNavigationShell navigationShell,
  ) {
    return AppScaffold(navigationShell: navigationShell);
  }
}

class HomeBranchData extends StatefulShellBranchData {
  const HomeBranchData();
}

class HomeRoute extends _AppGoRouteData with $HomeRoute {
  const HomeRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) => const HomeScreen();
}

class SearchBranchData extends StatefulShellBranchData {
  const SearchBranchData();
}

class SearchRoute extends _AppGoRouteData with $SearchRoute {
  const SearchRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const SearchScreen();
}

class LibraryBranchData extends StatefulShellBranchData {
  const LibraryBranchData();
}

class LibraryRoute extends _AppGoRouteData with $LibraryRoute {
  const LibraryRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const LibraryScreen();
}

class DownloadsBranchData extends StatefulShellBranchData {
  const DownloadsBranchData();
}

class DownloadsRoute extends _AppGoRouteData with $DownloadsRoute {
  const DownloadsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const DownloadsScreen();
}

class SettingsBranchData extends StatefulShellBranchData {
  const SettingsBranchData();
}

class SettingsRoute extends _AppGoRouteData with $SettingsRoute {
  const SettingsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) => const MoreScreen();
}

class MangaBranchData extends StatefulShellBranchData {
  const MangaBranchData();
}

class MangaHomeRoute extends _AppGoRouteData with $MangaHomeRoute {
  const MangaHomeRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const MangaHomeScreen();
}

// --- Typed Extras ---

class DetailsRouteExtra {
  const DetailsRouteExtra({
    required this.item,
    this.autoPlay = false,
    this.resumeEpisodeUrl,
    this.resumeEpisodeNumber,
    this.resumeSeason,
  });

  final MultimediaItem item;
  final bool autoPlay;
  final String? resumeEpisodeUrl;
  final int? resumeEpisodeNumber;
  final int? resumeSeason;
}

class MangaDetailsRouteExtra {
  const MangaDetailsRouteExtra({required this.item});

  final MultimediaItem item;
}

class MangaReaderRouteExtra {
  const MangaReaderRouteExtra({
    required this.manga,
    required this.chapter,
    required this.chapters,
    this.localChapterDirectory,
  });

  final MultimediaItem manga;
  final MangaChapter chapter;
  final List<MangaChapter> chapters;
  final String? localChapterDirectory;
}

class PlayerRouteExtra {
  const PlayerRouteExtra({
    required this.item,
    required this.videoUrl,
    this.progressUrl,
    this.episode,
    this.selectedSource,
  });
  final MultimediaItem item;
  final String videoUrl;
  final String? progressUrl;
  final Episode? episode;
  final StreamResult? selectedSource;
}

class ViewAllRouteExtra {
  const ViewAllRouteExtra({
    required this.title,
    required this.initialMediaList,
    required this.category,
    this.onTap,
    this.loadPage,
    this.initialOffset,
    this.initialHasMore = true,
    this.forcePortrait = false,
  });
  final String title;
  final List<MultimediaItem> initialMediaList;
  final ViewAllCategory category;
  final void Function(MultimediaItem item)? onTap;
  final Future<ProviderMediaPage> Function(int offset)? loadPage;
  final int? initialOffset;
  final bool initialHasMore;
  final bool forcePortrait;
}

// --- Full Screen Routes ---

final _pendingDetailOrigins = Expando<bool>();

Future<T?> _pushDetailsOnce<T>(
  BuildContext context, {
  required String location,
  required Object extra,
  required WidgetBuilder builder,
}) async {
  if (!context.mounted) return null;
  final navigator = Navigator.of(context, rootNavigator: true);
  final origin = ModalRoute.of(context) ?? navigator;
  if (_pendingDetailOrigins[origin] == true ||
      (origin is ModalRoute && !origin.isCurrent)) {
    return null;
  }
  // Lock before parsing: cards share their page's origin, while related items
  // on the new details page have their own origin and can still be opened.
  _pendingDetailOrigins[origin] = true;
  try {
    final router = GoRouter.maybeOf(context);
    final result = router != null
        ? router.push<T>(location, extra: extra)
        : navigator.push<T>(MaterialPageRoute<T>(builder: builder));
    WidgetsBinding.instance.ensureVisualUpdate();
    return await result;
  } finally {
    _pendingDetailOrigins[origin] = null;
  }
}

@TypedGoRoute<DetailsRoute>(path: '/details')
class DetailsRoute extends _AppGoRouteData with $DetailsRoute {
  const DetailsRoute({required this.$extra});
  final DetailsRouteExtra $extra;

  @override
  Future<T?> push<T>(BuildContext context) => _pushDetailsOnce<T>(
    context,
    location: location,
    extra: $extra,
    builder: (_) => _screen(),
  );

  @override
  Widget build(BuildContext context, GoRouterState state) => _screen();

  Widget _screen() {
    return DetailsScreen(
      item: $extra.item,
      autoPlay: $extra.autoPlay,
      resumeEpisodeUrl: $extra.resumeEpisodeUrl,
      resumeEpisodeNumber: $extra.resumeEpisodeNumber,
      resumeSeason: $extra.resumeSeason,
    );
  }
}

@TypedGoRoute<MangaDetailsRoute>(path: '/manga-details')
class MangaDetailsRoute extends _AppGoRouteData with $MangaDetailsRoute {
  const MangaDetailsRoute({required this.$extra});

  final MangaDetailsRouteExtra $extra;

  @override
  Future<T?> push<T>(BuildContext context) => _pushDetailsOnce<T>(
    context,
    location: location,
    extra: $extra,
    builder: (_) => MangaDetailsScreen(item: $extra.item),
  );

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return MangaDetailsScreen(item: $extra.item);
  }
}

@TypedGoRoute<MangaReaderRoute>(path: '/manga-reader')
class MangaReaderRoute extends _AppGoRouteData with $MangaReaderRoute {
  const MangaReaderRoute({required this.$extra});

  final MangaReaderRouteExtra $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return MangaReaderScreen(
      manga: $extra.manga,
      chapter: $extra.chapter,
      chapters: $extra.chapters,
      localChapterDirectory: $extra.localChapterDirectory,
    );
  }
}

@TypedGoRoute<ViewAllRoute>(path: '/view-all')
class ViewAllRoute extends _AppGoRouteData with $ViewAllRoute {
  const ViewAllRoute({required this.$extra});
  final ViewAllRouteExtra $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return ViewAllScreen(
      title: $extra.title,
      initialMediaList: $extra.initialMediaList,
      category: $extra.category,
      onTap: $extra.onTap,
      loadPage: $extra.loadPage,
      initialOffset: $extra.initialOffset,
      initialHasMore: $extra.initialHasMore,
      forcePortrait: $extra.forcePortrait,
    );
  }
}

@TypedGoRoute<PlayerRoute>(path: '/player')
class PlayerRoute extends _AppGoRouteData with $PlayerRoute {
  const PlayerRoute({required this.$extra});
  final PlayerRouteExtra $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return PlayerScreen(
      item: $extra.item,
      videoUrl: $extra.videoUrl,
      progressUrl: $extra.progressUrl,
      episode: $extra.episode,
      selectedSource: $extra.selectedSource,
    );
  }
}

// --- GoRouter Definition ---

final rootNavigatorKey = GlobalKey<NavigatorState>();

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  final repository = ref.read(settingsRepositoryProvider);
  final initial = resolveInitialTaskbarRoute(
    repository.getDefaultHomeScreen(),
    repository.getTaskbarOrder(),
    repository.getHiddenTaskbarItems(),
  );

  return GoRouter(
    initialLocation: initial,
    navigatorKey: rootNavigatorKey,
    debugLogDiagnostics: kDebugMode,
    routes: $appRoutes,
  );
}

// End of Routes
