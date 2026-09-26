import 'package:flutter/material.dart';

import 'apple_liquid_glass.dart';

/// Shared sort trigger used by Search and comment/review lists.
///
/// The current sort glyph is the button: no disclosure arrow is drawn. Opening
/// the menu hides that glyph with the same fade/scale/slide motion everywhere,
/// then restores it when the popup closes.
class AnimatedSortMenuButton extends StatefulWidget {
  const AnimatedSortMenuButton({
    super.key,
    required this.tooltip,
    required this.selectedValue,
    required this.items,
    required this.onSelected,
    required this.icon,
    required this.systemImage,
    this.tintColor,
    this.size = 46,
    this.fallbackIcon = Icons.swap_vert_rounded,
  });

  final String tooltip;
  final String selectedValue;
  final List<AppleNativeMenuItem> items;
  final ValueChanged<String> onSelected;
  final IconData icon;
  final String? systemImage;
  final Color? tintColor;
  final double size;
  final IconData fallbackIcon;

  @override
  State<AnimatedSortMenuButton> createState() => _AnimatedSortMenuButtonState();
}

class _AnimatedSortMenuButtonState extends State<AnimatedSortMenuButton> {
  static const _hideDuration = Duration(milliseconds: 160);
  static const _showDuration = Duration(milliseconds: 200);

  bool _menuOpen = false;

  void _setMenuOpen(bool open) {
    if (!mounted || _menuOpen == open) return;
    setState(() => _menuOpen = open);
  }

  String? _textGlyph(String? systemImage) => switch (systemImage) {
    'animewitcher.abc' => 'ABC',
    'animewitcher.zyx' => 'ZYX',
    _ => null,
  };

  Widget _glyph(
    Color tint, {
    required IconData icon,
    required String? systemImage,
    double iconSize = 22,
    double textSize = 15,
  }) {
    final textGlyph = _textGlyph(systemImage);
    if (textGlyph != null) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          textGlyph,
          maxLines: 1,
          style: TextStyle(
            color: tint,
            fontSize: textSize,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
            height: 1,
          ),
        ),
      );
    }
    return Icon(icon, size: iconSize, color: tint);
  }

  @override
  Widget build(BuildContext context) {
    final tint = widget.tintColor ?? Theme.of(context).colorScheme.primary;
    final visible = !_menuOpen;
    final animatedGlyph = AnimatedOpacity(
      key: const ValueKey<String>('animated-sort-glyph'),
      opacity: visible ? 1 : 0,
      duration: visible ? _showDuration : _hideDuration,
      curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
      child: AnimatedScale(
        scale: visible ? 1 : 0.88,
        duration: visible ? _showDuration : _hideDuration,
        curve: visible ? Curves.easeOutBack : Curves.easeInCubic,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, -0.18),
          duration: visible ? _showDuration : _hideDuration,
          curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
          child: _glyph(
            tint,
            icon: widget.icon,
            systemImage: widget.systemImage,
          ),
        ),
      ),
    );

    return PopupMenuButton<String>(
      tooltip: widget.tooltip,
      padding: EdgeInsets.zero,
      offset: const Offset(0, 8),
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      onOpened: () => _setMenuOpen(true),
      onCanceled: () => _setMenuOpen(false),
      itemBuilder: (menuContext) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: BlurredMenuPanel(
            items: widget.items,
            selectedValue: widget.selectedValue,
            tint: tint,
            fallbackIcon: widget.fallbackIcon,
            leadingBuilder: (item, color) => _glyph(
              color,
              icon: item.icon ?? widget.fallbackIcon,
              systemImage: item.systemImage,
              iconSize: 18,
              textSize: 11.5,
            ),
            onPick: (value) {
              Navigator.of(menuContext).pop();
              _setMenuOpen(false);
              widget.onSelected(value);
            },
          ),
        ),
      ],
      child: SizedBox.square(
        dimension: widget.size,
        child: Center(child: animatedGlyph),
      ),
    );
  }
}
