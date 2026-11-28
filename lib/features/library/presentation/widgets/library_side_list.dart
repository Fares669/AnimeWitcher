import 'package:flutter/material.dart';

import '../../../../core/storage/library_category.dart';
import '../../../../shared/widgets/desktop_sidebar_row.dart';
import '../library_lists.dart';
import '../library_media_kind.dart';

/// Every list of the library in one column, anime, manga and characters each
/// under their own heading, for PC and tablet. The watch history
/// heads the anime lists. Drawn like the More page's sidebar, so the two
/// read as one app.
class LibrarySideList extends StatelessWidget {
  const LibrarySideList({
    super.key,
    required this.kind,
    required this.category,
    required this.recentSelected,
    required this.counts,
    required this.recentCount,
    required this.onRecent,
    this.charactersSelected = false,
    this.onCharacters,
    required this.onSelect,
    required this.prefs,
    required this.onFilter,
    this.witanimeAnime = false,
  });

  final LibraryMediaKind kind;
  final LibraryCategory category;
  final bool recentSelected;
  final Map<LibraryMediaKind, Map<LibraryCategory, int?>> counts;
  final int recentCount;
  final VoidCallback onRecent;

  /// The favourite characters, which moved here from the More page, are
  /// showing rather than a list.
  final bool charactersSelected;

  /// Shows the favourite characters; no row without it.
  final VoidCallback? onCharacters;
  final void Function(LibraryMediaKind kind, LibraryCategory category) onSelect;

  /// Which lists get a row, and whether empty ones do; the one picked always
  /// keeps its row.
  final LibraryShelfPrefs prefs;

  /// Opens the filter, from the button beside the first heading.
  final VoidCallback onFilter;

  /// When true, anime shelves show only Witanime-supported lists.
  final bool witanimeAnime;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget heading(String text, {Widget? trailing}) => Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        14,
        trailing == null ? 14 : 4,
        4,
        6,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
    final special = recentSelected || charactersSelected;
    bool shown(bool listShown, int? count, bool selected) =>
        selected || (listShown && (count != 0 || !prefs.hideEmpty));

    return ListView(
      key: const ValueKey<String>('library-side-list'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
      children: [
        for (final listKind in LibraryMediaKind.values) ...[
          heading(
            libraryKindLabel(context, listKind),
            trailing: listKind == LibraryMediaKind.values.first
                ? IconButton(
                    key: const ValueKey<String>('library-side-filter'),
                    tooltip: 'تصفية',
                    icon: Icon(Icons.tune_rounded, color: colors.primary),
                    onPressed: onFilter,
                  )
                : null,
          ),
          if (libraryKindHasRecent(listKind) &&
              shown(prefs.showsRecent(), recentCount, recentSelected))
            LibrarySideRow(
              key: const ValueKey<String>('library-side-recent'),
              icon: libraryRecentIcon,
              label: libraryRecentLabel(context),
              count: recentCount,
              selected: recentSelected,
              onTap: onRecent,
            ),
          for (final listCategory in LibraryCategory.valuesForCatalog(
            witanimeAnime:
                witanimeAnime && listKind == LibraryMediaKind.anime,
          ))
            if (shown(
              prefs.shows(listCategory),
              counts[listKind]?[listCategory],
              !special && listKind == kind && listCategory == category,
            ))
              LibrarySideRow(
                key: ValueKey<String>(
                  'library-side-${listKind.storageKey}-${listCategory.storageKey}',
                ),
                icon: libraryCategoryIcon(listCategory),
                label: libraryCategoryLabel(context, listCategory, listKind),
                count: counts[listKind]?[listCategory],
                selected:
                    !special && listKind == kind && listCategory == category,
                onTap: () => onSelect(listKind, listCategory),
              ),
        ],
        if (onCharacters != null) ...[
          heading('الشخصيات'),
          LibrarySideRow(
            key: const ValueKey<String>('library-side-characters'),
            icon: Icons.face_rounded,
            label: libraryCharactersLabel(context),
            selected: charactersSelected,
            onTap: onCharacters!,
          ),
        ],
      ],
    );
  }
}

/// One list in [LibrarySideList]: glyph, name and how many it holds, with
/// the current one marked by a bar and a tint.
class LibrarySideRow extends StatefulWidget {
  const LibrarySideRow({
    super.key,
    required this.icon,
    required this.label,
    this.count,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;

  /// How many it holds; left off where that is not known up front.
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<LibrarySideRow> createState() => _LibrarySideRowState();
}

class _LibrarySideRowState extends DesktopSidebarRowState<LibrarySideRow> {
  @override
  Widget build(BuildContext context) {
    final count = widget.count;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return buildRow(
      icon: widget.icon,
      label: widget.label,
      selected: widget.selected,
      onTap: widget.onTap,
      verticalPadding: 10,
      accent: colors.primary,
      onSurface: colors.onSurface,
      onSurfaceVariant: colors.onSurfaceVariant,
      labelStyle: theme.textTheme.titleSmall,
      trailing: count == null
          ? null
          : Text(
              '$count',
              style: theme.textTheme.labelMedium?.copyWith(
                color: widget.selected
                    ? colors.primary
                    : colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
    );
  }
}
