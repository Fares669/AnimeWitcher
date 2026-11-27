import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:octo_image/octo_image.dart';

import '../../../core/utils/artwork_quality.dart';
import '../../../core/utils/responsive_breakpoints.dart';
import '../../../shared/widgets/multimedia_card.dart';
import '../../../shared/widgets/shimmer_placeholder.dart';
import '../../../shared/widgets/thumbnail_error_placeholder.dart';

const double characterPortraitCaptionGap = 6;

/// The same cached portrait is shown in catalog/cast cards and in the hero.
class CharacterPortraitImage extends StatelessWidget {
  const CharacterPortraitImage({
    super.key,
    required this.url,
    required this.name,
    required this.radius,
    required this.standardWidth,
    this.filterQuality = ui.FilterQuality.low,
  });

  final String url;
  final String name;
  final double radius;
  final double standardWidth;
  final ui.FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return ThumbnailErrorPlaceholder(label: name);
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return ValueListenableBuilder<bool>(
      valueListenable: highQualityArtwork,
      builder: (context, highQuality, _) {
        final source = CachedNetworkImageProvider(url);
        Widget buildImage(
          ImageProvider<Object> provider, {
          int? standardDecodeWidth,
        }) => OctoImage(
          image: provider,
          fit: BoxFit.cover,
          filterQuality: filterQuality,
          memCacheWidth: standardDecodeWidth,
          fadeOutDuration: const Duration(milliseconds: 1000),
          fadeOutCurve: Curves.easeOut,
          fadeInDuration: const Duration(milliseconds: 500),
          fadeInCurve: Curves.easeIn,
          placeholderBuilder: (_) => ShimmerPlaceholder(borderRadius: radius),
          errorBuilder: (_, _, _) => ThumbnailErrorPlaceholder(label: name),
        );

        if (!highQuality || kIsWeb) {
          return buildImage(
            source,
            standardDecodeWidth: artworkDisplayDecodeWidth(
              paintedWidth: standardWidth,
              devicePixelRatio: dpr,
              highQuality: highQuality,
            ),
          );
        }
        // Share the largest portrait budget in this viewport. The cast grid
        // can give a card more room than the hero on wide displays, so using
        // only each slot's own size would decode the same file twice.
        final view = MediaQuery.maybeSizeOf(context);
        final columns = view == null
            ? null
            : ResponsiveBreakpoints.isDesktopLandscape(context)
            ? ResponsiveBreakpoints.desktopLandscapeColumnsForViewport(context)
            : ResponsiveBreakpoints.isHandsetLandscape(context)
            ? ResponsiveBreakpoints.handsetLandscapeAnimeColumns
            : ResponsiveBreakpoints.isHandset(context)
            ? MultimediaCardLayout.handsetPortraitGridColumns
            : null;
        final double maxCardWidth;
        if (view != null && columns != null) {
          final padding = MultimediaCardLayout.catalogGridHorizontalPadding(
            context,
          );
          final spacing = MultimediaCardLayout.catalogGridCrossAxisSpacing(
            context,
            fallback: 12,
          );
          maxCardWidth =
              (view.width - 2 * padding - (columns - 1) * spacing) / columns;
        } else {
          maxCardWidth = 0;
        }
        final sharedWidth = math.max(168.0, maxCardWidth);
        final sharedHeight = math.max(
          236.0,
          maxCardWidth / MultimediaCardLayout.characterGridAspectRatio -
              characterPortraitCaptionGap,
        );
        return LayoutBuilder(
          builder: (context, constraints) {
            if (!constraints.hasBoundedWidth ||
                !constraints.hasBoundedHeight ||
                !dpr.isFinite ||
                dpr <= 0 ||
                !sharedWidth.isFinite ||
                !sharedHeight.isFinite) {
              return buildImage(source);
            }
            // Respect actual constraints for slots outside the normal grid
            // and hero geometry, and leave headroom for card focus effects.
            int bucket(double logical) =>
                (logical * dpr * 1.25 / 64).ceil() * 64;
            return buildImage(
              _CoverPortrait(
                source,
                bucket(math.max(sharedWidth, constraints.maxWidth)),
                bucket(math.max(sharedHeight, constraints.maxHeight)),
              ),
            );
          },
        );
      },
    );
  }
}

/// Computes the smallest proportional decode covering the display area. A
/// width-only resize would undersample a landscape source in a portrait crop;
/// a fit-inside resize can undersample either a wide or a tall source.
@immutable
class _CoverPortrait extends ImageProvider<_CoverPortrait> {
  const _CoverPortrait(this.source, this.width, this.height);

  final CachedNetworkImageProvider source;
  final int width;
  final int height;

  @override
  Future<_CoverPortrait> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _CoverPortrait key,
    ImageDecoderCallback decode,
  ) {
    final completer = key.source.loadImage(
      key.source,
      (buffer, {getTargetSize}) => decode(
        buffer,
        getTargetSize: (intrinsicWidth, intrinsicHeight) {
          if (key.width >= intrinsicWidth || key.height >= intrinsicHeight) {
            return const ui.TargetImageSize();
          }
          int ceilDivide(int numerator, int denominator) =>
              (numerator + denominator - 1) ~/ denominator;
          final widthRatio = key.width * intrinsicHeight;
          final heightRatio = key.height * intrinsicWidth;
          return widthRatio >= heightRatio
              ? ui.TargetImageSize(
                  width: key.width,
                  height: ceilDivide(widthRatio, intrinsicWidth),
                )
              : ui.TargetImageSize(
                  width: ceilDivide(heightRatio, intrinsicHeight),
                  height: key.height,
                );
        },
      ),
    );
    completer.addEphemeralErrorListener(
      (_, _) => scheduleMicrotask(() => imageCache.evict(key)),
    );
    return completer;
  }

  @override
  bool operator ==(Object other) =>
      other is _CoverPortrait &&
      source == other.source &&
      width == other.width &&
      height == other.height;

  @override
  int get hashCode => Object.hash(source, width, height);
}
