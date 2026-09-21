// Adapted from Mangayomi's lightweight continuous-page subsampling path
// (Apache-2.0). The outer reader owns zoom/pan; this widget owns image
// decoding/tiling so continuous pages do not install a second gesture arena.
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../shared/widgets/loading_indicator.dart';
import '../manga_reader_settings.dart';
import 'subsampling_scale_image_view.dart';

class MangaMinSubsamplingImage extends StatelessWidget {
  const MangaMinSubsamplingImage({
    super.key,
    required this.page,
    required this.settings,
    required this.fit,
    required this.rotation,
    required this.onImageLoaded,
    required this.onRetry,
    required this.retryEpoch,
  });

  final MangaPage page;
  final MangaReaderSettings settings;
  final BoxFit fit;
  final int rotation;
  final void Function(int width, int height) onImageLoaded;
  final VoidCallback onRetry;
  final int retryEpoch;

  ImageProvider<Object> get _provider {
    final uri = Uri.tryParse(page.imageUrl);
    if (uri != null && uri.scheme == 'file') {
      return FileImage(File.fromUri(uri));
    }
    return CachedNetworkImageProvider(page.imageUrl, headers: page.headers);
  }

  String? get _resolvedFilePath {
    final uri = Uri.tryParse(page.imageUrl);
    return uri != null && uri.scheme == 'file' ? File.fromUri(uri).path : null;
  }

  @override
  Widget build(BuildContext context) {
    return SubsamplingScaleImageView(
      key: ValueKey<String>('manga-reader-min-subsampling-$retryEpoch'),
      image: _provider,
      resolvedFilePath: _resolvedFilePath,
      cropBorders: settings.cropBorders,
      fit: fit,
      rotation: rotation,
      // Mangayomi's continuous reader owns zoom/pan for the whole strip.
      // Keep the image renderer out of the gesture arena.
      panEnabled: false,
      zoomEnabled: false,
      quickScaleEnabled: false,
      onImageLoaded: onImageLoaded,
      loadStateChanged: (state) => switch (state.loadState) {
        LoadState.loading => const Center(child: AppLoadingIndicator()),
        LoadState.failed => Center(
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
        LoadState.completed => null,
      },
    );
  }
}
