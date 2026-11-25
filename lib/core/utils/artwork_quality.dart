import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Whether artwork uses its high-quality source and display budget.
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
/// High quality keeps the full decode unless a fixed-size display opts into
/// [sizeHighQualityToDisplay]. Such artwork gets physical-pixel headroom and
/// shares nearby decode widths instead of caching an original for every card.
class ArtworkDecode extends StatelessWidget {
  const ArtworkDecode({
    super.key,
    required this.paintedWidth,
    required this.builder,
    this.sizeHighQualityToDisplay = false,
    this.bucketStandardDecode = false,
  });

  /// Logical width the artwork is painted at — the viewport width for
  /// full-bleed banners, the card width for posters.
  final double paintedWidth;
  final bool sizeHighQualityToDisplay;
  final bool bucketStandardDecode;

  final Widget Function(BuildContext context, int? decodeWidth) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: highQualityArtwork,
      builder: (context, highQuality, _) => builder(
        context,
        artworkDisplayDecodeWidth(
          paintedWidth: paintedWidth,
          devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
          highQuality: highQuality,
          sizeHighQualityToDisplay: sizeHighQualityToDisplay,
          bucketStandardDecode: bucketStandardDecode,
        ),
      ),
    );
  }
}

int? artworkDisplayDecodeWidth({
  required double paintedWidth,
  required double devicePixelRatio,
  required bool highQuality,
  bool sizeHighQualityToDisplay = false,
  bool bucketStandardDecode = false,
}) {
  final pixels = paintedWidth * devicePixelRatio;
  if (!pixels.isFinite || pixels <= 0) return null;
  if (highQuality) {
    if (!sizeHighQualityToDisplay || pixels >= 1920) return null;
    // Allow room for cover crops and card focus animations; use the source
    // width for large/high-DPI presentations.
    return ((pixels * 1.25 / 64).ceil() * 64).clamp(192, 2432);
  }
  if (pixels >= 2048) return 2048;
  final width = bucketStandardDecode
      ? (pixels / 32).ceil() * 32
      : pixels.ceil();
  return width.clamp(160, 2048);
}
