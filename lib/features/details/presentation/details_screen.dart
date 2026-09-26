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
import '../../characters/presentation/anime_characters_screen.dart';
import '../../characters/presentation/character_details_screen.dart';
import 'related_anime_screen.dart';
import '../../comments/presentation/animewitcher_comments_screen.dart';
import '../../../core/utils/window_controls_inset.dart';
import '../../../core/utils/image_fallbacks.dart';
import '../../../core/utils/resume_episode.dart';
import 'details_item_merge.dart';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:animewitcher/core/utils/responsive_breakpoints.dart';

import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';

import '../../library/presentation/library_provider.dart';
import '../../library/presentation/library_auth.dart';
import '../../../core/storage/library_category.dart';
import '../../../core/account/account_providers.dart';
import '../../settings/presentation/account_screen.dart';

import 'details_controller.dart';
import "widgets/details_layout_widgets.dart";
import "widgets/episode_browse.dart";
import "widgets/details_desktop_hero.dart";
import "widgets/details_extra_tabs.dart";
import "widgets/anime_information_section.dart";
import "adult_content_warning.dart";
import "../../../shared/widgets/expandable_text.dart";
import "../../../shared/widgets/loading_indicator.dart";

import 'package:animewitcher/l10n/generated/app_localizations.dart';

import 'package:animewitcher/core/utils/localized_text.dart';
import 'package:animewitcher/core/services/notification_service.dart';

import 'widgets/details_seasons_bar.dart';
import 'widgets/details_hero_actions.dart';
import 'widgets/episode_search.dart';
import 'widgets/next_airing_chip.dart';
import 'widgets/details_comments_preview.dart';
import 'details_ratings.dart';
import 'widgets/details_rating_actions.dart';

import 'package:url_launcher/url_launcher.dart';

class _DetailsLoadFailure extends StatefulWidget {
  const _DetailsLoadFailure({
    required this.onRetry,
    required this.title,
    required this.message,
  });

  final Future<void> Function() onRetry;
  final String title;
  final String message;

  @override
  State<_DetailsLoadFailure> createState() => _DetailsLoadFailureState();
}

class _DetailsLoadFailureState extends State<_DetailsLoadFailure> {
  bool _isRetrying = false;

  Future<void> _retry() async {
    if (_isRetrying) return;
    setState(() => _isRetrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _isRetrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.wifi_off_rounded,
            size: 68,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 18),
          Text(
            widget.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 22),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: _isRetrying ? null : _retry,
                icon: _isRetrying
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
                label: Text(
                  appText(context, english: 'Retry', arabic: 'إعادة المحاولة'),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  if (GoRouter.maybeOf(context) == null) return;
                  const DownloadsRoute().go(context);
                },
                icon: const Icon(Icons.download_for_offline_rounded),
                label: Text(
                  appText(context, english: 'Downloads', arabic: 'التنزيلات'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
    with TickerProviderStateMixin {
  bool _didTriggerAutoPlay = false;
  final GlobalKey _extraTabsKey = GlobalKey();

  static const String _removeLibraryAction = '__remove_from_library__';

  List<AppleLiquidGlassToolbarButton> _buildDetailsHeaderButtons(
    BuildContext context,
    MultimediaItem item, {
    required bool isFavorite,
    required dynamic libraryNotifier,
    required Color foregroundColor,

    /// The desktop page reads the comments themselves at its foot, so an
    /// icon that only says they exist would be the lesser way in.
    bool includeComments = true,

    /// The desktop hero spells the list out on a capsule of its own, so the
    /// same menu behind a bookmark glyph would be the second way to say it.
    bool includeLibraryMenu = true,
  }) {
    const favoriteRed = Color(0xFFFF3B30);
    final colors = Theme.of(context).colorScheme;
    final commentTarget = animeWitcherAnimeCommentTarget(item);
    final LibraryCategory? currentCategory =
        libraryNotifier.itemCategory(item.url) as LibraryCategory?;

    return <AppleLiquidGlassToolbarButton>[
      if (includeComments && commentTarget != null)
        AppleLiquidGlassToolbarButton(
          tooltip: appText(context, english: 'Comments', arabic: 'التعليقات'),
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
        onPressed: () async {
          if (!await _ensureSignedInForLibrary(context)) return;
          await libraryNotifier.setFavorite(item, !isFavorite);
        },
      ),
      if (includeLibraryMenu)
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
          onPressed: null,
          selectedMenuValue: currentCategory?.storageKey,
          menuItems: _libraryCategoryMenuItems(context, item, currentCategory),
          onMenuSelected: (value) => _handleLibraryMenuSelection(item, value),
        ),
    ];
  }

  /// The row that sits over the banner on a desktop details page.
  ///
  /// Playing the episode a viewer is up to is the reason the page exists, so
  /// it is a filled pill and the first thing on the line. The list this anime
  /// is in reads as a capsule saying which one, since a bookmark glyph alone
  /// never said whether it meant "saved" or "watching". The rest stay as
  /// glass buttons beside them.
  Widget _buildDesktopHeroActionRow(
    BuildContext context,
    MultimediaItem item, {
    required bool isFavorite,
    required dynamic libraryNotifier,
    required Color foregroundColor,
    Color? fallbackColor,
  }) {
    final LibraryCategory? category =
        libraryNotifier.itemCategory(item.url) as LibraryCategory?;
    final details = ref
        .watch(detailsControllerProvider(widget.item.url))
        .details
        .value;

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DetailsHeroPlayPill(
          item: item,
          details: details,
          itemUrl: widget.item.url,
        ),
        PopupMenuButton<String>(
          tooltip: appText(
            context,
            english: 'Choose list',
            arabic: 'اختر قائمة',
          ),
          padding: EdgeInsets.zero,
          offset: const Offset(0, 8),
          color: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          shape: const RoundedRectangleBorder(),
          itemBuilder: (menuContext) => [
            PopupMenuItem<String>(
              enabled: false,
              padding: EdgeInsets.zero,
              child: BlurredMenuPanel(
                items: _libraryCategoryMenuItems(context, item, category),
                selectedValue: category?.storageKey ?? '',
                tint: Theme.of(context).colorScheme.onSurface,
                fallbackIcon: Icons.bookmark_border_rounded,
                onPick: (value) {
                  Navigator.of(menuContext).pop();
                  _handleLibraryMenuSelection(item, value);
                },
              ),
            ),
          ],
          child: DetailsHeroPill(
            fallbackColor: fallbackColor,
            label: category == null
                ? appText(context, english: 'Add to list', arabic: 'أضف لقائمة')
                : _libraryCategoryLabel(context, category),
            icon: category == null
                ? Icons.bookmark_border_rounded
                : _libraryCategoryIcon(category),
            selected: category != null,
            trailing: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: category != null
                  ? Theme.of(context).colorScheme.primary
                  : foregroundColor,
            ),
          ),
        ),
        // Each on its own rather than sharing a capsule: they do unrelated
        // things, and a viewer reaching for one is not choosing from a set.
        DetailsHeroIconButton(
          icon: Icons.star_outline_rounded,
          tooltip: appText(context, english: 'Rate this', arabic: 'قيّم'),
          foregroundColor: foregroundColor,
          fallbackColor: fallbackColor,
          onPressed: () => openAnimeRatingDialog(
            context,
            ref,
            ratings: AnimeDetailsRatings.fromItem(item),
          ),
        ),
        DetailsHeroIconButton(
          icon: Icons.rate_review_outlined,
          tooltip: appText(context, english: 'Reviews', arabic: 'المراجعات'),
          foregroundColor: foregroundColor,
          fallbackColor: fallbackColor,
          onPressed: () => openAnimeReviews(
            context,
            ref,
            item: item,
            ratings: AnimeDetailsRatings.fromItem(item),
          ),
        ),
        if (_firstTrailerUrl(item) != null)
          DetailsHeroIconButton(
            icon: Icons.movie_outlined,
            tooltip: appText(
              context,
              english: 'Watch trailer',
              arabic: 'العرض الدعائي',
            ),
            foregroundColor: foregroundColor,
            fallbackColor: fallbackColor,
            onPressed: () => _openTrailer(context, item),
          ),
        for (final button in _buildDetailsHeaderButtons(
          context,
          item,
          isFavorite: isFavorite,
          libraryNotifier: libraryNotifier,
          foregroundColor: foregroundColor,
          includeLibraryMenu: false,
          includeComments: false,
        ))
          DetailsHeroIconButton(
            icon: button.icon,
            tooltip: button.tooltip ?? '',
            foregroundColor: button.color ?? foregroundColor,
            fallbackColor: fallbackColor,
            onPressed: button.onPressed ?? () {},
          ),
      ],
    );
  }

  /// The trailer this anime leads with, if it has one.
  String? _firstTrailerUrl(MultimediaItem item) {
    final trailers =
        ref
            .watch(detailsControllerProvider(widget.item.url))
            .trailers
            .asData
            ?.value ??
        item.trailers ??
        const <Trailer>[];
    for (final trailer in trailers) {
      final url = trailer.url.trim();
      if (url.isNotEmpty) return url;
    }
    return null;
  }

  Future<void> _openTrailer(BuildContext context, MultimediaItem item) async {
    final url = _firstTrailerUrl(item);
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
      for (final category in LibraryCategory.assignmentValuesFor(item))
        AppleNativeMenuItem(
          value: category.storageKey,
          label: _libraryCategoryLabel(context, category),
          systemImage: _libraryCategorySystemImage(category),
          icon: _libraryCategoryIcon(category),
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
          icon: Icons.delete_outline_rounded,
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
    if (!await _ensureSignedInForLibrary(context)) return;
    final notifier = ref.read(libraryProvider.notifier);
    if (value == _removeLibraryAction) {
      await notifier.clearItemCategory(item.url);
      return;
    }
    LibraryCategory? category;
    for (final candidate in LibraryCategory.assignmentValuesFor(item)) {
      if (candidate.storageKey == value) {
        category = candidate;
        break;
      }
    }
    if (category != null) {
      await notifier.addItem(item, category: category);
    }
  }

  Future<bool> _ensureSignedInForLibrary(BuildContext context) async {
    if (ref.read(animeWitcherAccountServiceProvider).isSignedIn) {
      return true;
    }
    final isArabic = Localizations.localeOf(context).languageCode == 'ar';
    ref
        .read(notificationServiceProvider)
        .showInfo(
          librarySignInRequiredMessage(isArabic: isArabic),
          icon: Icons.lock_outline_rounded,
          duration: const Duration(seconds: 3),
        );
    if (!context.mounted) return false;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => const AnimeWitcherAccountScreen(),
      ),
    );
    return ref.read(animeWitcherAccountServiceProvider).isSignedIn;
  }

  Future<void> _showPosterViewer(
    BuildContext context,
    MultimediaItem item,
  ) async {
    final posterUrl = AppImageFallbacks.poster(
      item.posterViewerUrl,
      label: item.title,
    );
    if (posterUrl == null || posterUrl.isEmpty) return;
    final previewUrl = AppImageFallbacks.poster(
      item.posterUrl,
      label: item.title,
    );

    await showGeneralDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
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
                // Always fetch and decode the largest poster, even when the
                // catalog high-quality setting is off.
                child: CachedNetworkImage(
                  imageUrl: posterUrl,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                  placeholder: (_, _) {
                    if (previewUrl != null &&
                        previewUrl.isNotEmpty &&
                        previewUrl != posterUrl) {
                      return CachedNetworkImage(
                        imageUrl: previewUrl,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.medium,
                        placeholder: (_, _) =>
                            const Center(child: CircularProgressIndicator()),
                        errorWidget: (_, _, _) =>
                            const Center(child: CircularProgressIndicator()),
                      );
                    }
                    return const Center(child: CircularProgressIndicator());
                  },
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
      transitionBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    );
  }

  Episode? _resumeEpisodeFrom(List<Episode> episodes) {
    return matchResumeEpisode(
      episodes,
      resumeEpisodeUrl: widget.resumeEpisodeUrl,
      resumeEpisodeNumber: widget.resumeEpisodeNumber,
      resumeSeason: widget.resumeSeason,
    );
  }

  @override
  void initState() {
    super.initState();
    // A number typed on one series means nothing on the next: arriving at an
    // anime already filtered down to four episodes reads as a broken list.
    episodeSearchQuery.value = '';
    // Likewise a block or filter picked on the last series.
    resetEpisodeBrowse();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(detailsControllerProvider(widget.item.url).notifier)
          .loadDetails(widget.item, autoPlay: widget.autoPlay);
    });
  }

  Future<void> _refreshDetails() {
    return ref
        .read(detailsControllerProvider(widget.item.url).notifier)
        .refreshDetails();
  }

  @override
  void dispose() {
    applePersistentGlassHeaderController.hide(this);
    super.dispose();
  }

  void _syncPersistentGlassHeader({
    required BuildContext context,
    required MultimediaItem item,
    required bool isFavorite,
    required dynamic libraryNotifier,
    required Color foregroundColor,
    required Color fallbackColor,
  }) {
    if (!appleUsesPersistentLiquidGlassHeader) return;
    final trailingButtons = _buildDetailsHeaderButtons(
      context,
      item,
      isFavorite: isFavorite,
      libraryNotifier: libraryNotifier,
      foregroundColor: foregroundColor,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      applePersistentGlassHeaderController.show(
        ApplePersistentGlassHeaderConfig(
          owner: this,
          route: ModalRoute.of(context),
          onBack: () => Navigator.of(context).maybePop(),
          backForegroundColor: foregroundColor,
          backFallbackColor: fallbackColor,
          trailingButtons: trailingButtons,
          instantRouteBoundary: true,
        ),
      );
    });
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
      final fallbackResumeUrl =
          resumeEpisode == null && resumeUrl != null && resumeUrl.isNotEmpty
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
      detailsControllerProvider(widget.item.url)
          .select((s) => s.recommendations),
    );
    final currentItem = ref.watch(
      detailsControllerProvider(widget.item.url).select((s) => s.item),
    );
    final initialPageReady = ref.watch(
      detailsControllerProvider(widget.item.url).select((s) => s.isShellReady),
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
      detailsControllerProvider(widget.item.url)
          .select((state) => state.selectedEpisodeKeys.length),
    );

    final l10n = AppLocalizations.of(context)!;

    if (!initialPageReady) {
      _syncPersistentGlassHeader(
        context: context,
        item: item,
        isFavorite: isFavorite,
        libraryNotifier: libraryNotifier,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        fallbackColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      );
      return Scaffold(
        // A wide window waits behind the same bare bar the page itself uses:
        // one back button over the artwork, nothing else. Handed the handset
        // header instead, the desktop page opened on a row of buttons that
        // vanished a moment later, once the details arrived.
        extendBodyBehindAppBar: true,
        appBar: _buildDesktopChromeAppBar(context),
        body: Center(
          child: AppLoadingIndicator(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
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

    _syncPersistentGlassHeader(
      context: context,
      item: item,
      isFavorite: isFavorite,
      libraryNotifier: libraryNotifier,
      foregroundColor: Theme.of(context).colorScheme.onSurface,
      fallbackColor: Theme.of(context).colorScheme.surfaceContainerHigh,
    );

    // ── Phone: one page, the desktop's in a phone's size ──
    // The artwork runs to the top with the poster beside the name, then the
    // actions, the story and the episodes on the same page, rather than a
    // pinned bar over two tabs with the episodes behind the second.
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Scaffold(
      extendBodyBehindAppBar: true,
      bottomNavigationBar: selectedEpisodeCount == 0
          ? null
          : _buildEpisodeSelectionBar(context, selectedEpisodeCount),
      appBar: _buildDesktopChromeAppBar(context),
      body: DetailsDesktopHero(
        compact: true,
        showPoster: true,
        displayItem: item,
        baseItem: widget.item,
        details: item,
        detailsState: detailsAsync,
        isMovie: false,
        itemUrl: widget.item.url,
        onRefresh: _refreshDetails,
        onPosterTap: () => _showPosterViewer(context, item),
        heroActions: _buildDesktopHeroActionRow(
          context,
          item,
          isFavorite: isFavorite,
          libraryNotifier: libraryNotifier,
          foregroundColor: theme.colorScheme.onSurface,
          fallbackColor: isDark ? Colors.black45 : Colors.white54,
        ),
        story: detailsAsync.hasError
            ? null
            : _buildHeroStory(context, item, l10n),
        nextAiring: item.nextAiring == null
            ? null
            : NextAiringChip(nextAiring: item.nextAiring!),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (shouldShowAdultContentWarning(item)) ...[
              const AdultContentWarningBanner(),
              const SizedBox(height: 16),
            ],
          ],
        ),
        // Built as they scroll into view: a long anime has hundreds of
        // episodes.
        slivers: <Widget>[
          ..._buildPhoneEpisodeSlivers(context, item, episodesAsync),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 32),
                _buildDesktopDetailsContentBelow(
                  context,
                  item,
                  detailsAsync,
                  castAsync,
                  trailersAsync,
                  relatedAsync,
                  recommendationsAsync,
                  l10n,
                ),
                const SizedBox(height: 24),
                DetailsCommentsPreview(item: item),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The seasons and the episodes for the phone page, the list built as it
  /// scrolls into view.
  List<Widget> _buildPhoneEpisodeSlivers(
    BuildContext context,
    MultimediaItem item,
    AsyncValue<List<Episode>> episodesState,
  ) {
    final ready =
        episodesState.hasValue && (episodesState.value?.isNotEmpty ?? false);
    if (!ready) {
      return [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 200,
            child: Center(child: _episodeLoadStatus(context, episodesState)),
          ),
        ),
      ];
    }
    return [
      SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DetailsSeasonsBar(
              itemUrl: widget.item.url,
              current: item,
              onOpen: (child) => _openExtraAnime(item, child),
            ),
            DetailsSeasonListWrapper(itemUrl: widget.item.url),
            const SizedBox(height: 12),
          ],
        ),
      ),
      SliverDetailsEpisodeList(
        parentItem: item,
        itemUrl: widget.item.url,
        isMovie: false,
      ),
    ];
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
                            tooltip: isArabic
                                ? 'إلغاء التحديد'
                                : 'Cancel selection',
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
                            tooltip: isArabic
                                ? 'تحديد جميع الحلقات'
                                : 'Select all episodes',
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

  void _openExtraAnime(MultimediaItem parent, MultimediaItem child) {
    final target = _inheritProvider(parent, child);
    DetailsRoute($extra: DetailsRouteExtra(item: target)).push<void>(context);
  }

  void _openCharacter(Actor actor) {
    final id = actor.id?.trim() ?? '';
    if (id.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CharacterDetailsScreen(
          characterId: id,
          initialName: actor.name,
          initialImageUrl: actor.image,
        ),
      ),
    );
  }

  void _openAnimeCharacters(MultimediaItem item, {String? characterType}) {
    final animeId = animeWitcherAnimeCommentTarget(item)?.animeId;
    if (animeId == null || animeId.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AnimeCharactersScreen(
          animeId: animeId,
          animeTitle: item.title,
          characterType: characterType,
        ),
      ),
    );
  }

  void _onExtraTabBecameVisible(int index) {
    final controller = ref.read(
      detailsControllerProvider(widget.item.url).notifier,
    );
    switch (index) {
      case detailsExtraCharactersTabIndex:
        controller.loadCastIfNeeded();
      default:
        controller.loadRecommendationsIfNeeded();
    }
  }

  Widget _buildDetailsExtraTabs(
    BuildContext context,
    MultimediaItem item,
    AsyncValue<List<Actor>> castState,
    AsyncValue<List<MultimediaItem>> relatedState,
    AsyncValue<List<MultimediaItem>> recommendationsState, {
    EdgeInsetsGeometry contentPadding = const EdgeInsets.symmetric(
      horizontal: MultimediaCardLayout.handsetPortraitGridHorizontalPadding,
    ),
  }) {
    final related = _uniqueMediaItems(
      relatedState.asData?.value ?? item.related,
    );
    final similarState = recommendationsState.whenData(
      (value) => _recommendationsWithoutRelatedLists(value, related),
    );
    final similarHasMore = ref.watch(
      detailsControllerProvider(widget.item.url)
          .select((state) => state.similarHasMore),
    );
    final controller = ref.read(
      detailsControllerProvider(widget.item.url).notifier,
    );
    return DetailsExtraTabs(
      key: _extraTabsKey,
      similar: similarState,
      similarHasMore: similarHasMore,
      cast: castState,
      contentPadding: contentPadding,
      onTabBecameVisible: _onExtraTabBecameVisible,
      onAnimeTap: (child) => _openExtraAnime(item, child),
      onCharacterTap: _openCharacter,
      onShowMoreSimilar: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SimilarAnimeScreen(source: item),
          ),
        );
      },
      onShowMoreCharacters: (role) {
        _openAnimeCharacters(item, characterType: role);
      },
      onRetrySimilar: controller.loadRecommendationsIfNeeded,
      onRetryCast: controller.loadCastIfNeeded,
    );
  }

  /// The bare bar the desktop page wears: a back button over the artwork and
  /// nothing else, since the anime's own actions sit under its title.
  PreferredSizeWidget _buildDesktopChromeAppBar(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          automaticallyImplyLeading: false,
          leadingWidth: appleUsesPersistentLiquidGlassHeader ? 0 : 64,
          leading: appleUsesPersistentLiquidGlassHeader
              ? null
              : Padding(
                  padding: EdgeInsets.only(
                    left: 8 + windowControlsLeadingInset,
                  ),
                  child: AppleLiquidGlassBackButton(
                    size: 46,
                    foregroundColor: theme.colorScheme.onSurface,
                    fallbackColor: isDark ? Colors.black45 : Colors.white54,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
          actions: const <Widget>[],
        ),
      ),
    );
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

    _syncPersistentGlassHeader(
      context: context,
      item: item,
      isFavorite: isFavorite,
      libraryNotifier: libraryNotifier,
      foregroundColor: textColor,
      fallbackColor: isDark
          ? Colors.black45
          : Theme.of(context).colorScheme.surfaceContainerHigh,
    );

    return Scaffold(
      // One page now, so this shows whenever episodes are selected rather
      // than only while the episodes tab was the one on screen.
      bottomNavigationBar: selectedEpisodeCount == 0
          ? null
          : _buildEpisodeSelectionBar(context, selectedEpisodeCount),
      // The banner starts at the top edge of the window, with the back button
      // and the two tabs floating over it. They used to sit in a bar of their
      // own above the artwork, which cut a black strip across the top of
      // every anime.
      extendBodyBehindAppBar: true,
      appBar: _buildDesktopChromeAppBar(context),
      body: DetailsDesktopHero(
        displayItem: item,
        baseItem: widget.item,
        details: item,
        detailsState: detailsState,
        isMovie: isMovie,
        itemUrl: widget.item.url,
        onRefresh: _refreshDetails,
        onPosterTap: () => _showPosterViewer(context, item),
        heroActions: _buildDesktopHeroActionRow(
          context,
          item,
          isFavorite: isFavorite,
          libraryNotifier: libraryNotifier,
          foregroundColor: textColor,
          fallbackColor: isDark ? Colors.black45 : Colors.white54,
        ),
        story: _buildHeroStory(context, item, l10n),
        nextAiring: item.nextAiring == null
            ? null
            : NextAiringChip(nextAiring: item.nextAiring!),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The rating warning sits with the episodes rather than at the
            // top of the particulars further down: it is about what is in
            // them, and this is where they start.
            if (shouldShowAdultContentWarning(item)) ...[
              const AdultContentWarningBanner(),
              const SizedBox(height: 20),
            ],
            // The episodes follow the synopsis on the same page rather than
            // behind a tab. Picking one is the reason for the page, and a
            // viewer who has just read what the anime is about should not
            // have to go looking for a second screen to start it.
            _buildDesktopEpisodesContent(context, item, episodesState),
            const SizedBox(height: 44),
            _buildDesktopDetailsContentBelow(
              context,
              item,
              detailsState,
              castState,
              trailersState,
              relatedState,
              recommendationsState,
              l10n,
            ),
            const SizedBox(height: 32),
            DetailsCommentsPreview(item: item),
          ],
        ),
      ),
    );
  }

  Widget _episodeLoadStatus(
    BuildContext context,
    AsyncValue<List<Episode>> episodesState,
  ) {
    final isArabic =
        Localizations.localeOf(context).languageCode.toLowerCase() == 'ar';

    if (episodesState.isLoading) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const AppLoadingIndicator(),
          const SizedBox(height: 12),
          Text(
            isArabic ? 'يتم تحميل الحلقات…' : 'Episodes are loading…',
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    if (episodesState.hasError) {
      return _DetailsLoadFailure(
        onRetry: () => ref
            .read(detailsControllerProvider(widget.item.url).notifier)
            .retryEpisodes(),
        title: appText(
          context,
          english: 'Unable to load episodes',
          arabic: 'تعذر تحميل الحلقات',
        ),
        message: _detailsRecoveryMessage(context),
      );
    }

    final episodes = episodesState.asData?.value ?? const <Episode>[];
    if (episodes.isEmpty) {
      return Text(
        isArabic ? 'لا توجد حلقات متاحة' : 'No episodes available',
        textAlign: TextAlign.center,
      );
    }

    return const SizedBox.shrink();
  }

  String _detailsRecoveryMessage(BuildContext context) {
    return appText(
      context,
      english: 'Check your connection, then retry or continue with downloaded episodes.',
      arabic: 'تحقق من اتصالك ثم أعد المحاولة، أو تابع الحلقات التي نزّلتها مسبقًا.',
    );
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

  /// The synopsis as it reads under the hero actions: the text itself and the
  /// genres, with nothing drawn around them.
  ///
  /// The card the page used further down had a panel and a border, which is
  /// right in a column of other cards and wrong as the first thing under a
  /// row of buttons on the artwork.
  Widget _buildHeroStory(
    BuildContext context,
    MultimediaItem item,
    AppLocalizations l10n,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final genres = _normalizedGenres(item);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExpandableText(
          text: item.description ?? l10n.noDescription,
          maxLines: 4,
          // Over artwork, among white words: the accent shouted.
          toggleColor: colors.onSurface,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: colors.onSurface.withValues(alpha: 0.86),
            height: 1.6,
          ),
        ),
        if (genres.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              // The same glass as the buttons above them. Solid accent, a
              // row of them read as the loudest thing on the artwork while
              // saying the least.
              for (final genre in genres)
                Material(
                  color: kDetailsHeroGlassFallback,
                  shape: StadiumBorder(
                    side: BorderSide(
                      color: colors.onSurfaceVariant.withValues(alpha: 0.16),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _openGenreResults(context, genre),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      child: Text(
                        genre,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: colors.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// Details-only content rendered below the desktop hero. The poster, title,
  /// metadata and every non-episode section stay inside the Details tab, just
  /// like the handset layout.
  Widget _buildDesktopDetailsContentBelow(
    BuildContext context,
    MultimediaItem item,
    AsyncValue<MultimediaItem?> detailsState,
    AsyncValue<List<Actor>> castState,
    AsyncValue<List<Trailer>> trailersState,
    AsyncValue<List<MultimediaItem>> relatedState,
    AsyncValue<List<MultimediaItem>> recommendationsState,
    AppLocalizations l10n,
  ) {
    if (detailsState.hasError) {
      return SizedBox(
        height: 360,
        width: double.infinity,
        child: Center(
          child: _DetailsLoadFailure(
            onRetry: _refreshDetails,
            title: appText(
              context,
              english: 'Unable to load this anime',
              arabic: 'تعذر تحميل بيانات الأنمي',
            ),
            message: _detailsRecoveryMessage(context),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The score panel, the synopsis and the countdown used to sit here.
        // All three are up in the hero now — the scores beside the buttons,
        // the story under them and the wait for the next episode on its own
        // line — so what is left is the anime's own particulars.
        AnimeInformationSection(item: item),
        const SizedBox(height: 24),
        _buildDetailsExtraTabs(
          context,
          item,
          castState,
          relatedState,
          recommendationsState,
          contentPadding: EdgeInsets.zero,
        ),
        // No tail here: this was the foot of the page when these tabs ended
        // it, and the comments follow them now.
      ],
    );
  }

  Widget _buildDesktopEpisodesContent(
    BuildContext context,
    MultimediaItem item,
    AsyncValue<List<Episode>> episodesState,
  ) {
    if (episodesState.hasValue && (episodesState.value?.isNotEmpty ?? false)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DetailsSeasonsBar(
            itemUrl: widget.item.url,
            current: item,
            onOpen: (child) => _openExtraAnime(item, child),
          ),
          DetailsSeasonListWrapper(itemUrl: widget.item.url),
          const SizedBox(height: 16),
          DetailsDesktopEpisodeColumn(
            parentItem: item,
            itemUrl: widget.item.url,
            isMovie: false,
          ),
        ],
      );
    }

    return SizedBox(
      height: 280,
      width: double.infinity,
      child: Center(child: _episodeLoadStatus(context, episodesState)),
    );
  }
}
