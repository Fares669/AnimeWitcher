import 'package:flutter/material.dart';

/// Shared geometry for the editable search field and its action capsule.
class SearchGlassSurface extends StatelessWidget {
  const SearchGlassSurface({super.key, required this.child});

  static const double height = 48;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Plain, as the library's search field is: a filled pill, with no
    // glass or blur behind it.
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(height / 2),
      ),
      child: child,
    );
  }
}
