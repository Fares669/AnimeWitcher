import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/artwork_quality.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import 'premium_details_widgets.dart';
import 'details_layout_widgets.dart';

import 'package:animewitcher/core/utils/localized_text.dart';
import 'package:animewitcher/core/services/notification_service.dart';

/// Immersive desktop/TV hero for non-TMDB details.
///
/// Layout: full-viewport backdrop fading via gradients, with metadata
/// overlaid on the left ~55% of the screen. [child] renders below the
/// hero section (episodes, cast, trailers, recommendations).
class DetailsDesktopHero extends ConsumerWidget {
  const DetailsDesktopHero({
    super.key,
    required this.displayItem,
    required this.baseItem,
    required this.details,
    required this.detailsState,
    required this.isMovie,
    required this.itemUrl,
    required this.child,
    required this.onRefresh,
  });

  /// The resolved item for display (details ?? widget.item).
  final MultimediaItem displayItem;

  /// The original item — used by [DetailsActionButtons] for URL matching.
  final MultimediaItem baseItem;

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
    final backdropUrl =
        AppImageFallbacks.banner(
          bannerUrl: displayItem.bannerUrl,
          posterUrl: displayItem.posterUrl,
          label: displayItem.title,
        ) ??
        '';

    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Layer 1: Backdrop image with left-fade ShaderMask ──
        Positioned.fill(
          child: ShaderMask(
            shaderCallback: (rect) {
              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  scaffoldColor,
                  scaffoldColor.withValues(alpha: 0.85),
                  scaffoldColor.withValues(alpha: 0.55),
                  scaffoldColor.withValues(alpha: 0.25),
                  scaffoldColor.withValues(alpha: 0.08),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
              ).createShader(rect);
            },
            blendMode: BlendMode.dstOut,
            child: ArtworkDecode(
              paintedWidth: MediaQuery.sizeOf(context).width,
              builder: (BuildContext context, int? decodeWidth) =>
                  CachedNetworkImage(
                    imageUrl: backdropUrl,
                    fit: BoxFit.cover,
                    alignment: Alignment.centerRight,
                    memCacheWidth: decodeWidth,
                    filterQuality: FilterQuality.medium,
                    errorWidget: (_, _, _) {
                      if (providedBannerUrl != null &&
                          posterUrl != null &&
                          providedBannerUrl != posterUrl) {
                        return CachedNetworkImage(
                          imageUrl: posterUrl,
                          fit: BoxFit.cover,
                          alignment: Alignment.centerRight,
                          memCacheWidth: decodeWidth,
                          filterQuality: FilterQuality.medium,
                          errorWidget: (_, _, _) => ThumbnailErrorPlaceholder(
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
        ),

        // ── Layer 2: Left-to-right gradient overlay ──
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  scaffoldColor,
                  scaffoldColor.withValues(alpha: 0.85),
                  scaffoldColor.withValues(alpha: 0.55),
                  scaffoldColor.withValues(alpha: 0.25),
                  scaffoldColor.withValues(alpha: 0.08),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
              ),
            ),
          ),
        ),

        // ── Layer 3: Bottom-to-top gradient (seamless transition) ──
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  scaffoldColor,
                  scaffoldColor.withValues(alpha: 0.85),
                  scaffoldColor.withValues(alpha: 0.55),
                  scaffoldColor.withValues(alpha: 0.25),
                  scaffoldColor.withValues(alpha: 0.08),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.1, 0.2, 0.28, 0.35, 0.4],
              ),
            ),
          ),
        ),

        // ── Layer 4: Scrollable content ──
        Positioned.fill(
          child: RefreshIndicator(
            onRefresh: onRefresh,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 60),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Hero content: poster + metadata ──
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: SizedBox(
                      width: MediaQuery.sizeOf(context).width * 0.68,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (posterUrl != null && posterUrl.isNotEmpty) ...[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: SizedBox(
                                width: 180,
                                height: 270,
                                child: ArtworkDecode(
                                  paintedWidth: 180,
                                  builder:
                                      (
                                        BuildContext context,
                                        int? decodeWidth,
                                      ) => CachedNetworkImage(
                                        imageUrl: posterUrl,
                                        fit: BoxFit.cover,
                                        memCacheWidth: decodeWidth,
                                        filterQuality: FilterQuality.medium,
                                        placeholder: (_, _) => ColoredBox(
                                          color: theme
                                              .colorScheme
                                              .surfaceContainerHighest,
                                        ),
                                        errorWidget: (_, _, _) =>
                                            ThumbnailErrorPlaceholder(
                                              label: displayItem.title,
                                            ),
                                      ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 28),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Logo or Title
                                GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onLongPress: () => _copyAnimeTitle(context),
                                  child: displayItem.logoUrl != null
                                      ? ArtworkDecode(
                                          paintedWidth: 400,
                                          builder:
                                              (
                                                BuildContext context,
                                                int? decodeWidth,
                                              ) => CachedNetworkImage(
                                                imageUrl: displayItem.logoUrl!,
                                                height: 200,
                                                alignment: Alignment.centerLeft,
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

                                MetadataBar(
                                  item: displayItem,
                                  isLoading: detailsState is AsyncLoading,
                                ),

                                if (displayItem.nextAiring != null) ...[
                                  const SizedBox(height: 20),
                                  NextAiringWidget(
                                    nextAiring: displayItem.nextAiring!,
                                  ),
                                ],

                                const SizedBox(height: 32),

                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 400,
                                  ),
                                  child: DetailsActionButtons(
                                    item: baseItem,
                                    details: details,
                                    itemUrl: itemUrl,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 60),

                  // ── Content below hero (full width) ──
                  child,
                ],
              ),
            ),
          ),
        ),
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
      style: TextStyle(
        color: textColor,
        fontSize: 56,
        fontWeight: FontWeight.bold,
        height: 1.1,
      ),
    );
  }
}
