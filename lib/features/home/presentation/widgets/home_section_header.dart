import 'package:flutter/material.dart';

import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/cards_wrapper.dart';

/// Home rail header: title on the start edge (right in Arabic) and the
/// action — usually [HomeViewAllButton] — on the end edge (left).
class HomeSectionHeader extends StatelessWidget {
  const HomeSectionHeader({
    super.key,
    required this.title,
    this.action,
    this.middle,
    this.topPadding,
    this.bottomPadding = LayoutConstants.spacingSm,
  });

  final String title;
  final Widget? action;
  final List<Widget>? middle;
  final double? topPadding;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final isDesktop = context.isDesktop;
    final titleSize = isDesktop ? 24.0 : 20.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isDesktop
            ? LayoutConstants.dashboardContentPadding
            : LayoutConstants.spacingMd,
        topPadding ?? LayoutConstants.spacingLg,
        isDesktop
            ? LayoutConstants.dashboardContentPadding
            : LayoutConstants.spacingMd,
        bottomPadding,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.start,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: titleSize,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Container(
                    width: isDesktop ? 30 : 20,
                    height: 3,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (middle != null) ...middle!,
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// "عرض الكل" with the chevron on the left of the label, pinned to the
/// left of the home section header.
class HomeViewAllButton extends StatelessWidget {
  const HomeViewAllButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.7);
    return CardsWrapper(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: LayoutConstants.spacingSm,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.arrow_forward_ios,
                size: 10,
                color: color,
                textDirection: TextDirection.ltr,
              ),
              const SizedBox(width: 4),
              Text(
                l10n.viewAll,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
