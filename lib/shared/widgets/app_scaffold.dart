import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:animewitcher/core/navigation/app_layout_style.dart';
import 'package:animewitcher/core/navigation/home_tab_reselection.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/news/presentation/open_news.dart';
import 'package:animewitcher/features/onboarding/first_run_setup_screen.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/shared/widgets/account_avatar_button.dart';
import 'package:animewitcher/shared/widgets/app_navigation_bars.dart';
import 'package:animewitcher/shared/widgets/app_side_menu.dart';
import 'package:animewitcher/shared/widgets/phone_fixed_side_menu.dart';
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

// Keep navigation independent of unrelated settings such as download limits.
final _shellNavigationProvider = Provider((ref) {
  final (:defaultHomeScreen, :taskbarOrder, :hiddenTaskbarItems) = ref.watch(
    generalSettingsProvider.select(
      (settings) => (
        defaultHomeScreen: settings.defaultHomeScreen,
        taskbarOrder: settings.taskbarOrder,
        hiddenTaskbarItems: settings.hiddenTaskbarItems,
      ),
    ),
  );
  return (
    defaultIndex:
        taskbarDestinationForRoute(defaultHomeScreen)?.branchIndex ??
        TaskbarDestination.home.branchIndex,
    destinations: visibleTaskbarDestinations(taskbarOrder, hiddenTaskbarItems),
  );
});

class AppScaffold extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;
  const AppScaffold({super.key, required this.navigationShell});

  /// Keeps each branch's viewport independent of which tab is selected.
  static Widget buildBranchContainer(
    BuildContext context,
    StatefulNavigationShell shell,
    List<Widget> children,
  ) =>
      _AppBranchViewports(currentIndex: shell.currentIndex, children: children);

  @override
  ConsumerState<AppScaffold> createState() => _AppScaffoldState();
}

class _TopBarBranchInset extends InheritedWidget {
  const _TopBarBranchInset({required this.top, required super.child});

  final double top;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TopBarBranchInset>()?.top ??
      0;

  @override
  bool updateShouldNotify(_TopBarBranchInset oldWidget) => oldWidget.top != top;
}

class _AppBranchViewports extends StatelessWidget {
  const _AppBranchViewports({
    required this.currentIndex,
    required this.children,
  });

  final int currentIndex;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final top = _TopBarBranchInset.of(context);
    final home = TaskbarDestination.home.branchIndex;
    // Preserve go_router's default layout and ticker/visibility semantics.
    // Give each retained navigator a stable height: Offstage still lays out
    // its child when constraints change, even though the child doesn't paint.
    return IndexedStack(
      index: currentIndex,
      children: [
        for (var index = 0; index < children.length; index++)
          Offstage(
            offstage: index != currentIndex,
            child: TickerMode(
              enabled: index == currentIndex,
              child: Padding(
                padding: EdgeInsets.only(top: index == home ? 0 : top),
                child: children[index],
              ),
            ),
          ),
      ],
    );
  }
}

class _AppScaffoldState extends ConsumerState<AppScaffold> {
  bool _askedForLayout = false;
  int? _previousBranchIndex;

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

  void _onItemTapped(int index) {
    if (appleUsesPersistentLiquidGlassHeader) {
      applePersistentGlassHeaderController.setActiveBranch(index);
    }
    if (index == TaskbarDestination.home.branchIndex &&
        index == widget.navigationShell.currentIndex) {
      ref.read(homeTabReselectionProvider.notifier).reselect();
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

    final (:defaultIndex, destinations: taskbarDestinations) = ref.watch(
      _shellNavigationProvider,
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

    void onDestination(TaskbarDestination destination) =>
        _onItemTapped(destination.branchIndex);
    final currentIndex = widget.navigationShell.currentIndex;
    if (_previousBranchIndex != currentIndex) {
      _previousBranchIndex = currentIndex;
      if (currentIndex == TaskbarDestination.library.branchIndex) {
        // StatefulShellRoute retains pages across tab switches. initState()
        // on LibraryScreen runs only once, so refresh on every actual entry.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              widget.navigationShell.currentIndex ==
                  TaskbarDestination.library.branchIndex) {
            unawaited(
              ref.read(libraryProvider.notifier).refreshVisibleFromServer(),
            );
          }
        });
      }
    }

    // Every layout shares the same fixed browse menu, independent of the
    // customizable taskbar order and visibility.
    Widget withSideMenu(Widget child) => AppSideMenuShell(
      showPageMenuButtons: layout != AppLayoutStyle.topBar,
      destinations: const <TaskbarDestination>[],
      entriesBuilder: (context, ref, menuVisible) => phoneFixedSideMenuEntries(
        context,
        ref,
        currentBranchIndex: currentIndex,
        onDestination: onDestination,
        menuVisible: menuVisible,
      ),
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
      child: child,
    );

    if (layout == AppLayoutStyle.sideRail) {
      final mq = MediaQuery.of(context);
      return withSideMenu(
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
              // The pages are told the width they really have. Told the
              // window's, a tablet held upright laid them out for the rail's
              // 76 points too, and their headers ran into one another.
              Expanded(
                child: MediaQuery(
                  data: mq.copyWith(
                    size: Size(
                      (mq.size.width - AppSideRail.width).clamp(
                        0.0,
                        double.infinity,
                      ),
                      mq.size.height,
                    ),
                  ),
                  child: widget.navigationShell,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (layout == AppLayoutStyle.topBar) {
      // Home runs its artwork under the bar; every other branch starts below
      // it. Reserve that inset within each navigator's viewport, not around
      // the whole shell, so switching tabs does not resize the warm branches.
      final overArtwork = currentIndex == TaskbarDestination.home.branchIndex;
      return withSideMenu(
        Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: Stack(
            children: [
              Positioned.fill(
                child: _TopBarBranchInset(
                  top: AppTopBar.totalHeight(context),
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

    // The dock rewrites the full page MediaQuery. The top bar only uses
    // window size and its top safe area, so leave keyboard/view-inset updates
    // to its Scaffold and pages instead of rebuilding the navigation shell.
    final bottomInset = CustomBottomNavBar.bottomInsetFor(context);
    final navBarTotalHeight = CustomBottomNavBar.height + bottomInset;
    final mq = MediaQuery.of(context);
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
          destinations: taskbarDestinations,
          showMenu: layoutsAvailable,
          onTap: onDestination,
          onNews: layoutsAvailable ? () => openNewsScreen(context, ref) : null,
        ),
      ),
    );
    return withSideMenu(dock);
  }
}
