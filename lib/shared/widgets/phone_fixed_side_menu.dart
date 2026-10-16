import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/navigation/taskbar_destination.dart';
import '../../features/characters/presentation/characters_screen.dart';
import '../../features/more/presentation/broadcast_schedule_screen.dart';
import '../../features/more/presentation/coming_soon_screen.dart';
import '../../features/more/presentation/global_statistics_screen.dart';
import '../../features/more/presentation/recent_watched_screen.dart';
import '../../features/more/presentation/seasons_screen.dart';
import '../../features/news/presentation/open_news.dart';
import '../../features/search/presentation/search_domain.dart';
import '../../features/settings/presentation/settings_screen.dart';
import 'app_side_menu.dart';

/// The phone side menu has a product-defined order. It deliberately does not
/// read the customizable bottom-bar order or hidden items.
List<AppSideMenuEntry> phoneFixedSideMenuEntries(
  BuildContext context,
  WidgetRef ref, {
  required int currentBranchIndex,
  required ValueChanged<TaskbarDestination> onDestination,
}) {
  final currentDomain = ref.watch(searchDomainProvider);

  void open(Widget page) {
    Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  void openSearch(SearchDomain domain) {
    ref.read(searchDomainProvider.notifier).set(domain);
    onDestination(TaskbarDestination.search);
  }

  bool selectedBranch(TaskbarDestination destination) =>
      currentBranchIndex == destination.branchIndex;

  bool selectedSearch(SearchDomain domain) =>
      selectedBranch(TaskbarDestination.search) && currentDomain == domain;

  return <AppSideMenuEntry>[
    AppSideMenuEntry(
      id: 'home',
      icon: selectedBranch(TaskbarDestination.home)
          ? Icons.home_rounded
          : Icons.home_outlined,
      label: 'الرئيسية',
      selected: selectedBranch(TaskbarDestination.home),
      onTap: () => onDestination(TaskbarDestination.home),
    ),
    AppSideMenuEntry(
      id: 'anime-search',
      icon: Icons.movie_rounded,
      label: 'الأنمي',
      selected: selectedSearch(SearchDomain.anime),
      onTap: () => openSearch(SearchDomain.anime),
    ),
    AppSideMenuEntry(
      id: 'manga-search',
      icon: Icons.menu_book_rounded,
      label: 'المانجا',
      selected: selectedSearch(SearchDomain.manga),
      onTap: () => openSearch(SearchDomain.manga),
    ),
    AppSideMenuEntry(
      id: 'animation-search',
      icon: Icons.animation_rounded,
      label: 'الانميشن',
      selected: selectedSearch(SearchDomain.animation),
      onTap: () => openSearch(SearchDomain.animation),
    ),
    AppSideMenuEntry(
      id: 'seasons',
      icon: Icons.calendar_month_rounded,
      label: 'المواسم',
      onTap: () => open(const SeasonsScreen()),
    ),
    AppSideMenuEntry(
      id: 'global-statistics',
      icon: Icons.query_stats_rounded,
      label: 'الإحصائيات العالمية',
      dividerBefore: true,
      onTap: () => open(const GlobalStatisticsScreen()),
    ),
    AppSideMenuEntry(
      id: 'coming-soon',
      icon: Icons.upcoming_rounded,
      label: 'القادم قريبًا',
      onTap: () => open(const ComingSoonScreen()),
    ),
    AppSideMenuEntry(
      id: 'library',
      icon: selectedBranch(TaskbarDestination.library)
          ? Icons.video_library_rounded
          : Icons.video_library_outlined,
      label: 'المكتبة',
      selected: selectedBranch(TaskbarDestination.library),
      dividerBefore: true,
      onTap: () => onDestination(TaskbarDestination.library),
    ),
    AppSideMenuEntry(
      id: 'favorite-characters',
      icon: Icons.face_rounded,
      label: 'الشخصيات المفضلة',
      onTap: () => open(const CharactersScreen(favoritesOnly: true)),
    ),
    AppSideMenuEntry(
      id: 'recent-watched',
      icon: Icons.history_rounded,
      label: 'آخر المشاهدات',
      onTap: () => open(const RecentWatchedScreen()),
    ),
    AppSideMenuEntry(
      id: 'characters-search',
      icon: Icons.groups_rounded,
      label: 'الشخصيات',
      selected: selectedSearch(SearchDomain.characters),
      dividerBefore: true,
      onTap: () => openSearch(SearchDomain.characters),
    ),
    AppSideMenuEntry(
      id: 'broadcast-schedule',
      icon: Icons.calendar_view_week_rounded,
      label: 'جدول الحلقات',
      onTap: () => open(const BroadcastScheduleScreen()),
    ),
    AppSideMenuEntry(
      id: 'news',
      icon: Icons.newspaper_rounded,
      label: 'الأخبار',
      onTap: () => openNewsScreen(context, ref),
    ),
    AppSideMenuEntry(
      id: 'settings',
      icon: Icons.settings_rounded,
      label: 'الإعدادات',
      dividerBefore: true,
      onTap: () => open(const SettingsScreen()),
    ),
  ];
}
