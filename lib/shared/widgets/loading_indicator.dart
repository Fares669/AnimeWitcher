import 'package:flutter/material.dart';

/// App-wide loading spinner.
///
/// Uses the same circular [CircularProgressIndicator] as the global
/// statistics screen, instead of the morphing polygon animation.
class AppLoadingIndicator extends StatelessWidget {
  /// The color of the loading indicator. If null, the theme's primary color is used.
  final Color? color;

  /// Sizing constraints for the indicator. Defaults to Material's 36x36 spinner.
  final BoxConstraints? constraints;

  const AppLoadingIndicator({super.key, this.color, this.constraints});

  @override
  Widget build(BuildContext context) {
    if (constraints == null) {
      return CircularProgressIndicator(color: color);
    }

    final double width =
        constraints!.hasBoundedWidth ? constraints!.maxWidth : 36.0;
    final double height =
        constraints!.hasBoundedHeight ? constraints!.maxHeight : 36.0;
    final double size = width < height ? width : height;
    final double strokeWidth = (size * 0.11).clamp(2.0, 4.0);

    return SizedBox(
      width: width,
      height: height,
      child: CircularProgressIndicator(
        color: color,
        strokeWidth: strokeWidth,
      ),
    );
  }
}
