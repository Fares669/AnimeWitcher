// Adapted from Mangayomi's lightweight continuous-page subsampling path
// (Apache-2.0). The outer reader owns zoom/pan; this widget owns image
// decoding/tiling so continuous pages do not install a second gesture arena.
import 'package:flutter/material.dart';

import '../manga_reader_settings.dart';
import '../widgets/manga_reader_page_loading.dart';
import 'subsampling_scale_image_view.dart';

class MangaMinSubsamplingImage extends StatelessWidget {
  const MangaMinSubsamplingImage({
    super.key,
    required this.image,
    required this.resolvedFilePath,
    required this.settings,
    required this.minimumScaleType,
    required this.rotation,
    this.sourceRect,
    required this.onImageLoaded,
    required this.onLoadSettled,
    required this.onRetry,
    required this.retryEpoch,
  });

  final ImageProvider<Object> image;
  final String? resolvedFilePath;
  final MangaReaderSettings settings;
  final ScaleType minimumScaleType;
  final int rotation;
  final Rect? sourceRect;
  final void Function(int width, int height) onImageLoaded;
  final VoidCallback onLoadSettled;
  final VoidCallback onRetry;
  final int retryEpoch;

  Widget _failedView(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => onLoadSettled());
    return SizedBox(
      height: mangaReaderPageLoadingExtent(MediaQuery.sizeOf(context)),
      child: Center(
        child: FilledButton.tonalIcon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: Text(
            Localizations.localeOf(context).languageCode.toLowerCase() == 'ar'
                ? 'إعادة المحاولة'
                : 'Retry',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SubsamplingScaleImageView(
      key: ValueKey<String>('manga-reader-min-subsampling-$retryEpoch'),
      image: image,
      resolvedFilePath: resolvedFilePath,
      cropBorders: settings.cropBorders,
      minimumScaleType: minimumScaleType,
      rotation: rotation,
      srcRect: sourceRect,
      // Mangayomi's continuous reader owns zoom/pan for the whole strip.
      // Keep the image renderer out of the gesture arena.
      panEnabled: false,
      zoomEnabled: false,
      quickScaleEnabled: false,
      onImageLoaded: onImageLoaded,
      loadStateChanged: (state) => switch (state.loadState) {
        LoadState.loading => MangaReaderPageLoadingPlaceholder(
          progress: mangaReaderChunkProgress(state.loadingProgress),
        ),
        LoadState.failed => _failedView(context),
        LoadState.completed => null,
      },
    );
  }
}
