/// The More screen as two panes: what there is, and the one being read.
///
/// On a phone these destinations are a list you tap through, one screen at a
/// time. A desktop window has room to keep the list on screen while you read
/// a destination, which is how a settings window has worked since settings
/// windows existed — and it opens on the account rather than on nothing.
library;

import 'package:flutter/material.dart';

import '../../../core/utils/localized_text.dart';
import '../../../shared/widgets/apple_liquid_glass.dart';

/// Marks the subtree as a pane inside [MoreSidebarShell].
///
/// The screens shown here are the same ones a handset pushes as full routes,
/// and they carry a back button for that case. In a pane there is nothing to
/// go back to — the sidebar beside them is how you leave — so they ask this
/// whether to draw one.
class MorePaneScope extends InheritedWidget {
  const MorePaneScope({super.key, required super.child});

  /// True when the screen is embedded in the More sidebar rather than pushed.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MorePaneScope>() != null;

  @override
  bool updateShouldNotify(MorePaneScope oldWidget) => false;
}

/// One destination in the sidebar.
class MoreDestination {
  const MoreDestination({
    required this.icon,
    required this.label,
    required this.builder,
  });

  final IconData icon;
  final String label;
  final WidgetBuilder builder;
}

/// A run of destinations under one heading.
class MoreDestinationGroup {
  const MoreDestinationGroup({required this.heading, required this.items});

  final String heading;
  final List<MoreDestination> items;
}

/// The sidebar, its heading rows, and the pane beside it.
class MoreSidebarShell extends StatefulWidget {
  const MoreSidebarShell({
    super.key,
    required this.groups,
    required this.header,
    this.initialGroup = 0,
    this.initialItem = 0,
  });

  final List<MoreDestinationGroup> groups;

  /// Drawn above the first heading — the signed-in account, in practice.
  final Widget header;

  final int initialGroup;
  final int initialItem;

  @override
  State<MoreSidebarShell> createState() => _MoreSidebarShellState();
}

class _MoreSidebarShellState extends State<MoreSidebarShell> {
  late int _group = widget.initialGroup;
  late int _item = widget.initialItem;

  MoreDestination? get _selected {
    if (_group >= widget.groups.length) return null;
    final items = widget.groups[_group].items;
    if (_item >= items.length) return null;
    return items[_item];
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selected = _selected;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 272,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
            children: [
              widget.header,
              const SizedBox(height: 18),
              for (var g = 0; g < widget.groups.length; g++) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                  child: Text(
                    widget.groups[g].heading,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                for (var i = 0; i < widget.groups[g].items.length; i++)
                  _SidebarRow(
                    destination: widget.groups[g].items[i],
                    selected: g == _group && i == _item,
                    onTap: () => setState(() {
                      _group = g;
                      _item = i;
                    }),
                  ),
              ],
            ],
          ),
        ),
        Expanded(
          child: selected == null
              ? const SizedBox.shrink()
              // Keyed by which destination is showing, so moving between two
              // of them builds the new one rather than handing it the last
              // one's scroll position and state.
              : KeyedSubtree(
                  key: ValueKey<String>('more-pane-${_group}-$_item'),
                  child: MorePaneScope(
                    child: Builder(builder: selected.builder),
                  ),
                ),
        ),
      ],
    );
  }
}

/// One destination in the sidebar.
///
/// A column of thirteen filled cards is thirteen things shouting at once, and
/// the one you are reading has to shout louder still to be found. So the list
/// is quiet — glyph and name, nothing drawn around them — and everything the
/// row has to say is spent on which one is current: a bar at the edge you
/// read from, an accent tint behind it, and its name in full white. One loud
/// element in a calm column is easier to find than the loudest of thirteen.
///
/// The pointer gets its own answer, a shade lighter than the page, and both
/// states fade rather than snap, which is the difference between a list that
/// responds and one that flickers.
class _SidebarRow extends StatefulWidget {
  const _SidebarRow({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final MoreDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<_SidebarRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selected = widget.selected;
    final accent = colors.primary;

    final background = selected
        ? accent.withValues(alpha: 0.13)
        : _hovered
        ? colors.onSurface.withValues(alpha: 0.06)
        : Colors.transparent;
    final foreground = selected
        ? colors.onSurface
        : _hovered
        ? colors.onSurface.withValues(alpha: 0.9)
        : colors.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Semantics(
          button: true,
          selected: selected,
          label: widget.destination.label,
          child: GestureDetector(
            onTap: widget.onTap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 130),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
              child: Row(
                children: [
                  // The mark of where you are, at the edge the language starts
                  // from. It holds its width when absent so the names below it
                  // do not shift as the selection moves.
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 130),
                    curve: Curves.easeOut,
                    width: 3,
                    height: selected ? 18 : 0,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Icon(
                    widget.destination.icon,
                    size: 20,
                    color: selected ? accent : foreground,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.destination.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: foreground,
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

/// The signed-in account, drawn at the top of the sidebar.
class MoreSidebarHeader extends StatelessWidget {
  const MoreSidebarHeader({
    super.key,
    required this.name,
    required this.subtitle,
    this.photoUrl,
  });

  final String name;
  final String subtitle;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final photo = photoUrl?.trim() ?? '';

    return AppleLiquidGlassSurface(
      borderRadius: BorderRadius.circular(14),
      fallbackColor: colors.surfaceContainerHighest.withValues(alpha: 0.4),
      fallbackBorder: BorderSide(
        color: colors.onSurfaceVariant.withValues(alpha: 0.1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: colors.surfaceContainerHighest,
              backgroundImage: photo.isEmpty ? null : NetworkImage(photo),
              child: photo.isEmpty
                  ? Icon(
                      Icons.person_rounded,
                      size: 20,
                      color: colors.onSurfaceVariant,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
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

/// Shared wording for the sidebar's headings.
String moreHeadingSetup(BuildContext context) =>
    appText(context, english: 'ACCOUNT', arabic: 'الحساب');

String moreHeadingBrowse(BuildContext context) =>
    appText(context, english: 'BROWSE', arabic: 'التصفح');

String moreHeadingApp(BuildContext context) =>
    appText(context, english: 'APP', arabic: 'التطبيق');
