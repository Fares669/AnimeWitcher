import 'package:flutter/material.dart';

import 'search_glass_surface.dart';

import '../../../../shared/widgets/apple_liquid_glass.dart';
import '../../../../shared/widgets/animated_sort_menu_button.dart';

/// Plain sort + filter controls matching the library header.
/// Layout is always [sort | filter] left-to-right.
class SearchActionButtons extends StatefulWidget {
  const SearchActionButtons({
    super.key,
    required this.sortValue,
    required this.sortItems,
    required this.onSortSelected,
    required this.onFilterPressed,
    required this.sortTooltip,
    required this.filterTooltip,
    required this.sortIcon,
    required this.sortSystemImage,
    this.showSort = true,
    this.showFilter = true,
    this.filterCount = 0,
    this.isFilterLoading = false,
    this.height = SearchGlassSurface.height,
    this.tintColor,
  });

  final String sortValue;
  final List<AppleNativeMenuItem> sortItems;
  final ValueChanged<String> onSortSelected;
  final VoidCallback onFilterPressed;
  final String sortTooltip;
  final String filterTooltip;
  final IconData sortIcon;
  final String sortSystemImage;
  final bool showSort;
  final bool showFilter;
  final int filterCount;
  final bool isFilterLoading;
  final double height;
  final Color? tintColor;

  /// Visible square tap targets. The search category is picked in the
  /// filter sheet, so hidden actions give their width back to search.
  static double groupWidthForHeight(double height, {int visibleControls = 2}) =>
      height * visibleControls;

  @override
  State<SearchActionButtons> createState() => _SearchActionButtonsState();
}

class _SearchActionButtonsState extends State<SearchActionButtons> {
  @override
  Widget build(BuildContext context) {
    final tint = widget.tintColor ?? Theme.of(context).colorScheme.primary;
    final height = widget.height;
    final visibleControls =
        (widget.showSort ? 1 : 0) + (widget.showFilter ? 1 : 0);
    final width = SearchActionButtons.groupWidthForHeight(
      height,
      visibleControls: visibleControls,
    );

    // AppBar leading slots impose a 48/56pt minimum height. Keep the slot's
    // horizontal constraint, but loosen only its vertical minimum so the
    // visible controls exactly match the library's 42pt search row.
    return UnconstrainedBox(
      constrainedAxis: Axis.horizontal,
      alignment: Alignment.center,
      child: SizedBox(
        key: const ValueKey('search-action-capsule'),
        width: width,
        height: height,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (widget.showSort)
                Expanded(
                  child: AnimatedSortMenuButton(
                    tooltip: widget.sortTooltip,
                    selectedValue: widget.sortValue,
                    items: widget.sortItems,
                    onSelected: widget.onSortSelected,
                    icon: widget.sortIcon,
                    systemImage: widget.sortSystemImage,
                    tintColor: tint,
                    size: height,
                  ),
                ),
              if (widget.showFilter)
                Expanded(
                  child: _ActionIcon(
                    tooltip: widget.filterTooltip,
                    icon: Icons.tune_rounded,
                    color: tint,
                    size: height,
                    onPressed: widget.isFilterLoading
                        ? null
                        : widget.onFilterPressed,
                    isLoading: widget.isFilterLoading,
                    badgeCount: widget.filterCount,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.size,
    required this.onPressed,
    this.isLoading = false,
    this.badgeCount = 0,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final double size;
  final VoidCallback? onPressed;
  final bool isLoading;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final showBadge = badgeCount > 0 && !isLoading;

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: onPressed != null,
        label: tooltip,
        onTap: onPressed,
        child: GestureDetector(
          // Own the entire square ourselves instead of relying on IconButton's
          // platform tap-target geometry. This keeps the painted filter icon
          // and its hitbox pixel-aligned inside RTL AppBar leading slots on iOS.
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: isLoading
                  ? SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: color,
                      ),
                    )
                  : Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: [
                        Icon(icon, size: 22, color: color),
                        if (showBadge)
                          Positioned(
                            right: -6,
                            top: -6,
                            child: SearchFilterBadge(count: badgeCount),
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

class SearchFilterBadge extends StatelessWidget {
  const SearchFilterBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: '$count',
      child: Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: colors.primary,
          shape: BoxShape.circle,
          border: Border.all(
            color: colors.onPrimary.withValues(alpha: 0.72),
            width: 1.5,
          ),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            count > 99 ? '99+' : '$count',
            style: TextStyle(
              color: colors.onPrimary,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

