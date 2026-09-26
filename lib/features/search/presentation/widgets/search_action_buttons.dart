import 'package:flutter/material.dart';

import 'search_glass_surface.dart';

import '../../../../shared/widgets/apple_liquid_glass.dart';

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
  static const _hideDuration = Duration(milliseconds: 160);
  static const _showDuration = Duration(milliseconds: 200);

  bool _sortMenuOpen = false;

  void _setSortMenuOpen(bool open) {
    if (!mounted || _sortMenuOpen == open) return;
    setState(() => _sortMenuOpen = open);
  }

  void _onSortSelected(String value) {
    _setSortMenuOpen(false);
    widget.onSortSelected(value);
  }

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
      if (widget.showSort) _buildSortControl(tint),
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
                          AppleLiquidGlassToolbarButton(
                            icon: widget.sortIcon,
                            systemImage: widget.sortSystemImage,
                            tooltip: widget.sortTooltip,
                            color: tint,
                            menuTintColor: tint,
                            menuItems: widget.sortItems,
                            selectedMenuValue: widget.sortValue,
                            onMenuSelected: widget.onSortSelected,
                            onPressed: () {},
                            width: height,
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

  String? _sortTextGlyph(String? systemImage) {
    return switch (systemImage) {
      'animewitcher.abc' => 'ABC',
      'animewitcher.zyx' => 'ZYX',
      _ => null,
    };
  }

  Widget _buildSortGlyph(
    Color tint, {
    required IconData icon,
    required String? systemImage,
    double iconSize = 22,
    double textSize = 15,
  }) {
    final textGlyph = _sortTextGlyph(systemImage);
    if (textGlyph != null) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          textGlyph,
          maxLines: 1,
          style: TextStyle(
            color: tint,
            fontSize: textSize,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
            height: 1,
          ),
        ),
      );
    }
    return Icon(icon, size: iconSize, color: tint);
  }

  Widget _buildSortIcon(Color tint) {
    final visible = !_sortMenuOpen;
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: visible ? _showDuration : _hideDuration,
      curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
      child: AnimatedScale(
        scale: visible ? 1 : 0.88,
        duration: visible ? _showDuration : _hideDuration,
        curve: visible ? Curves.easeOutBack : Curves.easeInCubic,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, -0.18),
          duration: visible ? _showDuration : _hideDuration,
          curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
          child: _buildSortGlyph(
            tint,
            icon: widget.sortIcon,
            systemImage: widget.sortSystemImage,
          ),
        ),
      ),
    );
  }

  Widget _buildSortControl(Color tint) {
    final height = widget.height;
    final sortIcon = _buildSortIcon(tint);

    // The menu carries its own blurred surface rather than the flat one a
    // popup paints, so it matches the taskbar and the search capsule. The
    // button still hosts it, which keeps the anchoring and dismissal that
    // come with a popup; only what is drawn changes.
    return PopupMenuButton<String>(
      tooltip: widget.sortTooltip,
      padding: EdgeInsets.zero,
      offset: const Offset(0, 8),
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      onOpened: () => _setSortMenuOpen(true),
      onCanceled: () => _setSortMenuOpen(false),
      itemBuilder: (menuContext) => [
        PopupMenuItem<String>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: BlurredMenuPanel(
            items: widget.sortItems,
            selectedValue: widget.sortValue,
            tint: tint,
            fallbackIcon: Icons.swap_vert_rounded,
            // Some sort orders are spelled out as letters rather than drawn
            // as icons, so the row asks for its own glyph.
            leadingBuilder: (item, color) => _buildSortGlyph(
              color,
              icon: item.icon ?? Icons.swap_vert_rounded,
              systemImage: item.systemImage,
              iconSize: 18,
              textSize: 11.5,
            ),
            onPick: (value) {
              Navigator.of(menuContext).pop();
              _setSortMenuOpen(false);
              _onSortSelected(value);
            },
          ),
        ),
      ],
      child: SizedBox(
        width: height,
        height: height,
        child: Center(child: sortIcon),
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

/// Always yellow, including when the user chooses another theme accent.
class SearchFilterBadge extends StatelessWidget {
  const SearchFilterBadge({super.key, required this.count});

  final int count;
  static const Color backgroundColor = Color(0xFFEEC60A);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$count',
      child: Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: backgroundColor,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black, width: 1.5),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            count > 99 ? '99+' : '$count',
            style: const TextStyle(
              color: Colors.black,
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
