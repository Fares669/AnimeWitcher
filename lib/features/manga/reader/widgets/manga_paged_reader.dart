import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import 'manga_page_image.dart';

class MangaPagedReader extends StatefulWidget {
  const MangaPagedReader({
    super.key,
    required this.pages,
    required this.initialPage,
    required this.rtl,
    required this.onPageChanged,
    this.pageBuilder,
  });

  final List<MangaPage> pages;
  final int initialPage;
  final bool rtl;
  final ValueChanged<int> onPageChanged;
  final MangaPageBuilder? pageBuilder;

  @override
  State<MangaPagedReader> createState() => _MangaPagedReaderState();
}

class _MangaPagedReaderState extends State<MangaPagedReader> {
  late final PageController _controller;

  int get _safeInitialPage => widget.pages.isEmpty
      ? 0
      : widget.initialPage.clamp(0, widget.pages.length - 1).toInt();

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: _safeInitialPage);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _preloadAround(_safeInitialPage);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _preloadAround(int index) {
    if (widget.pageBuilder != null || widget.pages.isEmpty) return;
    final start = (index - 2).clamp(0, widget.pages.length - 1).toInt();
    final end = (index + 2).clamp(0, widget.pages.length - 1).toInt();
    for (var i = start; i <= end; i++) {
      final page = widget.pages[i];
      unawaited(
        precacheImage(
          NetworkImage(page.imageUrl, headers: page.headers),
          context,
        ).catchError((_) {}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _controller,
      reverse: widget.rtl,
      allowImplicitScrolling: true,
      itemCount: widget.pages.length,
      onPageChanged: (index) {
        widget.onPageChanged(index);
        _preloadAround(index);
      },
      itemBuilder: (context, index) {
        final page = widget.pages[index];
        final custom = widget.pageBuilder;
        if (custom != null) return custom(context, page);
        return InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: MangaPageImage(
            page: page,
            fit: BoxFit.contain,
            expand: true,
          ),
        );
      },
    );
  }
}
