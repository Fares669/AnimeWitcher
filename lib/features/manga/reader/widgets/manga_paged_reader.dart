import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../manga_reader_settings.dart';
import 'manga_page_image.dart';
import 'manga_zoomable_page.dart';

class MangaPagedReader extends StatefulWidget {
  const MangaPagedReader({
    super.key,
    required this.pages,
    required this.initialPage,
    required this.rtl,
    required this.onPageChanged,
    this.pageBuilder,
    this.scrollDirection = Axis.horizontal,
    this.doublePage = false,
    this.settings = const MangaReaderSettings(),
    this.trailingPage,
  });

  final List<MangaPage> pages;
  final int initialPage;
  final bool rtl;
  final ValueChanged<int> onPageChanged;
  final MangaPageBuilder? pageBuilder;
  final Axis scrollDirection;
  final bool doublePage;
  final MangaReaderSettings settings;
  final Widget? trailingPage;

  @override
  State<MangaPagedReader> createState() => _MangaPagedReaderState();
}

class _MangaPagedReaderState extends State<MangaPagedReader> {
  late final PageController _controller;

  List<List<int>> get _spreads {
    if (!widget.doublePage) {
      return List<List<int>>.generate(
        widget.pages.length,
        (index) => <int>[index],
        growable: false,
      );
    }
    final result = <List<int>>[];
    var index = 0;
    if (widget.settings.doublePageSingleFirstPage && widget.pages.isNotEmpty) {
      result.add(<int>[0]);
      index = 1;
    }
    while (index < widget.pages.length) {
      final pair = <int>[index];
      if (index + 1 < widget.pages.length) pair.add(index + 1);
      if (widget.settings.dualPageInvert && pair.length == 2) {
        result.add(pair.reversed.toList(growable: false));
      } else {
        result.add(pair);
      }
      index += 2;
    }
    return result;
  }

  int get _safeInitialPage => widget.pages.isEmpty
      ? 0
      : widget.initialPage.clamp(0, widget.pages.length - 1).toInt();

  int _spreadForPage(int page) {
    final spreads = _spreads;
    for (var i = 0; i < spreads.length; i++) {
      if (spreads[i].contains(page)) return i;
    }
    return 0;
  }

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: _spreadForPage(_safeInitialPage));
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
    final amount = widget.settings.pagePreloadAmount.clamp(0, 20);
    final start = (index - amount).clamp(0, widget.pages.length - 1).toInt();
    final end = (index + amount).clamp(0, widget.pages.length - 1).toInt();
    for (var i = start; i <= end; i++) {
      final page = widget.pages[i];
      final uri = Uri.tryParse(page.imageUrl);
      if (uri?.scheme == 'file') continue;
      unawaited(
        precacheImage(
          NetworkImage(page.imageUrl, headers: page.headers),
          context,
        ).catchError((_) {}),
      );
    }
  }

  Widget _page(BuildContext context, MangaPage page) {
    final custom = widget.pageBuilder;
    if (custom != null) return custom(context, page);
    return _MangaPagedImage(
      page: page,
      settings: widget.settings,
      rtl: widget.rtl,
    );
  }

  Widget _spread(BuildContext context, List<int> indexes) {
    if (indexes.length == 1) return _page(context, widget.pages[indexes.first]);
    return Row(
      textDirection: widget.rtl ? TextDirection.rtl : TextDirection.ltr,
      children: <Widget>[
        for (final index in indexes)
          Expanded(child: _page(context, widget.pages[index])),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final spreads = _spreads;
    return PageView.builder(
      controller: _controller,
      scrollDirection: widget.scrollDirection,
      reverse: widget.rtl && widget.scrollDirection == Axis.horizontal,
      allowImplicitScrolling: true,
      physics: widget.settings.animatePageTransitions
          ? null
          : const PageScrollPhysics(),
      itemCount: spreads.length + (widget.trailingPage == null ? 0 : 1),
      onPageChanged: (spreadIndex) {
        if (spreadIndex >= spreads.length) return;
        final indexes = spreads[spreadIndex];
        final actual = indexes.isEmpty ? 0 : indexes.first;
        widget.onPageChanged(actual);
        _preloadAround(actual);
      },
      itemBuilder: (context, index) {
        if (index >= spreads.length) return widget.trailingPage!;
        return _spread(context, spreads[index]);
      },
    );
  }
}


class _MangaPagedImage extends StatefulWidget {
  const _MangaPagedImage({
    required this.page,
    required this.settings,
    required this.rtl,
  });

  final MangaPage page;
  final MangaReaderSettings settings;
  final bool rtl;

  @override
  State<_MangaPagedImage> createState() => _MangaPagedImageState();
}

class _MangaPagedImageState extends State<_MangaPagedImage> {
  Size? _imageSize;

  @override
  Widget build(BuildContext context) {
    return MangaZoomablePage(
      settings: widget.settings,
      contentSize: _imageSize,
      rtl: widget.rtl,
      child: MangaPageImage(
        page: widget.page,
        settings: widget.settings,
        fit: BoxFit.contain,
        expand: true,
        onImageSize: (size) {
          if (!mounted || size == _imageSize) return;
          setState(() => _imageSize = size);
        },
      ),
    );
  }
}
