import 'package:flutter/material.dart';

import '../../../../core/utils/layout_constants.dart';
import '../../../../core/utils/responsive_breakpoints.dart';
import '../../../../l10n/generated/app_localizations.dart';

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

/// The same simple primary text action used by search section headings.
class HomeViewAllButton extends StatelessWidget {
  const HomeViewAllButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      child: Text(AppLocalizations.of(context)!.viewAll),
    );
  }
}