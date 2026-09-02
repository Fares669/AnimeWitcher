import 'package:flutter/material.dart';

// Temporary CI-safe stubs. Full Liquid Glass implementation should be restored
// from main after this PR's character-card + menu hit-area fixes land.
bool get appleUsesPersistentLiquidGlassHeader => false;

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
          color: colors.primary,
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
    return SizedBox(
      height: height,
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

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
                child: Text(item.label),
              ),
          ],
          // Expand hit target so taps on the icon open the menu.
          child: SizedBox.expand(
            child: Icon(icon, color: color),
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
    final w = width ?? size;
    return SizedBox(
      width: w,
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
        child: Icon(fallbackIcon, color: tintColor),
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
    this.height = 42,
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
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<bool> appleNativeLiquidGlassAvailable() async => false;

Future<String?> showAppleNativeSearchSort({
  required String initialValue,
  required List<Map<String, String>> items,
  required bool isArabic,
  required Color tintColor,
}) async =>
    null;

Future<Map<String, dynamic>?> showAppleNativeSearchFilters({
  required Map<String, Object?> options,
  required Map<String, Object?> initialValue,
  required bool isArabic,
  required Color tintColor,
}) async =>
    null;

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
    this.height = 42,
    this.tintColor,
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
  final double height;
  final Color? tintColor;
  @override
  Widget build(BuildContext context) {
    return AppleLiquidGlassActionGroup(
      height: height,
      children: [
        AppleLiquidGlassToolbarButton(
          width: height,
          icon: Icons.sort_rounded,
          tooltip: sortAccessibilityLabel,
          color: tintColor ?? Theme.of(context).colorScheme.primary,
          onPressed: onSortPressed,
        ),
        AppleLiquidGlassToolbarButton(
          width: height,
          icon: Icons.tune_rounded,
          tooltip: filterAccessibilityLabel,
          color: tintColor ?? Theme.of(context).colorScheme.primary,
          onPressed: isFilterLoading ? null : onFilterPressed,
        ),
      ],
    );
  }
}
