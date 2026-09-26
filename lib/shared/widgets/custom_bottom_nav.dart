import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/account_avatar_button.dart';

class CustomBottomNavBar extends StatelessWidget {
  final int currentBranchIndex;
  final List<TaskbarDestination> destinations;
  final ValueChanged<TaskbarDestination> onTap;

  /// A news button after the page tabs — on a desktop, where the news has a
  /// button of its own instead of a row on home. Null leaves it out.
  final VoidCallback? onNews;

  /// The account picture at the end, where the news button is shown too.
  /// Null leaves it out.
  final VoidCallback? onAccount;

  const CustomBottomNavBar({
    super.key,
    required this.currentBranchIndex,
    required this.destinations,
    required this.onTap,
    this.onNews,
    this.onAccount,
  });

  static const double height = 64;

  /// Off: iOS has the same bar as every other platform, not the native
  /// glass tab bar.
  static bool get usesNativeAppleTabBar => false;

  static double nativeAppleHeight(BuildContext context) =>
      49 + MediaQuery.viewPaddingOf(context).bottom;

  static double bottomInsetFor(BuildContext context) =>
      math.max(MediaQuery.viewPaddingOf(context).bottom - 8, 12);

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    if (usesNativeAppleTabBar) {
      return SizedBox(
        height: nativeAppleHeight(context),
        width: double.infinity,
        child: _AppleNativeTabBar(
          currentBranchIndex: currentBranchIndex,
          destinations: destinations,
          onTap: onTap,
        ),
      );
    }
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    // The news and account cells count, so the highlight lands on the right
    // tab.
    final count =
        destinations.length +
        (onNews == null ? 0 : 1) +
        (onAccount == null ? 0 : 1);
    final selectedIndex = destinations.indexWhere(
      (destination) => destination.branchIndex == currentBranchIndex,
    );
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final visualIndex = selectedIndex < 0
        ? 0
        : (isRtl ? count - 1 - selectedIndex : selectedIndex);

    final highlight = AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: selectedIndex < 0 ? 0 : 1,
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: count <= 1
            ? Alignment.center
            : Alignment(-1 + 2 * (visualIndex / (count - 1)), 0),
        child: FractionallySizedBox(
          widthFactor: count == 0 ? 1 : 1 / count,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular((height - 12) / 2),
                color: colorScheme.primary.withValues(alpha: 0.15),
              ),
            ),
          ),
        ),
      ),
    );

    final tabs = <Widget>[
      for (final destination in destinations)
        Expanded(
          child: _NavTabCell(
            icon: destination.icon,
            selectedIcon: destination.selectedIcon,
            label: destination.label(localizations),
            isSelected: destination.branchIndex == currentBranchIndex,
            onTap: () {
              HapticFeedback.selectionClick();
              onTap(destination);
            },
          ),
        ),
      if (onNews case final openNews?)
        Expanded(
          child: _NavTabCell(
            icon: Icons.newspaper_rounded,
            selectedIcon: Icons.newspaper_rounded,
            label: localizations.localeName.toLowerCase().startsWith('ar')
                ? 'الأخبار'
                : 'News',
            isSelected: false,
            onTap: openNews,
          ),
        ),
      if (onAccount case final openAccount?)
        Expanded(
          child: Center(
            child: AccountAvatarButton(onTap: openAccount, size: 34),
          ),
        ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final fullWidth = constraints.maxWidth.clamp(0.0, 420.0);
        return Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: SizedBox(
            width: fullWidth,
            height: height,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(height / 2),
                // Same hairline the home search bar carries, so the two
                // floating controls read as one family.
                border: Border.all(
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.12),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(height / 2),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Container(
                    height: height,
                    // Matches the home search bar's fill. It sits over
                    // artwork, so it leans on the blur behind it rather
                    // than on being opaque.
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.5,
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        highlight,
                        Row(children: tabs),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NavTabCell extends StatefulWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavTabCell({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_NavTabCell> createState() => _NavTabCellState();
}

class _NavTabCellState extends State<_NavTabCell> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      selected: widget.isSelected,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        child: Focus(
          onFocusChange: (focused) => setState(() => _isFocused = focused),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: _isFocused
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: colorScheme.primary, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: colorScheme.primary.withValues(alpha: 0.3),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ],
                  )
                : null,
            child: InkWell(
              borderRadius: BorderRadius.circular(26),
              focusColor: Colors.transparent,
              hoverColor: colorScheme.primary.withValues(alpha: 0.08),
              onTap: widget.onTap,
              child: Center(
                child: Icon(
                  widget.isSelected ? widget.selectedIcon : widget.icon,
                  color: widget.isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  size: 24,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _appleNativeTabBarViewType = 'com.animewitcher.app/native_tab_bar';

String _appleTabSymbol(
  TaskbarDestination destination, {
  required bool selected,
}) {
  return switch (destination) {
    TaskbarDestination.home => selected ? 'house.fill' : 'house',
    TaskbarDestination.search => 'magnifyingglass',
    TaskbarDestination.library =>
      selected ? 'rectangle.stack.fill' : 'rectangle.stack',
    TaskbarDestination.downloads =>
      selected ? 'arrow.down.circle.fill' : 'arrow.down.circle',
    TaskbarDestination.settings =>
      selected ? 'ellipsis.circle.fill' : 'ellipsis.circle',
    TaskbarDestination.manga => selected ? 'book.fill' : 'book',
  };
}

class _AppleNativeTabBar extends StatefulWidget {
  const _AppleNativeTabBar({
    required this.currentBranchIndex,
    required this.destinations,
    required this.onTap,
  });

  final int currentBranchIndex;
  final List<TaskbarDestination> destinations;
  final ValueChanged<TaskbarDestination> onTap;

  @override
  State<_AppleNativeTabBar> createState() => _AppleNativeTabBarState();
}

class _AppleNativeTabBarState extends State<_AppleNativeTabBar> {
  MethodChannel? _channel;

  Map<String, Object?> _state(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    String? selected;
    for (final destination in widget.destinations) {
      if (destination.branchIndex == widget.currentBranchIndex) {
        selected = destination.id;
        break;
      }
    }
    return <String, Object?>{
      'selectedId': selected,
      'isRtl': Directionality.of(context) == TextDirection.rtl,
      'tintColor': Theme.of(context).colorScheme.primary.toARGB32(),
      'items': <Map<String, Object?>>[
        for (final destination in widget.destinations)
          <String, Object?>{
            'id': destination.id,
            'label': destination.label(l10n),
            'symbol': _appleTabSymbol(destination, selected: false),
            'selectedSymbol': _appleTabSymbol(destination, selected: true),
          },
      ],
    };
  }

  @override
  void didUpdateWidget(covariant _AppleNativeTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _channel?.invokeMethod<void>('update', _state(context));
    });
  }

  void _onPlatformViewCreated(int id) {
    final channel = MethodChannel('com.animewitcher.app/native_tab_bar/$id');
    channel.setMethodCallHandler((call) async {
      if (call.method != 'selected') return;
      final selectedId = call.arguments as String?;
      if (selectedId == null) return;
      for (final destination in widget.destinations) {
        if (destination.id == selectedId) {
          widget.onTap(destination);
          return;
        }
      }
    });
    _channel = channel;
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return UiKitView(
      viewType: _appleNativeTabBarViewType,
      layoutDirection: Directionality.of(context),
      creationParams: _state(context),
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _onPlatformViewCreated,
    );
  }
}
