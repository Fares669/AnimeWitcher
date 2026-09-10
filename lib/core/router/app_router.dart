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
import '../../features/player/presentation/player_screen.dart';
import '../../features/home/presentation/view_all_screen.dart';
import '../domain/entity/multimedia_item.dart';
import '../../shared/widgets/app_scaffold.dart';
import '../storage/settings_repository.dart';
import '../extensions/base_provider.dart';
import '../navigation/taskbar_destination.dart';

part 'app_router.g.dart';

@TypedStatefulShellRoute<AppShellRouteData>(
  branches: <TypedStatefulShellBranch<StatefulShellBranchData>>[
    TypedStatefulShellBranch<HomeBranchData>(
      routes: <TypedRoute<RouteData>>[TypedGoRoute<HomeRoute>(path: '/home')],
    ),
    TypedStatefulShellBranch<SearchBranchData>(
      routes: <TypedRoute<RouteData>>[TypedGoRoute<SearchRoute>(path: '/search')],
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
  ],
)
class AppShellRouteData extends StatefulShellRouteData {
  const AppShellRouteData();

  static final GlobalKey<NavigatorState> $navigatorKey = rootNavigatorKey;

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

class HomeRoute extends GoRouteData with $HomeRoute {
  const HomeRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) => const HomeScreen();
}

class SearchBranchData extends StatefulShellBranchData {
  const SearchBranchData();
}

class SearchRoute extends GoRouteData with $SearchRoute {
  const SearchRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const SearchScreen();
}

class LibraryBranchData extends StatefulShellBranchData {
  const LibraryBranchData();
}

class LibraryRoute extends GoRouteData with $LibraryRoute {
  const LibraryRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const LibraryScreen();
}

class DownloadsBranchData extends StatefulShellBranchData {
  const DownloadsBranchData();
}

class DownloadsRoute extends GoRouteData with $DownloadsRoute {
  const DownloadsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const DownloadsScreen();
}

class SettingsBranchData extends StatefulShellBranchData {
  const SettingsBranchData();
}

class SettingsRoute extends GoRouteData with $SettingsRoute {
  const SettingsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const MoreScreen();
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
    this.forcePortrait = false,
  });
  final String title;
  final List<MultimediaItem> initialMediaList;
  final ViewAllCategory category;
  final void Function(MultimediaItem item)? onTap;
  final Future<ProviderMediaPage> Function(int offset)? loadPage;
  final bool forcePortrait;
}

// --- Full Screen Routes ---

@TypedGoRoute<DetailsRoute>(path: '/details')
class DetailsRoute extends GoRouteData with $DetailsRoute {
  const DetailsRoute({required this.$extra});
  final DetailsRouteExtra $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return DetailsScreen(
      item: $extra.item,
      autoPlay: $extra.autoPlay,
      resumeEpisodeUrl: $extra.resumeEpisodeUrl,
      resumeEpisodeNumber: $extra.resumeEpisodeNumber,
      resumeSeason: $extra.resumeSeason,
    );
  }
}

@TypedGoRoute<ViewAllRoute>(path: '/view-all')
class ViewAllRoute extends GoRouteData with $ViewAllRoute {
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
      forcePortrait: $extra.forcePortrait,
    );
  }
}

@TypedGoRoute<PlayerRoute>(path: '/player')
class PlayerRoute extends GoRouteData with $PlayerRoute {
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
