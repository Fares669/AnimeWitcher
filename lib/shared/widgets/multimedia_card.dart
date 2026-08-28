import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import '../../core/domain/entity/multimedia_item.dart';
import '../../core/utils/artwork_quality.dart';
import '../../core/utils/catalog_label.dart';
import '../../core/utils/image_fallbacks.dart';
import '../../core/utils/responsive_breakpoints.dart';
import 'cards_wrapper.dart';
import 'shimmer_placeholder.dart';
import 'thumbnail_error_placeholder.dart';

/// Shared poster + caption metrics so rails and grids reserve the same space.
class MultimediaCardLayout {
  static const double captionHeight = 46;
  static const double posterRadius = 12;
  static const double portraitGridAspectRatio = 0.52;
  static const double landscapeGridAspectRatio = 1.12;
  static const double desktopPortraitGridAspectRatio = 0.54;

  static double cardWidth(
    BuildContext context, {
    required bool isPortrait,
  }) {
    if (context.isHandsetLandscape) {
      return ResponsiveBreakpoints.handsetLandscapeAnimeCardWidth(context);
    }
    if (context.isDesktopLandscape) {
      return ResponsiveBreakpoints.desktopLandscapeAnimeCardWidth(context);
    }
    if (context.isDesktop) {
      return isPortrait ? 200.0 : 300.0;
    }
    return isPortrait ? 130.0 : 200.0;
  }

  static double posterAspectRatio({required bool isPortrait}) =>
      isPortrait ? 2 / 3 : 16 / 9;

  static double listHeight(double cardWidth, {required bool isPortrait}) {
    return cardWidth / posterAspectRatio(isPortrait: isPortrait) +
        captionHeight;
  }

  static double gridAspectRatio({
    required bool isPortrait,
    bool isDesktop = false,
  }) {
    if (!isPortrait) return landscapeGridAspectRatio;
    return isDesktop
        ? desktopPortraitGridAspectRatio
        : portraitGridAspectRatio;
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

  /// Shows a stable card surface while the poster is still loading.
  /// Search results disable the shimmer so the card is visible immediately.
  final bool showImageLoadingShimmer;

  /// Fully formatted text supplied by the provider.
  ///
  /// This widget displays the string unchanged.
  final String? episodeBadge;

  /// Smaller gray line under the title: episode time or catalog type.
  final String? subtitle;

  /// Release year drawn on the bottom-right of the poster.
  final int? year;

  /// Optional yellow badge at the top-right (`مدبلج`, relation, …).
  final String? posterBadge;

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
    this.year,
    this.posterBadge,
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
       title = item.title,
       episodeBadge = item.episodeBadge,
       subtitle = multimediaCardSubtitle(item),
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
    final caption =
        normalizedSubtitle == null || normalizedSubtitle.isEmpty
        ? null
        : normalizedSubtitle;
    final yearText = year == null || year! <= 0 ? null : '$year';

    final normalizedImageUrl = imageUrl?.trim();
    final hasImageUrl =
        normalizedImageUrl != null && normalizedImageUrl.isNotEmpty;
    final imageWidget = Hero(
      tag: heroTag,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(MultimediaCardLayout.posterRadius),
        child: hasImageUrl
            ? ArtworkDecode(
                paintedWidth: cardWidth,
                builder: (BuildContext context, int? decodeWidth) =>
                    _buildPoster(
                      context,
                      normalizedImageUrl,
                      decodeWidth: decodeWidth,
                    ),
              )
            : ThumbnailErrorPlaceholder(label: title),
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
    return CachedNetworkImage(
      imageUrl: imageUrl,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      memCacheWidth: decodeWidth,
      filterQuality: FilterQuality.medium,
      placeholder: (context, url) => showImageLoadingShimmer
          ? ShimmerPlaceholder(borderRadius: MultimediaCardLayout.posterRadius)
          : _buildImageLoadingCard(context),
      errorWidget: (_, _, _) => ThumbnailErrorPlaceholder(label: title),
      fadeOutDuration: Duration.zero,
      fadeInDuration: const Duration(milliseconds: 120),
      useOldImageOnUrlChange: true,
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

  Widget _buildCaption({
    required TextStyle titleTextStyle,
    required TextStyle subtitleTextStyle,
    required String? caption,
  }) {
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
            if (caption != null) ...[
              const SizedBox(height: 2),
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.left,
                style: subtitleTextStyle,
              ),
            ],
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
