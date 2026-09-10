import 'package:flutter/material.dart';

import 'package:animewitcher/core/utils/localized_text.dart';
import '../../../../core/utils/layout_constants.dart';

/// The searches you made last, offered where the empty-search placeholder was.
///
/// A list rather than a row of chips: anime titles run long — "Buchigire
/// Reijou wa Houfuku wo Chikaimashita" is one search — and a chip wide enough
/// to hold one is not a chip. Down a list each gets a full line and the
/// remove buttons line up in a column you can run down.
class RecentSearchesView extends StatelessWidget {
  const RecentSearchesView({
    super.key,
    required this.searches,
    required this.onSelected,
    required this.onRemoved,
    required this.onClearAll,
  });

  final List<String> searches;
  final ValueChanged<String> onSelected;
  final ValueChanged<String> onRemoved;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.only(
        top: LayoutConstants.spacingSm,
        bottom: LayoutConstants.spacingLg,
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LayoutConstants.spacingMd,
            LayoutConstants.spacingXs,
            LayoutConstants.spacingSm,
            LayoutConstants.spacingXs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  appText(
                    context,
                    english: 'Recent searches',
                    arabic: 'عمليات البحث الأخيرة',
                  ),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant.withValues(alpha: 0.75),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              TextButton(
                onPressed: onClearAll,
                child: Text(
                  appText(context, english: 'Clear all', arabic: 'مسح الكل'),
                ),
              ),
            ],
          ),
        ),
        for (final query in searches)
          ListTile(
            key: ValueKey<String>('recent-search-$query'),
            leading: Icon(
              Icons.history_rounded,
              color: colors.onSurfaceVariant,
              size: 22,
            ),
            minLeadingWidth: 24,
            title: Text(
              query,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge,
            ),
            trailing: IconButton(
              key: ValueKey<String>('recent-search-remove-$query'),
              tooltip: appText(context, english: 'Remove', arabic: 'إزالة'),
              icon: Icon(
                Icons.close_rounded,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
              onPressed: () => onRemoved(query),
            ),
            onTap: () => onSelected(query),
          ),
      ],
    );
  }
}
