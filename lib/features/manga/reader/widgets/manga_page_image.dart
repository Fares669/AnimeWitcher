import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../shared/widgets/loading_indicator.dart';
import '../manga_reader_settings.dart';

typedef MangaPageBuilder = Widget Function(
  BuildContext context,
  MangaPage page,
);

class MangaPageImage extends StatelessWidget {
  const MangaPageImage({
    super.key,
    required this.page,
    this.fit,
    this.expand = false,
    this.settings = const MangaReaderSettings(),
  });

  final MangaPage page;
  final BoxFit? fit;
  final bool expand;
  final MangaReaderSettings settings;

  BoxFit get _fit => fit ?? switch (settings.scaleType) {
    MangaReaderScaleType.fitScreen => BoxFit.contain,
    MangaReaderScaleType.stretch => BoxFit.fill,
    MangaReaderScaleType.fitWidth => BoxFit.fitWidth,
    MangaReaderScaleType.fitHeight => BoxFit.fitHeight,
    MangaReaderScaleType.originalSize => BoxFit.none,
    MangaReaderScaleType.smartFit => BoxFit.contain,
  };

  BlendMode? get _blendMode => switch (settings.colorFilterBlendMode) {
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
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(page.imageUrl);
    final Widget image;
    if (uri != null && uri.scheme == 'file') {
      image = Image.file(
        File.fromUri(uri),
        width: double.infinity,
        height: expand ? double.infinity : null,
        fit: _fit,
        errorBuilder: (_, __, ___) => SizedBox(
          height: expand ? null : 280,
          child: const Center(child: Icon(Icons.broken_image_outlined, size: 42)),
        ),
      );
    } else {
      image = CachedNetworkImage(
        imageUrl: page.imageUrl,
        httpHeaders: page.headers,
        width: double.infinity,
        height: expand ? double.infinity : null,
        fit: _fit,
        placeholder: (_, __) => SizedBox(
          height: expand ? null : 360,
          child: const Center(child: AppLoadingIndicator()),
        ),
        errorWidget: (_, __, ___) => SizedBox(
          height: expand ? null : 280,
          child: const Center(child: Icon(Icons.broken_image_outlined, size: 42)),
        ),
      );
    }

    Widget filtered = ColorFiltered(
      colorFilter: ColorFilter.matrix(mangaReaderColorMatrix(settings)),
      child: image,
    );
    final blend = _blendMode;
    if (settings.enableCustomColorFilter && blend != null) {
      filtered = ColorFiltered(
        colorFilter: ColorFilter.mode(
          Color(settings.customColorFilterArgb),
          blend,
        ),
        child: filtered,
      );
    }

    if (settings.cropBorders) {
      filtered = ClipRect(
        child: FractionallySizedBox(
          widthFactor: 1.02,
          heightFactor: 1.02,
          child: filtered,
        ),
      );
    }
    return expand ? SizedBox.expand(child: filtered) : filtered;
  }
}
