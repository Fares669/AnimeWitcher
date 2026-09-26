/// What the library's lists are called, what they hold and how the phone's
/// shelves are set up, shared by the PC side list and the phone shelves.
library;

import 'package:flutter/material.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/storage/library_category.dart';
import '../../../core/storage/library_repository.dart';
import '../../../core/storage/storage_service.dart';
import 'history_provider.dart';
import 'library_media_kind.dart';

bool _arabic(BuildContext context) =>
    Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

/// The name of [category] as the [kind] half of the library says it.
String libraryCategoryLabel(
  BuildContext context,
  LibraryCategory category,
  LibraryMediaKind kind,
) {
  final ar = _arabic(context);
  if (kind == LibraryMediaKind.manga) {
    return switch (category) {
      LibraryCategory.favorite => ar ? 'المفضلة' : 'Favorites',
      LibraryCategory.watching => ar ? 'أقرأها حاليًا' : 'Reading',
      LibraryCategory.continueLater => ar ? 'أكملها لاحقًا' : 'Continue Later',
      LibraryCategory.planToWatch => ar ? 'أرغب بقراءتها' : 'Plan to Read',
      LibraryCategory.completed => ar ? 'تمت قراءتها' : 'Completed',
      LibraryCategory.notInterested =>
        ar ? 'لا أرغب بقراءتها' : 'Not Interested',
    };
  }
  return switch (category) {
    LibraryCategory.favorite => ar ? 'المفضلة' : 'Favorites',
    LibraryCategory.watching => ar ? 'أشاهده حاليًا' : 'Watching',
    LibraryCategory.continueLater => ar ? 'أكملها لاحقًا' : 'Continue Later',
    LibraryCategory.planToWatch => ar ? 'أرغب بمشاهدته' : 'Plan to Watch',
    LibraryCategory.completed => ar ? 'تمت مشاهدته' : 'Completed',
    LibraryCategory.notInterested => ar ? 'لا أرغب بمشاهدته' : 'Not Interested',
  };
}

IconData libraryCategoryIcon(LibraryCategory category) => switch (category) {
  LibraryCategory.favorite => Icons.favorite_rounded,
  LibraryCategory.watching => Icons.play_circle_fill_rounded,
  LibraryCategory.continueLater => Icons.pause_circle_filled_rounded,
  LibraryCategory.planToWatch => Icons.schedule_rounded,
  LibraryCategory.completed => Icons.check_circle_rounded,
  LibraryCategory.notInterested => Icons.block_rounded,
};

/// "آخر المشاهدات", the history that moved here from the More page.
String libraryRecentLabel(BuildContext context) =>
    _arabic(context) ? 'آخر المشاهدات' : 'Recently watched';

const IconData libraryRecentIcon = Icons.history_rounded;

/// "الشخصيات المفضلة", the favourite characters that moved here from the
/// More page.
String libraryCharactersLabel(BuildContext context) =>
    _arabic(context) ? 'الشخصيات المفضلة' : 'Favorite characters';

String libraryKindLabel(BuildContext context, LibraryMediaKind kind) =>
    switch (kind) {
      LibraryMediaKind.anime => _arabic(context) ? 'أنمي' : 'Anime',
      LibraryMediaKind.manga => _arabic(context) ? 'مانجا' : 'Manga',
    };

/// Only anime has a watch history; the reader keeps its place per chapter,
/// not per title.
bool libraryKindHasRecent(LibraryMediaKind kind) =>
    kind == LibraryMediaKind.anime;

/// The titles in [category] for [kind], as the repository keeps them.
List<MultimediaItem> libraryItemsFor(
  LibraryRepository repository,
  LibraryCategory category,
  LibraryMediaKind kind,
) => filterLibraryItemsByKind(
  repository.getLibraryItems(category: category),
  kind,
);

/// The watch history, latest first, for [kind].
List<HistoryItem> libraryRecentFor(
  List<HistoryItem> history,
  LibraryMediaKind kind,
) {
  if (!libraryKindHasRecent(kind)) return const <HistoryItem>[];
  return history.where((entry) => kind.accepts(entry.item)).toList()
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
}

/// How a shelf orders its titles.
enum LibrarySort { added, name, year }

/// Shelves, one row per list, or every list in one grid.
enum LibraryView { shelves, grid }

/// [items] in [sort] order. [items] come from the library newest-added
/// first already, so that order costs nothing; looking each title's date
/// up again scanned the whole library per comparison, and a few hundred
/// titles made every redraw of the library stall.
List<MultimediaItem> sortLibraryItems(
  List<MultimediaItem> items,
  LibrarySort sort,
) {
  final sorted = List<MultimediaItem>.of(items);
  switch (sort) {
    case LibrarySort.added:
      break;
    case LibrarySort.name:
      sorted.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    case LibrarySort.year:
      sorted.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
  }
  return sorted;
}

/// [history] in [sort] order; "latest added" is latest watched.
List<HistoryItem> sortLibraryHistory(
  List<HistoryItem> history,
  LibrarySort sort,
) {
  final sorted = List<HistoryItem>.of(history);
  switch (sort) {
    case LibrarySort.added:
      sorted.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    case LibrarySort.name:
      sorted.sort(
        (a, b) =>
            a.item.title.toLowerCase().compareTo(b.item.title.toLowerCase()),
      );
    case LibrarySort.year:
      sorted.sort((a, b) => (b.item.year ?? 0).compareTo(a.item.year ?? 0));
  }
  return sorted;
}

/// Whether [item] answers [query]: every word of it, anywhere in the title.
bool libraryItemMatches(MultimediaItem item, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((word) => word.isEmpty);
  if (words.isEmpty) return true;
  final title = item.title.toLowerCase();
  return words.every(title.contains);
}

/// The phone shelves' settings from the filter sheet, kept between visits.
class LibraryShelfPrefs extends ChangeNotifier {
  LibraryShelfPrefs(this._storage) {
    final hidden = _storage.getString(_hiddenKey);
    _hidden = hidden == null
        ? <String>{LibraryCategory.notInterested.storageKey}
        : hidden.split(',').where((key) => key.isNotEmpty).toSet();
    _sort = LibrarySort.values.firstWhere(
      (value) => value.name == _storage.getString(_sortKey),
      orElse: () => LibrarySort.added,
    );
    _view = LibraryView.values.firstWhere(
      (value) => value.name == _storage.getString(_viewKey),
      orElse: () => LibraryView.shelves,
    );
    _hideEmpty = _storage.getString(_hideEmptyKey) == 'true';
  }

  static const String recentKey = 'recent';
  static const String _hiddenKey = 'library_shelves_hidden';
  static const String _sortKey = 'library_shelves_sort';
  static const String _viewKey = 'library_shelves_view';
  static const String _hideEmptyKey = 'library_shelves_hide_empty';

  final StorageService _storage;
  late Set<String> _hidden;
  late LibrarySort _sort;
  late LibraryView _view;
  late bool _hideEmpty;

  LibrarySort get sort => _sort;
  LibraryView get view => _view;
  bool get hideEmpty => _hideEmpty;

  bool showsRecent() => !_hidden.contains(recentKey);
  bool shows(LibraryCategory category) =>
      !_hidden.contains(category.storageKey);

  void setShown(String key, bool shown) {
    shown ? _hidden.remove(key) : _hidden.add(key);
    _storage.setString(_hiddenKey, _hidden.join(','));
    notifyListeners();
  }

  set sort(LibrarySort value) {
    _sort = value;
    _storage.setString(_sortKey, value.name);
    notifyListeners();
  }

  set view(LibraryView value) {
    _view = value;
    _storage.setString(_viewKey, value.name);
    notifyListeners();
  }

  set hideEmpty(bool value) {
    _hideEmpty = value;
    _storage.setString(_hideEmptyKey, '$value');
    notifyListeners();
  }
}
