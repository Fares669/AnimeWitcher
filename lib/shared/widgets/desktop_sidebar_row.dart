import 'package:flutter/widgets.dart';

/// Shared chrome and hover state for the More and Library desktop sidebar rows.
abstract class DesktopSidebarRowState<T extends StatefulWidget>
    extends State<T> {
  bool _hovered = false;

  @protected
  Widget buildRow({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required double verticalPadding,
    required Color accent,
    required Color onSurface,
    required Color onSurfaceVariant,
    required TextStyle? labelStyle,
    Widget? trailing,
  }) {
    final background = selected
        ? accent.withValues(alpha: 0.13)
        : _hovered
        ? onSurface.withValues(alpha: 0.06)
        : const Color(0x00000000);
    final foreground = selected
        ? onSurface
        : _hovered
        ? onSurface.withValues(alpha: 0.9)
        : onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Semantics(
          button: true,
          selected: selected,
          label: label,
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 130),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(12),
              ),
              padding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: verticalPadding,
              ),
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
                  Icon(icon, size: 20, color: selected ? accent : foreground),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: labelStyle?.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
