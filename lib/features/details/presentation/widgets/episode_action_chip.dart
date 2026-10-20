/// The small actions at the end of an episode row.
///
/// Bare glyphs, the way Harbor draws them: no box, no border, nothing around
/// them competing with the artwork beside them. What they get instead is a
/// tap target bigger than the glyph and a colour that answers the pointer, so
/// they still read as buttons when reached for.
library;

import 'package:flutter/material.dart';

class EpisodeActionChip extends StatefulWidget {
  static const double defaultSize = 34;

  const EpisodeActionChip({
    super.key,
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.child,
    this.color,
    this.size = defaultSize,
  }) : assert(
         icon != null || child != null,
         'a chip shows either a glyph or its own content',
       );

  final String tooltip;
  final VoidCallback onPressed;

  /// The glyph, when the chip is not carrying [child] — a progress ring, say.
  final IconData? icon;
  final Widget? child;

  /// Overrides the glyph colour, for a state that has one of its own.
  final Color? color;
  final double size;

  @override
  State<EpisodeActionChip> createState() => _EpisodeActionChipState();
}

class _EpisodeActionChipState extends State<EpisodeActionChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Resting grey, brightening under the pointer: with no box to light up,
    // the glyph itself has to be what answers a hover.
    final foreground =
        widget.color ?? (_hovered ? colors.onSurface : colors.onSurfaceVariant);

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Semantics(
          button: true,
          label: widget.tooltip,
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onPressed,
              child: SizedBox.square(
                dimension: widget.size,
                child:
                    widget.child ??
                    Icon(widget.icon, size: 21, color: foreground),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
