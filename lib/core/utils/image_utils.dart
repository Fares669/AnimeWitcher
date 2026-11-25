import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';

import '../network/poster_cache.dart';

class ImageUtils {
  /// Resolves the image from the given URL and determines if it is portrait (height >= width).
  /// Returns `true` by default if the URL is empty or the image fails to load.
  static Future<bool> isImagePortrait(String url) {
    if (url.isEmpty) return Future.value(true);

    final completer = Completer<bool>();
    // The probe needs the original frame, but it can share its encoded file
    // with the card and with the home rail's disk prefetch.
    final stream = CachedNetworkImageProvider(
      url,
      cacheManager: posterCacheManager,
    ).resolve(const ImageConfiguration());

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
