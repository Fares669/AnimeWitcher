import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/account/account_providers.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/providers/witanime_provider.dart';
import '../../../../core/storage/library_category.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../shared/widgets/app_search_field.dart';
import '../../../../shared/widgets/app_side_menu.dart';
import '../../../../shared/widgets/underline_segment_tabs.dart';
import '../../../characters/presentation/characters_screen.dart';
import '../../../more/presentation/recent_watched_screen.dart';
import '../history_provider.dart';
import '../library_lists.dart';
import '../library_media_kind.dart';
import '../library_provider.dart';
import '../library_state.dart';
import 'bookmarks_tab.dart';

String _t(BuildContext context, String en, String ar) => ar;

enum LibraryPhoneSection { anime, manga, characters }

String _sectionLabel(BuildContext context, LibraryPhoneSection section) =>
    switch (section) {
      LibraryPhoneSection.anime => _t(context, 'Anime', 'أنمي'),
      LibraryPhoneSection.manga => _t(context, 'Manga', 'مانجا'),
      LibraryPhoneSection.characters => _t(context, 'Characters', 'شخصيات'),
    };

LibraryMediaKind? _sectionKind(LibraryPhoneSection section) =>
    switch (section) {
      LibraryPhoneSection.anime => LibraryMediaKind.anime,
      LibraryPhoneSection.manga => LibraryMediaKind.manga,
      LibraryPhoneSection.characters => null,
    };

typedef _LibraryListTab = ({
  String key,
  String label,
  int? count,
  LibraryCategory? category,
});

/// The phone library is always a poster grid. The bar below search selects a
/// concrete list; the filter chooses Anime, Manga, or favorite Characters and
/// which list tabs are visible.
class LibraryPhoneShelves extends ConsumerStatefulWidget {
  const LibraryPhoneShelves({super.key});

  @override
  ConsumerState<LibraryPhoneShelves> createState() =>
      _LibraryPhoneShelvesState();
}

class _LibraryPhoneShelvesState extends ConsumerState<LibraryPhoneShelves> {
  late final LibraryShelfPrefs _prefs;
  late LibraryPhoneSection _section;
  final TextEditingController _search = TextEditingController();
  String _selectedListKey = LibraryCategory.watching.storageKey;
  String _query = '';

  Timer? _typing;
  static const Duration _typingPause = Duration(milliseconds: 500);

  final Map<(LibraryMediaKind, LibraryCategory), List<MultimediaItem>> _lists =
      <(LibraryMediaKind, LibraryCategory), List<MultimediaItem>>{};
  final Map<(LibraryMediaKind, LibraryCategory), int?> _tabCounts = {};
  final PageStorageBucket _scrollBucket = PageStorageBucket();
  Object? _listsFor;

  @override
  void initState() {
    super.initState();
    _prefs = LibraryShelfPrefs(ref.read(storageServiceProvider));
    final library = ref.read(libraryProvider);
    _section = library.mediaKind == LibraryMediaKind.manga
        ? LibraryPhoneSection.manga
        : LibraryPhoneSection.anime;
    _selectedListKey = library.category.storageKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !TickerMode.valuesOf(context).enabled) return;
      unawaited(_syncHistory());
      final state = ref.read(libraryProvider);
      unawaited(
        ref
            .read(libraryProvider.notifier)
            .refreshVisibleFromServer(
              category: state.category,
              mediaKind: state.mediaKind,
            ),
      );
    });
  }

  Future<void> _syncHistory() async {
    try {
      await ref.read(watchHistoryProvider.notifier).refreshFromServer();
    } catch (_) {
      // Keep the latest local history when the account is temporarily offline.
    }
  }

  @override
  void dispose() {
    _typing?.cancel();
    _search.dispose();
    _prefs.dispose();
    super.dispose();
  }

  List<MultimediaItem> _list(
    LibraryMediaKind kind,
    LibraryCategory category,
  ) => _lists.putIfAbsent(
    (kind, category),
    () => sortLibraryItems(
      ref.read(libraryProvider.notifier).itemsForCategory(kind, category),
      _prefs.sort,
    ),
  );

  Iterable<MultimediaItem> _entries(
    LibraryMediaKind kind,
    List<HistoryItem> history, {
    required bool witanimeAnime,
  }) sync* {
    final seen = <String>{};
    for (final category in LibraryCategory.valuesForCatalog(
      witanimeAnime: witanimeAnime,
    )) {
      if (!_prefs.shows(category)) continue;
      for (final item in _list(kind, category)) {
        if (seen.add(item.url)) yield item;
      }
    }
    if (libraryKindHasRecent(kind) && _prefs.showsRecent()) {
      for (final entry in sortLibraryHistory(
        libraryRecentEntries(history, kind).toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp)),
        _prefs.sort,
      )) {
        if (seen.add(entry.item.url)) yield entry.item;
      }
    }
  }

  List<_LibraryListTab> _listTabs(
    LibraryMediaKind kind,
    List<HistoryItem> history, {
    required bool witanimeAnime,
  }) {
    final tabs = <_LibraryListTab>[];
    if (libraryKindHasRecent(kind) && _prefs.showsRecent()) {
      final count = libraryRecentEntries(history, kind).length;
      if (!_prefs.hideEmpty || count > 0) {
        tabs.add((
          key: LibraryShelfPrefs.recentKey,
          label: libraryRecentLabel(context),
          count: count,
          category: null,
        ));
      }
    }
    final categories = LibraryCategory.valuesForCatalog(
      witanimeAnime: witanimeAnime,
    ).where(_prefs.shows);
    final missing = categories.where(
      (category) => !_tabCounts.containsKey((kind, category)),
    );
    if (missing.isNotEmpty) {
      final counts = ref
          .read(libraryProvider.notifier)
          .categoryCountsFor(kind, missing);
      for (final entry in counts.entries) {
        _tabCounts[(kind, entry.key)] = entry.value;
      }
    }

    for (final category in categories) {
      // The server total can exceed the number of loaded poster cards.
      final count = _tabCounts[(kind, category)];
      if (_prefs.hideEmpty && count == 0) continue;
      tabs.add((
        key: category.storageKey,
        label: libraryCategoryLabel(context, category, kind),
        count: count,
        category: category,
      ));
    }
    return tabs;
  }

  _LibraryListTab? _effectiveTab(List<_LibraryListTab> tabs) {
    for (final tab in tabs) {
      if (tab.key == _selectedListKey) return tab;
    }
    return tabs.isEmpty ? null : tabs.first;
  }

  void _selectList(LibraryMediaKind kind, _LibraryListTab tab) {
    if (_selectedListKey == tab.key) return;
    setState(() => _selectedListKey = tab.key);
    final category = tab.category;
    if (category != null) {
      unawaited(ref.read(libraryProvider.notifier).select(kind, category));
    } else if (tab.key == LibraryShelfPrefs.recentKey) {
      unawaited(_syncHistory());
    }
  }

  Widget _listBody(
    LibraryMediaKind kind,
    _LibraryListTab tab, {
    required bool isActive,
  }) {
    if (tab.key == LibraryShelfPrefs.recentKey) {
      return RecentWatchedBody(
        key: const ValueKey<String>('library-recent'),
        sort: _prefs.sort,
      );
    }
    final category = tab.category!;
    final items = _list(kind, category);
    final page = ref
        .read(libraryProvider.notifier)
        .pageInfo(kind, category, loadedLocalCount: items.length);
    return items.isEmpty && !page.hasMore && !page.loading
        ? LibraryEmptyState(mediaKind: kind)
        : LibraryItemsGrid(
            key: ValueKey<String>(
              'library-grid-${kind.storageKey}-${category.storageKey}',
            ),
            items: items,
            heroPrefix: 'lib_${kind.storageKey}_${category.storageKey}',
            totalCount: page.total,
            hasMore: page.hasMore,
            loadingMore: page.loading,
            loadFailed: page.loadFailed,
            onLoadMore: isActive
                ? () => ref
                      .read(libraryProvider.notifier)
                      .loadNextPage(mediaKind: kind, category: category)
                : null,
          );
  }

  void _selectSection(LibraryPhoneSection section) {
    if (_section == section) return;
    final kind = _sectionKind(section);
    setState(() {
      _section = section;
      _query = '';
      _search.clear();
      _selectedListKey = kind == null
          ? 'characters'
          : ref.read(libraryProvider).category.storageKey;
    });
    if (kind != null) {
      unawaited(ref.read(libraryProvider.notifier).selectMediaKind(kind));
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider);
    final witanimeActive = ref.watch(activeProviderProvider) is WitanimeProvider;
    final dataRevision = ref.watch(accountDataRevisionProvider);
    final history = ref.watch(watchHistoryProvider);
    final colors = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: _prefs,
      builder: (context, _) {
        // A search query changes only the view, not the underlying library.
        // Invalidate local shelf caches on actual data/account/page changes,
        // not on harmless loading-state rebuilds.
        final listsFor = (
          library.category,
          library.mediaKind,
          witanimeActive,
          _prefs.sort,
          dataRevision,
          ref.read(libraryProvider.notifier).countRevision,
          ref.read(libraryProvider.notifier).pageRevision,
          library is LibrarySuccess
              ? Object.hashAll(library.items.map((item) => item.url))
              : 0,
        );
        if (listsFor != _listsFor) {
          _lists.clear();
          _tabCounts.clear();
          _listsFor = listsFor;
        }

        final searching = _query.trim().isNotEmpty;
        final kind = _sectionKind(_section);
        final witanimeAnime =
            witanimeActive && kind == LibraryMediaKind.anime;
        final tabs = _section == LibraryPhoneSection.characters
            ? <_LibraryListTab>[
                (
                  key: 'characters',
                  label: libraryCharactersLabel(context),
                  count: null,
                  category: null,
                ),
              ]
            : _listTabs(
                kind!,
                history,
                witanimeAnime: witanimeAnime,
              );
        final selected = _effectiveTab(tabs);
        final selectedIndex = selected == null
            ? 0
            : tabs.indexWhere((tab) => tab.key == selected.key);
        final controllerKey = ValueKey<String>(
          'library-tabs-${_section.name}-'
          '${tabs.map((tab) => tab.key).join('-')}',
        );

        return PageStorage(
          bucket: _scrollBucket,
          child: DefaultTabController(
            key: controllerKey,
            length: tabs.isEmpty ? 1 : tabs.length,
            initialIndex: selectedIndex < 0 ? 0 : selectedIndex,
            child: Builder(
              builder: (tabContext) {
                final controller = DefaultTabController.of(tabContext);

                Widget body;
                if (_section == LibraryPhoneSection.characters) {
                  body = const CharactersScreen(
                    key: ValueKey<String>('library-characters'),
                    favoritesOnly: true,
                    embedded: true,
                  );
                } else if (searching) {
                  final shown = filterLibraryTitles(
                    _entries(
                      kind!,
                      history,
                      witanimeAnime: witanimeAnime,
                    ),
                    _query,
                  );
                  body = shown.isEmpty
                      ? Center(
                          child: Text(
                            _t(context, 'Nothing matches', 'لا توجد نتائج'),
                            key: const ValueKey<String>('library-search-empty'),
                          ),
                        )
                      : LibraryItemsGrid(
                          key: ValueKey<String>(
                            'library-grid-${kind.storageKey}-search',
                          ),
                          items: shown,
                          heroPrefix: 'lib_search_${kind.storageKey}',
                        );
                } else if (tabs.isEmpty) {
                  body = LibraryEmptyState(mediaKind: kind!);
                } else {
                  body = NotificationListener<ScrollEndNotification>(
                    onNotification: (notification) {
                      if (notification.metrics.axis != Axis.horizontal) {
                        return false;
                      }
                      final index = controller.index;
                      if (index >= 0 && index < tabs.length) {
                        _selectList(kind!, tabs[index]);
                      }
                      return false;
                    },
                    child: TabBarView(
                      key: const ValueKey<String>('library-list-pager'),
                      controller: controller,
                      // TabBarView builds adjacent pages lazily. Do not decode
                      // and sort every stored shelf on each swipe/scroll frame.
                      children: [
                        for (final tab in tabs)
                          Builder(
                            builder: (_) => _listBody(
                              kind!,
                              tab,
                              isActive: tab.key == selected?.key,
                            ),
                          ),
                      ],
                    ),
                  );
                }

                return Scaffold(
                  appBar: AppBar(
                    titleSpacing: 12,
                    title: AppSearchField(
                      fieldKey: const ValueKey<String>('library-search'),
                      controller: _search,
                      hintText: _t(
                        context,
                        'Search your library',
                        'ابحث في مكتبتك',
                      ),
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
                    ),
                    leading: IconButton(
                      key: const ValueKey<String>('library-filter'),
                      tooltip: _t(context, 'Filter', 'تصفية'),
                      icon: Icon(Icons.tune_rounded, color: colors.primary),
                      onPressed: () => _openFilterSheet(context),
                    ),
                    actions: const [
                      AppSideMenuButton(
                        padding: EdgeInsetsDirectional.only(start: 2, end: 4),
                      ),
                      SizedBox(width: 4),
                    ],
                    bottom: tabs.isEmpty
                        ? const PreferredSize(
                            preferredSize: Size.fromHeight(46),
                            child: SizedBox(height: 46),
                          )
                        : FilterStyleTabBar(
                            controller: controller,
                            tabs: [
                              for (final tab in tabs)
                                FilterStyleTab(
                                  key: ValueKey<String>(
                                    'library-list-tab-${tab.key}',
                                  ),
                                  label: tab.count == null
                                      ? tab.label
                                      : '${tab.label} ${tab.count}',
                                ),
                            ],
                            onTap: kind == null
                                ? null
                                : (index) => _selectList(kind, tabs[index]),
                          ),
                  ),
                  body: body,
                );
              },
            ),
          ),
        );
      },
    );
  }

  void _openFilterSheet(BuildContext context) {
    var section = _section;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: LibraryFilterPanel(
            prefs: _prefs,
            kind: _sectionKind(section),
            phoneSection: section,
            onPhoneSectionChanged: (value) {
              setSheetState(() => section = value);
              _selectSection(value);
            },
          ),
        ),
      ),
    );
  }
}

/// The library filter. On phone it also chooses Anime, Manga, or favorite
/// Characters. Desktop passes only [kind] and keeps its existing navigation.
class LibraryFilterPanel extends ConsumerWidget {
  const LibraryFilterPanel({
    super.key,
    required this.prefs,
    this.kind,
    this.phoneSection,
    this.onPhoneSectionChanged,
  }) : assert(kind != null || phoneSection != null);

  final LibraryShelfPrefs prefs;
  final LibraryMediaKind? kind;
  final LibraryPhoneSection? phoneSection;
  final ValueChanged<LibraryPhoneSection>? onPhoneSectionChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final witanimeActive = ref.watch(activeProviderProvider) is WitanimeProvider;
    return ListenableBuilder(
      listenable: prefs,
      builder: (context, _) {
        final theme = Theme.of(context);
        final activeKind = phoneSection == LibraryPhoneSection.characters
            ? null
            : phoneSection == LibraryPhoneSection.manga
            ? LibraryMediaKind.manga
            : phoneSection == LibraryPhoneSection.anime
            ? LibraryMediaKind.anime
            : kind;

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
          ValueChanged<T> on, {
          Key? key,
        }) => ChoiceChip(
          key: key,
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
              if (phoneSection != null) ...[
                heading(_t(context, 'Library section', 'القسم')),
                wrap([
                  for (final section in LibraryPhoneSection.values)
                    choice<LibraryPhoneSection>(
                      section,
                      phoneSection!,
                      _sectionLabel(context, section),
                      onPhoneSectionChanged ?? (_) {},
                      key: ValueKey<String>('library-section-${section.name}'),
                    ),
                ]),
              ],
              heading(_t(context, 'Lists shown', 'القوائم الظاهرة')),
              if (phoneSection == LibraryPhoneSection.characters)
                wrap([
                  FilterChip(
                    key: const ValueKey<String>('library-filter-characters'),
                    label: Text(libraryCharactersLabel(context)),
                    selected: true,
                    showCheckmark: false,
                    onSelected: null,
                  ),
                ])
              else if (activeKind != null)
                wrap([
                  if (libraryKindHasRecent(activeKind))
                    FilterChip(
                      key: const ValueKey<String>('library-filter-recent'),
                      label: Text(libraryRecentLabel(context)),
                      selected: prefs.showsRecent(),
                      showCheckmark: false,
                      onSelected: (on) =>
                          prefs.setShown(LibraryShelfPrefs.recentKey, on),
                    ),
                  for (final category in LibraryCategory.valuesForCatalog(
                    witanimeAnime:
                        witanimeActive && activeKind == LibraryMediaKind.anime,
                  ))
                    FilterChip(
                      key: ValueKey<String>(
                        'library-filter-${category.storageKey}',
                      ),
                      label: Text(
                        libraryCategoryLabel(context, category, activeKind),
                      ),
                      selected: prefs.shows(category),
                      showCheckmark: false,
                      onSelected: (on) =>
                          prefs.setShown(category.storageKey, on),
                    ),
                ]),
              if (activeKind != null) ...[
                heading(_t(context, 'Sort', 'الترتيب')),
                wrap([
                  for (final (value, label) in <(LibrarySort, String)>[
                    (
                      LibrarySort.added,
                      _t(context, 'Latest added', 'آخر إضافة'),
                    ),
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
