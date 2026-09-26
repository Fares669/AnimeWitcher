import 'package:flutter/material.dart';

import '../../../../core/storage/library_category.dart';
import '../library_lists.dart';
import '../library_media_kind.dart';

/// Every list of the library in one column, anime and manga each under its
/// own heading, for PC and tablet: nothing behind a menu. The watch history
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
  });

  final LibraryMediaKind kind;
  final LibraryCategory category;
  final bool recentSelected;
  final Map<LibraryMediaKind, Map<LibraryCategory, int>> counts;
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
    bool shown(bool listShown, int count, bool selected) =>
        selected || (listShown && (count > 0 || !prefs.hideEmpty));

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
                    tooltip:
                        Localizations.localeOf(context).languageCode == 'ar'
                        ? 'تصفية'
                        : 'Filter',
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
          for (final listCategory in LibraryCategory.values)
            if (shown(
              prefs.shows(listCategory),
              counts[listKind]?[listCategory] ?? 0,
              !special && listKind == kind && listCategory == category,
            ))
              LibrarySideRow(
                key: ValueKey<String>(
                  'library-side-${listKind.storageKey}-${listCategory.storageKey}',
                ),
                icon: libraryCategoryIcon(listCategory),
                label: libraryCategoryLabel(context, listCategory, listKind),
                count: counts[listKind]?[listCategory] ?? 0,
                selected:
                    !special && listKind == kind && listCategory == category,
                onTap: () => onSelect(listKind, listCategory),
              ),
          // The characters are anime's: last under its heading.
          if (listKind == LibraryMediaKind.anime && onCharacters != null)
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

class _LibrarySideRowState extends State<LibrarySideRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selected = widget.selected;
    final accent = colors.primary;
    final background = selected
        ? accent.withValues(alpha: 0.13)
        : _hovered
        ? colors.onSurface.withValues(alpha: 0.06)
        : Colors.transparent;
    final foreground = selected
        ? colors.onSurface
        : _hovered
        ? colors.onSurface.withValues(alpha: 0.9)
        : colors.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Semantics(
          button: true,
          selected: selected,
          label: widget.label,
          child: GestureDetector(
            onTap: widget.onTap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 130),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 130),
                    curve: Curves.easeOut,
                    width: 3,
                    height: selected ? 18 : 0,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Icon(
                    widget.icon,
                    size: 20,
                    color: selected ? accent : foreground,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (widget.count case final count?)
                    Text(
                      '$count',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: selected ? accent : colors.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
