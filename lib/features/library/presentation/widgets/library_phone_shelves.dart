import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/account/account_providers.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/storage/library_category.dart';
import '../../../../core/storage/library_repository.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../shared/widgets/multimedia_card.dart';
import '../../../../shared/widgets/app_side_menu.dart';
import '../../../../shared/widgets/app_back_button.dart';
import '../../../home/presentation/widgets/home_section_header.dart';
import '../../../../shared/widgets/underline_segment_tabs.dart';
import '../../../characters/presentation/characters_screen.dart';
import '../../../more/presentation/recent_watched_screen.dart';
import '../history_provider.dart';
import '../library_lists.dart';
import '../library_media_kind.dart';
import '../library_provider.dart';
import 'bookmarks_tab.dart';

bool _arabic(BuildContext context) =>
    Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

String _t(BuildContext context, String en, String ar) =>
    _arabic(context) ? ar : en;

/// The phone library: a search box and a filter button on top, anime and
/// manga as two tabs, and each list a row of posters you scroll sideways —
/// the watch history first. The filter sheet picks which lists get a row,
/// their order, rows or one grid, and whether empty lists show at all.
/// Searching folds the rows into one grid of what matches, each poster
/// tagged with its list.
class LibraryPhoneShelves extends ConsumerStatefulWidget {
  const LibraryPhoneShelves({super.key});

  @override
  ConsumerState<LibraryPhoneShelves> createState() =>
      _LibraryPhoneShelvesState();
}

class _LibraryPhoneShelvesState extends ConsumerState<LibraryPhoneShelves>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final LibraryShelfPrefs _prefs;
  final TextEditingController _search = TextEditingController();
  String _query = '';

  /// Waits for a pause in the typing before searching, so every letter does
  /// not redraw the grid with a crowd of titles holding it.
  Timer? _typing;
  static const Duration _typingPause = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _prefs = LibraryShelfPrefs(ref.read(storageServiceProvider));
    _tabs = TabController(
      length: LibraryMediaKind.values.length,
      vsync: this,
      initialIndex: ref.read(libraryProvider).mediaKind.index,
    )..addListener(_onTab);
    Future<void>.microtask(_syncHistory);
  }

  Future<void> _syncHistory() async {
    try {
      await ref.read(watchHistoryProvider.notifier).refreshFromServer();
    } catch (_) {
      // The last local history stays on screen when the account is out of
      // reach.
    }
  }

  void _onTab() {
    if (_tabs.indexIsChanging) return;
    final kind = LibraryMediaKind.values[_tabs.index];
    if (kind != ref.read(libraryProvider).mediaKind) {
      unawaited(ref.read(libraryProvider.notifier).selectMediaKind(kind));
    }
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTab)
      ..dispose();
    _typing?.cancel();
    _search.dispose();
    _prefs.dispose();
    super.dispose();
  }

  /// Each list, sorted, kept until the library or the sort changes. The
  /// rows, the tab counts and the search all read the same lists, and each
  /// read went back to storage and sorted again on every redraw.
  final Map<(LibraryMediaKind, LibraryCategory), List<MultimediaItem>> _lists =
      <(LibraryMediaKind, LibraryCategory), List<MultimediaItem>>{};
  Object? _listsFor;

  List<MultimediaItem> _list(
    LibraryRepository repository,
    LibraryMediaKind kind,
    LibraryCategory category,
  ) => _lists.putIfAbsent(
    (kind, category),
    () => sortLibraryItems(
      libraryItemsFor(repository, category, kind),
      _prefs.sort,
    ),
  );

  /// Every title the lists shown hold for [kind], each with its list's name,
  /// the history last; a title in two lists shows once, under the first.
  List<(MultimediaItem, String)> _entries(
    LibraryMediaKind kind,
    LibraryRepository repository,
    List<HistoryItem> history,
  ) {
    final seen = <String>{};
    final entries = <(MultimediaItem, String)>[];
    for (final category in LibraryCategory.values) {
      if (!_prefs.shows(category)) continue;
      final label = libraryCategoryLabel(context, category, kind);
      for (final item in _list(repository, kind, category)) {
        if (seen.add(item.url)) entries.add((item, label));
      }
    }
    if (_prefs.showsRecent()) {
      final label = libraryRecentLabel(context);
      for (final entry in sortLibraryHistory(
        libraryRecentFor(history, kind),
        _prefs.sort,
      )) {
        if (seen.add(entry.item.url)) entries.add((entry.item, label));
      }
    }
    return entries;
  }

  List<(MultimediaItem, String)> _matches(
    List<(MultimediaItem, String)> entries,
  ) => [
    for (final entry in entries)
      if (libraryItemMatches(entry.$1, _query)) entry,
  ];

  @override
  Widget build(BuildContext context) {
    // The library notifier hands out a new state on every change to a list,
    // which is what brings the rows up to date.
    final library = ref.watch(libraryProvider);
    final history = ref.watch(watchHistoryProvider);
    final repository = ref.read(libraryRepositoryProvider);
    final colors = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: _prefs,
      builder: (context, _) {
        // The kept lists last until the library or the sort changes.
        final listsFor = (library, _prefs.sort);
        if (listsFor != _listsFor) {
          _lists.clear();
          _listsFor = listsFor;
        }
        final entriesByKind = {
          for (final kind in LibraryMediaKind.values)
            kind: _entries(kind, repository, history),
        };
        final searching = _query.trim().isNotEmpty;
        // Matched once, for both the tab's count and its grid.
        final matchesByKind = {
          if (searching)
            for (final kind in LibraryMediaKind.values)
              kind: _matches(entriesByKind[kind]!),
        };
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 12,
            title: SizedBox(
              height: 42,
              child: TextField(
                key: const ValueKey<String>('library-search'),
                controller: _search,
                onChanged: (value) {
                  _typing?.cancel();
                  _typing = Timer(_typingPause, () {
                    if (mounted) setState(() => _query = value);
                  });
                },
                onSubmitted: (value) {
                  _typing?.cancel();
                  setState(() => _query = value);
                },
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: _t(
                    context,
                    'Search your library',
                    'ابحث في مكتبتك',
                  ),
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: searching
                      ? IconButton(
                          tooltip: _t(context, 'Clear', 'مسح'),
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _search.clear();
                            _typing?.cancel();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: colors.surfaceContainerHighest.withValues(
                    alpha: 0.6,
                  ),
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(99),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            actions: [
              IconButton(
                key: const ValueKey<String>('library-filter'),
                tooltip: _t(context, 'Filter', 'تصفية'),
                icon: Icon(Icons.tune_rounded, color: colors.primary),
                onPressed: () => _openFilterSheet(context),
              ),
              // The side menu's button, in the corner the menu comes from.
              const AppSideMenuButton(
                padding: EdgeInsetsDirectional.only(start: 2, end: 4),
              ),
              const SizedBox(width: 4),
            ],
            bottom: FilterStyleTabBar(
              controller: _tabs,
              isScrollable: false,
              padding: EdgeInsets.zero,
              tabs: [
                for (final kind in LibraryMediaKind.values)
                  FilterStyleTab(
                    label: searching
                        ? '${libraryKindLabel(context, kind)} '
                              '${matchesByKind[kind]!.length}'
                        : libraryKindLabel(context, kind),
                  ),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabs,
            children: [
              for (final kind in LibraryMediaKind.values)
                _kindBody(
                  kind,
                  entriesByKind[kind]!,
                  repository,
                  history,
                  matches: matchesByKind[kind],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _kindBody(
    LibraryMediaKind kind,
    List<(MultimediaItem, String)> entries,
    LibraryRepository repository,
    List<HistoryItem> history, {
    List<(MultimediaItem, String)>? matches,
  }) {
    if (_query.trim().isNotEmpty || _prefs.view == LibraryView.grid) {
      final shown = _query.trim().isEmpty
          ? entries
          : (matches ?? _matches(entries));
      if (shown.isEmpty) {
        return _query.trim().isEmpty
            ? LibraryEmptyState(mediaKind: kind)
            : Center(
                child: Text(
                  _t(context, 'Nothing matches', 'لا توجد نتائج'),
                  key: const ValueKey<String>('library-search-empty'),
                ),
              );
      }
      return LibraryItemsGrid(
        key: ValueKey<String>('library-grid-${kind.storageKey}'),
        items: [for (final entry in shown) entry.$1],
        labels: [for (final entry in shown) entry.$2],
        heroPrefix: 'lib_grid_${kind.storageKey}',
      );
    }

    final recent = _prefs.showsRecent()
        ? sortLibraryHistory(libraryRecentFor(history, kind), _prefs.sort)
        : const <HistoryItem>[];
    final signedIn =
        kind == LibraryMediaKind.manga ||
        (ref
                .watch(animeWitcherAccountControllerProvider)
                .asData
                ?.value
                .isSignedIn ??
            false);
    final rows = <Widget>[
      if (libraryKindHasRecent(kind) &&
          _prefs.showsRecent() &&
          (recent.isNotEmpty || !_prefs.hideEmpty))
        _Shelf(
          key: const ValueKey<String>('library-shelf-recent'),
          title: libraryRecentLabel(context),
          count: recent.length,
          items: [for (final entry in recent) entry.item],
          progress: [
            for (final entry in recent)
              entry.duration <= 0
                  ? 0.0
                  : (entry.position / entry.duration).clamp(0.0, 1.0),
          ],
          heroPrefix: 'lib_recent',
          onSeeAll: () => Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute<void>(
              builder: (_) => const RecentWatchedScreen(),
            ),
          ),
        ),
      if (!signedIn)
        SizedBox(height: 320, child: LibraryEmptyState(mediaKind: kind))
      else
        for (final category in LibraryCategory.values)
          if (_prefs.shows(category))
            ..._categoryShelf(kind, category, repository),
    ];
    // The favourite characters moved here from the More page: a row that
    // opens them, under the anime lists.
    if (kind == LibraryMediaKind.anime) {
      rows.add(
        ListTile(
          key: const ValueKey<String>('library-characters'),
          contentPadding: EdgeInsets.symmetric(
            horizontal:
                MultimediaCardLayout.catalogGridHorizontalPadding(context) + 4,
          ),
          leading: Icon(
            Icons.face_rounded,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(
            libraryCharactersLabel(context),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute<void>(
              builder: (_) => const CharactersScreen(favoritesOnly: true),
            ),
          ),
        ),
      );
    }
    if (rows.isEmpty) return LibraryEmptyState(mediaKind: kind);
    return ListView(
      key: ValueKey<String>('library-shelves-${kind.storageKey}'),
      padding: const EdgeInsets.only(top: 8, bottom: 110),
      children: rows,
    );
  }

  List<Widget> _categoryShelf(
    LibraryMediaKind kind,
    LibraryCategory category,
    LibraryRepository repository,
  ) {
    final items = _list(repository, kind, category);
    if (items.isEmpty && _prefs.hideEmpty) return const <Widget>[];
    final title = libraryCategoryLabel(context, category, kind);
    return <Widget>[
      _Shelf(
        key: ValueKey<String>(
          'library-shelf-${kind.storageKey}-${category.storageKey}',
        ),
        title: title,
        count: items.length,
        items: items,
        heroPrefix: 'lib_${category.storageKey}',
        onSeeAll: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => LibraryListPage(
              title: title,
              kind: kind,
              category: category,
              sort: _prefs.sort,
            ),
          ),
        ),
      ),
    ];
  }

  void _openFilterSheet(BuildContext context) {
    final kind = LibraryMediaKind.values[_tabs.index];
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: LibraryFilterPanel(prefs: _prefs, kind: kind),
      ),
    );
  }
}

/// The library's filter: which lists show, their order, rows or one grid,
/// and whether empty lists show. The phone opens it as a sheet, PC and
/// tablet as a dialog from the side list, where [showView] is off since the
/// side list is the view.
class LibraryFilterPanel extends StatelessWidget {
  const LibraryFilterPanel({
    super.key,
    required this.prefs,
    required this.kind,
    this.showView = true,
  });

  final LibraryShelfPrefs prefs;
  final LibraryMediaKind kind;
  final bool showView;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        final theme = Theme.of(context);
        Widget heading(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Text(
            text,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        );
        Widget wrap(List<Widget> chips) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 8, children: chips),
        );
        Widget choice<T>(
          T value,
          T current,
          String label,
          ValueChanged<T> on,
        ) => ChoiceChip(
          label: Text(label),
          selected: value == current,
          showCheckmark: false,
          onSelected: (_) => on(value),
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            key: const ValueKey<String>('library-filter-sheet'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              heading(_t(context, 'Lists shown', 'القوائم الظاهرة')),
              wrap([
                if (libraryKindHasRecent(kind))
                  FilterChip(
                    key: const ValueKey<String>('library-filter-recent'),
                    label: Text(libraryRecentLabel(context)),
                    selected: prefs.showsRecent(),
                    showCheckmark: false,
                    onSelected: (on) =>
                        prefs.setShown(LibraryShelfPrefs.recentKey, on),
                  ),
                for (final category in LibraryCategory.values)
                  FilterChip(
                    key: ValueKey<String>(
                      'library-filter-${category.storageKey}',
                    ),
                    label: Text(libraryCategoryLabel(context, category, kind)),
                    selected: prefs.shows(category),
                    showCheckmark: false,
                    onSelected: (on) => prefs.setShown(category.storageKey, on),
                  ),
              ]),
              heading(_t(context, 'Sort', 'الترتيب')),
              wrap([
                for (final (value, label) in <(LibrarySort, String)>[
                  (LibrarySort.added, _t(context, 'Latest added', 'آخر إضافة')),
                  (LibrarySort.name, _t(context, 'Name', 'الاسم')),
                  (LibrarySort.year, _t(context, 'Year', 'السنة')),
                ])
                  choice<LibrarySort>(
                    value,
                    prefs.sort,
                    label,
                    (v) => prefs.sort = v,
                  ),
              ]),
              if (showView) ...[
                heading(_t(context, 'View', 'العرض')),
                wrap([
                  choice<LibraryView>(
                    LibraryView.shelves,
                    prefs.view,
                    _t(context, 'Rows', 'رفوف'),
                    (v) => prefs.view = v,
                  ),
                  choice<LibraryView>(
                    LibraryView.grid,
                    prefs.view,
                    _t(context, 'Grid', 'شبكة'),
                    (v) => prefs.view = v,
                  ),
                ]),
              ],
              const SizedBox(height: 6),
              SwitchListTile(
                key: const ValueKey<String>('library-filter-hide-empty'),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                title: Text(
                  _t(context, 'Hide empty lists', 'إخفاء القوائم الفارغة'),
                ),
                value: prefs.hideEmpty,
                onChanged: (on) => prefs.hideEmpty = on,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One list as a row: its name and count over posters you scroll sideways,
/// or, empty, the name alone on one line.
class _Shelf extends StatelessWidget {
  const _Shelf({
    super.key,
    required this.title,
    required this.count,
    required this.items,
    required this.heroPrefix,
    required this.onSeeAll,
    this.progress,
  });

  final String title;
  final int count;
  final List<MultimediaItem> items;
  final String heroPrefix;
  final VoidCallback onSeeAll;

  /// How far into each title the history is, for a bar under its poster.
  final List<double>? progress;

  static const double _cardWidth = 112;

  /// Titles a row shows; "عرض الكل" has the rest.
  static const int limit = 10;
  static const double _spacing = 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final side = MultimediaCardLayout.catalogGridHorizontalPadding(context);
    final header = Padding(
      padding: EdgeInsetsDirectional.fromSTEB(side + 4, 10, side, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$title · $count',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: items.isEmpty ? colors.onSurfaceVariant : null,
              ),
            ),
          ),
          // The same pill as home's rows.
          if (items.isNotEmpty) HomeViewAllButton(onTap: onSeeAll),
        ],
      ),
    );
    if (items.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Divider(height: 1, indent: side, endIndent: side),
        ],
      );
    }
    const posterHeight = _cardWidth * 1.5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        SizedBox(
          height: MultimediaCardLayout.listHeight(_cardWidth, isPortrait: true),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: side),
            itemCount: items.length.clamp(0, limit),
            separatorBuilder: (_, _) => const SizedBox(width: _spacing),
            itemBuilder: (context, index) {
              final item = items[index];
              final card = MultimediaCard.fromItem(
                key: ValueKey<String>('$heroPrefix-${item.url}'),
                item: item,
                heroTag: '${heroPrefix}_${item.url}_$index',
                onTap: () => openLibraryItem(context, item),
              );
              final fraction = progress?[index] ?? 0;
              return SizedBox(
                width: _cardWidth,
                child: fraction <= 0
                    ? card
                    : Stack(
                        children: [
                          Positioned.fill(child: card),
                          Positioned(
                            left: 6,
                            right: 6,
                            top: posterHeight - 9,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: fraction,
                                minHeight: 3,
                                color: colors.primary,
                                backgroundColor: Colors.black.withValues(
                                  alpha: 0.45,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One list in full, from a row's "عرض الكل".
class LibraryListPage extends ConsumerWidget {
  const LibraryListPage({
    super.key,
    required this.title,
    required this.kind,
    required this.category,
    required this.sort,
  });

  final String title;
  final LibraryMediaKind kind;
  final LibraryCategory category;
  final LibrarySort sort;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(libraryProvider);
    final repository = ref.read(libraryRepositoryProvider);
    final items = sortLibraryItems(
      libraryItemsFor(repository, category, kind),
      sort,
    );
    final titleDirection = _arabic(context)
        ? TextDirection.rtl
        : TextDirection.ltr;
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppBar(
            automaticallyImplyLeading: false,
            leading: const AppBackButton(),
            title: Directionality(
              textDirection: titleDirection,
              child: Text(title),
            ),
          ),
        ),
      ),
      body: items.isEmpty
          ? LibraryEmptyState(mediaKind: kind)
          : LibraryItemsGrid(items: items, heroPrefix: 'lib_page'),
    );
  }
}
