import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:animewitcher/core/navigation/app_layout_style.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/news/presentation/open_news.dart';
import 'package:animewitcher/features/more/presentation/more_screen.dart';
import 'package:animewitcher/features/onboarding/first_run_setup_screen.dart';
import 'package:animewitcher/shared/widgets/account_avatar_button.dart';
import 'package:animewitcher/shared/widgets/app_navigation_bars.dart';
import 'package:animewitcher/shared/widgets/app_side_menu.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:animewitcher/shared/widgets/custom_bottom_nav.dart';

import '../../core/utils/responsive_breakpoints.dart';
import '../../features/settings/presentation/general_settings_provider.dart';

/// Whether a back press is allowed to pop the shell route itself.
///
/// Backing out of the app is Android's gesture and still belongs there. On a
/// desktop window there is nothing underneath this route, so the pop tears the
/// view down and leaves an empty black window with only the caption buttons —
/// which is what a stray back press looked like.
bool shellBackLeavesApp({
  required bool isAtDefaultHome,
  required bool isDesktopPlatform,
}) => isAtDefaultHome && !isDesktopPlatform;

class AppScaffold extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;
  const AppScaffold({super.key, required this.navigationShell});

  @override
  ConsumerState<AppScaffold> createState() => _AppScaffoldState();
}

class _AppScaffoldState extends ConsumerState<AppScaffold> {
  bool _askedForLayout = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _askForLayoutOnce());
  }

  /// The first launch opens the setup screen: layout, seasons bar and
  /// Anime4K on one page with a live preview.
  Future<void> _askForLayoutOnce() async {
    if (!mounted || _askedForLayout) return;
    _askedForLayout = true;
    if (FirstRunSetup.isDone(ref.read(storageServiceProvider))) return;
    await showFirstRunSetup(context);
  }

  void _onItemTapped(int index, BuildContext context) {
    if (appleUsesPersistentLiquidGlassHeader) {
      applePersistentGlassHeaderController.setActiveBranch(index);
    }
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  /// Whether the tab showing is on its own page rather than one pushed
  /// inside it, where a pull to the right is how one goes back.
  bool _tabAtItsFirstPage() {
    final navigator =
        widget.navigationShell.shellRouteContext.navigatorKey.currentState;
    return navigator == null || !navigator.canPop();
  }

  int _getRouteIndex(String route) {
    return taskbarDestinationForRoute(route)?.branchIndex ??
        TaskbarDestination.home.branchIndex;
  }

  @override
  Widget build(BuildContext context) {
    if (appleUsesPersistentLiquidGlassHeader) {
      final activeBranch = widget.navigationShell.currentIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          applePersistentGlassHeaderController.setActiveBranch(activeBranch);
        }
      });
    }

    final generalSettings = ref.watch(generalSettingsProvider);
    final defaultIndex = _getRouteIndex(generalSettings.defaultHomeScreen);
    final taskbarDestinations = visibleTaskbarDestinations(
      generalSettings.taskbarOrder,
      generalSettings.hiddenTaskbarItems,
    );
    final isAtDefaultHome = widget.navigationShell.currentIndex == defaultIndex;

    final isDesktopPlatform = ResponsiveBreakpoints.isDesktopPlatform();
    // Desktops and tablets offer the rail and the top bar; phones have the
    // dock and the side menu together.
    final layoutsAvailable = appLayoutsAvailable(context);
    final layout = effectiveAppLayout(
      stored: ref.watch(appLayoutStyleProvider),
      isDesktopPlatform: layoutsAvailable,
    );

    final bottomInset = CustomBottomNavBar.bottomInsetFor(context);
    final navBarTotalHeight = CustomBottomNavBar.height + bottomInset;
    final mq = MediaQuery.of(context);

    Widget withShellPopScope(Widget child) => PopScope(
      canPop: shellBackLeavesApp(
        isAtDefaultHome: isAtDefaultHome,
        isDesktopPlatform: isDesktopPlatform,
      ),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || isAtDefaultHome) return;
        widget.navigationShell.goBranch(defaultIndex);
      },
      child: child,
    );

    void onDestination(TaskbarDestination destination) =>
        _onItemTapped(destination.branchIndex, context);
    final currentIndex = widget.navigationShell.currentIndex;

    if (layout == AppLayoutStyle.sideRail) {
      return withShellPopScope(
        Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: Row(
            children: [
              AppSideRail(
                destinations: taskbarDestinations,
                currentBranchIndex: currentIndex,
                onTap: onDestination,
                onNews: () => openNewsScreen(context, ref),
                onAccount: () => openAccountScreen(context),
              ),
              Expanded(child: widget.navigationShell),
            ],
          ),
        ),
      );
    }

    if (layout == AppLayoutStyle.topBar) {
      // Home runs its artwork up under the bar; every other page starts
      // below it. Only the padding changes between them, so the shell keeps
      // its place in the tree and no branch loses its state on a switch.
      final overArtwork = currentIndex == TaskbarDestination.home.branchIndex;
      return withShellPopScope(
        Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(
                    top: overArtwork ? 0 : AppTopBar.totalHeight(context),
                  ),
                  child: widget.navigationShell,
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AppTopBar(
                  destinations: taskbarDestinations,
                  currentBranchIndex: currentIndex,
                  overArtwork: overArtwork,
                  onTap: onDestination,
                  onNews: () => openNewsScreen(context, ref),
                  onAccount: () => openAccountScreen(context),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // A phone's bar leaves More out: its pages are in the side menu.
    final dockDestinations = layoutsAvailable
        ? taskbarDestinations
        : taskbarDestinations
              .where((d) => d != TaskbarDestination.settings)
              .toList(growable: false);
    final dock = Scaffold(
      resizeToAvoidBottomInset: false,
      extendBody: true,
      body: MediaQuery(
        data: mq.copyWith(
          padding: mq.padding.copyWith(
            bottom: mq.padding.bottom + navBarTotalHeight,
          ),
          viewPadding: mq.viewPadding.copyWith(
            bottom: mq.viewPadding.bottom + navBarTotalHeight,
          ),
        ),
        child: widget.navigationShell,
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.only(left: 24, right: 24, bottom: bottomInset),
        child: CustomBottomNavBar(
          currentBranchIndex: currentIndex,
          destinations: dockDestinations,
          onTap: onDestination,
          onNews: layoutsAvailable ? () => openNewsScreen(context, ref) : null,
          // A phone reaches the account through the side menu; a wider
          // dock has room for it beside the news.
          onAccount: layoutsAvailable ? () => openAccountScreen(context) : null,
        ),
      ),
    );
    if (layoutsAvailable) return withShellPopScope(dock);

    // A phone has both: the bar, and the side menu pulled out from the left
    // with the bar's pages and everything the More tab held.
    return AppSideMenuShell(
      destinations: dockDestinations,
      entries: phoneMoreMenuEntries(context),
      currentBranchIndex: currentIndex,
      onDestination: onDestination,
      onAccount: () => openAccountScreen(context),
      canOpen: _tabAtItsFirstPage,
      canPopWhenClosed: shellBackLeavesApp(
        isAtDefaultHome: isAtDefaultHome,
        isDesktopPlatform: isDesktopPlatform,
      ),
      onBackWhenClosed: () {
        if (!isAtDefaultHome) widget.navigationShell.goBranch(defaultIndex);
      },
      child: dock,
    );
  }
}
