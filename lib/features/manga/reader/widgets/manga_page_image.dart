import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../../../../shared/widgets/loading_indicator.dart';

typedef MangaPageBuilder = Widget Function(
  BuildContext context,
  MangaPage page,
);

class MangaPageImage extends StatelessWidget {
  const MangaPageImage({
    super.key,
    required this.page,
    this.fit = BoxFit.fitWidth,
    this.expand = false,
  });

  final MangaPage page;
  final BoxFit fit;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(page.imageUrl);
    final Widget image;
    if (uri != null && uri.scheme == 'file') {
      image = Image.file(
        File.fromUri(uri),
        width: double.infinity,
        height: expand ? double.infinity : null,
        fit: fit,
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
        fit: fit,
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

    return expand ? SizedBox.expand(child: image) : image;
  }
}
