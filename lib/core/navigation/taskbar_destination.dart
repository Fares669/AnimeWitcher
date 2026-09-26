import 'package:flutter/material.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';

enum TaskbarDestination {
  home,
  search,
  library,
  downloads,
  settings,

  /// Manga as a tab of its own. Hidden until the viewer turns it on; while
  /// it is on, manga moves off the home page onto it.
  manga;

  String get id => name;

  int get branchIndex => switch (this) {
    TaskbarDestination.home => 0,
    TaskbarDestination.search => 1,
    TaskbarDestination.library => 2,
    TaskbarDestination.downloads => 3,
    TaskbarDestination.settings => 4,
    // After the others, so no existing tab changes its branch.
    TaskbarDestination.manga => 5,
  };

  String get route => switch (this) {
    TaskbarDestination.home => '/home',
    TaskbarDestination.search => '/search',
    TaskbarDestination.library => '/library',
    TaskbarDestination.downloads => '/downloads',
    TaskbarDestination.settings => '/settings',
    TaskbarDestination.manga => '/manga',
  };

  IconData get icon => switch (this) {
    TaskbarDestination.home => Icons.home_outlined,
    TaskbarDestination.search => Icons.search_outlined,
    TaskbarDestination.library => Icons.video_library_outlined,
    TaskbarDestination.downloads => Icons.download_for_offline_outlined,
    TaskbarDestination.settings => Icons.more_horiz_rounded,
    TaskbarDestination.manga => Icons.menu_book_outlined,
  };

  IconData get selectedIcon => switch (this) {
    TaskbarDestination.home => Icons.home,
    TaskbarDestination.search => Icons.search,
    TaskbarDestination.library => Icons.video_library,
    TaskbarDestination.downloads => Icons.download_for_offline_rounded,
    TaskbarDestination.settings => Icons.more_horiz_rounded,
    TaskbarDestination.manga => Icons.menu_book_rounded,
  };

  String label(AppLocalizations l10n) => switch (this) {
    TaskbarDestination.home => l10n.home,
    TaskbarDestination.search => l10n.search,
    TaskbarDestination.library => l10n.library,
    TaskbarDestination.downloads => l10n.downloads,
    TaskbarDestination.settings =>
      l10n.localeName.toLowerCase().startsWith('ar') ? 'المزيد' : 'More',
    TaskbarDestination.manga =>
      l10n.localeName.toLowerCase().startsWith('ar') ? 'المانجا' : 'Manga',
  };
}

const List<String> defaultTaskbarOrderIds = <String>[
  'home',
  'search',
  'manga',
  'library',
  'downloads',
  'settings',
];

TaskbarDestination? taskbarDestinationFromId(String id) {
  for (final destination in TaskbarDestination.values) {
    if (destination.id == id) return destination;
  }
  return null;
}

TaskbarDestination? taskbarDestinationForRoute(String route) {
  for (final destination in TaskbarDestination.values) {
    if (destination.route == route) return destination;
  }
  return null;
}

List<TaskbarDestination> normalizeTaskbarOrder(Iterable<String> storedIds) {
  final result = <TaskbarDestination>[];
  final seen = <TaskbarDestination>{};

  for (final id in storedIds) {
    final destination = taskbarDestinationFromId(id);
    if (destination != null && seen.add(destination)) {
      result.add(destination);
    }
  }

  for (final destination in TaskbarDestination.values) {
    if (seen.add(destination)) result.add(destination);
  }

  return List<TaskbarDestination>.unmodifiable(result);
}

Set<String> normalizeHiddenTaskbarItems(Iterable<String> storedIds) {
  final valid = TaskbarDestination.values.map((value) => value.id).toSet();
  return Set<String>.unmodifiable(
    storedIds.where(
      (id) => id != TaskbarDestination.settings.id && valid.contains(id),
    ),
  );
}

List<TaskbarDestination> visibleTaskbarDestinations(
  Iterable<String> orderIds,
  Iterable<String> hiddenIds,
) {
  final hidden = normalizeHiddenTaskbarItems(hiddenIds);
  return normalizeTaskbarOrder(orderIds)
      .where(
        (destination) =>
            destination == TaskbarDestination.settings ||
            !hidden.contains(destination.id),
      )
      .toList(growable: false);
}

String resolveInitialTaskbarRoute(
  String preferredRoute,
  Iterable<String> orderIds,
  Iterable<String> hiddenIds,
) {
  final preferred = taskbarDestinationForRoute(preferredRoute);
  final hidden = normalizeHiddenTaskbarItems(hiddenIds);
  if (preferred != null &&
      (preferred == TaskbarDestination.settings ||
          !hidden.contains(preferred.id))) {
    return preferred.route;
  }

  return visibleTaskbarDestinations(orderIds, hiddenIds).first.route;
}
