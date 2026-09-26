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
    this.child = const SizedBox.shrink(),
    this.slivers,
    required this.onRefresh,
    this.onPosterTap,
    this.heroActions,
    this.story,
    this.nextAiring,
    this.manga = false,
    this.showPoster = false,
    this.compact = false,
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

  /// Content after [child] that is built only as it scrolls into view, such
  /// as a manga's chapters, which can run to well over a thousand rows.
  final List<Widget>? slivers;

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

  /// A manga: its artwork is looked up as a manga, and since the catalog
  /// keeps no banner for one, the banner AniList has is asked for before the
  /// poster is stretched across the window in its place.
  final bool manga;

  /// The poster beside the title. The anime page leaves it out; a manga,
  /// whose banner is often missing, keeps its cover in view.
  final bool showPoster;

  /// Drawn for a phone: the same page — the artwork, the poster beside the
  /// name, the actions and the story, then everything else — at a phone's
  /// size, with narrow margins and a smaller poster and title.
  final bool compact;

  double get _side => compact ? 16 : 60;
  double get _posterWidth => compact ? 104 : 170;
  double get _posterHeight => compact ? 150 : 245;

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
      manga && providedBannerUrl == null ? '' : backdropUrl,
      maxWidth: storyblokBannerWidth,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // How far down the actions sit. Enough of the picture is left above
        // them to read as a frame from the show rather than a header image,
        // and enough room below for the synopsis to start on the same screen.
        // With the poster beside the name the block is taller, so it starts
        // higher and the synopsis still begins on the first screen.
        final heroBand = compact
            // A phone keeps a wide slice of the picture above the poster:
            // about half the screen's width, so the frame still reads.
            ? (constraints.maxWidth * 0.5).clamp(150.0, 280.0)
            : showPoster
            ? (constraints.maxHeight * 0.56 - 150).clamp(160.0, 410.0)
            : (constraints.maxHeight * 0.56).clamp(300.0, 560.0);

        // How far the picture runs on below the name and the buttons, under
        // the first lines of the synopsis, fading out as it goes. A fixed
        // run rather than the synopsis's own height: tied to that, "show
        // more" made the box taller and the picture, filling it, zoomed in.
        final pictureRunOn = compact ? 150.0 : 200.0;

        final lazy = slivers;
        final page = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The artwork and what sits on it are one piece of the page,
            // so they leave together as it is scrolled. Pinned behind the
            // scroll the picture never went anywhere, and the synopsis
            // and episodes read as if they were sliding over a window.
            Stack(
              // The picture runs on past this block, under the synopsis.
              clipBehavior: Clip.none,
              children: [
                // The picture, behind the words and as tall as they make
                // this section plus the run-on — short of its foot by a
                // hair, so the fade below is the last thing drawn there.
                // Ending on the same edge, a fractional pixel row let a line
                // of the picture show through under the fade.
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  bottom: 3 - pictureRunOn,
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
                          manga: manga,
                          malId: displayItem.artworkLookupMalId,
                          title: displayItem.artworkLookupTitle,
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          memCacheWidth: decodeWidth,
                          filterQuality: FilterQuality.medium,
                          placeholder: (_) => ColoredBox(
                            color: theme.colorScheme.surfaceContainerHighest,
                          ),
                          errorWidget: (_) {
                            // A manga with no banner anywhere keeps its
                            // poster behind the title, as before.
                            if ((providedBannerUrl != null || manga) &&
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
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  bottom: -pictureRunOn,
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
                Positioned(
                  left: 0,
                  top: 0,
                  right: 0,
                  bottom: -pictureRunOn,
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
                    padding: EdgeInsets.fromLTRB(_side, heroBand, _side, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _withPoster(
                          context,
                          posterUrl,
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
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
                                        paintedWidth: compact ? 240 : 420,
                                        builder:
                                            (
                                              BuildContext context,
                                              int? decodeWidth,
                                            ) => CachedNetworkImage(
                                              imageUrl: displayItem.logoUrl!,
                                              memCacheWidth: decodeWidth,
                                              // Only the logo is held to its
                                              // height. The name standing in
                                              // for it, while it loads or when
                                              // it fails, was held to it too,
                                              // and a name of three lines lost
                                              // its last one under the details.
                                              imageBuilder: (context, image) =>
                                                  Image(
                                                    image: image,
                                                    height: compact ? 56 : 96,
                                                    // This widget takes a
                                                    // resolved alignment, so
                                                    // the start edge is worked
                                                    // out here.
                                                    alignment:
                                                        Directionality.of(
                                                              context,
                                                            ) ==
                                                            TextDirection.rtl
                                                        ? Alignment.centerRight
                                                        : Alignment.centerLeft,
                                                    fit: BoxFit.contain,
                                                  ),
                                              placeholder: (_, _) =>
                                                  _buildTitle(textColor),
                                              errorWidget: (_, _, _) =>
                                                  _buildTitle(textColor),
                                            ),
                                      )
                                    : _buildTitle(textColor),
                              ),
                              SizedBox(height: compact ? 8 : 16),
                              // The scores ride with the metadata, in the same
                              // compact form the phone header uses: one line of
                              // "★ 7.34 · MAL 6.37" reads faster than two pills,
                              // and it keeps both layouts saying it one way.
                              MetadataBar(
                                item: displayItem,
                                isLoading: detailsState is AsyncLoading,
                              ),
                            ],
                          ),
                        ),
                        if (heroActions != null) ...[
                          SizedBox(height: compact ? 18 : 24),
                          heroActions!,
                        ],
                        if (nextAiring != null) ...[
                          const SizedBox(height: 16),
                          nextAiring!,
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),

            // The synopsis, below the block whose height sizes the picture,
            // so opening it lengthens the page rather than the picture.
            if (story != null)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  _side,
                  compact ? 18 : 28,
                  _side,
                  0,
                ),
                // Held to a readable measure rather than run to the width
                // of the window, where the eye loses its way back to the
                // start of the next line.
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 880),
                  child: story!,
                ),
              ),

            SizedBox(height: compact ? 24 : 44),

            // Everything else about the anime, on solid ground.
            Padding(
              padding: EdgeInsets.fromLTRB(
                _side,
                0,
                _side,
                lazy == null ? _side : 0,
              ),
              child: child,
            ),
          ],
        );

        return MouseDragRefreshIndicator(
          onRefresh: onRefresh,
          child: lazy == null
              ? SingleChildScrollView(
                  key: const PageStorageKey<String>('desktop-details-info-tab'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: page,
                )
              : CustomScrollView(
                  key: const PageStorageKey<String>('desktop-details-info-tab'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: <Widget>[
                    SliverToBoxAdapter(child: page),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(_side, 0, _side, _side),
                      sliver: SliverMainAxisGroup(slivers: lazy),
                    ),
                  ],
                ),
        );
      },
    );
  }

  /// The name and its details, with the poster beside them at the start
  /// edge when [showPoster] asks for it, their bottoms lined up.
  Widget _withPoster(BuildContext context, String? posterUrl, Widget title) {
    if (!showPoster) return title;
    final colors = Theme.of(context).colorScheme;
    final poster = GestureDetector(
      key: const ValueKey<String>('details-hero-poster'),
      behavior: HitTestBehavior.opaque,
      onTap: onPosterTap,
      child: Container(
        width: _posterWidth,
        height: _posterHeight,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(compact ? 10 : 14),
          border: Border.all(color: colors.onSurface.withValues(alpha: 0.12)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 24,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: ArtworkDecode(
          paintedWidth: _posterWidth,
          builder: (BuildContext context, int? decodeWidth) =>
              FallbackPosterImage(
                imageUrl: posterUrl ?? '',
                malId: displayItem.artworkLookupMalId,
                title: displayItem.artworkLookupTitle,
                manga: manga,
                fit: BoxFit.cover,
                memCacheWidth: decodeWidth,
                placeholder: (_) =>
                    ColoredBox(color: colors.surfaceContainerHighest),
                errorWidget: (_) =>
                    ThumbnailErrorPlaceholder(label: displayItem.title),
              ),
        ),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        poster,
        SizedBox(width: compact ? 14 : 28),
        Expanded(child: title),
      ],
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
      maxLines: compact ? 3 : 2,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.start,
      style: TextStyle(
        color: textColor,
        fontSize: compact ? 22 : 44,
        fontWeight: FontWeight.bold,
        height: 1.1,
        letterSpacing: -0.5,
      ),
    );
  }
}
