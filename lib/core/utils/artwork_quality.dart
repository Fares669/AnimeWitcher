import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Whether artwork is fetched and decoded at its largest available size.
///
/// Image widgets are leaves spread across every feature, so the switch lives in
/// one listenable instead of being threaded through all of them. The app
/// bootstrap seeds it from storage and the settings notifier keeps it in sync.
final ValueNotifier<bool> highQualityArtwork = ValueNotifier<bool>(true);

/// Publishes the switch and sizes the image cache for it.
void applyArtworkQuality(bool highQuality) {
  highQualityArtwork.value = highQuality;
  // Full-size artwork needs room to stay cached; a small budget would only
  // evict and re-decode the same posters while scrolling. Standard artwork is
  // small enough for the lighter budget the app used before.
  //
  // A desktop has the memory to keep every poster of home and a search in
  // memory, so scrolling back draws them at once rather than decoding again;
  // phones and TV boxes keep the lighter budgets.
  final roomy =
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  PaintingBinding.instance.imageCache
    ..maximumSize = roomy ? 1500 : (highQuality ? 400 : 200)
    ..maximumSizeBytes = (roomy ? 320 : (highQuality ? 256 : 50)) * 1024 * 1024;
}

/// Hands [builder] the decode width for artwork painted [paintedWidth] logical
/// pixels wide, and rebuilds when the quality switch flips.
///
/// High quality passes null so the image decodes at source resolution; standard
/// quality bounds the decode to the pixels actually painted, which is what
/// keeps memory flat on low-RAM devices such as TV boxes.
class ArtworkDecode extends StatelessWidget {
  const ArtworkDecode({
    super.key,
    required this.paintedWidth,
    required this.builder,
  });

  /// Logical width the artwork is painted at — the viewport width for
  /// full-bleed banners, the card width for posters.
  final double paintedWidth;

  final Widget Function(BuildContext context, int? decodeWidth) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: highQualityArtwork,
      builder: (context, highQuality, _) =>
          builder(context, highQuality ? null : _decodeWidth(context)),
    );
  }

  int _decodeWidth(BuildContext context) {
    final pixels = paintedWidth * MediaQuery.devicePixelRatioOf(context);
    // The floor keeps tiny thumbnails legible. Decoding never upscales, so a
    // width above the source resolution is simply ignored.
    return pixels.ceil().clamp(160, 2048);
  }
}
