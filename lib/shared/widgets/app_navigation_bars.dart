import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/navigation/taskbar_destination.dart';
import '../../core/utils/responsive_breakpoints.dart';
import '../../l10n/generated/app_localizations.dart';
import 'account_avatar_button.dart';

/// Room left at the window's right edge for the caption buttons
/// (minimise, maximise, close), which the title bar draws over everything.
double _captionButtonsReserve() => !kIsWeb && Platform.isWindows ? 150.0 : 0.0;

/// The side-rail layout: a narrow column of icons with their names under
/// them, on the reading-start edge of the window.
class AppSideRail extends StatelessWidget {
  const AppSideRail({
    super.key,
    required this.destinations,
    required this.currentBranchIndex,
    required this.onTap,
    required this.onNews,
    required this.onAccount,
  });

  static const double width = 76;

  final List<TaskbarDestination> destinations;
  final int currentBranchIndex;
  final ValueChanged<TaskbarDestination> onTap;

  /// Opens the news; this layout takes the news row off the home page.
  final VoidCallback onNews;

  /// Opens the account, from the picture at the foot of the rail.
  final VoidCallback onAccount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accent = Theme.of(context).colorScheme.primary;
    final arabic = l10n.localeName.toLowerCase().startsWith('ar');
    return Container(
      width: width,
      // A step up from the page, in the theme's own colours.
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      // Clear of the title bar on a desktop, where the window is dragged
      // from, and of the status bar on a tablet.
      padding: EdgeInsets.only(
        top: ResponsiveBreakpoints.isDesktopPlatform()
            ? 64
            : MediaQuery.viewPaddingOf(context).top + 16,
        bottom: 16,
      ),
      child: Column(
        children: [
          ..._destinationItems(l10n, accent),
          const Spacer(),
          _RailItem(
            icon: Icons.newspaper_rounded,
            label: arabic ? 'الأخبار' : 'News',
            selected: false,
            accent: accent,
            onTap: onNews,
          ),
          const SizedBox(height: 8),
          // The account last, at the foot of the rail, as Harbor has it.
          AccountAvatarButton(onTap: onAccount, size: 40),
        ],
      ),
    );
  }

  Iterable<Widget> _destinationItems(AppLocalizations l10n, Color accent) {
    return [
      for (final destination in destinations)
        _RailItem(
          icon: destination.branchIndex == currentBranchIndex
              ? destination.selectedIcon
              : destination.icon,
          label: destination.label(l10n),
          selected: destination.branchIndex == currentBranchIndex,
          accent: accent,
          onTap: () => onTap(destination),
        ),
    ];
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? accent
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 48,
                    height: 30,
                    decoration: BoxDecoration(
                      color: selected
                          ? accent.withValues(alpha: 0.18)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Icon(icon, size: 22, color: color),
                  ),
                  const SizedBox(height: 4),
                  ExcludeSemantics(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
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

/// The top-bar layout: the app's name and its pages by name, across the top
/// of the window. Translucent over home's artwork, solid everywhere else.
class AppTopBar extends StatelessWidget {
  const AppTopBar({
    super.key,
    required this.destinations,
    required this.currentBranchIndex,
    required this.overArtwork,
    required this.onTap,
    required this.onNews,
    required this.onAccount,
  });

  /// The same height as the title bar, so the page names sit on one line
  /// with the caption buttons.
  static const double height = 56;

  /// The bar's full height: [height], plus the status bar on a tablet,
  /// which the bar sits below rather than behind.
  static double totalHeight(BuildContext context) =>
      height +
      (ResponsiveBreakpoints.isDesktopPlatform()
          ? 0
          : MediaQuery.viewPaddingOf(context).top);

  final List<TaskbarDestination> destinations;
  final int currentBranchIndex;
  final bool overArtwork;
  final ValueChanged<TaskbarDestination> onTap;
  final VoidCallback onNews;
  final VoidCallback onAccount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accent = Theme.of(context).colorScheme.primary;
    final foreground = overArtwork
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    final reserve = _captionButtonsReserve();
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: totalHeight(context),
      padding: EdgeInsets.only(top: totalHeight(context) - height),
      decoration: BoxDecoration(
        color: overArtwork
            ? Colors.black.withValues(alpha: 0.35)
            : Theme.of(context).colorScheme.surfaceContainerLow,
      ),
      child: Stack(
        children: [
          // The name in the left corner, opposite the caption buttons, with
          // the news beside it: this layout takes the news off home.
          Positioned(
            left: 24,
            top: 0,
            bottom: 0,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Row(
                children: [
                  Text(
                    'AnimeWitcher',
                    style: TextStyle(
                      color: accent,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 10),
                  // The account right after the name, then the news.
                  AccountAvatarButton(onTap: onAccount, size: 32),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: l10n.localeName.toLowerCase().startsWith('ar')
                        ? 'الأخبار'
                        : 'News',
                    onPressed: onNews,
                    icon: Icon(
                      Icons.newspaper_rounded,
                      color: foreground.withValues(alpha: 0.8),
                      size: 22,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // The pages centred on the window, clear of both corners.
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 260 + reserve / 2),
            child: Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final destination in destinations)
                      _TopBarItem(
                        label: destination.label(l10n),
                        icon: destination.branchIndex == currentBranchIndex
                            ? destination.selectedIcon
                            : destination.icon,
                        selected: destination.branchIndex == currentBranchIndex,
                        accent: accent,
                        foreground: foreground,
                        onTap: () => onTap(destination),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBarItem extends StatelessWidget {
  const _TopBarItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.accent,
    required this.onTap,
    required this.foreground,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  /// White over home's artwork, the theme's text colour everywhere else.
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final color = selected ? foreground : foreground.withValues(alpha: 0.65);
    return Semantics(
      button: true,
      selected: selected,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(end: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(99),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: selected
                  ? foreground.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: selected ? accent : color),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
