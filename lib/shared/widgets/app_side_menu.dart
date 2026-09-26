import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/account/account_providers.dart';
import '../../core/navigation/taskbar_destination.dart';
import '../../l10n/generated/app_localizations.dart';
import 'account_avatar_button.dart';

bool _arabic(BuildContext context) =>
    Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

/// A row of the side menu that is not a tab: one of the pages the More tab
/// used to hold, opened over the app.
class AppSideMenuEntry {
  const AppSideMenuEntry({
    required this.id,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String id;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// Lets a page open the side menu from a button of its own. Present only
/// while the side-menu layout is drawn, so a page that asks outside it gets
/// nothing and draws no button.
class AppSideMenuScope extends InheritedWidget {
  const AppSideMenuScope({super.key, required this.open, required super.child});

  /// Slides the page aside and shows the menu.
  final VoidCallback open;

  static AppSideMenuScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppSideMenuScope>();

  @override
  bool updateShouldNotify(AppSideMenuScope oldWidget) => open != oldWidget.open;
}

/// The round menu button a page puts in its top-left corner, the way the
/// side menu comes from that side. Draws nothing unless the side-menu layout
/// is on.
class AppSideMenuButton extends StatelessWidget {
  const AppSideMenuButton({
    super.key,
    this.overArtwork = false,
    this.padding = EdgeInsets.zero,
  });

  /// White on dark glass, for home's artwork.
  final bool overArtwork;

  /// Room around the button, kept only when there is a button.
  final EdgeInsetsGeometry padding;

  static const double size = 40;

  @override
  Widget build(BuildContext context) {
    final scope = AppSideMenuScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final foreground = overArtwork ? Colors.white : colors.onSurface;
    return Padding(
      padding: padding,
      child: Tooltip(
        message: _arabic(context) ? 'القائمة' : 'Menu',
        child: Material(
          color: overArtwork
              ? Colors.black.withValues(alpha: 0.35)
              : colors.surfaceContainerHighest.withValues(alpha: 0.7),
          shape: CircleBorder(
            side: BorderSide(color: foreground.withValues(alpha: 0.12)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey<String>('app-side-menu-button'),
            onTap: scope.open,
            child: SizedBox.square(
              dimension: size,
              child: Icon(Icons.menu_rounded, size: 22, color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}

/// The phone layout without a bar: the pages fill the screen, and pulling
/// one to the right — or its menu button — slides it aside to uncover a menu
/// on the left, the account at its head and the pages under it, as ChatGPT
/// keeps its chats. The ✕ in the menu's top-left corner, a tap on the page
/// peeking out beside it, a pull back to the left or the back button close
/// it again.
class AppSideMenuShell extends StatefulWidget {
  const AppSideMenuShell({
    super.key,
    required this.destinations,
    required this.currentBranchIndex,
    required this.onDestination,
    required this.onAccount,
    required this.canOpen,
    required this.canPopWhenClosed,
    required this.onBackWhenClosed,
    required this.child,
    this.entries = const <AppSideMenuEntry>[],
  });

  /// The pages under the tabs, after a divider.
  final List<AppSideMenuEntry> entries;

  final List<TaskbarDestination> destinations;
  final int currentBranchIndex;
  final ValueChanged<TaskbarDestination> onDestination;
  final VoidCallback onAccount;

  /// Whether a pull may open the menu: not over a page pushed inside a tab,
  /// where the same pull is how one goes back.
  final bool Function() canOpen;

  /// What the back button does with the menu shut: leave the app, or...
  final bool canPopWhenClosed;

  /// ...go back to the start tab.
  final VoidCallback onBackWhenClosed;

  final Widget child;

  /// The menu's width: most of a phone, never more than a comfortable column.
  static double menuWidthFor(double screenWidth) =>
      math.min(screenWidth * 0.8, 320);

  @override
  State<AppSideMenuShell> createState() => _AppSideMenuShellState();
}

class _AppSideMenuShellState extends State<AppSideMenuShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _menu = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  )..addListener(_onTick);

  /// Whether the pull under way moves the menu; decided as it starts.
  bool _dragging = false;

  /// Shut all the way. Read from where the menu is rather than from the
  /// animation's status, which an animation run down to nothing reports as
  /// completed.
  bool _closed = true;

  void _onTick() {
    final closed = _menu.value == 0;
    // Open or shut decides what the back button does; nothing else here
    // needs a rebuild as the menu moves.
    if (closed != _closed) setState(() => _closed = closed);
  }

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  void _open() {
    // A search field's keyboard would otherwise stay up over the menu.
    FocusManager.instance.primaryFocus?.unfocus();
    _menu.animateTo(1, curve: Curves.easeOutCubic);
  }

  void _close() => _menu.animateBack(0, curve: Curves.easeOutCubic);

  void _onDragStart(DragStartDetails details) {
    _dragging = !_closed || widget.canOpen();
    if (!_dragging) return;
    _menu.stop();
    if (_closed) FocusManager.instance.primaryFocus?.unfocus();
  }

  void _onDragUpdate(DragUpdateDetails details, double width) {
    if (!_dragging) return;
    // Physical right opens, whichever way the text reads: the menu is on
    // the left.
    final delta = (details.primaryDelta ?? 0) / width;
    _menu.value = (_menu.value + delta).clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final velocity = details.velocity.pixelsPerSecond.dx;
    if (velocity.abs() >= 365) {
      velocity > 0 ? _open() : _close();
    } else {
      _menu.value >= 0.5 ? _open() : _close();
    }
  }

  void _pick(TaskbarDestination destination) {
    HapticFeedback.selectionClick();
    _close();
    widget.onDestination(destination);
  }

  void _entry(AppSideMenuEntry entry) {
    _close();
    entry.onTap();
  }

  void _account() {
    _close();
    widget.onAccount();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _closed && widget.canPopWhenClosed,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (!_closed) {
          _close();
          return;
        }
        widget.onBackWhenClosed();
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = AppSideMenuShell.menuWidthFor(constraints.maxWidth);
          GestureDetector draggable({
            Key? key,
            required Widget child,
            HitTestBehavior behavior = HitTestBehavior.translucent,
            VoidCallback? onTap,
          }) => GestureDetector(
            key: key,
            behavior: behavior,
            onTap: onTap,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: (details) => _onDragUpdate(details, width),
            onHorizontalDragEnd: _onDragEnd,
            child: child,
          );

          return ColoredBox(
            color: colors.surfaceContainerLow,
            child: AnimatedBuilder(
              animation: _menu,
              // The pages, built once: only where they are drawn moves.
              child: AppSideMenuScope(open: _open, child: widget.child),
              builder: (context, page) {
                final t = _menu.value;
                final radius = 28 * t;
                return Stack(
                  children: [
                    // Under the page, sliding in a little behind it.
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: width,
                      child: Offstage(
                        offstage: t == 0,
                        child: Transform.translate(
                          offset: Offset(-(1 - t) * width * 0.3, 0),
                          child: draggable(
                            child: AppSideMenuPanel(
                              destinations: widget.destinations,
                              currentBranchIndex: widget.currentBranchIndex,
                              entries: widget.entries,
                              onDestination: _pick,
                              onEntry: _entry,
                              onAccount: _account,
                              onClose: _close,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: Transform.translate(
                        offset: Offset(t * width, 0),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(radius),
                            boxShadow: t == 0
                                ? null
                                : [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.35 * t,
                                      ),
                                      blurRadius: 24,
                                    ),
                                  ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(radius),
                            clipBehavior: t == 0 ? Clip.none : Clip.antiAlias,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                draggable(child: page!),
                                // The page peeking out is for closing the
                                // menu, not for using.
                                if (t > 0)
                                  draggable(
                                    key: const ValueKey<String>(
                                      'app-side-menu-scrim',
                                    ),
                                    behavior: HitTestBehavior.opaque,
                                    onTap: _close,
                                    child: ColoredBox(
                                      color: Colors.black.withValues(
                                        alpha: 0.3 * t,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// The menu: the account across the top with ✕ in its left corner, then the
/// pages, the one showing marked.
class AppSideMenuPanel extends ConsumerWidget {
  const AppSideMenuPanel({
    super.key,
    required this.destinations,
    required this.currentBranchIndex,
    required this.onDestination,
    required this.onAccount,
    required this.onClose,
    this.entries = const <AppSideMenuEntry>[],
    this.onEntry,
  });

  final List<TaskbarDestination> destinations;
  final List<AppSideMenuEntry> entries;
  final ValueChanged<AppSideMenuEntry>? onEntry;
  final int currentBranchIndex;
  final ValueChanged<TaskbarDestination> onDestination;
  final VoidCallback onAccount;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final arabic = _arabic(context);
    final profile = ref
        .watch(animeWitcherAccountControllerProvider)
        .asData
        ?.value
        .profile;
    final userName = profile?.userName?.trim() ?? '';
    final email = profile?.email?.trim() ?? '';
    final title = profile == null
        ? (arabic ? 'تسجيل الدخول' : 'Sign in')
        : (userName.isNotEmpty ? userName : email);
    final subtitle = profile == null
        ? (arabic ? 'مزامنة القوائم والتقدم' : 'Sync your lists and progress')
        : (userName.isNotEmpty ? email : '');

    return Material(
      key: const ValueKey<String>('app-side-menu'),
      color: colors.surfaceContainerLow,
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
              // Left to right on purpose: ✕ in the top-left corner, the
              // account across from it, whichever way the text reads.
              child: Row(
                textDirection: TextDirection.ltr,
                children: [
                  IconButton(
                    key: const ValueKey<String>('app-side-menu-close'),
                    tooltip: arabic ? 'إغلاق' : 'Close',
                    onPressed: onClose,
                    icon: Icon(
                      Icons.close_rounded,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      key: const ValueKey<String>('app-side-menu-account'),
                      borderRadius: BorderRadius.circular(16),
                      onTap: onAccount,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            AccountAvatarButton(onTap: onAccount, size: 44),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (subtitle.isNotEmpty)
                                    Text(
                                      subtitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: colors.onSurfaceVariant,
                                          ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: colors.outlineVariant.withValues(alpha: 0.5),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                children: [
                  for (final destination in destinations)
                    _SideMenuRow(
                      key: ValueKey<String>('app-side-menu-${destination.id}'),
                      icon: destination.branchIndex == currentBranchIndex
                          ? destination.selectedIcon
                          : destination.icon,
                      label: destination.label(l10n),
                      selected: destination.branchIndex == currentBranchIndex,
                      onTap: () => onDestination(destination),
                    ),
                  if (entries.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Divider(
                        height: 1,
                        indent: 4,
                        endIndent: 4,
                        color: colors.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                  for (final entry in entries)
                    _SideMenuRow(
                      key: ValueKey<String>('app-side-menu-page-${entry.id}'),
                      icon: entry.icon,
                      label: entry.label,
                      selected: false,
                      onTap: () => onEntry?.call(entry),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SideMenuRow extends StatelessWidget {
  const _SideMenuRow({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = colors.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Material(
          color: selected ? accent.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 24,
                    color: selected ? accent : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ExcludeSemantics(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: selected ? colors.onSurface : null,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
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
