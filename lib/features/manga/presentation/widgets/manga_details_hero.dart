import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/artwork_quality.dart';
import '../../../../core/utils/image_fallbacks.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../details/presentation/widgets/premium_details_widgets.dart';

class MangaDetailsHero extends StatelessWidget {
  const MangaDetailsHero({
    super.key,
    required this.item,
    this.isLoading = false,
    this.onPosterTap,
    this.onTitleLongPress,
  });

  final MultimediaItem item;
  final bool isLoading;
  final VoidCallback? onPosterTap;
  final VoidCallback? onTitleLongPress;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final scale =
        screenSize.shortestSide / LayoutConstants.detailsSdpReferenceWidth;
    double sdp(double value) => value * scale;

    final bannerHeight = sdp(LayoutConstants.detailsBannerHeightMobile);
    final posterUrl =
        AppImageFallbacks.poster(item.posterUrl, label: item.title) ?? '';
    final providedBannerUrl = AppImageFallbacks.optional(item.bannerUrl);
    final bannerUrl =
        AppImageFallbacks.banner(
          bannerUrl: item.bannerUrl,
          posterUrl: item.posterUrl,
          label: item.title,
        ) ??
        '';
    final titleHeight = sdp(28).clamp(28.0, 44.0).toDouble();
    final titleTop =
        bannerHeight -
        sdp(LayoutConstants.detailsHeaderBottomMobile) -
        titleHeight;

    return SizedBox(
      height: LayoutConstants.detailsExpandedHeightMobile * scale,
      width: double.infinity,
      child: ColoredBox(
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
                  if (bannerUrl.isEmpty)
                    const ColoredBox(color: Colors.black)
                  else
                    ColoredBox(
                      color: Colors.black,
                      child: _MangaDetailsArtwork(
                        imageUrl: bannerUrl,
                        fit: BoxFit.cover,
                        alignment: Alignment.center,
                        paintedWidth: screenSize.width,
                        fallbackUrl:
                            providedBannerUrl != null &&
                                posterUrl.isNotEmpty &&
                                providedBannerUrl != posterUrl
                            ? posterUrl
                            : null,
                      ),
                    ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: <Color>[
                          Colors.transparent,
                          Colors.transparent,
                          Color(0x26000000),
                          Color(0x99000000),
                          Colors.black,
                        ],
                        stops: <double>[0, 0.30, 0.58, 0.86, 1],
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
                onTap: onPosterTap,
                child: Material(
                  color: Colors.black,
                  elevation: sdp(6),
                  borderRadius: BorderRadius.circular(sdp(5)),
                  clipBehavior: Clip.antiAlias,
                  child: posterUrl.isEmpty
                      ? const ColoredBox(
                          color: Colors.black,
                          child: Icon(
                            Icons.menu_book_rounded,
                            color: Colors.white38,
                          ),
                        )
                      : _MangaDetailsArtwork(
                          key: posterUrl.startsWith('file:')
                              ? const ValueKey('manga-details-custom-cover')
                              : ValueKey<String>(
                                  'manga_details_poster_$posterUrl',
                                ),
                          imageUrl: posterUrl,
                          fit: BoxFit.cover,
                          paintedWidth: sdp(
                            LayoutConstants.detailsPosterWidthMobile,
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
                  onLongPress: onTitleLongPress,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      item.title,
                      textAlign: TextAlign.start,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
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
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: MetadataBar(item: item, isLoading: isLoading),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class _MangaDetailsArtwork extends StatelessWidget {
  const _MangaDetailsArtwork({
    super.key,
    required this.imageUrl,
    required this.fit,
    required this.paintedWidth,
    this.alignment = Alignment.center,
    this.fallbackUrl,
  });

  final String imageUrl;
  final BoxFit fit;
  final double paintedWidth;
  final Alignment alignment;
  final String? fallbackUrl;

  Widget _image(BuildContext context, String url, int? decodeWidth) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.scheme == 'file') {
      return Image.file(
        File.fromUri(uri),
        fit: fit,
        alignment: alignment,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      alignment: alignment,
      memCacheWidth: decodeWidth,
      filterQuality: FilterQuality.medium,
      placeholder: (_, _) => const ColoredBox(color: Colors.black),
      errorWidget: (_, _, _) {
        final fallback = fallbackUrl?.trim() ?? '';
        if (fallback.isEmpty || fallback == url) {
          return const ColoredBox(color: Colors.black);
        }
        return _image(context, fallback, decodeWidth);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ArtworkDecode(
      paintedWidth: paintedWidth,
      builder: (context, decodeWidth) => _image(context, imageUrl, decodeWidth),
    );
  }
}
