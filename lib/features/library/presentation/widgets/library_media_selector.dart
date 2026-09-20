import 'package:flutter/material.dart';

import '../../../../shared/widgets/apple_liquid_glass.dart';
import '../library_media_kind.dart';

class LibraryMediaSelector extends StatelessWidget {
  const LibraryMediaSelector({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final LibraryMediaKind selected;
  final ValueChanged<LibraryMediaKind> onSelected;

  String _label(BuildContext context, LibraryMediaKind kind) {
    final ar =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    return switch (kind) {
      LibraryMediaKind.anime => ar ? 'أنمي' : 'Anime',
      LibraryMediaKind.manga => ar ? 'مانجا' : 'Manga',
    };
  }

  IconData _icon(LibraryMediaKind kind) => switch (kind) {
    LibraryMediaKind.anime => Icons.movie_rounded,
    LibraryMediaKind.manga => Icons.menu_book_rounded,
  };

  String _systemImage(LibraryMediaKind kind) => switch (kind) {
    LibraryMediaKind.anime => 'play.rectangle.fill',
    LibraryMediaKind.manga => 'book.closed.fill',
  };

  @override
  Widget build(BuildContext context) {
    final ar =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final tooltip = ar ? 'نوع المكتبة' : 'Library type';
    final color = Theme.of(context).colorScheme.primary;
    final items = <AppleNativeMenuItem>[
      for (final kind in LibraryMediaKind.values)
        AppleNativeMenuItem(
          value: kind.storageKey,
          label: _label(context, kind),
          systemImage: _systemImage(kind),
          icon: _icon(kind),
        ),
    ];

    void select(String value) {
      final next = LibraryMediaKind.fromStorageKey(value);
      if (next != selected) onSelected(next);
    }

    if (appleUsesPersistentLiquidGlassHeader) {
      return Semantics(
        button: true,
        label: tooltip,
        child: AppleNativeMenuButton(
          items: items,
          onSelected: select,
          accessibilityLabel: tooltip,
          systemImage: _systemImage(selected),
          fallbackIcon: _icon(selected),
          selectedValue: selected.storageKey,
          title: _label(context, selected),
          width: 124,
          size: 44,
          tintColor: color,
          cornerRadius: 16,
          showsMenuIndicator: true,
        ),
      );
    }

    return PopupMenuButton<String>(
      tooltip: tooltip,
      onSelected: select,
      itemBuilder: (menuContext) => [
        for (final kind in LibraryMediaKind.values)
          PopupMenuItem<String>(
            value: kind.storageKey,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_icon(kind), color: color),
                const SizedBox(width: 10),
                Text(_label(context, kind)),
              ],
            ),
          ),
      ],
      child: AppleLiquidGlassSurface(
        borderRadius: BorderRadius.circular(22),
        interactive: true,
        child: SizedBox(
          width: 124,
          height: 44,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(_icon(selected), color: color, size: 21),
              const SizedBox(width: 7),
              Text(
                _label(context, selected),
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: color,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
