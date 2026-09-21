import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../shared/widgets/loading_indicator.dart';
import '../manga_reader_settings.dart';

typedef MangaPageBuilder = Widget Function(
  BuildContext context,
  MangaPage page,
);

class MangaPageImage extends StatefulWidget {
  const MangaPageImage({
    super.key,
    required this.page,
    this.fit,
    this.expand = false,
    this.settings = const MangaReaderSettings(),
    this.onImageSize,
  });

  final MangaPage page;
  final BoxFit? fit;
  final bool expand;
  final MangaReaderSettings settings;
  final ValueChanged<Size>? onImageSize;

  @override
  State<MangaPageImage> createState() => _MangaPageImageState();
}

class _MangaPageImageState extends State<MangaPageImage> {
  ImageStream? _sizeStream;
  ImageStreamListener? _sizeListener;
  Size? _imageSize;
  int _retryEpoch = 0;

  BoxFit get _fit => widget.fit ?? switch (widget.settings.scaleType) {
    MangaReaderScaleType.fitScreen => BoxFit.contain,
    MangaReaderScaleType.stretch => BoxFit.fill,
    MangaReaderScaleType.fitWidth => BoxFit.fitWidth,
    MangaReaderScaleType.fitHeight => BoxFit.fitHeight,
    MangaReaderScaleType.originalSize => BoxFit.none,
    MangaReaderScaleType.smartFit => BoxFit.contain,
  };

  BlendMode? get _blendMode => switch (widget.settings.colorFilterBlendMode) {
    MangaReaderColorBlendMode.none => null,
    MangaReaderColorBlendMode.multiply => BlendMode.multiply,
    MangaReaderColorBlendMode.screen => BlendMode.screen,
    MangaReaderColorBlendMode.overlay => BlendMode.overlay,
    MangaReaderColorBlendMode.colorDodge => BlendMode.colorDodge,
    MangaReaderColorBlendMode.lighten => BlendMode.lighten,
    MangaReaderColorBlendMode.colorBurn => BlendMode.colorBurn,
    MangaReaderColorBlendMode.darken => BlendMode.darken,
    MangaReaderColorBlendMode.difference => BlendMode.difference,
    MangaReaderColorBlendMode.saturation => BlendMode.saturation,
    MangaReaderColorBlendMode.softLight => BlendMode.softLight,
    MangaReaderColorBlendMode.plus => BlendMode.plus,
    MangaReaderColorBlendMode.exclusion => BlendMode.exclusion,
  };

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
      _imageSize = null;
      _listenForImageSize();
    }
  }

  void _listenForImageSize() {
    final oldListener = _sizeListener;
    if (oldListener != null) _sizeStream?.removeListener(oldListener);

    final uri = Uri.tryParse(widget.page.imageUrl);
    final ImageProvider provider = uri != null && uri.scheme == 'file'
        ? FileImage(File.fromUri(uri))
        : CachedNetworkImageProvider(
            widget.page.imageUrl,
            headers: widget.page.headers,
          );
    final stream = provider.resolve(createLocalImageConfiguration(context));
    final listener = ImageStreamListener((info, _) {
      final size = Size(
        info.image.width.toDouble(),
        info.image.height.toDouble(),
      );
      if (!mounted || size == _imageSize) return;
      setState(() => _imageSize = size);
      widget.onImageSize?.call(size);
    });
    _sizeStream = stream;
    _sizeListener = listener;
    stream.addListener(listener);
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
      _retryEpoch++;
    });
    _listenForImageSize();
  }

  Widget _errorView(BuildContext context) => SizedBox(
    height: widget.expand ? null : 280,
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

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(widget.page.imageUrl);
    final Widget image;
    if (uri != null && uri.scheme == 'file') {
      image = Image.file(
        File.fromUri(uri),
        key: ValueKey<String>('reader-local-${widget.page.imageUrl}-$_retryEpoch'),
        width: double.infinity,
        height: widget.expand ? double.infinity : null,
        fit: _fit,
        errorBuilder: (_, _, _) => _errorView(context),
      );
    } else {
      image = CachedNetworkImage(
        key: ValueKey<String>('reader-network-${widget.page.imageUrl}-$_retryEpoch'),
        imageUrl: widget.page.imageUrl,
        httpHeaders: widget.page.headers,
        width: double.infinity,
        height: widget.expand ? double.infinity : null,
        fit: _fit,
        placeholder: (_, _) => SizedBox(
          height: widget.expand ? null : 360,
          child: const Center(child: AppLoadingIndicator()),
        ),
        errorWidget: (_, _, _) => _errorView(context),
      );
    }

    Widget filtered = ColorFiltered(
      colorFilter: ColorFilter.matrix(
        mangaReaderColorMatrix(widget.settings),
      ),
      child: image,
    );
    final blend = _blendMode;
    if (widget.settings.enableCustomColorFilter && blend != null) {
      filtered = ColorFiltered(
        colorFilter: ColorFilter.mode(
          Color(widget.settings.customColorFilterArgb),
          blend,
        ),
        child: filtered,
      );
    }

    if (widget.settings.cropBorders) {
      filtered = ClipRect(
        child: FractionallySizedBox(
          widthFactor: 1.02,
          heightFactor: 1.02,
          child: filtered,
        ),
      );
    }

    final imageSize = _imageSize;
    if (imageSize != null) {
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
