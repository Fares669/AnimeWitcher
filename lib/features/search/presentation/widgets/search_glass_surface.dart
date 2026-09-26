import 'package:flutter/material.dart';

/// Shared geometry for the editable search field and its action capsule.
class SearchGlassSurface extends StatelessWidget {
  const SearchGlassSurface({
    super.key,
    required this.child,
    this.focusNode,
  });

  static const double height = 48;
  final Widget child;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    Widget surface() {
      final colors = Theme.of(context).colorScheme;
      final focused = focusNode?.hasFocus == true;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: height,
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(height / 2),
          border: Border.all(
            color: focused ? colors.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: child,
      );
    }

    final node = focusNode;
    if (node == null) return surface();
    return ListenableBuilder(
      listenable: node,
      builder: (context, _) => surface(),
    );
  }
}
