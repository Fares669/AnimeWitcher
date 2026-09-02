import 'package:flutter/material.dart';

// Temporary CI-safe stubs for analyze/build_runner.
// Full Liquid Glass implementation lives on main; restore after this PR lands.
// Hit-area fix for Android PopupMenuButton is included below.

bool get appleUsesPersistentLiquidGlassHeader => false;

void appleUpdatePersistentGlassHeader(ApplePersistentGlassHeaderConfig? config) {
  if (config == null) return;
  applePersistentGlassHeaderController.show(config);
}

void appleClearPersistentGlassHeader(Object owner) {
  applePersistentGlassHeaderController.hide(owner);
}

class ApplePersistentGlassHeaderConfig {
  ApplePersistentGlassHeaderConfig({
    required this.owner,
    this.route,
    this.onBack,
    this.backTooltip,
    this.backForegroundColor,
    this.backFallbackColor,
    this.trailing,
    this.trailingButtons,
    this.branchIndex,
    this.deferTrailingMorphUntilRouteSettles = false,
    this.instantRouteBoundary = false,
  });

  final Object owner;
  ModalRoute<dynamic>? route;
  VoidCallback? onBack;
  String? backTooltip;
  Color? backForegroundColor;
  Color? backFallbackColor;
  Widget? trailing;
  List<AppleLiquidGlassToolbarButton>? trailingButtons;
  int? branchIndex;
  bool deferTrailingMorphUntilRouteSettles;
  bool instantRouteBoundary;

  bool visuallyMatches(ApplePersistentGlassHeaderConfig other) {
    final sameCustomTrailing =
        (trailing == null && other.trailing == null) ||
            identical(trailing, other.trailing);
    return (onBack != null) == (other.onBack != null) &&
        backTooltip == other.backTooltip &&
        backForegroundColor == other.backForegroundColor &&
        backFallbackColor == other.backFallbackColor &&
        branchIndex == other.branchIndex &&
        deferTrailingMorphUntilRouteSettles ==
            other.deferTrailingMorphUntilRouteSettles &&
        instantRouteBoundary == other.instantRouteBoundary &&
        sameCustomTrailing;
  }

  void updateFrom(ApplePersistentGlassHeaderConfig other) {
    route = other.route;
    onBack = other.onBack;
    backTooltip = other.backTooltip;
    backForegroundColor = other.backForegroundColor;
    backFallbackColor = other.backFallbackColor;
    trailing = other.trailing;
    trailingButtons = other.trailingButtons;
    branchIndex = other.branchIndex;
    deferTrailingMorphUntilRouteSettles =
        other.deferTrailingMorphUntilRouteSettles;
    instantRouteBoundary = other.instantRouteBoundary;
  }
}

class ApplePersistentGlassHeaderController
    extends ValueNotifier<ApplePersistentGlassHeaderConfig?> {
  ApplePersistentGlassHeaderController() : super(null);

  final List<ApplePersistentGlassHeaderConfig> _routeStack =
      <ApplePersistentGlassHeaderConfig>[];
  int? _activeBranchIndex;

  int? get activeBranchIndex => _activeBranchIndex;

  void setActiveBranch(int index) {
    if (_activeBranchIndex == index) return;
    _activeBranchIndex = index;
    _syncVisibleItem();
  }

  void _syncVisibleItem() {
    ApplePersistentGlassHeaderConfig? next;
    for (final entry in _routeStack.reversed) {
      if (entry.branchIndex == null ||
          _activeBranchIndex == null ||
          entry.branchIndex == _activeBranchIndex) {
        next = entry;
        break;
      }
    }
    if (!identical(value, next)) value = next;
  }

  void show(ApplePersistentGlassHeaderConfig config) {
    final existingIndex = _routeStack.indexWhere(
      (entry) => identical(entry.owner, config.owner),
    );
    if (existingIndex < 0) {
      _routeStack.add(config);
      _syncVisibleItem();
      return;
    }
    final existing = _routeStack[existingIndex];
    final wasVisible = identical(value, existing);
    final visualChanged = !existing.visuallyMatches(config);
    existing.updateFrom(config);
    _syncVisibleItem();
    if (wasVisible && identical(value, existing) && visualChanged) {
      notifyListeners();
    }
  }

  void hide(Object owner) {
    _routeStack.removeWhere((entry) => identical(entry.owner, owner));
    _syncVisibleItem();
  }
}

final applePersistentGlassHeaderController =
    ApplePersistentGlassHeaderController();

class ApplePersistentGlassHeaderScope extends StatelessWidget {
  const ApplePersistentGlassHeaderScope({
    super.key,
    required this.child,
    this.enabled = true,
    this.onBack,
    this.backTooltip,
    this.backForegroundColor,
    this.backFallbackColor,
    this.trailing,
    this.trailingButtons,
    this.branchIndex,
    this.deferTrailingMorphUntilRouteSettles = false,
  });

  final Widget child;
  final bool enabled;
  final VoidCallback? onBack;
  final String? backTooltip;
  final Color? backForegroundColor;
  final Color? backFallbackColor;
  final Widget? trailing;
  final List<AppleLiquidGlassToolbarButton>? trailingButtons;
  final int? branchIndex;
  final bool deferTrailingMorphUntilRouteSettles;

  @override
  Widget build(BuildContext context) => child;
}

class ApplePersistentGlassHeaderOverlay extends StatelessWidget {
  const ApplePersistentGlassHeaderOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

class AppleLiquidGlassSurface extends StatelessWidget {
  const AppleLiquidGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(999)),
    this.style = 'regular',
    this.interactive = false,
    this.fallbackColor = Colors.transparent,
    this.fallbackBorder,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final String style;
  final bool interactive;
  final Color fallbackColor;
  final BorderSide? fallbackBorder;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fallbackColor,
        borderRadius: borderRadius,
        border: fallbackBorder == null
            ? null
            : Border.fromBorderSide(fallbackBorder!),
      ),
      child: child,
    );
  }
}

class AppleLiquidGlassBackButton extends StatelessWidget {
  const AppleLiquidGlassBackButton({
    super.key,
    this.onPressed,
    this.size = 46,
    this.foregroundColor,
    this.fallbackColor,
    this.tooltip,
  });

  final VoidCallback? onPressed;
  final double size;
  final Color? foregroundColor;
  final Color? fallbackColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: SizedBox.square(
        dimension: size,
        child: IconButton(
          tooltip: tooltip ??
              MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
          icon: const Icon(
            Icons.arrow_back_rounded,
            textDirection: TextDirection.ltr,
          ),
          color: foregroundColor ?? colors.onSurface,
          style: IconButton.styleFrom(
            backgroundColor: fallbackColor ?? colors.surfaceContainerHighest,
          ),
        ),
      ),
    );
  }
}

class AppleLiquidGlassActionGroup extends StatelessWidget {
  const AppleLiquidGlassActionGroup({
    super.key,
    required this.children,
    this.height = 46,
    this.fallbackColor,
    this.collapsed = false,
    this.collapsedSystemImage = 'arrow.up.arrow.down',
    this.minimumCapacity = 0,
  });

  final List<Widget> children;
  final double height;
  final Color? fallbackColor;
  final bool collapsed;
  final String collapsedSystemImage;
  final int minimumCapacity;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppleLiquidGlassSurface(
      borderRadius: BorderRadius.circular(height / 2),
      interactive: true,
      fallbackColor: fallbackColor ?? colors.surfaceContainerHigh,
      fallbackBorder: BorderSide(
        color: colors.outlineVariant.withValues(alpha: 0.28),
      ),
      child: SizedBox(
        height: height,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// Material / Android path for toolbar actions (including the library menu).
///
/// Hit-area fix: PopupMenuButton child is [SizedBox.expand] + centered icon so
/// taps on the icon itself open the menu, not only the right side of the glyph.
class AppleLiquidGlassToolbarButton extends StatelessWidget {
  const AppleLiquidGlassToolbarButton({
    super.key,
    required this.icon,
    this.systemImage,
    required this.onPressed,
    this.color,
    this.tooltip,
    this.title,
    this.titleOnly = false,
    this.width = 46,
    this.menuItems = const <AppleNativeMenuItem>[],
    this.selectedMenuValue,
    this.onMenuSelected,
    this.menuTintColor,
  });

  final IconData icon;
  final String? systemImage;
  final VoidCallback? onPressed;
  final Color? color;
  final String? tooltip;
  final String? title;
  final bool titleOnly;
  final double width;
  final List<AppleNativeMenuItem> menuItems;
  final String? selectedMenuValue;
  final ValueChanged<String>? onMenuSelected;
  final Color? menuTintColor;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.onSurface;

    if (menuItems.isNotEmpty && onMenuSelected != null) {
      final tint = menuTintColor ?? effectiveColor;
      return SizedBox(
        width: width,
        height: double.infinity,
        child: PopupMenuButton<String>(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          offset: const Offset(0, 8),
          onSelected: onMenuSelected,
          itemBuilder: (context) => [
            for (final item in menuItems)
              PopupMenuItem<String>(
                value: item.value,
                child: Row(
                  children: [
                    if (item.icon != null) ...[
                      Icon(
                        item.icon,
                        size: 20,
                        color: item.destructive
                            ? Theme.of(context).colorScheme.error
                            : tint,
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Text(
                        item.label,
                        style: item.destructive
                            ? TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              )
                            : null,
                      ),
                    ),
                    if (selectedMenuValue == item.value)
                      Icon(Icons.check, size: 18, color: tint),
                  ],
                ),
              ),
          ],
          // Expand hit target to the full toolbar slot.
          child: SizedBox.expand(
            child: Center(
              child: titleOnly && title != null
                  ? Text(
                      title!,
                      style: TextStyle(
                        color: effectiveColor,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : Icon(icon, color: color),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: width,
      height: double.infinity,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: effectiveColor,
          padding: EdgeInsets.zero,
        ),
        icon: Icon(icon, color: color),
      ),
    );
  }
}

class AppleNativeMenuItem {
  const AppleNativeMenuItem({
    required this.value,
    required this.label,
    this.systemImage,
    this.icon,
    this.destructive = false,
  });

  final String value;
  final String label;
  final String? systemImage;
  final IconData? icon;
  final bool destructive;

  Map<String, Object?> toPlatformValue() => <String, Object?>{
        'value': value,
        'label': label,
        'systemImage': systemImage,
        'destructive': destructive,
      };
}

class AppleNativeMenuButton extends StatelessWidget {
  const AppleNativeMenuButton({
    super.key,
    required this.items,
    required this.onSelected,
    required this.accessibilityLabel,
    required this.systemImage,
    this.selectedValue,
    this.title,
    this.width,
    this.fallbackIcon = Icons.sort_rounded,
    this.size = 44,
    this.enabled = true,
    this.tintColor,
    this.invisibleAnchor = false,
    this.onMenuOpened,
    this.onMenuClosed,
  });

  final List<AppleNativeMenuItem> items;
  final ValueChanged<String> onSelected;
  final String accessibilityLabel;
  final String systemImage;
  final String? selectedValue;
  final String? title;
  final double? width;
  final IconData fallbackIcon;
  final double size;
  final bool enabled;
  final Color? tintColor;
  final bool invisibleAnchor;
  final VoidCallback? onMenuOpened;
  final VoidCallback? onMenuClosed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width ?? size,
      height: size,
      child: PopupMenuButton<String>(
        enabled: enabled,
        tooltip: accessibilityLabel,
        onOpened: onMenuOpened,
        onCanceled: onMenuClosed,
        onSelected: (value) {
          onSelected(value);
          onMenuClosed?.call();
        },
        itemBuilder: (context) => [
          for (final item in items)
            PopupMenuItem<String>(
              value: item.value,
              child: Text(item.label),
            ),
        ],
        child: SizedBox.expand(
          child: Center(
            child: Icon(fallbackIcon, color: tintColor),
          ),
        ),
      ),
    );
  }
}

class AppleNativeGlassSearchField extends StatelessWidget {
  const AppleNativeGlassSearchField({
    super.key,
    required this.controller,
    required this.placeholder,
    required this.onChanged,
    required this.onSubmitted,
    required this.tintColor,
    required this.textColor,
    required this.placeholderColor,
    this.focusRequest = 0,
    this.loading = false,
    this.textDirection = TextDirection.ltr,
    this.height = 44,
  });

  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final Color tintColor;
  final Color textColor;
  final Color placeholderColor;
  final int focusRequest;
  final bool loading;
  final TextDirection textDirection;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textDirection: textDirection,
        style: TextStyle(color: textColor),
        decoration: InputDecoration(
          hintText: placeholder,
          hintStyle: TextStyle(color: placeholderColor),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );
  }
}

class AppleSearchGlassActions extends StatelessWidget {
  const AppleSearchGlassActions({
    super.key,
    required this.onSortPressed,
    required this.onSortSelected,
    required this.onFilterPressed,
    required this.sortValue,
    required this.sortItems,
    required this.sortAccessibilityLabel,
    required this.filterAccessibilityLabel,
    this.filterCount = 0,
    this.isFilterLoading = false,
    this.isArabic = false,
  });

  final VoidCallback onSortPressed;
  final ValueChanged<String> onSortSelected;
  final VoidCallback onFilterPressed;
  final String sortValue;
  final List<AppleNativeMenuItem> sortItems;
  final String sortAccessibilityLabel;
  final String filterAccessibilityLabel;
  final int filterCount;
  final bool isFilterLoading;
  final bool isArabic;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppleNativeMenuButton(
          items: sortItems,
          onSelected: onSortSelected,
          accessibilityLabel: sortAccessibilityLabel,
          systemImage: 'arrow.up.arrow.down',
          selectedValue: sortValue,
        ),
        IconButton(
          tooltip: filterAccessibilityLabel,
          onPressed: onFilterPressed,
          icon: Badge(
            isLabelVisible: filterCount > 0,
            label: Text('$filterCount'),
            child: const Icon(Icons.filter_list_rounded),
          ),
        ),
      ],
    );
  }
}

// Legacy aliases some call sites may still reference.
typedef AppleLiquidGlassMenuItem = AppleNativeMenuItem;
typedef AppleLiquidGlassSearchField = AppleNativeGlassSearchField;
typedef AppleLiquidGlassMenuButton = AppleNativeMenuButton;

class AppleLiquidGlassContainer extends StatelessWidget {
  const AppleLiquidGlassContainer({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

class AppleLiquidGlassButton extends StatelessWidget {
  const AppleLiquidGlassButton({
    super.key,
    required this.child,
    this.onPressed,
  });
  final Widget child;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    return TextButton(onPressed: onPressed, child: child);
  }
}
