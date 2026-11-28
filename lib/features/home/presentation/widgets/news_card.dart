import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture, kIsWeb;
import 'package:flutter/material.dart';
import 'package:octo_image/octo_image.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/utils/artwork_quality.dart';
import '../../../../core/utils/image_utils.dart';
import '../../../../core/account/animewitcher_comment_models.dart';
import '../../../comments/presentation/animewitcher_comments_screen.dart';
import '../../../../shared/widgets/taskbar_visibility.dart';

class NewsCard extends StatelessWidget {
  const NewsCard({
    super.key,
    required this.item,
    this.compact = true,
    this.expandToFill = false,
    this.onOpen,
    this.onAnimeTap,
  });

  final NewsItem item;
  final bool compact;
  final bool expandToFill;
  final VoidCallback? onOpen;
  final VoidCallback? onAnimeTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final compact = this.compact;
    final expandToFill = this.expandToFill;
    final width = compact ? 200.0 : double.infinity;
    final imageHeight = compact ? 100.0 : 210.0;

    final image = Stack(
      fit: StackFit.expand,
      children: [
        _buildImage(context),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.88),
                  ],
                  stops: const [0.42, 1],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: compact ? 7 : 10,
          bottom: compact ? 6 : 8,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.hasAnimeLink) ...[
                _NewsActionIcon(
                  icon: Icons.link_rounded,
                  onTap: onAnimeTap,
                  size: compact ? 20 : 28,
                ),
                SizedBox(width: compact ? 7 : 10),
              ],
              _NewsActionIcon(
                icon: Icons.chat_bubble_outline_rounded,
                onTap: () {
                  final target = animeWitcherNewsCommentTarget(item);
                  pushOverTaskbar<void>(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          AnimeWitcherCommentsScreen(target: target),
                    ),
                  );
                },
                size: compact ? 20 : 28,
              ),
            ],
          ),
        ),
      ],
    );

    return SizedBox(
      width: width,
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 3,
        color: colors.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(compact ? 8 : 5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Column(
            mainAxisSize: expandToFill ? MainAxisSize.max : MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (expandToFill)
                Expanded(child: image)
              else
                SizedBox(height: imageHeight, child: image),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 10 : 12,
                  compact ? 7 : 9,
                  compact ? 10 : 12,
                  compact ? 3 : 5,
                ),
                child: Directionality(
                  textDirection: TextDirection.rtl,
                  child: Text(
                    item.title,
                    maxLines: compact ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.start,
                    style: TextStyle(
                      color: colors.onSurface,
                      fontSize: compact ? 12 : 15,
                      height: 1.25,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 12 : 14,
                  0,
                  compact ? 12 : 14,
                  compact ? 8 : 10,
                ),
                child: Directionality(
                  textDirection: TextDirection.rtl,
                  child: Text(
                    _newsTimeAgo(context, item.publishedAt),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: compact ? 10 : 11,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImage(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final url = item.imageUrl.trim();
    if (url.isEmpty) return _imageFallback(colors);

    return ArtworkDecode(
      paintedWidth: compact ? 200 : MediaQuery.sizeOf(context).width,
      builder: (context, decodeWidth) {
        Widget original() => CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          memCacheWidth: decodeWidth,
          filterQuality: FilterQuality.medium,
          fadeInDuration: const Duration(milliseconds: 120),
          fadeOutDuration: Duration.zero,
          placeholder: (context, url) => _imageFallback(colors),
          errorWidget: (context, url, error) => _imageFallback(colors),
        );

        // Only the standard-quality two-column grid used the entire
        // viewport as the width of each tile. Keep full-quality, the compact
        // rail, one-column layouts and the web loader on the existing path.
        if (kIsWeb || compact || !expandToFill || decodeWidth == null) {
          return original();
        }
        final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
        return LayoutBuilder(
          builder: (context, slot) {
            final width = slot.maxWidth * dpr;
            final height = slot.maxHeight * dpr;
            if (!width.isFinite ||
                !height.isFinite ||
                width <= 0 ||
                height <= 0 ||
                width >= decodeWidth) {
              return original();
            }
            return OctoImage(
              image: _NewsGridCover(
                CachedNetworkImageProvider(url),
                (width / 32).ceil() * 32,
                (height / 32).ceil() * 32,
                decodeWidth,
              ),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              filterQuality: FilterQuality.medium,
              fadeInDuration: const Duration(milliseconds: 120),
              fadeOutDuration: Duration.zero,
              placeholderBuilder: (_) => _imageFallback(colors),
              errorBuilder: (_, _, _) => _imageFallback(colors),
            );
          },
        );
      },
    );
  }

  Widget _imageFallback(ColorScheme colors) {
    return ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.article_outlined,
          color: colors.onSurfaceVariant.withValues(alpha: 0.55),
          size: compact ? 30 : 42,
        ),
      ),
    );
  }
}

class _NewsActionIcon extends StatelessWidget {
  const _NewsActionIcon({
    required this.icon,
    required this.onTap,
    required this.size,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Icon(
        icon,
        size: size,
        color: colors.onSurface.withValues(alpha: 0.9),
      ),
    );
  }
}

String _newsTimeAgo(BuildContext context, DateTime? date) {
  if (date == null) return '';
  final difference = DateTime.now().difference(date);
  final elapsed = difference.isNegative ? Duration.zero : difference;

  if (elapsed.inMinutes < 1) return 'الآن';
  if (elapsed.inHours < 1) {
    final value = elapsed.inMinutes;
    return ('منذ ' + (value == 1 ? 'دقيقة' : value.toString() + ' دقيقة'));
  }
  if (elapsed.inDays < 1) {
    final value = elapsed.inHours;
    return ('منذ ' + (value == 1 ? 'ساعة' : value.toString() + ' ساعة'));
  }

  final value = elapsed.inDays;
  return ('منذ ' + (value == 1 ? 'يوم' : value.toString() + ' يوم'));
}

/// Decode enough for a cover crop while never exceeding the previous
/// standard-quality budget. The original encoded file/cache is unchanged.
@immutable
class _NewsGridCover extends ImageProvider<_NewsGridCover> {
  const _NewsGridCover(this.source, this.width, this.height, this.maxWidth);

  final CachedNetworkImageProvider source;
  final int width;
  final int height;
  final int maxWidth;

  @override
  Future<_NewsGridCover> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _NewsGridCover key,
    ImageDecoderCallback decode,
  ) {
    final stream = key.source.loadImage(
      key.source,
      (buffer, {getTargetSize}) => decode(
        buffer,
        getTargetSize: coverDecodeTarget(key.width, key.height, key.maxWidth),
      ),
    );
    stream.addEphemeralErrorListener(
      (_, _) => scheduleMicrotask(() => imageCache.evict(key)),
    );
    return stream;
  }

  @override
  bool operator ==(Object other) =>
      other is _NewsGridCover &&
      other.source == source &&
      other.width == width &&
      other.height == height &&
      other.maxWidth == maxWidth;

  @override
  int get hashCode => Object.hash(source, width, height, maxWidth);
}
