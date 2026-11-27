import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture, kIsWeb;
import 'package:flutter/widgets.dart';

import '../network/poster_cache.dart';

class ImageUtils {
  /// Resolves the image from the given URL and determines if it is portrait (height >= width).
  /// Returns `true` by default if the URL is empty or the image fails to load.
  static Future<bool> isImagePortrait(String url) {
    if (url.isEmpty) return Future.value(true);

    final completer = Completer<bool>();
    final source = CachedNetworkImageProvider(
      url,
      cacheManager: posterCacheManager,
    );
    // Use a full frame only if another observer already requested it or on
    // the web, where the HTML image loader ignores the native codec callback.
    final ImageProvider<Object> provider =
        kIsWeb || imageCache.statusForKey(source).tracked
        ? source
        : _PosterOrientationProbe(source);
    final stream = provider.resolve(const ImageConfiguration());

    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (ImageInfo info, bool _) {
        try {
          if (!completer.isCompleted) {
            completer.complete(info.image.height >= info.image.width);
          }
        } finally {
          // The stream delivers a separately owned handle to every listener.
          info.dispose();
          stream.removeListener(listener);
        }
      },
      onError: (dynamic exception, StackTrace? stackTrace) {
        if (!completer.isCompleted) {
          completer.complete(true); // default to portrait on error
        }
        stream.removeListener(listener);
      },
    );

    stream.addListener(listener);
    return completer.future;
  }
}

/// A private cache key for an orientation-only frame, never used for display.
/// The same file-cache loader still owns encoded-byte sharing and refresh.
@immutable
class _PosterOrientationProbe extends ImageProvider<_PosterOrientationProbe> {
  const _PosterOrientationProbe(this.source);

  final CachedNetworkImageProvider source;

  @override
  Future<_PosterOrientationProbe> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _PosterOrientationProbe key,
    ImageDecoderCallback decode,
  ) {
    final stream = key.source.loadImage(
      key.source,
      (buffer, {getTargetSize}) => decode(
        buffer,
        // Even a one-pixel difference between natural dimensions is retained
        // in this marker. Decode the frame to keep the existing error path.
        getTargetSize: (width, height) =>
            ui.TargetImageSize(width: width > height ? 2 : 1, height: 1),
      ),
    );
    stream.addEphemeralErrorListener(
      (_, _) => scheduleMicrotask(() => imageCache.evict(key)),
    );
    return stream;
  }

  @override
  bool operator ==(Object other) =>
      other is _PosterOrientationProbe && other.source == source;

  @override
  int get hashCode => Object.hash(_PosterOrientationProbe, source);
}
