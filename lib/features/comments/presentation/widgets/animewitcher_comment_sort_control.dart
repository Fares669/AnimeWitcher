import 'package:flutter/material.dart';

import 'package:animewitcher/core/account/animewitcher_comment_models.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:animewitcher/shared/widgets/animated_sort_menu_button.dart';
import '../../../../core/utils/window_controls_inset.dart';

/// Shared key for the details comments/reviews trailing sort control.
///
/// Account **تعليقاتي** / **مراجعاتي** reuse this same widget so tests can
/// assert one implementation across those headers.
const Key kAnimeWitcherCommentSortControlKey = Key(
  'animewitcher-comment-sort-control',
);

/// Trailing sort control used by anime-details comments/reviews and by
/// account my-comments / my-reviews.
///
/// On iOS this is the persistent Liquid Glass toolbar button. On Android and
/// desktop it is [AppleNativeMenuButton] with the details header size, icon,
/// and padding. Callers must not reimplement that chrome.
class AnimeWitcherCommentSortControl extends StatelessWidget {
  const AnimeWitcherCommentSortControl({
    super.key,
    required this.tooltip,
    required this.selectedValue,
    required this.items,
    required this.onSelected,
  });

  /// Details comments/reviews non-iOS control size.
  static const double size = 46;

  /// Details comments/reviews non-iOS control width.
  static const double width = size;

  /// Matches the persistent back button's physical leading inset on iOS.
  /// Keeping both controls 8pt from their respective edges mirrors their
  /// centers around the middle of the screen.
  static const double persistentTrailingInset = 8;

  /// Space kept between the page title and the compact 46pt sort control.
  /// The old 92pt value was sized for the former wide, titled menu button and
  /// left Arabic titles noticeably too far toward the center.
  static const double persistentTitleClearance = 64;

  static const String systemImage = 'arrow.up.arrow.down';
  static const IconData fallbackIcon = Icons.filter_list_rounded;

  final String tooltip;
  final String selectedValue;
  final List<AppleNativeMenuItem> items;
  final ValueChanged<String> onSelected;

  static String labelFor(AnimeWitcherCommentSort sort, bool isArabic) {
    return switch (sort) {
      AnimeWitcherCommentSort.newest => isArabic ? 'الأحدث' : 'Newest',
      AnimeWitcherCommentSort.oldest => isArabic ? 'الأقدم' : 'Oldest',
      AnimeWitcherCommentSort.mostLiked =>
        isArabic ? 'الأكثر اعجابا' : 'Most liked',
    };
  }

  static String systemImageFor(AnimeWitcherCommentSort sort) {
    return switch (sort) {
      AnimeWitcherCommentSort.newest => 'clock',
      AnimeWitcherCommentSort.oldest => 'clock.arrow.circlepath',
      AnimeWitcherCommentSort.mostLiked => 'heart',
    };
  }

  static IconData fallbackIconFor(AnimeWitcherCommentSort sort) {
    return switch (sort) {
      AnimeWitcherCommentSort.newest => Icons.schedule_rounded,
      AnimeWitcherCommentSort.oldest => Icons.history_rounded,
      AnimeWitcherCommentSort.mostLiked => Icons.favorite_border_rounded,
    };
  }

  static List<AppleNativeMenuItem> menuItems(bool isArabic) {
    return <AppleNativeMenuItem>[
      AppleNativeMenuItem(
        value: AnimeWitcherCommentSort.newest.name,
        label: labelFor(AnimeWitcherCommentSort.newest, isArabic),
        systemImage: systemImageFor(AnimeWitcherCommentSort.newest),
        icon: fallbackIconFor(AnimeWitcherCommentSort.newest),
      ),
      AppleNativeMenuItem(
        value: AnimeWitcherCommentSort.oldest.name,
        label: labelFor(AnimeWitcherCommentSort.oldest, isArabic),
        systemImage: systemImageFor(AnimeWitcherCommentSort.oldest),
        icon: fallbackIconFor(AnimeWitcherCommentSort.oldest),
      ),
      AppleNativeMenuItem(
        value: AnimeWitcherCommentSort.mostLiked.name,
        label: labelFor(AnimeWitcherCommentSort.mostLiked, isArabic),
        systemImage: systemImageFor(AnimeWitcherCommentSort.mostLiked),
        icon: fallbackIconFor(AnimeWitcherCommentSort.mostLiked),
      ),
    ];
  }

  static double persistentWidth(bool isArabic) => size;

  /// iOS persistent Liquid Glass trailing button from the details header.
  static List<AppleLiquidGlassToolbarButton> persistentButtons({
    required BuildContext context,
    required bool isArabic,
    required String tooltip,
    required AnimeWitcherCommentSort sort,
    required ValueChanged<String> onSelected,
  }) {
    final colors = Theme.of(context).colorScheme;
    return <AppleLiquidGlassToolbarButton>[
      AppleLiquidGlassToolbarButton(
        width: persistentWidth(isArabic),
        tooltip: tooltip,
        icon: fallbackIconFor(sort),
        systemImage: systemImageFor(sort),
        // The selected value stays visible in the menu itself. Keeping the
        // persistent chrome icon-only lets its 46pt circle mirror Back exactly.
        title: null,
        color: colors.primary,
        menuTintColor: colors.primary,
        onPressed: null,
        selectedMenuValue: sort.name,
        menuItems: menuItems(isArabic),
        onMenuSelected: onSelected,
      ),
    ];
  }

  /// AppBar `actions` used by details comments/reviews on non-iOS.
  static List<Widget> appBarActions({
    required String tooltip,
    required String selectedValue,
    required List<AppleNativeMenuItem> items,
    required ValueChanged<String> onSelected,
  }) {
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: AnimeWitcherCommentSortControl(
          key: kAnimeWitcherCommentSortControlKey,
          tooltip: tooltip,
          selectedValue: selectedValue,
          items: items,
          onSelected: onSelected,
        ),
      ),
      // Every header that takes these holds itself left to right, so this is
      // the corner the window paints its caption buttons over — the sort
      // control would sit underneath them, where it cannot be clicked.
      const WindowControlsGap(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final selected = AnimeWitcherCommentSort.values.firstWhere(
      (value) => value.name == selectedValue,
      orElse: () => AnimeWitcherCommentSort.commentsDefault,
    );
    return SizedBox(
      width: width,
      height: size,
      child: AnimatedSortMenuButton(
        tooltip: tooltip,
        selectedValue: selectedValue,
        items: items,
        onSelected: onSelected,
        icon: fallbackIconFor(selected),
        systemImage: systemImageFor(selected),
        tintColor: Theme.of(context).colorScheme.primary,
        size: size,
        fallbackIcon: fallbackIcon,
      ),
    );
  }
}
