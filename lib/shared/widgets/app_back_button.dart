import 'package:flutter/material.dart';

/// The one back affordance used throughout AnimeWitcher.
///
/// It is deliberately direction-independent: Back always occupies the physical
/// left side of a page/player header and always points left, including on RTL
/// Arabic pages. The control is plain chrome with no glass/fill behind it.
class AppBackButton extends StatelessWidget {
  const AppBackButton({
    super.key,
    this.onPressed,
    this.size = 46,
    this.color,
    this.tooltip,
    this.focusNode,
  });

  final VoidCallback? onPressed;
  final double size;
  final Color? color;
  final String? tooltip;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final effectiveOnPressed =
        onPressed ?? () => Navigator.of(context).maybePop();
    final effectiveTooltip =
        tooltip ?? MaterialLocalizations.of(context).backButtonTooltip;
    final foreground = color ?? Theme.of(context).colorScheme.onSurface;

    return Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox.square(
        dimension: size,
        child: IconButton(
          focusNode: focusNode,
          tooltip: effectiveTooltip,
          onPressed: effectiveOnPressed,
          style: IconButton.styleFrom(
            backgroundColor: Colors.transparent,
            foregroundColor: foreground,
            padding: EdgeInsets.zero,
          ),
          icon: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: size * 0.58,
            color: foreground,
          ),
        ),
      ),
    );
  }
}
