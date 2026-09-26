import 'package:flutter/material.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';

import '../../core/domain/entity/multimedia_item.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/artwork_quality.dart';
import '../../core/utils/catalog_rating.dart';
import '../../core/utils/catalog_label.dart';
import '../../core/utils/image_fallbacks.dart';
import '../../core/utils/responsive_breakpoints.dart';
import 'cards_wrapper.dart';
import 'fallback_poster_image.dart';
import 'shimmer_placeholder.dart';
import 'thumbnail_error_placeholder.dart';

/// Shared poster + caption metrics so rails and grids reserve the same space.
class MultimediaCardLayout {
  static const double captionHeight = 46;
  static const double posterRadius = 12;
  static const double portraitGridAspectRatio = 0.52;
  static const double landscapeGridAspectRatio = 1.12;
  static const double desktopPortraitGridAspectRatio = 0.54;

  /// Character cards reserve less room below the poster because they only
  /// render one name line, while anime cards reserve title + type space.
  static const double characterGridAspectRatio = 0.58;

  /// Search is the mobile catalog reference: every portrait anime grid uses
  /// these metrics so the same poster has the same physical size everywhere.
  static const int handsetPortraitGridColumns = 3;
  static const double handsetPortraitGridHorizontalPadding = 12;
  static const double handsetPortraitGridCrossAxisSpacing = 10;
  static const double handsetPortraitGridMainAxisSpacing = 14;
  static const double handsetLandscapeGridHorizontalPadding = 8;

  static double catalogGridHorizontalPadding(
    BuildContext context, {
    double fallback = 16,
  }) {
    if (context.isHandsetLandscape)
      return handsetLandscapeGridHorizontalPadding;
    if (context.isHandset) return handsetPortraitGridHorizontalPadding;
    return fallback;
  }

  static double catalogGridCrossAxisSpacing(
    BuildContext context, {
    double fallback = 16,
  }) {
    if (context.isHandsetLandscape) {
      return ResponsiveBreakpoints.handsetLandscapeGridMaxSpacing;
    }
    if (context.isHandset) return handsetPortraitGridCrossAxisSpacing;
    return fallback;
  }

  static double catalogGridMainAxisSpacing(
    BuildContext context, {
    double fallback = 16,
  }) {
    if (context.isHandsetLandscape) {
      return ResponsiveBreakpoints.handsetLandscapeGridMaxSpacing;
    }
    if (context.isHandset) return handsetPortraitGridMainAxisSpacing;
    return fallback;
  }

  /// Single source of truth for the poster width used by horizontal rails.
  ///
  /// Rails, their shimmer placeholders and the cards themselves must all
  /// agree on this number, otherwise the reserved row height does not match
  /// the painted card and the rail jitters as posters load. Pass the same
  /// [horizontalPadding] / [spacing] the rail uses for its own padding and
  /// inter-card gap.
  static double cardWidth(
    BuildContext context, {
    required bool isPortrait,
    double? horizontalPadding,
    double? spacing,
  }) {
    if (context.isHandsetLandscape) {
      return ResponsiveBreakpoints.handsetLandscapeAnimeCardWidth(
        context,
        horizontalPadding: horizontalPadding ?? 16,
        spacing: spacing ?? 8,
      );
    }
    if (context.isDesktopLandscape) {
      return ResponsiveBreakpoints.desktopLandscapeAnimeCardWidth(
        context,
        horizontalPadding: horizontalPadding ?? 16,
        spacing: spacing ?? 16,
      );
    }
    if (context.isDesktop) {
      return isPortrait ? 200.0 : 300.0;
    }
    return isPortrait ? 130.0 : 200.0;
  }

  static double posterAspectRatio({required bool isPortrait}) =>
      isPortrait ? 2 / 3 : 16 / 9;

  /// Height of an anime caption block when both title and subtitle are present.
  /// This mirrors [_buildCaption] exactly so loading skeletons leave the same
  /// amount of room as the final card instead of changing poster height on load.
  static double animeCaptionExtent(BuildContext context) {
    final effectiveCompact = context.isDesktopLandscape;
    final isDesktop = context.isDesktop;
    final titleSize = effectiveCompact ? 12.0 : (isDesktop ? 15.0 : 13.0);
    final subtitleSize = effectiveCompact ? 10.0 : (isDesktop ? 12.0 : 11.0);
    return 6 + (titleSize * 1.2) + 2 + (subtitleSize * 1.2);
  }

  /// Character cards only have the name line under the image.
  static double characterCaptionExtent(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final fontSize = style?.fontSize ?? 12.0;
    return 6 + (fontSize * 1.15);
  }

  /// Horizontal home rails use the same total card aspect ratio as catalog
  /// grids. This keeps the home card height identical to Search/View All for a
  /// given width and prevents the home cards from looking shorter.
  static double listHeight(
    double cardWidth, {
    required bool isPortrait,
    bool isDesktop = false,
  }) {
    return cardWidth /
        gridAspectRatio(isPortrait: isPortrait, isDesktop: isDesktop);
  }

  static double gridAspectRatio({
    required bool isPortrait,
    bool isDesktop = false,
  }) {
    if (!isPortrait) return landscapeGridAspectRatio;
    return isDesktop ? desktopPortraitGridAspectRatio : portraitGridAspectRatio;
  }
}

class MultimediaCard extends StatelessWidget {
  final String? imageUrl;
  final String title;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String heroTag;
  final bool isPortrait;
  final FocusNode? focusNode;
  final bool compact;

  /// Shows the same poster shimmer used on home, view-all, and library
  /// while artwork is still downloading.
  final bool showImageLoadingShimmer;

  /// Fully formatted text supplied by the provider.
  ///
  /// This widget displays the string unchanged.
  final String? episodeBadge;

  /// Smaller gray line under the title: episode time or catalog type.
  final String? subtitle;

  /// Preferred catalog rating, using MAL -> IMDb -> AnimeWitcher priority.
  final CatalogRating? catalogRating;

  /// Release year drawn on the bottom-right of the poster.
  final int? year;

  /// Optional yellow badge at the top-right (`مدبلج`, relation, …).
  final String? posterBadge;

  /// MyAnimeList id, used only to find replacement artwork when the
  /// catalog's poster host cannot be reached.
  final int? malId;

  /// The name to search by when there is no id: the English title where the
  /// catalog has one, since the displayed Arabic name is a transliteration
  /// that other services do not index.
  final String lookupTitle;

  /// Looks replacement artwork up as a manga rather than an anime.
  final bool manga;

  const MultimediaCard({
    super.key,
    required this.imageUrl,
    required this.title,
    required this.onTap,
    this.onLongPress,
    required this.heroTag,
    this.isPortrait = true,
    this.focusNode,
    this.compact = false,
    this.episodeBadge,
    this.showImageLoadingShimmer = true,
    this.subtitle,
    this.catalogRating,
    this.year,
    this.posterBadge,
    this.malId,
    this.lookupTitle = '',
    this.manga = false,
  });

  MultimediaCard.fromItem({
    super.key,
    required MultimediaItem item,
    required this.heroTag,
    required this.onTap,
    this.onLongPress,
    this.focusNode,
    this.compact = false,
    this.isPortrait = true,
    this.showImageLoadingShimmer = true,
    bool showRelationBadge = false,
  }) : imageUrl = AppImageFallbacks.poster(item.posterUrl, label: item.title),
       malId = item.artworkLookupMalId,
       lookupTitle = item.artworkLookupTitle,
       manga = item.contentType == MultimediaContentType.manga,
       title = item.title,
       episodeBadge = item.episodeBadge,
       subtitle = multimediaCardSubtitle(item),
       catalogRating = preferredCatalogRating(item),
       year = multimediaCardYear(item),
       posterBadge = multimediaCardPosterBadge(
         item,
         showRelationBadge: showRelationBadge,
       );

  @override
  Widget build(BuildContext context) {
    final isDesktopLandscape = context.isDesktopLandscape;
    final isDesktop = context.isDesktop;
    final effectiveCompact = compact || isDesktopLandscape;
    final cardWidth = MultimediaCardLayout.cardWidth(
      context,
      isPortrait: isPortrait,
    );
    final normalizedEpisodeBadge = episodeBadge?.trim();
    final badgeText =
        normalizedEpisodeBadge == null || normalizedEpisodeBadge.isEmpty
        ? null
        : normalizedEpisodeBadge;
    final normalizedPosterBadge = posterBadge?.trim();
    final cornerBadge =
        normalizedPosterBadge == null || normalizedPosterBadge.isEmpty
        ? null
        : normalizedPosterBadge;
    final normalizedSubtitle = subtitle?.trim();
    final caption = normalizedSubtitle == null || normalizedSubtitle.isEmpty
        ? null
        : normalizedSubtitle;
    final yearText = year == null || year! <= 0 ? null : '$year';

    final normalizedImageUrl = imageUrl?.trim();
    final imageWidget = Hero(
      tag: heroTag,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MultimediaCardLayout.posterRadius),
        // Every card goes through the poster widget, including one with no
        // catalog artwork at all: it falls back to the same placeholder this
        // used to pick directly, and it is the piece that knows how to look
        // a missing poster up and repaint when that switch is flipped.
        child: ArtworkDecode(
          paintedWidth: cardWidth,
          builder: (BuildContext context, int? decodeWidth) => _buildPoster(
            context,
            normalizedImageUrl ?? '',
            decodeWidth: decodeWidth,
          ),
        ),
      ),
    );

    final titleSize = effectiveCompact ? 12.0 : (isDesktop ? 15.0 : 13.0);
    final subtitleSize = effectiveCompact ? 10.0 : (isDesktop ? 12.0 : 11.0);
    final isLight = Theme.of(context).brightness == Brightness.light;
    final titleTextStyle = TextStyle(
      color: isLight
          ? const Color(0xFF111111)
          : Colors.white.withValues(alpha: 0.92),
      fontSize: titleSize,
      fontWeight: FontWeight.w600,
      height: 1.2,
    );
    final subtitleTextStyle = TextStyle(
      color: isLight
          ? const Color(0xFF1A1A1A)
          : Colors.white.withValues(alpha: 0.45),
      fontSize: subtitleSize,
      fontWeight: FontWeight.w500,
      height: 1.2,
    );

    final semanticParts = <String>[title];
    if (badgeText != null) semanticParts.add(badgeText);
    if (cornerBadge != null) semanticParts.add(cornerBadge);
    if (yearText != null) semanticParts.add(yearText);
    if (caption != null) semanticParts.add(caption);
    if (catalogRating case final rating?) {
      final source = switch (rating.source) {
        CatalogRatingSource.mal => 'MAL',
        CatalogRatingSource.imdb => 'IMDb',
        CatalogRatingSource.animeWitcher => 'تقييم انمي ويتشر',
      };
      semanticParts.add('$source ${formatCatalogRatingScore(rating.score)}');
    }
    final semanticLabel = semanticParts.join('، ');

    return Semantics(
      button: true,
      label: semanticLabel,
      hint: AppLocalizations.of(context)?.viewDetails ?? 'عرض التفاصيل',
      onTap: onTap,
      onLongPress: onLongPress,
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CardsWrapper(
            onTap: onTap,
            onLongPress: onLongPress,
            focusNode: focusNode,
            scaleFactor: 1.05,
            child: SizedBox(
              width: cardWidth,
              child: _buildCard(
                context,
                imageWidget: imageWidget,
                titleTextStyle: titleTextStyle,
                subtitleTextStyle: subtitleTextStyle,
                badgeText: badgeText,
                cornerBadge: cornerBadge,
                yearText: yearText,
                caption: caption,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPoster(
    BuildContext context,
    String imageUrl, {
    required int? decodeWidth,
  }) {
    return FallbackPosterImage(
      imageUrl: imageUrl,
      malId: malId,
      title: lookupTitle.isNotEmpty ? lookupTitle : title,
      manga: manga,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      memCacheWidth: decodeWidth,
      filterQuality: FilterQuality.medium,
      placeholder: (context) => showImageLoadingShimmer
          ? ShimmerPlaceholder(borderRadius: MultimediaCardLayout.posterRadius)
          : _buildImageLoadingCard(context),
      errorWidget: (context) => ThumbnailErrorPlaceholder(label: title),
    );
  }

  Widget _buildImageLoadingCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.surfaceContainerHighest, colors.surface],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          size: 32,
          color: colors.onSurfaceVariant.withValues(alpha: 0.45),
        ),
      ),
    );
  }

  Widget _buildYellowBadge(BuildContext context, String text) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(maxWidth: 108),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: colors.primary,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colors.onPrimary,
          fontSize: 11,
          height: 1.1,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildPosterStack(
    BuildContext context, {
    required Widget imageWidget,
    required String? badgeText,
    required String? cornerBadge,
    required String? yearText,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(MultimediaCardLayout.posterRadius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          imageWidget,
          if (cornerBadge != null)
            Positioned(
              top: 6,
              right: 6,
              child: _buildYellowBadge(context, cornerBadge),
            ),
          if (badgeText != null)
            Positioned(
              right: 6,
              bottom: 6,
              child: _buildYellowBadge(context, badgeText),
            )
          else if (yearText != null)
            Positioned(
              right: 7,
              bottom: 6,
              child: Text(
                yearText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  shadows: [
                    Shadow(
                      color: Colors.black87,
                      blurRadius: 6,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCatalogSourceBadge({
    required Key key,
    required String label,
    required Color backgroundColor,
    required Color foregroundColor,
    required TextStyle subtitleTextStyle,
  }) {
    final sourceSize = ((subtitleTextStyle.fontSize ?? 11) - 2)
        .clamp(7.5, 10.0)
        .toDouble();
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 3.5, vertical: 1),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(3.5),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: subtitleTextStyle.copyWith(
          color: foregroundColor,
          fontSize: sourceSize,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.25,
          height: 1,
        ),
      ),
    );
  }

  Widget _buildCatalogRating(TextStyle subtitleTextStyle) {
    final rating = catalogRating!;
    final score = Text(
      formatCatalogRatingScore(rating.score),
      maxLines: 1,
      style: subtitleTextStyle,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: switch (rating.source) {
        CatalogRatingSource.mal => <Widget>[
          _buildCatalogSourceBadge(
            key: const Key('catalog-rating-mal-source'),
            label: 'MAL',
            backgroundColor: const Color(0xFF2E51A2),
            foregroundColor: Colors.white,
            subtitleTextStyle: subtitleTextStyle,
          ),
          const SizedBox(width: 4),
          score,
        ],
        CatalogRatingSource.imdb => <Widget>[
          _buildCatalogSourceBadge(
            key: const Key('catalog-rating-imdb-source'),
            label: 'IMDb',
            backgroundColor: const Color(0xFFF5C518),
            foregroundColor: Colors.black,
            subtitleTextStyle: subtitleTextStyle,
          ),
          const SizedBox(width: 4),
          score,
        ],
        CatalogRatingSource.animeWitcher => <Widget>[
          Icon(
            Icons.star_rounded,
            key: const Key('catalog-rating-witcher-source'),
            size: (subtitleTextStyle.fontSize ?? 11) + 3,
            color: AppTheme.animeWitcherAccent,
          ),
          const SizedBox(width: 3),
          score,
        ],
      },
    );
  }

  Widget _buildCaption({
    required TextStyle titleTextStyle,
    required TextStyle subtitleTextStyle,
    required String? caption,
  }) {
    final hasRating = catalogRating != null;
    final subtitleHeight =
        (subtitleTextStyle.fontSize ?? 11) * (subtitleTextStyle.height ?? 1.2);

    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 6, start: 2, end: 2),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.left,
              style: titleTextStyle,
            ),
            const SizedBox(height: 2),
            if (caption != null || hasRating)
              SizedBox(
                height: subtitleHeight,
                child: Row(
                  children: [
                    if (caption != null)
                      Flexible(
                        child: Text(
                          caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textDirection: TextDirection.ltr,
                          textAlign: TextAlign.left,
                          style: subtitleTextStyle,
                        ),
                      ),
                    // Intentionally no bullet/dot between the catalog caption
                    // and the rating source.
                    if (caption != null && hasRating) const SizedBox(width: 8),
                    if (hasRating) _buildCatalogRating(subtitleTextStyle),
                  ],
                ),
              )
            else
              SizedBox(height: subtitleHeight),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required Widget imageWidget,
    required TextStyle titleTextStyle,
    required TextStyle subtitleTextStyle,
    required String? badgeText,
    required String? cornerBadge,
    required String? yearText,
    required String? caption,
  }) {
    final poster = _buildPosterStack(
      context,
      imageWidget: imageWidget,
      badgeText: badgeText,
      cornerBadge: cornerBadge,
      yearText: yearText,
    );
    final captionBlock = _buildCaption(
      titleTextStyle: titleTextStyle,
      subtitleTextStyle: subtitleTextStyle,
      caption: caption,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final boundedHeight =
            constraints.maxHeight.isFinite &&
            constraints.maxHeight < double.infinity;
        if (boundedHeight) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: poster),
              captionBlock,
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: MultimediaCardLayout.posterAspectRatio(
                isPortrait: isPortrait,
              ),
              child: poster,
            ),
            captionBlock,
          ],
        );
      },
    );
  }
}
