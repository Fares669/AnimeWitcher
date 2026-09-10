import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:animewitcher/shared/widgets/mouse_drag_refresh_indicator.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/artwork_quality.dart';
import '../../../../core/utils/storyblok_image.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../../../../shared/widgets/fallback_poster_image.dart';
import 'premium_details_widgets.dart';

import 'package:animewitcher/core/utils/localized_text.dart';
import 'package:animewitcher/core/services/notification_service.dart';

/// Immersive desktop/TV hero for non-TMDB details.
///
/// The artwork is the page: it runs full width from the top of the window,
/// and the anime's name, its numbers and the row of actions sit low over it
/// where the picture has already darkened, rather than in a panel beside a
/// poster. Everything else about the page follows below in [child], reading
/// on the solid background the banner fades into.
class DetailsDesktopHero extends ConsumerWidget {
  const DetailsDesktopHero({
    super.key,
    required this.displayItem,
    required this.details,
    required this.detailsState,
    required this.isMovie,
    required this.itemUrl,
    required this.child,
    required this.onRefresh,
    this.onPosterTap,
    this.heroActions,
    this.story,
    this.nextAiring,
    // Kept for backwards compatibility with callers that still pass it,
    // but it's no longer used now that [DetailsActionButtons] is removed
    // from the desktop layout.
    this.baseItem,
  });

  /// The resolved item for display (details ?? widget.item).
  final MultimediaItem displayItem;

  /// Original item, retained as an optional hook. No longer used by the
  /// desktop hero now that the Play/Resume button is intentionally
  /// excluded from wide screens.
  final MultimediaItem? baseItem;

  /// Loaded details (nullable while loading).
  final MultimediaItem? details;

  /// Async state for loading/error indicators.
  final AsyncValue<MultimediaItem?> detailsState;

  final bool isMovie;
  final String itemUrl;

  /// Content rendered below the hero section (episodes, cast, etc.).
  final Widget child;

  /// Pull-to-refresh, matching Home and the other catalog lists.
  final Future<void> Function() onRefresh;

  /// Opens the fullscreen poster viewer at the largest available artwork.
  /// Reached by tapping the anime's name, which is what stands where the
  /// poster used to.
  final VoidCallback? onPosterTap;

  /// Actions for this anime, shown beneath its metadata. They used to sit in
  /// the toolbar, where the window's own caption buttons are painted over the
  /// same corner.
  final Widget? heroActions;

  /// The synopsis, which follows the actions rather than waiting in a card
  /// further down the page: it is the first thing a viewer reads to decide
  /// whether to press the button above it.
  final Widget? story;

  /// When the next episode lands, for a series still airing.
  final Widget? nextAiring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scaffoldColor = theme.scaffoldBackgroundColor;
    final textColor = theme.colorScheme.onSurface;

    final providedBannerUrl = AppImageFallbacks.optional(displayItem.bannerUrl);
    final posterUrl = AppImageFallbacks.poster(
      displayItem.posterUrl,
      label: displayItem.title,
    );
    // Asked for at its stored size; the catalog's own URL requests a
    // thumbnail-sized copy of it.
    final backdropUrl =
        AppImageFallbacks.banner(
          bannerUrl: displayItem.bannerUrl,
          posterUrl: displayItem.posterUrl,
          label: displayItem.title,
        ) ??
        '';
    final backdrop = storyblokAtStoredWidth(
      backdropUrl,
      maxWidth: storyblokBannerWidth,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // How far down the actions sit. Enough of the picture is left above
        // them to read as a frame from the show rather than a header image,
        // and enough room below for the synopsis to start on the same screen.
        final heroBand = (constraints.maxHeight * 0.56).clamp(300.0, 560.0);

        return MouseDragRefreshIndicator(
          onRefresh: onRefresh,
          child: SingleChildScrollView(
            key: const PageStorageKey<String>('desktop-details-info-tab'),
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The artwork and what sits on it are one piece of the page,
                // so they leave together as it is scrolled. Pinned behind the
                // scroll the picture never went anywhere, and the synopsis
                // and episodes read as if they were sliding over a window.
                Stack(
                  children: [
                    // The picture, behind the words and as tall as they make
                    // this section.
                    Positioned.fill(
                      child: ArtworkDecode(
                        paintedWidth: MediaQuery.sizeOf(context).width,
                        builder: (BuildContext context, int? decodeWidth) =>
                            FallbackPosterImage(
                              imageUrl: backdrop,
                              // Wide art, looked up the way Harbor does when
                              // the catalog has none and the viewer asked for
                              // other sources: AniList's banner, then what
                              // AniZip knows of TheTVDB and Kitsu.
                              preferBanner: true,
                              malId: displayItem.artworkLookupMalId,
                              title: displayItem.artworkLookupTitle,
                              fit: BoxFit.cover,
                              alignment: Alignment.topCenter,
                              memCacheWidth: decodeWidth,
                              filterQuality: FilterQuality.medium,
                              placeholder: (_) => ColoredBox(
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                              ),
                              errorWidget: (_) {
                                if (providedBannerUrl != null &&
                                    posterUrl != null &&
                                    providedBannerUrl != posterUrl) {
                                  return CachedNetworkImage(
                                    imageUrl: posterUrl,
                                    fit: BoxFit.cover,
                                    alignment: Alignment.topCenter,
                                    memCacheWidth: decodeWidth,
                                    filterQuality: FilterQuality.medium,
                                    errorWidget: (_, _, _) =>
                                        ThumbnailErrorPlaceholder(
                                          label: displayItem.title,
                                          isBackdrop: true,
                                        ),
                                  );
                                }
                                return ThumbnailErrorPlaceholder(
                                  label: displayItem.title,
                                  isBackdrop: true,
                                );
                              },
                            ),
                      ),
                    ),

                    // The picture goes to ground before the page's own
                    // content starts, so nothing below is read against art.
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              scaffoldColor.withValues(alpha: 0.15),
                              scaffoldColor.withValues(alpha: 0.78),
                              scaffoldColor,
                            ],
                            stops: const [0.0, 0.34, 0.62, 0.9],
                          ),
                        ),
                      ),
                    ),

                    // A lean toward the side the words are on, so a title
                    // over a pale frame keeps its contrast without dimming
                    // the whole shot.
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: AlignmentDirectional.centerStart,
                            end: AlignmentDirectional.centerEnd,
                            colors: [
                              scaffoldColor.withValues(alpha: 0.72),
                              scaffoldColor.withValues(alpha: 0.35),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.35, 0.72],
                          ),
                        ),
                      ),
                    ),

                    // The words. This is the only child that is not
                    // positioned, so it is what gives the section its size —
                    // and a column is only as wide as its widest child, which
                    // left the picture painted in a band the width of the
                    // text with the window black either side of it. Full
                    // width, so the artwork has the whole section to fill.
                    SizedBox(
                      width: double.infinity,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(60, heroBand, 60, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              // The poster is no longer in the hero, so the
                              // name carries the way into the artwork viewer
                              // rather than leaving it unreachable here.
                              onTap: onPosterTap,
                              onLongPress: () => _copyAnimeTitle(context),
                              child: displayItem.logoUrl != null
                                  ? ArtworkDecode(
                                      paintedWidth: 420,
                                      builder:
                                          (
                                            BuildContext context,
                                            int? decodeWidth,
                                          ) => CachedNetworkImage(
                                            imageUrl: displayItem.logoUrl!,
                                            height: 96,
                                            // This widget takes a resolved
                                            // alignment, so the start edge is
                                            // worked out here.
                                            alignment:
                                                Directionality.of(context) ==
                                                    TextDirection.rtl
                                                ? Alignment.centerRight
                                                : Alignment.centerLeft,
                                            fit: BoxFit.contain,
                                            memCacheWidth: decodeWidth,
                                            placeholder: (_, _) =>
                                                _buildTitle(textColor),
                                            errorWidget: (_, _, _) =>
                                                _buildTitle(textColor),
                                          ),
                                    )
                                  : _buildTitle(textColor),
                            ),
                            const SizedBox(height: 16),
                            // The scores ride with the metadata, in the same
                            // compact form the phone header uses: one line of
                            // "★ 7.34 · MAL 6.37" reads faster than two pills,
                            // and it keeps both layouts saying it one way.
                            MetadataBar(
                              item: displayItem,
                              isLoading: detailsState is AsyncLoading,
                            ),
                            if (heroActions != null) ...[
                              const SizedBox(height: 24),
                              heroActions!,
                            ],
                            if (nextAiring != null) ...[
                              const SizedBox(height: 16),
                              nextAiring!,
                            ],
                            if (story != null) ...[
                              const SizedBox(height: 28),
                              // Held to a readable measure rather than run to
                              // the width of the window, where the eye loses
                              // its way back to the start of the next line.
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 880,
                                ),
                                child: story!,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 44),

                // Everything else about the anime, on solid ground.
                Padding(
                  padding: const EdgeInsets.fromLTRB(60, 0, 60, 60),
                  child: child,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _copyAnimeTitle(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: displayItem.title));
    await HapticFeedback.selectionClick();

    if (!context.mounted) {
      return;
    }

    notificationServiceOf(context).showSuccess(
      appText(context, english: 'Title copied', arabic: 'تم نسخ العنوان'),
    );
  }

  Widget _buildTitle(Color textColor) {
    return Text(
      displayItem.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.start,
      style: TextStyle(
        color: textColor,
        fontSize: 44,
        fontWeight: FontWeight.bold,
        height: 1.1,
        letterSpacing: -0.5,
      ),
    );
  }
}
