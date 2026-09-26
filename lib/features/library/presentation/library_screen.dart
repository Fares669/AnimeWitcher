import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';

import '../../../core/providers/device_info_provider.dart';
import '../../../core/storage/library_category.dart';
import '../../../core/storage/library_repository.dart';
import '../../../core/storage/storage_service.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';
import '../../characters/presentation/characters_screen.dart';
import '../../more/presentation/recent_watched_screen.dart';
import 'history_provider.dart';
import 'library_lists.dart';
import 'library_provider.dart';
import 'library_media_kind.dart';
import 'widgets/bookmarks_tab.dart';
import 'widgets/library_phone_shelves.dart';
import 'widgets/library_side_list.dart';

/// The library. On PC and tablet every list sits in a side column, anime
/// and manga under their own headings with the watch history first, and the
/// one picked fills the rest. On a phone it is [LibraryPhoneShelves].
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  /// The side column's "آخر المشاهدات" is picked rather than a list.
  bool _recent = false;

  /// The favourite characters are picked rather than a list.
  bool _characters = false;

  /// The filter's settings, shared with the phone's shelves.
  late final LibraryShelfPrefs _prefs;

  @override
  void initState() {
    super.initState();
    _prefs = LibraryShelfPrefs(ref.read(storageServiceProvider));
  }

  @override
  void dispose() {
    _prefs.dispose();
    super.dispose();
  }

  void _openFilter(LibraryMediaKind kind) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: LibraryFilterPanel(
              prefs: _prefs,
              kind: kind,
              showView: false,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final isTv = profile?.isTv == true || context.isTv;
    final isWidescreen = isTv || context.isTabletOrLarger;

    if (isWidescreen) return _buildWide(context);

    const phone = LibraryPhoneShelves();
    if (!appleUsesPersistentLiquidGlassHeader) return phone;
    return ApplePersistentGlassHeaderScope(
      branchIndex: TaskbarDestination.library.branchIndex,
      trailingButtons: const <AppleLiquidGlassToolbarButton>[],
      child: phone,
    );
  }

  Widget _buildWide(BuildContext context) {
    final libraryState = ref.watch(libraryProvider);
    final history = ref.watch(watchHistoryProvider);
    final repository = ref.read(libraryRepositoryProvider);
    final kind = libraryState.mediaKind;
    final category = libraryState.category;
    final counts = <LibraryMediaKind, Map<LibraryCategory, int>>{
      for (final listKind in LibraryMediaKind.values)
        listKind: <LibraryCategory, int>{
          for (final listCategory in LibraryCategory.values)
            listCategory: libraryItemsFor(
              repository,
              listCategory,
              listKind,
            ).length,
        },
    };
    final recentCount = libraryRecentFor(
      history,
      LibraryMediaKind.anime,
    ).length;
    final title = _characters
        ? libraryCharactersLabel(context)
        : _recent
        ? libraryRecentLabel(context)
        : libraryCategoryLabel(context, category, kind);
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: _prefs,
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.transparent,
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 272,
              child: LibrarySideList(
                kind: kind,
                category: category,
                recentSelected: _recent,
                charactersSelected: _characters,
                onCharacters: () => setState(() {
                  _recent = false;
                  _characters = true;
                }),
                counts: counts,
                recentCount: recentCount,
                prefs: _prefs,
                onFilter: () => _openFilter(kind),
                onRecent: () => setState(() {
                  _recent = true;
                  _characters = false;
                }),
                onSelect: (listKind, listCategory) {
                  setState(() {
                    _recent = false;
                    _characters = false;
                  });
                  unawaited(
                    ref
                        .read(libraryProvider.notifier)
                        .select(listKind, listCategory),
                  );
                },
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: LayoutConstants.dashboardHeaderHeight,
                    padding: const EdgeInsets.only(
                      top: 8,
                      left: LayoutConstants.dashboardContentPadding,
                      right: LayoutConstants.dashboardContentPadding,
                    ),
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      _recent || _characters
                          ? title
                          : '${libraryKindLabel(context, kind)} · $title',
                      key: const ValueKey<String>('library-pane-title'),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: _characters
                        ? const CharactersScreen(
                            key: ValueKey<String>('library-characters'),
                            favoritesOnly: true,
                            embedded: true,
                          )
                        : _recent
                        ? RecentWatchedBody(
                            key: const ValueKey<String>('library-recent'),
                            sort: _prefs.sort,
                          )
                        : BookmarksTab(sort: _prefs.sort),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
