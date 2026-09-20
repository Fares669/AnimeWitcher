import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/library_category.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/apple_liquid_glass.dart';
import '../library_provider.dart';
import '../library_media_kind.dart';

/// Library category picker.
///
/// On iPhone the visible control is the native Liquid Glass menu button itself.
/// UIKit therefore owns both the resting glass and the UIMenu transition, so the
/// same surface morphs open and returns without a hidden duplicate underneath.
class LibraryCategorySelector extends ConsumerStatefulWidget {
  const LibraryCategorySelector({
    super.key,
    required this.selected,
    required this.counts,
    required this.mediaKind,
  });

  final LibraryCategory selected;
  final Map<LibraryCategory, int> counts;
  final LibraryMediaKind mediaKind;

  @override
  ConsumerState<LibraryCategorySelector> createState() =>
      _LibraryCategorySelectorState();
}

class _LibraryCategorySelectorState
    extends ConsumerState<LibraryCategorySelector> {
  static const _hideDuration = Duration(milliseconds: 160);
  static const _showDuration = Duration(milliseconds: 200);

  bool _menuOpen = false;

  void _setMenuOpen(bool open) {
    if (!mounted || _menuOpen == open) return;
    setState(() => _menuOpen = open);
  }

  String _categoryLabel(BuildContext context, LibraryCategory category) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    if (widget.mediaKind == LibraryMediaKind.manga) {
      final l10n = AppLocalizations.of(context)!;
      return switch (category) {
        LibraryCategory.favorite => isArabic ? 'المفضلة' : 'Favorites',
        LibraryCategory.watching => l10n.mangaReadingNow,
        LibraryCategory.continueLater => l10n.mangaContinueLater,
        LibraryCategory.planToWatch => l10n.mangaPlanToRead,
        LibraryCategory.completed => l10n.mangaCompletedReading,
        LibraryCategory.notInterested => l10n.mangaNotInterested,
      };
    }
    return switch (category) {
      LibraryCategory.favorite => isArabic ? 'المفضلة' : 'Favorites',
      LibraryCategory.watching => isArabic ? 'أشاهده حاليًا' : 'Watching',
      LibraryCategory.continueLater =>
        isArabic ? 'أكملها لاحقًا' : 'Continue Later',
      LibraryCategory.planToWatch =>
        isArabic ? 'أرغب بمشاهدته' : 'Plan to Watch',
      LibraryCategory.completed => isArabic ? 'تمت مشاهدته' : 'Completed',
      LibraryCategory.notInterested =>
        isArabic ? 'لا أرغب بمشاهدته' : 'Not Interested',
    };
  }

  String _categoryLabelWithCount(
    BuildContext context,
    LibraryCategory category,
  ) {
    return '${_categoryLabel(context, category)} (${widget.counts[category] ?? 0})';
  }

  IconData _categoryIcon(LibraryCategory category) {
    return switch (category) {
      LibraryCategory.favorite => Icons.favorite_rounded,
      LibraryCategory.watching => Icons.play_circle_fill_rounded,
      LibraryCategory.continueLater => Icons.pause_circle_filled_rounded,
      LibraryCategory.planToWatch => Icons.schedule_rounded,
      LibraryCategory.completed => Icons.check_circle_rounded,
      LibraryCategory.notInterested => Icons.block_rounded,
    };
  }

  String _categorySystemImage(LibraryCategory category) {
    return switch (category) {
      LibraryCategory.favorite => 'heart.fill',
      LibraryCategory.watching => 'play.circle.fill',
      LibraryCategory.continueLater => 'pause.circle.fill',
      LibraryCategory.planToWatch => 'clock',
      LibraryCategory.completed => 'checkmark.circle.fill',
      LibraryCategory.notInterested => 'xmark.circle.fill',
    };
  }

  List<AppleNativeMenuItem> _menuItems(BuildContext context) {
    return <AppleNativeMenuItem>[
      for (final category in LibraryCategory.values)
        AppleNativeMenuItem(
          value: category.storageKey,
          label: _categoryLabelWithCount(context, category),
          systemImage: _categorySystemImage(category),
          icon: _categoryIcon(category),
        ),
    ];
  }

  void _selectCategory(String value, LibraryCategory current) {
    final category = LibraryCategory.values.firstWhere(
      (candidate) => candidate.storageKey == value,
      orElse: () => current,
    );
    if (category != current) {
      ref.read(libraryProvider.notifier).selectCategory(category);
    }
  }

  Widget _buildAnimatedContent({
    required Color primary,
    required String label,
  }) {
    final visible = !_menuOpen;
    return AnimatedOpacity(
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_categoryIcon(widget.selected), color: primary, size: 22),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: primary,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.keyboard_arrow_down_rounded, color: primary, size: 22),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final primary = Theme.of(context).colorScheme.primary;
    final label = _categoryLabelWithCount(context, widget.selected);
    final width = isArabic ? 240.0 : 224.0;
    final menuItems = _menuItems(context);
    final accessibilityLabel = isArabic ? 'اختر قائمة' : 'Choose list';
    if (appleUsesPersistentLiquidGlassHeader) {
      return Semantics(
        button: true,
        label: accessibilityLabel,
        child: AppleNativeMenuButton(
          items: menuItems,
          onSelected: (value) => _selectCategory(value, widget.selected),
          accessibilityLabel: accessibilityLabel,
          systemImage: _categorySystemImage(widget.selected),
          fallbackIcon: _categoryIcon(widget.selected),
          selectedValue: widget.selected.storageKey,
          title: label,
          width: width,
          size: 44,
          tintColor: primary,
          cornerRadius: 16,
          showsMenuIndicator: true,
        ),
      );
    }

    final content = _buildAnimatedContent(primary: primary, label: label);
    return _MaterialCategoryMenu(
      selected: widget.selected,
      menuItems: menuItems,
      tintColor: primary,
      accessibilityLabel: accessibilityLabel,
      iconForValue: (value) {
        final category = LibraryCategory.values.firstWhere(
          (candidate) => candidate.storageKey == value,
          orElse: () => widget.selected,
        );
        return _categoryIcon(category);
      },
      onOpened: () => _setMenuOpen(true),
      onClosed: () => _setMenuOpen(false),
      onSelected: (value) {
        _selectCategory(value, widget.selected);
        _setMenuOpen(false);
      },
      child: content,
    );
  }
}

class _MaterialCategoryMenu extends StatelessWidget {
  const _MaterialCategoryMenu({
    required this.selected,
    required this.menuItems,
    required this.tintColor,
    required this.accessibilityLabel,
    required this.iconForValue,
    required this.onSelected,
    required this.onOpened,
    required this.onClosed,
    required this.child,
  });

  final LibraryCategory selected;
  final List<AppleNativeMenuItem> menuItems;
  final Color tintColor;
  final String accessibilityLabel;
  final IconData Function(String value) iconForValue;
  final ValueChanged<String> onSelected;
  final VoidCallback onOpened;
  final VoidCallback onClosed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The popup still places and dismisses the menu; what is drawn is the
    // blurred capsule the rest of the app uses.
    return PopupMenuButton<String>(
      tooltip: accessibilityLabel,
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      onOpened: onOpened,
      onCanceled: onClosed,
      itemBuilder: (menuContext) => [
        PopupMenuItem<String>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: BlurredMenuPanel(
            items: menuItems,
            selectedValue: selected.storageKey,
            tint: tintColor,
            iconForValue: iconForValue,
            onPick: (value) {
              Navigator.of(menuContext).pop();
              onClosed();
              onSelected(value);
            },
          ),
        ),
      ],
      child: child,
    );
  }
}
