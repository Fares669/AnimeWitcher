import 'package:flutter/material.dart';

import '../../../../core/utils/localized_text.dart';
import '../../../../shared/widgets/multimedia_card.dart';

/// Recent searches embedded above the catalogue in its scroll view.
class SearchStartPage extends StatelessWidget {
  const SearchStartPage({
    super.key,
    required this.recents,
    required this.onRecent,
    required this.onRemoveRecent,
    required this.onClearRecents,
  });

  final List<String> recents;
  final ValueChanged<String> onRecent;
  final ValueChanged<String> onRemoveRecent;
  final VoidCallback onClearRecents;

  Widget _recentsHeading(BuildContext context, double side) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(side, 18, side - 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              appText(
                context,
                english: 'Recent',
                arabic: 'عمليات البحث الأخيرة',
              ),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onClearRecents,
            icon: const Icon(
              Icons.delete_outline,
              size: 16,
              color: Colors.red,
            ),
            label: Text(
              appText(context, english: 'Clear all', arabic: 'مسح الكل'),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  Widget _recentChips(BuildContext context, {WrapAlignment? alignment}) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: alignment ?? WrapAlignment.start,
      children: [
        for (final recent in recents)
          InputChip(
            key: ValueKey<String>('search-recent-$recent'),
            label: Text(recent),
            onPressed: () => onRecent(recent),
            onDeleted: () => onRemoveRecent(recent),
            deleteIcon: const Icon(Icons.close_rounded, size: 16),
            side: BorderSide.none,
            backgroundColor: colors.surfaceContainerHighest.withValues(
              alpha: 0.6,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(99),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (recents.isEmpty) return const SizedBox.shrink();
    final side = MultimediaCardLayout.catalogGridHorizontalPadding(context) + 4;
    return Column(
      key: const ValueKey<String>('search-recent-searches'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _recentsHeading(context, side),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: side),
          child: _recentChips(context),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
