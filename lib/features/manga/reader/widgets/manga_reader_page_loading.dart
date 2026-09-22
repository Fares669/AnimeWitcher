import 'package:flutter/material.dart';

import '../../../../shared/widgets/loading_indicator.dart';

double mangaReaderPageLoadingExtent(Size viewport) => viewport.height * 0.8;

double? mangaReaderChunkProgress(ImageChunkEvent? progress) {
  final total = progress?.expectedTotalBytes;
  if (progress == null || total == null || total <= 0) return null;
  final loaded = progress.cumulativeBytesLoaded;
  if (loaded <= 0) return null;
  return (loaded / total).clamp(0.0, 1.0).toDouble();
}

class MangaReaderPageLoadingPlaceholder extends StatelessWidget {
  const MangaReaderPageLoadingPlaceholder({
    super.key,
    this.progress,
  });

  final double? progress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey<String>('manga-reader-page-loading-placeholder'),
      width: double.infinity,
      height: mangaReaderPageLoadingExtent(MediaQuery.sizeOf(context)),
      child: Center(child: AppLoadingIndicator(value: progress)),
    );
  }
}
