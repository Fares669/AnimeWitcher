import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../manga_reader_settings.dart';
import 'manga_reader_page_loading.dart';
import '../subsampling/manga_min_subsampling_image.dart';
import '../subsampling/subsampling_scale_image_view.dart';

typedef MangaPageBuilder = Widget Function(
  BuildContext context,
  MangaPage page,
);

enum MangaPageImageTier {
  pagedSubsampling,
  continuousSubsampling,
  animated,
}

@visibleForTesting
MangaPageImageTier mangaPageImageTier({
  required MangaPage page,
  required bool expand,
}) {
  final uri = Uri.tryParse(page.imageUrl);
  final path = (uri?.path ?? page.imageUrl).toLowerCase();
  if (path.endsWith('.gif')) return MangaPageImageTier.animated;
  return expand
      ? MangaPageImageTier.pagedSubsampling
      : MangaPageImageTier.continuousSubsampling;
}

@visibleForTesting
ScaleType mangaReaderMinimumScaleType(MangaReaderScaleType scaleType) =>
    switch (scaleType) {
      MangaReaderScaleType.fitScreen => ScaleType.centerInside,
      MangaReaderScaleType.stretch => ScaleType.centerCrop,
      MangaReaderScaleType.fitWidth => ScaleType.fitWidth,
      MangaReaderScaleType.fitHeight => ScaleType.fitHeight,
      MangaReaderScaleType.originalSize => ScaleType.originalSize,
      MangaReaderScaleType.smartFit => ScaleType.smartFit,
    };

ImageProvider<Object> mangaPageImageProvider(MangaPage page) {
  final uri = Uri.tryParse(page.imageUrl);
  return uri != null && uri.scheme == 'file'
      ? FileImage(File.fromUri(uri))
      : CachedNetworkImageProvider(
          page.imageUrl,
          headers: page.headers,
        );
}

class MangaPageImage extends StatefulWidget {
  const MangaPageImage({
    super.key,
    required this.page,
    this.fit,
    this.expand = false,
    this.settings = const MangaReaderSettings(),
    this.onImageSize,
    this.onLoadSettled,
    this.onImageError,
    this.sourceRect,
  });

  final MangaPage page;
  final BoxFit? fit;
  final bool expand;
  final MangaReaderSettings settings;
  final ValueChanged<Size>? onImageSize;
  final VoidCallback? onLoadSettled;
  final ValueChanged<MangaPage>? onImageError;
  final Rect? sourceRect;

  @override
  State<MangaPageImage> createState() => _MangaPageImageState();
}

class _MangaPageImageState extends State<MangaPageImage>
    with AutomaticKeepAliveClientMixin<MangaPageImage> {
  ImageStream? _sizeStream;
  ImageStreamListener? _sizeListener;
  Size? _imageSize;
  int _retryEpoch = 0;
  bool _loadSettledNotified = false;
  bool _errorReported = false;
  late ImageProvider<Object> _provider;

  @override
  void initState() {
    super.initState();
    _provider = _createImageProvider(widget.page);
  }

  BoxFit get _fit => widget.fit ?? switch (widget.settings.scaleType) {
    MangaReaderScaleType.fitScreen => BoxFit.contain,
    MangaReaderScaleType.stretch => BoxFit.fill,
    MangaReaderScaleType.fitWidth => BoxFit.fitWidth,
    MangaReaderScaleType.fitHeight => BoxFit.fitHeight,
    MangaReaderScaleType.originalSize => BoxFit.none,
    MangaReaderScaleType.smartFit => BoxFit.contain,
  };

  bool get _useSubsampling =>
      mangaPageImageTier(page: widget.page, expand: widget.expand) !=
      MangaPageImageTier.animated;

  ImageProvider<Object> _createImageProvider(MangaPage page) =>
      mangaPageImageProvider(page);

  ImageProvider<Object> get _imageProvider => _provider;

  String? get _resolvedFilePath {
    final uri = Uri.tryParse(widget.page.imageUrl);
    return uri != null && uri.scheme == 'file' ? File.fromUri(uri).path : null;
  }


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listenForImageSize();
  }

  @override
  void didUpdateWidget(covariant MangaPageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.imageUrl != widget.page.imageUrl ||
        !mapEquals(oldWidget.page.headers, widget.page.headers)) {
      _provider = _createImageProvider(widget.page);
      _imageSize = null;
      _loadSettledNotified = false;
      _errorReported = false;
      _retryEpoch++;
      _listenForImageSize();
    }
  }

  void _listenForImageSize() {
    final oldListener = _sizeListener;
    if (oldListener != null) _sizeStream?.removeListener(oldListener);

    if (_useSubsampling) {
      _sizeStream = null;
      _sizeListener = null;
      return;
    }
    final ImageProvider<Object> provider = _imageProvider;
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((info, _) {
      final size = Size(
        info.image.width.toDouble(),
        info.image.height.toDouble(),
      );
      if (!mounted || size == _imageSize) return;
      setState(() => _imageSize = size);
      widget.onImageSize?.call(size);
      _notifyLoadSettled();
    });
    _sizeStream = stream;
    _sizeListener = listener;
    stream.addListener(listener);
  }

  void _notifyLoadSettled() {
    if (_loadSettledNotified) return;
    _loadSettledNotified = true;
    widget.onLoadSettled?.call();
  }

  void _scheduleLoadSettled() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _notifyLoadSettled();
    });
  }

  @override
  void dispose() {
    final listener = _sizeListener;
    if (listener != null) _sizeStream?.removeListener(listener);
    super.dispose();
  }

  Future<void> _retry() async {
    final uri = Uri.tryParse(widget.page.imageUrl);
    if (uri == null || uri.scheme != 'file') {
      await CachedNetworkImage.evictFromCache(widget.page.imageUrl);
    }
    if (!mounted) return;
    setState(() {
      _imageSize = null;
      _loadSettledNotified = false;
      _errorReported = false;
      _retryEpoch++;
    });
    _listenForImageSize();
  }

  void _reportImageError() {
    if (_errorReported) return;
    _errorReported = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onImageError?.call(widget.page);
    });
  }

  Widget _errorView(BuildContext context) {
    _scheduleLoadSettled();
    _reportImageError();
    return SizedBox(
    height: mangaReaderPageLoadingExtent(MediaQuery.sizeOf(context)),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.broken_image_outlined, size: 42),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: _retry,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(
              Localizations.localeOf(context).languageCode.toLowerCase() == 'ar'
                  ? 'إعادة المحاولة'
                  : 'Retry',
            ),
          ),
        ],
      ),
    ),
  );
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final uri = Uri.tryParse(widget.page.imageUrl);
    final localFile = uri != null && uri.scheme == 'file'
        ? File.fromUri(uri)
        : null;
    if (localFile != null && !localFile.existsSync()) {
      return _errorView(context);
    }

    final Widget image;
    final useSubsampling = _useSubsampling;
    if (useSubsampling) {
      final imageSize = _imageSize;
      final quarterTurns = imageSize == null
          ? 0
          : mangaReaderRotateQuarterTurns(
              settings: widget.settings,
              imageSize: imageSize,
            );
      void loaded(int width, int height) {
        final size = Size(width.toDouble(), height.toDouble());
        if (!mounted || size == _imageSize) return;
        setState(() => _imageSize = size);
        widget.onImageSize?.call(size);
        _notifyLoadSettled();
      }

      if (widget.expand) {
        image = SubsamplingScaleImageView(
          key: ValueKey<String>(
            'reader-subsampling-${widget.page.imageUrl}-$_retryEpoch',
          ),
          image: _imageProvider,
          resolvedFilePath: _resolvedFilePath,
          cropBorders: widget.settings.cropBorders,
          minimumScaleType: mangaReaderMinimumScaleType(
            widget.settings.scaleType,
          ),
          rotation: quarterTurns * 90,
          srcRect: widget.sourceRect,
          // MangaZoomablePage owns gestures in the paged reader. Leaving the
          // renderer interactive here creates two competing zoom recognizers.
          panEnabled: false,
          zoomEnabled: false,
          quickScaleEnabled: false,
          onImageLoaded: loaded,
          loadStateChanged: (state) => switch (state.loadState) {
            LoadState.loading => MangaReaderPageLoadingPlaceholder(
              progress: mangaReaderChunkProgress(state.loadingProgress),
            ),
            LoadState.failed => _errorView(context),
            LoadState.completed => null,
          },
        );
      } else {
        image = MangaMinSubsamplingImage(
          image: _imageProvider,
          resolvedFilePath: _resolvedFilePath,
          settings: widget.settings,
          minimumScaleType: mangaReaderMinimumScaleType(
            widget.settings.scaleType,
          ),
          rotation: quarterTurns * 90,
          sourceRect: widget.sourceRect,
          onImageLoaded: loaded,
          onLoadSettled: _notifyLoadSettled,
          onImageError: _reportImageError,
          onRetry: () {
            _retry();
          },
          retryEpoch: _retryEpoch,
        );
      }
    } else if (localFile != null) {
      image = Image.file(
        localFile,
        key: ValueKey<String>(
          'reader-local-${widget.page.imageUrl}-$_retryEpoch',
        ),
        width: double.infinity,
        height: widget.expand ? double.infinity : null,
        fit: _fit,
        errorBuilder: (_, _, _) => _errorView(context),
      );
    } else {
      image = CachedNetworkImage(
        key: ValueKey<String>(
          'reader-network-${widget.page.imageUrl}-$_retryEpoch',
        ),
        imageUrl: widget.page.imageUrl,
        httpHeaders: widget.page.headers,
        width: double.infinity,
        height: widget.expand ? double.infinity : null,
        fit: _fit,
        progressIndicatorBuilder: (_, _, progress) =>
            MangaReaderPageLoadingPlaceholder(progress: progress.progress),
        errorWidget: (_, _, _) => _errorView(context),
      );
    }

    Widget filtered = image;

    if (widget.settings.cropBorders && !useSubsampling) {
      filtered = ClipRect(
        child: FractionallySizedBox(
          widthFactor: 1.02,
          heightFactor: 1.02,
          child: filtered,
        ),
      );
    }

    final imageSize = _imageSize;
    if (imageSize != null &&
        !useSubsampling &&
        widget.sourceRect != null &&
        imageSize.width > 0) {
      final rect = widget.sourceRect!;
      final alignment = rect.left > 0
          ? Alignment.centerRight
          : Alignment.centerLeft;
      filtered = ClipRect(
        child: Align(
          alignment: alignment,
          widthFactor: (rect.width / imageSize.width).clamp(0.0, 1.0),
          child: filtered,
        ),
      );
    }
    if (imageSize != null && !useSubsampling) {
      final quarterTurns = mangaReaderRotateQuarterTurns(
        settings: widget.settings,
        imageSize: imageSize,
      );
      if (quarterTurns != 0) {
        filtered = RotatedBox(
          key: const ValueKey('manga-reader-rotate-to-fit'),
          quarterTurns: quarterTurns,
          child: filtered,
        );
      }
    }

    return widget.expand ? SizedBox.expand(child: filtered) : filtered;
  }
}
