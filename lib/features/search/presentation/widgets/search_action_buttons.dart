import 'package:flutter/material.dart';

import 'search_glass_surface.dart';

import '../../../../shared/widgets/apple_liquid_glass.dart';
import '../../../../shared/widgets/animated_sort_menu_button.dart';

/// Sort + filter controls.
///
/// Layout is always [sort | filter] left-to-right. On iOS the sort trigger is
/// the real native Liquid Glass menu button, so the system morphs that same
/// control into the UIMenu and back instead of hiding Flutter chrome over an
/// invisible native anchor.
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

  /// Visible sort/filter tap targets (no divider chrome). The search
  /// category is picked in the filter sheet.
  static double groupWidthForHeight(double height, {int visibleControls = 2}) =>
      height * visibleControls +
      (appleUsesPersistentLiquidGlassHeader && visibleControls > 0 ? 32 : 0);

  @override
  State<SearchActionButtons> createState() => _SearchActionButtonsState();
}

class _SearchActionButtonsState extends State<SearchActionButtons> {
  static const _showDuration = Duration(milliseconds: 200);

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

    final native = appleUsesPersistentLiquidGlassHeader;
    final badge = widget.showFilter && widget.filterCount > 0
        ? SearchFilterBadge(count: widget.filterCount)
        : null;
    final fallbackControls = <Widget>[
      if (widget.showSort)
        AnimatedSortMenuButton(
          tooltip: widget.sortTooltip,
          selectedValue: widget.sortValue,
          items: widget.sortItems,
          onSelected: widget.onSortSelected,
          icon: widget.sortIcon,
          systemImage: widget.sortSystemImage,
          tintColor: tint,
          size: height,
        ),
      if (widget.showFilter)
        _ActionIcon(
          tooltip: widget.filterTooltip,
          icon: Icons.tune_rounded,
          color: tint,
          size: height,
          onPressed: widget.isFilterLoading ? null : widget.onFilterPressed,
          isLoading: widget.isFilterLoading,
          badgeCount: widget.filterCount,
        ),
    ];

    return Align(
      widthFactor: 1,
      heightFactor: 1,
      child: AnimatedContainer(
        key: const ValueKey('search-action-capsule'),
        width: width,
        height: height,
        duration: _showDuration,
        curve: Curves.easeOutCubic,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: native
              ? Stack(
                  children: <Widget>[
                    AppleLiquidGlassActionGroup(
                      height: height,
                      captureGestures: true,
                      children: <Widget>[
                        if (widget.showSort)
                          AnimatedSortMenuButton(
                            tooltip: widget.sortTooltip,
                            selectedValue: widget.sortValue,
                            items: widget.sortItems,
                            onSelected: widget.onSortSelected,
                            icon: widget.sortIcon,
                            systemImage: widget.sortSystemImage,
                            tintColor: tint,
                            size: height,
                          ),
                        if (widget.showFilter)
                          AppleLiquidGlassToolbarButton(
                            icon: Icons.tune_rounded,
                            systemImage: widget.isFilterLoading
                                ? 'hourglass'
                                : 'slider.horizontal.3',
                            tooltip: widget.filterTooltip,
                            color: tint,
                            onPressed: widget.isFilterLoading
                                ? null
                                : widget.onFilterPressed,
                            width: height,
                          ),
                      ],
                    ),
                    if (badge != null)
                      Positioned(
                        top: 2,
                        right: 14,
                        child: IgnorePointer(child: badge),
                      ),
                  ],
                )
              : AppleLiquidGlassSurface(
                  borderRadius: BorderRadius.circular(height / 2),
                  interactive: true,
                  // The search field's own fill, so the two read as one.
                  fallbackColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (final control in fallbackControls)
                        Expanded(child: control),
                    ],
                  ),
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
