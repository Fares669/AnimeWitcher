import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/app_router.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../core/extensions/base_provider.dart';
import '../../home/presentation/view_all_screen.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/account/animewitcher_comment_models.dart';
import '../../comments/presentation/animewitcher_comments_screen.dart';
import '../../../core/utils/image_fallbacks.dart';
import 'details_item_merge.dart';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:skystream/core/utils/layout_constants.dart';
import 'package:skystream/core/utils/responsive_breakpoints.dart';

import 'package:skystream/shared/widgets/custom_widgets.dart';
import 'package:skystream/shared/widgets/apple_liquid_glass.dart';

import '../../library/presentation/library_provider.dart';
import '../../../core/storage/library_category.dart';

import 'details_controller.dart';
import "widgets/details_layout_widgets.dart";
import "widgets/details_desktop_hero.dart";
import "widgets/premium_details_widgets.dart";
import "widgets/anime_information_section.dart";
import "../../../shared/widgets/expandable_text.dart";
import "../../../shared/widgets/loading_indicator.dart";
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'package:skystream/core/utils/localized_text.dart';

/// Keeps the native pull-to-stretch reaction while making it deliberately
/// subtle. The whole flexible header remains one moving unit.
class _GentleTopOverscrollPhysics extends BouncingScrollPhysics {
  const _GentleTopOverscrollPhysics({super.parent});

  @override
  _GentleTopOverscrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _GentleTopOverscrollPhysics(parent: buildParent(ancestor));
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    final appliedOffset = super.applyPhysicsToUserOffset(position, offset);
    final isPullingPastTop =
        position.pixels <= position.minScrollExtent && offset > 0;
    return isPullingPastTop ? appliedOffset * 0.16 : appliedOffset;
  }
}

class _DeferredDetailSection extends StatefulWidget {
  const _DeferredDetailSection({
    required this.enabled,
    required this.placeholderHeight,
    required this.onVisible,
    required this.child,
  });

  final bool enabled;
  final double placeholderHeight;
  final Future<void> Function() onVisible;
  final Widget child;

  @override
  State<_DeferredDetailSection> createState() => _DeferredDetailSectionState();
}

class _DeferredDetailSectionState extends State<_DeferredDetailSection> {
  // Do not prefetch lower detail sections off-screen. Their network request
  // starts only when the section itself reaches the viewport.
  static const double _preloadExtent = 0;
  ScrollPosition? _position;
  bool _activated = false;
  bool _checkScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context)?.position;
    if (!identical(next, _position)) {
      _position?.removeListener(_scheduleVisibilityCheck);
      _position = next;
      _position?.addListener(_scheduleVisibilityCheck);
    }
    _scheduleVisibilityCheck();
  }

  @override
  void didUpdateWidget(covariant _DeferredDetailSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleVisibilityCheck();
  }

  void _scheduleVisibilityCheck() {
    if (!widget.enabled || _activated || _checkScheduled || !mounted) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted || !widget.enabled || _activated) return;
      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) return;
      final top = renderObject.localToGlobal(Offset.zero).dy;
      final bottom = top + renderObject.size.height;
      final viewportHeight = MediaQuery.sizeOf(context).height;
      if (top <= viewportHeight + _preloadExtent &&
          bottom >= -_preloadExtent) {
        setState(() => _activated = true);
        widget.onVisible();
      }
    });
  }

  @override
  void dispose() {
    _position?.removeListener(_scheduleVisibilityCheck);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_activated) {
      return SizedBox(height: widget.placeholderHeight);
    }
    return widget.child;
  }
}

class DetailsScreen extends ConsumerStatefulWidget {
  final MultimediaItem item;
  final bool autoPlay;
  final String? resumeEpisodeUrl;
  final int? resumeEpisodeNumber;
  final int? resumeSeason;

  const DetailsScreen({
    super.key,
    required this.item,
    this.autoPlay = false,
    this.resumeEpisodeUrl,
    this.resumeEpisodeNumber,
    this.resumeSeason,
  });

  @override
  ConsumerState<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends ConsumerState<DetailsScreen>
    with SingleTickerProviderStateMixin {
  static const double _tabSwipeDistanceThreshold = 72;
  static const double _tabSwipeVelocityThreshold = 650;
  static const Duration _tabTransitionDuration = Duration(milliseconds: 260);

  bool _didTriggerAutoPlay = false;
  int _selectedDetailsTab = 0;
  double _tabSwipeDistance = 0;
  bool _tabSwipeStartedAtBackEdge = false;
  Offset _tabSlideFrom = Offset.zero;
  final ScrollController _detailsScrollController = ScrollController(
    keepScrollOffset: false,
  );
  late final AnimationController _tabTransitionController;
  late final Animation<double> _tabTransitionAnimation;

  static const String _removeLibraryAction = '__remove_from_library__';

  double get _detailsHeaderPullTranslation {
    if (!_detailsScrollController.hasClients) return 0;

    final pullDistance = (-_detailsScrollController.offset)
        .clamp(0.0, 24.0)
        .toDouble();
    return pullDistance * 0.20;
  }

  Widget _withDetailsHeaderPullReaction(Widget child) {
    return AnimatedBuilder(
      animation: _detailsScrollController,
      child: child,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, _detailsHeaderPullTranslation),
        child: child,
      ),
    );
  }

  Widget _withDetailsHeaderCollapseFade(
    Widget child,
    double collapseExtent,
  ) {
    return AnimatedBuilder(
      animation: _detailsScrollController,
      child: child,
      builder: (context, child) {
        final offset = _detailsScrollController.hasClients
            ? _detailsScrollController.offset
            : 0.0;
        final opacity = (1.0 - (offset / collapseExtent))
            .clamp(0.0, 1.0)
            .toDouble();
        return Opacity(opacity: opacity, child: child);
      },
    );
  }

  List<AppleLiquidGlassToolbarButton> _buildDetailsHeaderButtons(
    BuildContext context,
    MultimediaItem item, {
    required bool isFavorite,
    required dynamic libraryNotifier,
    required Color foregroundColor,
  }) {
    const favoriteRed = Color(0xFFFF3B30);
    final colors = Theme.of(context).colorScheme;
    final commentTarget = animeWitcherAnimeCommentTarget(item);
    final LibraryCategory? currentCategory = libraryNotifier.itemCategory(item.url);

    return <AppleLiquidGlassToolbarButton>[
      if (commentTarget != null)
        AppleLiquidGlassToolbarButton(
          tooltip: appText(
            context,
            english: 'Comments',
            arabic: 'التعليقات',
          ),
          icon: Icons.chat_bubble_outline_rounded,
          color: foregroundColor,
          onPressed: () => _openAnimeComments(context, commentTarget),
        ),
      AppleLiquidGlassToolbarButton(
        tooltip: isFavorite
            ? appText(
                context,
                english: 'Remove favorite',
                arabic: 'إزالة من المفضلة',
              )
            : appText(
                context,
                english: 'Add to favorites',
                arabic: 'إضافة إلى المفضلة',
              ),
        icon: isFavorite
            ? Icons.favorite_rounded
            : Icons.favorite_border_rounded,
        color: isFavorite ? favoriteRed : foregroundColor,
        onPressed: () => libraryNotifier.setFavorite(item, !isFavorite),
      ),
      AppleLiquidGlassToolbarButton(
        tooltip: appText(
          context,
          english: 'Choose list',
          arabic: 'اختر قائمة',
        ),
        icon: currentCategory == null
            ? Icons.bookmark_border_rounded
            : _libraryCategoryIcon(currentCategory),
        systemImage: currentCategory == null
            ? 'bookmark'
            : _libraryCategorySystemImage(currentCategory),
        color: currentCategory != null ? colors.primary : foregroundColor,
        menuTintColor: colors.primary,
        onPressed: () => _showLibraryCategoryPicker(context, item),
        selectedMenuValue: currentCategory?.storageKey,
        menuItems: _libraryCategoryMenuItems(
          context,
          item,
          currentCategory,
        ),
        onMenuSelected: (value) => _handleLibraryMenuSelection(item, value),
      ),
    ];
  }

  Widget _buildDetailsHeaderActions(
    BuildContext context,
    MultimediaItem item, {
    required bool isFavorite,
    required dynamic libraryNotifier,
    required Color foregroundColor,
    Color? fallbackColor,
  }) {
    return AppleLiquidGlassActionGroup(
      height: 46,
      fallbackColor: fallbackColor,
      children: _buildDetailsHeaderButtons(
        context,
        item,
        isFavorite: isFavorite,
        libraryNotifier: libraryNotifier,
        foregroundColor: foregroundColor,
      ),
    );
  }

  Future<void> _openAnimeComments(
    BuildContext context,
    AnimeWitcherCommentTarget target,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnimeWitcherCommentsScreen(target: target),
      ),
    );
    if (!mounted || !appleUsesPersistentLiquidGlassHeader) return;
    setState(() {});
  }

  String _libraryCategoryLabel(BuildContext context, LibraryCategory category) {
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    return switch (category) {
      LibraryCategory.favorite => isArabic ? 'مفضلة' : 'Favorites',
      LibraryCategory.watching => isArabic ? 'أشاهده حاليًا' : 'Watching',
      LibraryCategory.continueLater =>
        isArabic ? 'أكملها لاحقًا' : 'Continue later',
      LibraryCategory.planToWatch =>
        isArabic ? 'أرغب بمشاهدته' : 'Plan to watch',
      LibraryCategory.completed => isArabic ? 'تمت مشاهدته' : 'Completed',
      LibraryCategory.notInterested =>
        isArabic ? 'لا أرغب بمشاهدته' : 'Not interested',
    };
  }

  IconData _libraryCategoryIcon(LibraryCategory category) {
    return switch (category) {
      LibraryCategory.favorite => Icons.favorite_rounded,
      LibraryCategory.watching => Icons.play_circle_fill_rounded,
      LibraryCategory.continueLater => Icons.pause_circle_filled_rounded,
      LibraryCategory.planToWatch => Icons.schedule_rounded,
      LibraryCategory.completed => Icons.check_circle_rounded,
      LibraryCategory.notInterested => Icons.block_rounded,
    };
  }


  String _libraryCategorySystemImage(LibraryCategory category) {
    return switch (category) {
      LibraryCategory.favorite => 'heart.fill',
      LibraryCategory.watching => 'play.circle.fill',
      LibraryCategory.continueLater => 'pause.circle.fill',
      LibraryCategory.planToWatch => 'clock',
      LibraryCategory.completed => 'checkmark.circle.fill',
      LibraryCategory.notInterested => 'xmark.circle.fill',
    };
  }

  List<AppleNativeMenuItem> _libraryCategoryMenuItems(
    BuildContext context,
    MultimediaItem item,
    LibraryCategory? currentCategory,
  ) {
    final items = <AppleNativeMenuItem>[
      for (final category in LibraryCategory.primaryValues.where(
        (category) =>
            category != LibraryCategory.completed ||
            item.status == ShowStatus.completed,
      ))
        AppleNativeMenuItem(
          value: category.storageKey,
          label: _libraryCategoryLabel(context, category),
          systemImage: _libraryCategorySystemImage(category),
        ),
    ];
    if (currentCategory != null) {
      items.add(
        AppleNativeMenuItem(
          value: _removeLibraryAction,
          label: Localizations.localeOf(context).languageCode == 'ar'
              ? 'إزالة من القائمة'
              : 'Remove from list',
          systemImage: 'trash',
          destructive: true,
        ),
      );
    }
    return items;
  }

  Future<void> _handleLibraryMenuSelection(
    MultimediaItem item,
    String value,
  ) async {
    final notifier = ref.read(libraryProvider.notifier);
    if (value == _removeLibraryAction) {
      await notifier.clearItemCategory(item.url);
      return;
    }
    LibraryCategory? category;
    for (final candidate in LibraryCategory.primaryValues) {
      if (candidate.storageKey == value) {
        category = candidate;
        break;
      }
    }
    if (category != null) {
      await notifier.addItem(item, category: category);
    }
  }

  Future<void> _showLibraryCategoryPicker(
    BuildContext context,
    MultimediaItem item,
  ) async {
    final notifier = ref.read(libraryProvider.notifier);
    final currentCategory = notifier.itemCategory(item.url);
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';

    final result = await showModalBottomSheet<Object>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.56),
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final colors = theme.colorScheme;
        return Container(
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.78,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: 0.36),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.onSurfaceVariant.withValues(alpha: 0.34),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
                    child: Text(
                      isArabic ? 'حفظ في قائمة' : 'Save to list',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  for (final category in LibraryCategory.primaryValues.where(
                    (category) =>
                        category != LibraryCategory.completed ||
                        item.status == ShowStatus.completed,
                  ))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Material(
                        color: currentCategory == category
                            ? colors.primaryContainer.withValues(alpha: 0.70)
                            : colors.surfaceContainerHighest.withValues(alpha: 0.46),
                        borderRadius: BorderRadius.circular(15),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(15),
                          onTap: () => Navigator.of(sheetContext).pop(category),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 11,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: currentCategory == category
                                        ? colors.primary.withValues(alpha: 0.14)
                                        : colors.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(11),
                                  ),
                                  child: Icon(
                                    _libraryCategoryIcon(category),
                                    size: 21,
                                    color: currentCategory == category
                                        ? colors.primary
                                        : colors.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    _libraryCategoryLabel(sheetContext, category),
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if (currentCategory == category)
                                  Icon(
                                    Icons.check_rounded,
                                    color: colors.primary,
                                    size: 22,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (currentCategory != null) ...[
                    const SizedBox(height: 8),
                    Divider(color: colors.outlineVariant.withValues(alpha: 0.5)),
                    const SizedBox(height: 4),
                    Material(
                      color: colors.errorContainer.withValues(alpha: 0.36),
                      borderRadius: BorderRadius.circular(15),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(15),
                        onTap: () => Navigator.of(sheetContext).pop(
                          _removeLibraryAction,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.delete_outline_rounded, color: colors.error),
                              const SizedBox(width: 12),
                              Text(
                                isArabic ? 'إزالة من القائمة' : 'Remove from list',
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: colors.error,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );

    if (!mounted || result == null) return;
    if (result is LibraryCategory) {
      await notifier.addItem(item, category: result);
    } else if (result == _removeLibraryAction) {
      await notifier.clearItemCategory(item.url);
    }
  }


  void _switchDetailsTab(int targetTab) {
    if (targetTab == _selectedDetailsTab) return;

    if (targetTab == 1) {
      ref
          .read(detailsControllerProvider(widget.item.url).notifier)
          .loadEpisodesOnDemand();
    }

    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final entersFromLeft = isRtl ? targetTab == 1 : targetTab == 0;
    _tabSlideFrom = Offset(entersFromLeft ? -0.16 : 0.16, 0);

    setState(() => _selectedDetailsTab = targetTab);
    _tabTransitionController.forward(from: 0);
  }

  Widget _buildTabTransition({required Widget child}) {
    return FadeTransition(
      opacity: _tabTransitionAnimation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: _tabSlideFrom,
          end: Offset.zero,
        ).animate(_tabTransitionAnimation),
        child: child,
      ),
    );
  }

  Widget _buildDetailsTabSwipeRegion({
    required Widget child,
    required bool enabled,
  }) {
    if (!enabled) return child;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (details) {
        _tabSwipeDistance = 0;
        // Preserve the native iOS back gesture from the physical left edge.
        _tabSwipeStartedAtBackEdge = details.globalPosition.dx <= 24;
      },
      onHorizontalDragUpdate: (details) {
        if (_tabSwipeStartedAtBackEdge) return;
        _tabSwipeDistance += details.primaryDelta ?? 0;
      },
      onHorizontalDragCancel: () {
        _tabSwipeDistance = 0;
        _tabSwipeStartedAtBackEdge = false;
      },
      onHorizontalDragEnd: (details) {
        final distance = _tabSwipeDistance;
        final velocity = details.primaryVelocity ?? 0;
        final ignored = _tabSwipeStartedAtBackEdge;
        _tabSwipeDistance = 0;
        _tabSwipeStartedAtBackEdge = false;
        if (ignored) return;

        final swipeLeft =
            distance <= -_tabSwipeDistanceThreshold ||
            velocity <= -_tabSwipeVelocityThreshold;
        final swipeRight =
            distance >= _tabSwipeDistanceThreshold ||
            velocity >= _tabSwipeVelocityThreshold;

        final isRtl = Directionality.of(context) == TextDirection.rtl;
        // Arabic: details -> episodes by swiping right, and episodes ->
        // details by swiping left. English uses the opposite directions.
        final swipeTowardEpisodes = isRtl ? swipeRight : swipeLeft;
        final swipeTowardDetails = isRtl ? swipeLeft : swipeRight;

        if (swipeTowardEpisodes && _selectedDetailsTab != 1) {
          _switchDetailsTab(1);
        } else if (swipeTowardDetails && _selectedDetailsTab != 0) {
          _switchDetailsTab(0);
        }
      },
      child: child,
    );
  }

  Future<void> _copyAnimeTitle(BuildContext context, String title) async {
    await Clipboard.setData(ClipboardData(text: title));
    await HapticFeedback.selectionClick();

    if (!context.mounted) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          appText(context, english: 'Title copied', arabic: 'تم نسخ العنوان'),
        ),
        duration: Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _showPosterViewer(
    BuildContext context,
    MultimediaItem item,
  ) async {
    final posterUrl = AppImageFallbacks.poster(
      item.posterUrl,
      label: item.title,
    );
    if (posterUrl == null || posterUrl.isEmpty) return;

    await showGeneralDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(
        context,
      ).modalBarrierDismissLabel,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (dialogContext, _, _) {
        final size = MediaQuery.of(dialogContext).size;
        return Material(
          color: Colors.black,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(dialogContext).pop(),
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: CachedNetworkImage(
                  imageUrl: posterUrl,
                  fit: BoxFit.contain,
                  placeholder: (_, _) => const Center(
                    child: CircularProgressIndicator(),
                  ),
                  errorWidget: (_, _, _) => const Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 52,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (_, animation, _, child) => FadeTransition(
        opacity: animation,
        child: child,
      ),
    );
  }

  Widget _buildAnimeWitcherMobileHeader(
    BuildContext context,
    MultimediaItem item,
    AsyncValue<MultimediaItem?> detailsState,
  ) {
    final screenSize = MediaQuery.sizeOf(context);
    final screenWidth = screenSize.width;
    // Scale the handset header from the physical phone width in portrait terms.
    // Using the landscape width makes every SDP position grow ~2x and pushes
    // the poster/title below the visible header on rotated phones.
    final scale =
        screenSize.shortestSide / LayoutConstants.detailsSdpReferenceWidth;
    double sdp(double value) => value * scale;

    final bannerHeight = sdp(LayoutConstants.detailsBannerHeightMobile);
    final posterUrl =
        AppImageFallbacks.poster(item.posterUrl, label: item.title) ?? '';
    final providedBannerUrl = AppImageFallbacks.optional(item.bannerUrl);
    final logoUrl = AppImageFallbacks.optional(item.logoUrl);
    final bannerUrl =
        AppImageFallbacks.banner(
          bannerUrl: item.bannerUrl,
          posterUrl: item.posterUrl,
          label: item.title,
        ) ??
        '';
    final titleHeight = sdp(28).clamp(28.0, 44.0).toDouble();
    final titleStyle = TextStyle(
      color: Colors.white,
      fontSize: 14.0,
      fontWeight: FontWeight.bold,
      height: 1.1,
    );
    final titleTop =
        bannerHeight -
        sdp(LayoutConstants.detailsHeaderBottomMobile) -
        titleHeight;

    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: bannerHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                bannerUrl.isEmpty
                    ? const ColoredBox(color: Colors.black)
                    : ColoredBox(
                        color: Colors.black,
                        child: CachedNetworkImage(
                          key: ValueKey<String>('details_banner_$bannerUrl'),
                          imageUrl: bannerUrl,
                          fit: BoxFit.cover,
                          alignment: Alignment.center,
                          memCacheWidth:
                              (screenWidth *
                                      MediaQuery.devicePixelRatioOf(context))
                                  .round(),
                          placeholder: (_, _) => const ColoredBox(
                            color: Colors.black,
                          ),
                          errorWidget: (_, _, _) {
                            if (providedBannerUrl != null &&
                                posterUrl.isNotEmpty &&
                                providedBannerUrl != posterUrl) {
                              return CachedNetworkImage(
                                key: ValueKey<String>(
                                  'details_banner_poster_$posterUrl',
                                ),
                                imageUrl: posterUrl,
                                fit: BoxFit.cover,
                                alignment: Alignment.center,
                                memCacheWidth:
                                    (screenWidth *
                                            MediaQuery.devicePixelRatioOf(
                                              context,
                                            ))
                                        .round(),
                                placeholder: (_, _) => const ColoredBox(
                                  color: Colors.black,
                                ),
                                errorWidget: (_, _, _) => const ColoredBox(
                                  color: Colors.black,
                                ),
                              );
                            }
                            return const ColoredBox(color: Colors.black);
                          },
                        ),
                      ),
                // Keep the fade broad and finish on the same solid black as
                // the content below. Ending at a translucent black leaves a
                // visible horizontal seam where the banner meets the page.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.transparent,
                        Color(0x26000000),
                        Color(0x99000000),
                        Colors.black,
                      ],
                      stops: [0, 0.30, 0.58, 0.86, 1],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: sdp(LayoutConstants.detailsPosterTopMobile),
            left: sdp(LayoutConstants.detailsPosterStartMobile),
            width: sdp(LayoutConstants.detailsPosterWidthMobile),
            height: sdp(LayoutConstants.detailsPosterHeightMobile),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showPosterViewer(context, item),
              child: Material(
                color: Colors.black,
                elevation: sdp(6),
                borderRadius: BorderRadius.circular(sdp(5)),
                clipBehavior: Clip.antiAlias,
                child: posterUrl.isEmpty
                    ? const ColoredBox(color: Colors.black)
                    : CachedNetworkImage(
                        key: ValueKey<String>('details_poster_$posterUrl'),
                        imageUrl: posterUrl,
                        fit: BoxFit.cover,
                        placeholder: (_, _) => const ColoredBox(
                          color: Colors.black,
                        ),
                        errorWidget: (_, _, _) => const ColoredBox(
                          color: Colors.black,
                        ),
                      ),
              ),
            ),
          ),
          Positioned(
            left: sdp(LayoutConstants.detailsTitleStartMobile),
            right: sdp(LayoutConstants.detailsHeaderEndMobile),
            top: titleTop,
            height: titleHeight,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: () => _copyAnimeTitle(context, item.title),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: logoUrl != null
                      ? CachedNetworkImage(
                          imageUrl: logoUrl,
                          height: titleHeight,
                          fit: BoxFit.contain,
                          alignment: Alignment.centerLeft,
                          placeholder: (_, _) => Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                          errorWidget: (_, _, _) => Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                        )
                      : Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle,
                        ),
                ),
              ),
            ),
          ),
          Positioned(
            top: bannerHeight + sdp(6),
            left: sdp(LayoutConstants.detailsTitleStartMobile),
            right: sdp(LayoutConstants.detailsHeaderEndMobile),
            bottom: sdp(LayoutConstants.detailsHeaderBottomMobile),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: Theme.of(context).colorScheme.copyWith(
                    onSurface: Colors.white,
                    onSurfaceVariant: Colors.white70,
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) => FittedBox(
                    alignment: Alignment.topLeft,
                    fit: BoxFit.scaleDown,
                    child: SizedBox(
                      width: constraints.maxWidth,
                      child: MetadataBar(
                        item: item,
                        isLoading: detailsState is AsyncLoading,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Episode? _resumeEpisodeFrom(List<Episode> episodes) {
    final resumeUrl = widget.resumeEpisodeUrl?.trim();
    if (resumeUrl != null && resumeUrl.isNotEmpty) {
      for (final episode in episodes) {
        if (episode.url.trim() == resumeUrl) return episode;
      }
    }

    final resumeNumber = widget.resumeEpisodeNumber;
    if (resumeNumber == null || resumeNumber <= 0) return null;

    final resumeSeason = widget.resumeSeason;
    Episode? numberMatch;
    for (final episode in episodes) {
      if (episode.episode != resumeNumber) continue;
      numberMatch ??= episode;
      if (resumeSeason != null &&
          resumeSeason > 0 &&
          episode.season == resumeSeason) {
        return episode;
      }
    }
    return numberMatch;
  }

  @override
  void initState() {
    super.initState();
    _tabTransitionController = AnimationController(
      vsync: this,
      duration: _tabTransitionDuration,
      value: 1,
    );
    _tabTransitionAnimation = CurvedAnimation(
      parent: _tabTransitionController,
      curve: Curves.easeOutCubic,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(detailsControllerProvider(widget.item.url).notifier)
          .loadDetails(widget.item, autoPlay: widget.autoPlay);
    });
  }

  @override
  void dispose() {
    applePersistentGlassHeaderController.hide(this);
    _detailsScrollController.dispose();
    _tabTransitionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(detailsControllerProvider(widget.item.url), (prev, next) {
      if (!widget.autoPlay || _didTriggerAutoPlay) return;
      final prevState = prev ?? const DetailsState();
      final nextState = next;
      final wasReady =
          prevState.episodes.hasValue &&
          (prevState.episodes.value?.isNotEmpty ?? false);
      final isReady =
          nextState.episodes.hasValue &&
          (nextState.episodes.value?.isNotEmpty ?? false);

      if (wasReady || !isReady) {
        return;
      }

      final item = nextState.item ?? nextState.details.value ?? widget.item;
      final episodes = nextState.episodes.value ?? const <Episode>[];
      final resumeEpisode = _resumeEpisodeFrom(episodes);
      final resumeUrl = widget.resumeEpisodeUrl?.trim();
      final fallbackResumeUrl = resumeEpisode == null &&
              resumeUrl != null &&
              resumeUrl.isNotEmpty
          ? resumeUrl
          : null;
      _didTriggerAutoPlay = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref
            .read(detailsControllerProvider(widget.item.url).notifier)
            .handlePlayPress(
              context,
              item,
              specificEpisode: resumeEpisode,
              overrideUrl: fallbackResumeUrl,
            );
      });
    });
    // Watch library state so the icon refreshes after add/remove, but check
    // membership globally instead of only inside the currently selected list.
    ref.watch(libraryProvider);
    final libraryNotifier = ref.read(libraryProvider.notifier);
    final isFavorite = libraryNotifier.isFavorite(widget.item.url);
    final isLarge = context.isTabletOrLarger;

    final detailsAsync = ref.watch(
      detailsControllerProvider(widget.item.url).select((s) => s.details),
    );
    final details = detailsAsync.value;
    final episodesAsync = ref.watch(
      detailsControllerProvider(widget.item.url).select((s) => s.episodes),
    );
    final castAsync = ref.watch(
      detailsControllerProvider(widget.item.url).select((s) => s.cast),
    );
    final trailersAsync = ref.watch(
      detailsControllerProvider(widget.item.url).select((s) => s.trailers),
    );
    final relatedAsync = ref.watch(
      detailsControllerProvider(widget.item.url).select((s) => s.related),
    );
    final recommendationsAsync = ref.watch(
      detailsControllerProvider(
        widget.item.url,
      ).select((s) => s.recommendations),
    );
    final currentItem = ref.watch(
      detailsControllerProvider(widget.item.url).select((s) => s.item),
    );
    final initialPageReady = ref.watch(
      detailsControllerProvider(widget.item.url).select(
        (s) => s.basicDetailsResolved && s.nextAiringResolved,
      ),
    );
    // Movies and one-episode anime share the exact same mobile layout, so
    // iPhone/iPad-small pages must not rebuild just because isMovie resolves.
    // Desktop still uses the flag for hero-specific playback presentation.
    final isMovie = isLarge
        ? ref.watch(
            detailsControllerProvider(widget.item.url).select((s) => s.isMovie),
          )
        : false;
    final item = mergeDetailsItem(
      fallback: widget.item,
      incoming: currentItem ?? details ?? widget.item,
      episodes: episodesAsync.asData?.value,
    );
    final selectedEpisodeCount = ref.watch(
      detailsControllerProvider(
        widget.item.url,
      ).select((state) => state.selectedEpisodeKeys.length),
    );

    final l10n = AppLocalizations.of(context)!;

    if (!initialPageReady) {
      if (appleUsesPersistentLiquidGlassHeader) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
          applePersistentGlassHeaderController.show(
            ApplePersistentGlassHeaderConfig(
              owner: this,
              route: ModalRoute.of(context),
              onBack: () => Navigator.of(context).maybePop(),
              backForegroundColor: Theme.of(context).colorScheme.primary,
              backFallbackColor: Colors.black45,
              trailingButtons: const <AppleLiquidGlassToolbarButton>[],
              instantRouteBoundary: true,
            ),
          );
        });
      }
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: appleUsesPersistentLiquidGlassHeader
            ? null
            : AppBar(
                backgroundColor: Colors.black,
                elevation: 0,
                automaticallyImplyLeading: false,
                leading: AppleLiquidGlassBackButton(
                  foregroundColor: Theme.of(context).colorScheme.primary,
                  fallbackColor: Colors.black45,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
        body: Center(
          child: AppLoadingIndicator(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }

    if (appleUsesPersistentLiquidGlassHeader) {
      final headerForeground = isLarge
          ? Theme.of(context).colorScheme.onSurface
          : Colors.white;
      final headerFallback = isLarge
          ? Theme.of(context).colorScheme.surfaceContainerHigh
          : Colors.black45;
      final trailingButtons = _buildDetailsHeaderButtons(
        context,
        item,
        isFavorite: isFavorite,
        libraryNotifier: libraryNotifier,
        foregroundColor: headerForeground,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
        applePersistentGlassHeaderController.show(
          ApplePersistentGlassHeaderConfig(
            owner: this,
            route: ModalRoute.of(context),
            onBack: () => Navigator.of(context).maybePop(),
            backForegroundColor: headerForeground,
            backFallbackColor: headerFallback,
            trailingButtons: trailingButtons,
            instantRouteBoundary: true,
          ),
        );
      });
    }

    // ── Desktop / TV: Immersive hero layout ──
    if (isLarge) {
      return _buildDesktopLayout(
        context,
        item,
        detailsAsync,
        episodesAsync,
        castAsync,
        trailersAsync,
        relatedAsync,
        recommendationsAsync,
        isMovie,
        isFavorite,
        libraryNotifier,
        l10n,
        selectedEpisodeCount,
      );
    }

    final mobileHeaderScale =
        MediaQuery.sizeOf(context).shortestSide /
        LayoutConstants.detailsSdpReferenceWidth;
    final mobileHeaderHeight =
        LayoutConstants.detailsExpandedHeightMobile * mobileHeaderScale;
    // SliverAppBar adds the status-bar inset to expandedHeight. Subtract it
    // so the complete visible header remains AnimeWitcher's 230sdp tall.
    final mobileExpandedHeight =
        (mobileHeaderHeight - MediaQuery.paddingOf(context).top)
            .clamp(kToolbarHeight, mobileHeaderHeight)
            .toDouble();
    final mobileCollapseExtent = (mobileExpandedHeight - kToolbarHeight)
        .clamp(1.0, double.infinity)
        .toDouble();

    // ── Mobile: AnimeWitcher-sized overlapping details header ──
    return Scaffold(
      bottomNavigationBar:
          selectedEpisodeCount == 0 || _selectedDetailsTab != 1
          ? null
          : _buildEpisodeSelectionBar(context, selectedEpisodeCount),
      body: _buildDetailsTabSwipeRegion(
        enabled: true,
        child: CustomScrollView(
          controller: _detailsScrollController,
          physics: const _GentleTopOverscrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            Directionality(
              textDirection: TextDirection.ltr,
              child: SliverAppBar(
                pinned: true,
                expandedHeight: mobileExpandedHeight,
                stretch: true,
                // Keep an opaque black fallback under the artwork. FlexibleSpaceBar
                // applies its own automatic background fade during route/sliver
                // layout changes; that exposed a neutral gray frame while short
                // movie / one-episode pages were still settling. Render the header
                // directly so only our explicit collapse fade can affect it.
                backgroundColor: Colors.black,
                surfaceTintColor: Colors.transparent,
                shadowColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                forceMaterialTransparency: false,
                flexibleSpace: _withDetailsHeaderCollapseFade(
                  _withDetailsHeaderPullReaction(
                    _buildAnimeWitcherMobileHeader(
                      context,
                      item,
                      detailsAsync,
                    ),
                  ),
                  mobileCollapseExtent,
                ),
                automaticallyImplyLeading: false,
                leadingWidth: appleUsesPersistentLiquidGlassHeader ? 0 : 64,
                leading: appleUsesPersistentLiquidGlassHeader
                    ? null
                    : _withDetailsHeaderPullReaction(
                        Focus(
                          descendantsAreTraversable: false,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: AppleLiquidGlassBackButton(
                              size: 46,
                              foregroundColor: Colors.white,
                              fallbackColor: Colors.black45,
                              onPressed: () => Navigator.of(context).maybePop(),
                            ),
                          ),
                        ),
                      ),
                actions: appleUsesPersistentLiquidGlassHeader
                    ? const <Widget>[]
                    : [
                        _withDetailsHeaderPullReaction(
                          Focus(
                            descendantsAreTraversable: false,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _buildDetailsHeaderActions(
                                context,
                                item,
                                isFavorite: isFavorite,
                                libraryNotifier: libraryNotifier,
                                foregroundColor: Colors.white,
                                fallbackColor: Colors.black45,
                              ),
                            ),
                          ),
                        ),
                      ],
              ),
            ),
            ..._buildMobileSlivers(
              context,
              item,
              detailsAsync,
              episodesAsync,
              castAsync,
              trailersAsync,
              relatedAsync,
              recommendationsAsync,
              l10n,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEpisodeSelectionBar(BuildContext context, int selectedCount) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final selectedLabel = isArabic
        ? 'تم تحديد $selectedCount'
        : '$selectedCount selected';
    final controller = ref.read(
      detailsControllerProvider(widget.item.url).notifier,
    );

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Material(
          elevation: 10,
          shadowColor: Colors.black.withValues(alpha: 0.30),
          color: colors.surfaceContainerHigh,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: 112,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  Widget actionButton({
                    required String label,
                    required IconData icon,
                    required VoidCallback onPressed,
                    required bool outlined,
                  }) {
                    final style = outlined
                        ? OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            visualDensity: VisualDensity.compact,
                          )
                        : FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                            visualDensity: VisualDensity.compact,
                          );

                    if (outlined) {
                      return OutlinedButton.icon(
                        onPressed: onPressed,
                        icon: Icon(icon, size: 21),
                        label: Text(label),
                        style: style,
                      );
                    }

                    return FilledButton.icon(
                      onPressed: onPressed,
                      icon: Icon(icon, size: 21),
                      label: Text(label),
                      style: style,
                    );
                  }

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.checklist_rounded,
                            color: colors.primary,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              selectedLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: isArabic ? 'إلغاء التحديد' : 'Cancel selection',
                            visualDensity: VisualDensity.compact,
                            onPressed: controller.clearEpisodeSelection,
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: actionButton(
                              label: isArabic ? 'تمت مشاهدته' : 'Watched',
                              icon: Icons.visibility_rounded,
                              outlined: false,
                              onPressed: () async {
                                await controller.setSelectedEpisodesWatched(
                                  widget.item.url,
                                  true,
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: actionButton(
                              label: isArabic ? 'غير مشاهدة' : 'Unwatched',
                              icon: Icons.visibility_off_rounded,
                              outlined: true,
                              onPressed: () async {
                                await controller.setSelectedEpisodesWatched(
                                  widget.item.url,
                                  false,
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filledTonal(
                            tooltip: isArabic ? 'تحديد جميع الحلقات' : 'Select all episodes',
                            onPressed: controller.selectAllEpisodes,
                            icon: const Icon(Icons.select_all_rounded),
                            style: IconButton.styleFrom(
                              minimumSize: const Size(48, 48),
                              maximumSize: const Size(48, 48),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────
  //  DESKTOP / TV  — Immersive hero layout
  // ─────────────────────────────────────────────────────────────────

  String _mediaIdentity(MultimediaItem item) {
    final url = item.url.trim();
    if (url.isNotEmpty) return 'url:$url';

    return [
      item.provider ?? '',
      item.title.trim().toLowerCase(),
      item.year?.toString() ?? '',
      item.contentType.name,
    ].join('|');
  }

  MultimediaItem _inheritProvider(MultimediaItem parent, MultimediaItem child) {
    final childProvider = child.provider?.trim();
    if (childProvider != null && childProvider.isNotEmpty) {
      return child;
    }

    final parentProvider = parent.provider?.trim();
    if (parentProvider == null || parentProvider.isEmpty) {
      return child;
    }

    return child.copyWith(provider: parentProvider);
  }

  List<MultimediaItem> _uniqueMediaItems(List<MultimediaItem>? items) {
    if (items == null || items.isEmpty) {
      return const <MultimediaItem>[];
    }

    final seen = <String>{};
    return items
        .where((item) => seen.add(_mediaIdentity(item)))
        .toList(growable: false);
  }

  List<MultimediaItem> _recommendationsWithoutRelatedLists(
    List<MultimediaItem>? recommendations,
    List<MultimediaItem>? related,
  ) {
    final relatedKeys = _uniqueMediaItems(related).map(_mediaIdentity).toSet();
    return _uniqueMediaItems(recommendations)
        .where((value) => !relatedKeys.contains(_mediaIdentity(value)))
        .toList(growable: false);
  }

  Widget _sectionLoadingPlaceholder(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 18),
          const Center(child: AppLoadingIndicator()),
        ],
      ),
    );
  }

  List<Widget> _buildIndependentDetailSections(
    BuildContext context,
    MultimediaItem item,
    AppLocalizations l10n,
    AsyncValue<List<Actor>> castState,
    AsyncValue<List<Trailer>> trailersState,
    AsyncValue<List<MultimediaItem>> relatedState,
    AsyncValue<List<MultimediaItem>> recommendationsState,
  ) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final cast = castState.asData?.value ?? item.cast ?? const <Actor>[];
    final trailers =
        trailersState.asData?.value ?? item.trailers ?? const <Trailer>[];
    final related = _uniqueMediaItems(
      relatedState.asData?.value ?? item.related,
    );
    final recommendations = _recommendationsWithoutRelatedLists(
      recommendationsState.asData?.value ?? item.recommendations,
      related,
    );
    final controller = ref.read(
      detailsControllerProvider(widget.item.url).notifier,
    );
    final widgets = <Widget>[];

    Widget castSection() {
      if (cast.isNotEmpty) {
        return Column(
          children: [const SizedBox(height: 32), CastCarousel(cast: cast)],
        );
      }
      if (castState.isLoading) {
        return _sectionLoadingPlaceholder(
          context,
          isArabic ? 'طاقم الشخصيات' : 'Cast',
        );
      }
      return const SizedBox.shrink();
    }

    Widget recommendationsSection() {
      if (recommendations.isNotEmpty) {
        return Column(
          children: [
            const SizedBox(height: 32),
            RecommendationsCarousel(
              items: recommendations,
              onItemTap: (recommendation) {
                final target = _inheritProvider(item, recommendation);
                DetailsRoute(
                  $extra: DetailsRouteExtra(item: target),
                ).push<void>(context);
              },
            ),
          ],
        );
      }
      if (recommendationsState.isLoading) {
        return _sectionLoadingPlaceholder(
          context,
          isArabic ? 'المزيد مثل هذا' : 'More Like This',
        );
      }
      return const SizedBox.shrink();
    }

    Widget relatedSection() {
      if (related.isNotEmpty) {
        return Column(
          children: [
            const SizedBox(height: 32),
            RecommendationsCarousel(
              title: l10n.relatedAnime,
              items: related,
              showRelationBadge: true,
              onItemTap: (relatedItem) {
                final target = _inheritProvider(item, relatedItem);
                DetailsRoute(
                  $extra: DetailsRouteExtra(item: target),
                ).push<void>(context);
              },
            ),
          ],
        );
      }
      if (relatedState.isLoading) {
        return _sectionLoadingPlaceholder(context, l10n.relatedAnime);
      }
      return const SizedBox.shrink();
    }

    // Lower-page order: trailer -> related -> recommendations -> cast.
    // Related, recommendations and cast stay completely deferred until their
    // own placeholder reaches the viewport on the Details tab.
    if (trailers.isNotEmpty) {
      widgets.addAll([
        const SizedBox(height: 32),
        TrailersSection(trailers: trailers),
      ]);
    } else if (trailersState.isLoading) {
      widgets.add(
        _sectionLoadingPlaceholder(
          context,
          isArabic ? 'العرض الدعائي' : 'Trailers & Extras',
        ),
      );
    }

    widgets.add(
      _DeferredDetailSection(
        enabled: _selectedDetailsTab == 0,
        placeholderHeight: 230,
        onVisible: controller.loadRelatedIfNeeded,
        child: relatedSection(),
      ),
    );
    widgets.add(
      _DeferredDetailSection(
        enabled: _selectedDetailsTab == 0,
        placeholderHeight: 230,
        onVisible: controller.loadRecommendationsIfNeeded,
        child: recommendationsSection(),
      ),
    );
    widgets.add(
      _DeferredDetailSection(
        enabled: _selectedDetailsTab == 0,
        placeholderHeight: 210,
        onVisible: controller.loadCastIfNeeded,
        child: castSection(),
      ),
    );

    return widgets;
  }

  Widget _buildDesktopLayout(
    BuildContext context,
    MultimediaItem item,
    AsyncValue<MultimediaItem?> detailsState,
    AsyncValue<List<Episode>> episodesState,
    AsyncValue<List<Actor>> castState,
    AsyncValue<List<Trailer>> trailersState,
    AsyncValue<List<MultimediaItem>> relatedState,
    AsyncValue<List<MultimediaItem>> recommendationsState,
    bool isMovie,
    bool isFavorite,
    dynamic libraryNotifier,
    AppLocalizations l10n,
    int selectedEpisodeCount,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      bottomNavigationBar:
          selectedEpisodeCount == 0 || _selectedDetailsTab != 1
          ? null
          : _buildEpisodeSelectionBar(context, selectedEpisodeCount),
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            automaticallyImplyLeading: false,
            leadingWidth: appleUsesPersistentLiquidGlassHeader ? 0 : 64,
            leading: appleUsesPersistentLiquidGlassHeader
                ? null
                : Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: AppleLiquidGlassBackButton(
                      size: 46,
                      foregroundColor: textColor,
                      fallbackColor: isDark ? Colors.black45 : Colors.white54,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
            actions: appleUsesPersistentLiquidGlassHeader
                ? const <Widget>[]
                : [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _buildDetailsHeaderActions(
                        context,
                        item,
                        isFavorite: isFavorite,
                        libraryNotifier: libraryNotifier,
                        foregroundColor: textColor,
                        fallbackColor: isDark ? Colors.black45 : Colors.white54,
                      ),
                    ),
                  ],
          ),
        ),
      ),
      body: _buildDetailsTabSwipeRegion(
        enabled: true,
        child: DetailsDesktopHero(
          displayItem: item,
          baseItem: widget.item,
          details: item,
          detailsState: detailsState,
          isMovie: isMovie,
          itemUrl: widget.item.url,
          child: _buildDesktopContentBelow(
            context,
            item,
            detailsState,
            episodesState,
            castState,
            trailersState,
            relatedState,
            recommendationsState,
            l10n,
          ),
        ),
      ),
    );
  }

  Widget _buildDetailsPageTabs(
    BuildContext context,
    AsyncValue<List<Episode>> episodesState,
  ) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';
    final episodeCount = episodesState.asData?.value.length ?? 0;
    final episodeLabel = episodeCount > 0
        ? '${isArabic ? 'الحلقات' : 'Episodes'} ($episodeCount)'
        : isArabic
        ? 'الحلقات'
        : 'Episodes';

    // Episode UI v2: equal-width tabs without selected checkmarks.
    Widget tab({
      required bool selected,
      required Widget leading,
      required String label,
      required VoidCallback onTap,
    }) {
      return ChoiceChip(
        selected: selected,
        showCheckmark: false,
        labelPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        label: SizedBox(
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.max,
            children: [
              leading,
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
        onSelected: (_) => onTap(),
      );
    }

    return Row(
      children: [
        Expanded(
          child: tab(
            selected: _selectedDetailsTab == 0,
            leading: const Icon(Icons.info_outline_rounded, size: 21),
            label: isArabic ? 'التفاصيل' : 'Details',
            onTap: () {
              if (_selectedDetailsTab == 0) return;
              _switchDetailsTab(0);
            },
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: tab(
            selected: _selectedDetailsTab == 1,
            leading: episodesState.isLoading
                ? const SizedBox.square(
                    dimension: 19,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.video_library_outlined, size: 21),
            label: episodeLabel,
            onTap: () {
              if (_selectedDetailsTab == 1) return;
              _switchDetailsTab(1);
            },
          ),
        ),
      ],
    );
  }

  Widget _episodeLoadStatus(
    BuildContext context,
    AsyncValue<List<Episode>> episodesState,
  ) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

    if (episodesState.isLoading) {
      // Episode UI v2: keep the loading state centered horizontally.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const AppLoadingIndicator(),
              const SizedBox(height: 12),
              Text(
                isArabic
                    ? 'يتم تحميل الحلقات…'
                    : 'Episodes are loading…',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (episodesState.hasError) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isArabic ? 'تعذر تحميل الحلقات' : 'Could not load episodes',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: () {
                ref
                    .read(detailsControllerProvider(widget.item.url).notifier)
                    .retryEpisodes();
              },
              icon: const Icon(Icons.refresh_rounded),
              label: Text(isArabic ? 'إعادة المحاولة' : 'Retry'),
            ),
          ],
        ),
      );
    }

    final episodes = episodesState.asData?.value ?? const <Episode>[];
    if (episodes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Text(isArabic ? 'لا توجد حلقات متاحة' : 'No episodes available'),
      );
    }

    return const SizedBox.shrink();
  }

  List<String> _normalizedGenres(MultimediaItem item) {
    final seen = <String>{};
    final genres = <String>[];

    for (final rawTag in item.tags ?? const <String>[]) {
      for (final candidate in rawTag.split(RegExp(r'[,،|/]'))) {
        final genre = candidate.trim();
        if (genre.isEmpty) continue;

        final key = genre.toLowerCase();
        if (seen.add(key)) {
          genres.add(genre);
        }
      }
    }

    return genres;
  }

  void _openGenreResults(BuildContext context, String genre) {
    final provider = ref.read(activeProviderProvider);
    if (provider == null) return;

    final filters = ProviderSearchFilters(genres: <String>{genre});
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ViewAllScreen(
          title: genre,
          initialMediaList: const <MultimediaItem>[],
          category: ViewAllCategory.providerContent,
          forcePortrait: true,
          loadPage: (offset) => provider.searchPage(
            '',
            filters,
            offset: offset,
            limit: provider.searchPageSize,
          ),
        ),
      ),
    );
  }

  Widget _buildSynopsisAndGenres(
    BuildContext context,
    MultimediaItem item,
    AsyncValue<MultimediaItem?> detailsState,
    AppLocalizations l10n,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final genres = _normalizedGenres(item);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.38),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExpandableText(
              text: item.description ?? l10n.noDescription,
              maxLines: 4,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            if (detailsState.hasError) ...[
              const SizedBox(height: 12),
              Text(
                l10n.errorPrefix(detailsState.error.toString()),
                style: TextStyle(color: colors.error),
              ),
            ],
            if (genres.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final genre in genres)
                    Material(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(999),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => _openGenreResults(context, genre),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Text(
                            genre,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colors.onPrimary,
                              fontWeight: FontWeight.w600,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Content rendered below the desktop hero.
  Widget _buildDesktopContentBelow(
    BuildContext context,
    MultimediaItem item,
    AsyncValue<MultimediaItem?> detailsState,
    AsyncValue<List<Episode>> episodesState,
    AsyncValue<List<Actor>> castState,
    AsyncValue<List<Trailer>> trailersState,
    AsyncValue<List<MultimediaItem>> relatedState,
    AsyncValue<List<MultimediaItem>> recommendationsState,
    AppLocalizations l10n,
  ) {
    final tabContent = _selectedDetailsTab == 0
        ? <Widget>[
            _buildSynopsisAndGenres(context, item, detailsState, l10n),
            const SizedBox(height: 28),
            AnimeInformationSection(item: item),
            ..._buildIndependentDetailSections(
              context,
              item,
              l10n,
              castState,
              trailersState,
              relatedState,
              recommendationsState,
            ),
          ]
        : <Widget>[
            _episodeLoadStatus(context, episodesState),
            if (episodesState.hasValue &&
                (episodesState.value?.isNotEmpty ?? false)) ...[
              DetailsSeasonListWrapper(itemUrl: widget.item.url),
              const SizedBox(height: 16),
              DetailsDesktopEpisodeColumn(
                parentItem: item,
                itemUrl: widget.item.url,
                isMovie: false,
              ),
            ],
          ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDetailsPageTabs(context, episodesState),
        const SizedBox(height: 24),
        _buildTabTransition(
          child: Column(
            key: ValueKey<int>(_selectedDetailsTab),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: tabContent,
          ),
        ),
        const SizedBox(height: 100),
      ],
    );
  }

  List<Widget> _buildMobileSlivers(
    BuildContext context,
    MultimediaItem item,
    AsyncValue<MultimediaItem?> detailsState,
    AsyncValue<List<Episode>> episodesState,
    AsyncValue<List<Actor>> castState,
    AsyncValue<List<Trailer>> trailersState,
    AsyncValue<List<MultimediaItem>> relatedState,
    AsyncValue<List<MultimediaItem>> recommendationsState,
    AppLocalizations l10n,
  ) {
    final showDetailsPage = _selectedDetailsTab == 0;
    final episodeReady =
        episodesState.hasValue && (episodesState.value?.isNotEmpty ?? false);

    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DetailsActionButtons(
                item: widget.item,
                details: item,
                itemUrl: widget.item.url,
              ),
              if (item.nextAiring != null) ...[
                const SizedBox(height: 16),
                NextAiringWidget(nextAiring: item.nextAiring!),
              ],
              const SizedBox(height: 24),
              _buildDetailsPageTabs(context, episodesState),
            ],
          ),
        ),
      ),
    ];

    if (showDetailsPage) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildTabTransition(
            child: Padding(
              key: const ValueKey<int>(0),
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSynopsisAndGenres(context, item, detailsState, l10n),
                  const SizedBox(height: 28),
                  AnimeInformationSection(item: item),
                  ..._buildIndependentDetailSections(
                    context,
                    item,
                    l10n,
                    castState,
                    trailersState,
                    relatedState,
                    recommendationsState,
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      );

    } else {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildTabTransition(
            child: Padding(
              key: const ValueKey<int>(1),
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _episodeLoadStatus(context, episodesState),
                  if (episodeReady)
                    DetailsSeasonListWrapper(itemUrl: widget.item.url),
                  if (episodeReady) const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      );

      if (episodeReady) {
        slivers.add(
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            sliver: SliverDetailsEpisodeList(
              parentItem: item,
              itemUrl: widget.item.url,
              isMovie: false,
              transition: _tabTransitionAnimation,
              transitionOffset: _tabSlideFrom,
            ),
          ),
        );
      }

      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 50)));
    }

    return slivers;
  }
}
