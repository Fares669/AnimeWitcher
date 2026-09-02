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
          color: foregroundColor ?? colors.onSurface,
          style: IconButton.styleFrom(
            backgroundColor: fallbackColor ?? colors.surfaceContainerHighest,
          ),
        ),
      ),
    );
  }
}

class AppleLiquidGlassToolbarButton extends StatelessWidget {
  const AppleLiquidGlassToolbarButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.color,
    this.width = 46,
    this.menuItems = const [],
    this.onMenuSelected,
    this.selectedMenuValue,
    this.menuTintColor,
    this.systemImage,
  });
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;
  final double width;
  final List<AppleLiquidGlassMenuItem> menuItems;
  final ValueChanged<String>? onMenuSelected;
  final String? selectedMenuValue;
  final Color? menuTintColor;
  final String? systemImage;

  @override
  Widget build(BuildContext context) {
    final effectiveColor =
        color ?? Theme.of(context).colorScheme.onSurface;

    if (menuItems.isNotEmpty && onMenuSelected != null) {
      final tint = menuTintColor ?? effectiveColor;
      // Expand hit target to full SizedBox so taps on the icon itself open the menu.
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
                      Icon(item.icon, size: 20, color: tint),
                      const SizedBox(width: 12),
                    ],
                    Expanded(child: Text(item.label)),
                  ],
                ),
              ),
          ],
          child: SizedBox.expand(
            child: Center(
              child: Icon(icon, color: color),
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

class AppleLiquidGlassMenuItem {
  const AppleLiquidGlassMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.systemImage,
    this.destructive = false,
  });
  final String value;
  final String label;
  final IconData? icon;
  final String? systemImage;
  final bool destructive;
}

class AppleLiquidGlassSearchField extends StatelessWidget {
  const AppleLiquidGlassSearchField({
    super.key,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.hintText,
    this.autofocus = false,
  });
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? hintText;
  final bool autofocus;
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      autofocus: autofocus,
      decoration: InputDecoration(
        hintText: hintText ?? 'Search',
        border: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      ),
    );
  }
}

class AppleLiquidGlassMenuButton extends StatelessWidget {
  const AppleLiquidGlassMenuButton({
    super.key,
    required this.items,
    required this.onSelected,
    this.selectedValue,
    this.fallbackIcon = Icons.more_horiz,
    this.tintColor,
    this.size = 46,
    this.enabled = true,
    this.accessibilityLabel,
    this.onMenuOpened,
    this.onMenuClosed,
  });
  final List<AppleLiquidGlassMenuItem> items;
  final ValueChanged<String> onSelected;
  final String? selectedValue;
  final IconData fallbackIcon;
  final Color? tintColor;
  final double size;
  final bool enabled;
  final String? accessibilityLabel;
  final VoidCallback? onMenuOpened;
  final VoidCallback? onMenuClosed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
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

// Additional stubs used across the app to keep analyzer happy.
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

void appleUpdatePersistentGlassHeader(ApplePersistentGlassHeaderConfig? config) {}
void appleClearPersistentGlassHeader(Object owner) {}

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
}
