import 'package:flutter/material.dart';

/// One tab for [FilterStyleTabBar], matching search-filter icon+label tabs.
class FilterStyleTab extends StatelessWidget {
  const FilterStyleTab({
    super.key,
    required this.label,
    this.icon,
    this.leading,
    this.showDot = false,
    this.maxWidth,
  });

  final String label;
  final IconData? icon;
  final Widget? leading;
  final bool showDot;

  /// When set, the label fills this width (equal-width [TabBar] tabs)
  /// and ellipsizes instead of overflowing.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: maxWidth == null ? TextOverflow.visible : TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    );
    final row = Row(
      mainAxisSize: maxWidth == null ? MainAxisSize.min : MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (leading != null || icon != null)
          Stack(
            clipBehavior: Clip.none,
            children: [
              leading ?? Icon(icon, size: 20),
              if (showDot)
                const Positioned(
                  right: -3,
                  top: -3,
                  child: CircleAvatar(
                    radius: 4,
                    backgroundColor: Colors.redAccent,
                  ),
                ),
            ],
          ),
        if (leading != null || icon != null) const SizedBox(width: 7),
        if (maxWidth == null) labelText else Flexible(child: labelText),
      ],
    );
    return Tab(
      child: maxWidth == null
          ? row
          : SizedBox(width: maxWidth, child: row),
    );
  }
}

/// Exact same chrome as the search-filter [TabBar]: gold label/underline
/// that slides smoothly with [TabController] / [TabBarView].
class FilterStyleTabBar extends StatelessWidget implements PreferredSizeWidget {
  const FilterStyleTabBar({
    super.key,
    required this.controller,
    required this.tabs,
    this.isScrollable = true,
    this.padding,
    this.labelPadding,
    this.indicatorSize,
    this.onTap,
  });

  final TabController controller;
  final List<Widget> tabs;
  final bool isScrollable;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? labelPadding;
  final TabBarIndicatorSize? indicatorSize;
  final ValueChanged<int>? onTap;

  @override
  Size get preferredSize => const Size.fromHeight(46);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TabBar(
      controller: controller,
      isScrollable: isScrollable,
      tabAlignment: isScrollable ? TabAlignment.start : TabAlignment.fill,
      padding: padding,
      labelPadding: labelPadding,
      indicatorSize: indicatorSize,
      indicatorColor: colors.primary,
      labelColor: colors.primary,
      unselectedLabelColor: colors.onSurfaceVariant,
      onTap: onTap,
      tabs: tabs,
    );
  }
}

/// Defers a [TabBarView] child until its tab is first reached, so pages that
/// fetch on mount keep [TabBarView]'s native indicator motion without every
/// tab requesting data as soon as the screen opens.
class LazyTabChild extends StatefulWidget {
  const LazyTabChild({
    super.key,
    required this.controller,
    required this.index,
    required this.builder,
    this.placeholder = const SizedBox.shrink(),
  });

  final TabController controller;
  final int index;
  final WidgetBuilder builder;
  final Widget placeholder;

  @override
  State<LazyTabChild> createState() => _LazyTabChildState();
}

class _LazyTabChildState extends State<LazyTabChild> {
  bool _visited = false;

  @override
  void initState() {
    super.initState();
    _visited = _isReached;
    widget.controller.animation?.addListener(_handleAnimationTick);
  }

  @override
  void dispose() {
    widget.controller.animation?.removeListener(_handleAnimationTick);
    super.dispose();
  }

  // Build as soon as the view starts sliding toward this tab, so the incoming
  // page is not blank while the indicator animates.
  bool get _isReached {
    final value =
        widget.controller.animation?.value ?? widget.controller.index.toDouble();
    return (value - widget.index).abs() < 0.999;
  }

  void _handleAnimationTick() {
    if (_visited || !_isReached) return;
    setState(() => _visited = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_visited) return widget.placeholder;
    return widget.builder(context);
  }
}
