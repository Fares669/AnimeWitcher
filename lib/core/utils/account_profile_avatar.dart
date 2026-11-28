import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Shares a display-sized decode across the More and profile views.
///
/// The profile editor has the largest circle (116 logical pixels). Using one
/// size based on that circle lets these views share a cached photo instead of
/// fetching it again while navigating between them.
final class AccountProfileAvatar
    extends ImageProvider<({Object source, int diameter})> {
  const AccountProfileAvatar(this.source);

  static const double largestPaintedDiameter = 116;

  final ImageProvider<Object> source;

  @override
  bool operator ==(Object other) =>
      other is AccountProfileAvatar && source == other.source;

  @override
  int get hashCode => Object.hash(AccountProfileAvatar, source);

  @override
  Future<({Object source, int diameter})> obtainKey(
    ImageConfiguration configuration,
  ) {
    final diameter =
        (largestPaintedDiameter * (configuration.devicePixelRatio ?? 1)).ceil();
    return source
        .obtainKey(configuration)
        .then((key) => (source: key, diameter: diameter));
  }

  @override
  ImageStreamCompleter loadImage(
    ({Object source, int diameter}) key,
    ImageDecoderCallback decode,
  ) {
    final completer = source.loadImage(key.source, (buffer, {getTargetSize}) {
      assert(getTargetSize == null);
      return decode(
        buffer,
        getTargetSize: (width, height) {
          // A square cover shrinks by its shorter edge. Keep the source aspect
          // ratio so legacy photos crop exactly as they did before.
          return width <= height
              ? ui.TargetImageSize(width: math.min(width, key.diameter))
              : ui.TargetImageSize(height: math.min(height, key.diameter));
        },
      );
    });
    completer.addEphemeralErrorListener((_, _) {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }
}
