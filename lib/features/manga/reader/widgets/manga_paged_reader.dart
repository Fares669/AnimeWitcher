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

class _MangaPageUnit {
  const _MangaPageUnit(this.pageIndex, this.slice);

  final int pageIndex;
  final MangaReaderPageSlice slice;
}

class _MangaPagedReaderState extends State<MangaPagedReader> {
  late final PageController _controller;
  final Set<int> _widePages = <int>{};
  int _lastActualPage = 0;

  List<List<_MangaPageUnit>> get _spreads {
    if (!widget.doublePage) {
      final result = <List<_MangaPageUnit>>[];
      for (var index = 0; index < widget.pages.length; index++) {
        final slices = mangaReaderWidePageSlices(
          settings: widget.settings,
          isWide: _widePages.contains(index),
          isRtl: widget.rtl,
          doublePageActive: false,
        );
        for (final slice in slices) {
          result.add(<_MangaPageUnit>[_MangaPageUnit(index, slice)]);
        }
      }
      return result;
    }

    final result = <List<_MangaPageUnit>>[];
    var index = 0;
    if (widget.settings.doublePageSingleFirstPage && widget.pages.isNotEmpty) {
      result.add(const <_MangaPageUnit>[
        _MangaPageUnit(0, MangaReaderPageSlice.full),
      ]);
      index = 1;
    }
    while (index < widget.pages.length) {
      final pair = <_MangaPageUnit>[
        _MangaPageUnit(index, MangaReaderPageSlice.full),
      ];
      if (index + 1 < widget.pages.length) {
        pair.add(_MangaPageUnit(index + 1, MangaReaderPageSlice.full));
      }
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
      if (spreads[i].any((unit) => unit.pageIndex == page)) return i;
    }
    return 0;
  }

  @override
  void initState() {
    super.initState();
    _lastActualPage = _safeInitialPage;
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

  void _handleImageSize(int pageIndex, Size size) {
    if (!widget.settings.splitWidePages ||
        widget.doublePage ||
        size.width <= size.height ||
        _widePages.contains(pageIndex)) {
      return;
    }
    setState(() => _widePages.add(pageIndex));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final target = _spreadForPage(_lastActualPage);
      if ((_controller.page ?? target).round() != target) {
        _controller.jumpToPage(target);
      }
    });
  }

  Widget _page(
    BuildContext context,
    _MangaPageUnit unit, {
    bool zoomable = true,
  }) {
    final page = widget.pages[unit.pageIndex];
    final custom = widget.pageBuilder;
    if (custom != null) return custom(context, page);
    return _MangaPagedImage(
      page: page,
      settings: widget.settings,
      rtl: widget.rtl,
      slice: unit.slice,
      onImageSize: (size) => _handleImageSize(unit.pageIndex, size),
      zoomable: zoomable,
    );
  }

  Widget _spread(BuildContext context, List<_MangaPageUnit> units) {
    if (units.length == 1) return _page(context, units.first);
    return MangaZoomablePage(
      settings: widget.settings,
      rtl: widget.rtl,
      child: Row(
        textDirection: widget.rtl ? TextDirection.rtl : TextDirection.ltr,
        children: <Widget>[
          for (final unit in units)
            Expanded(child: _page(context, unit, zoomable: false)),
        ],
      ),
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
        final units = spreads[spreadIndex];
        final actual = units.isEmpty ? 0 : units.first.pageIndex;
        _lastActualPage = actual;
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
    required this.slice,
    required this.onImageSize,
    this.zoomable = true,
  });

  final MangaPage page;
  final MangaReaderSettings settings;
  final bool rtl;
  final MangaReaderPageSlice slice;
  final ValueChanged<Size> onImageSize;
  final bool zoomable;

  @override
  State<_MangaPagedImage> createState() => _MangaPagedImageState();
}

class _MangaPagedImageState extends State<_MangaPagedImage> {
  Size? _imageSize;

  @override
  Widget build(BuildContext context) {
    final size = _imageSize;
    final isSlice =
        widget.slice != MangaReaderPageSlice.full &&
        size != null &&
        size.width > size.height;

    Widget image;
    Size? contentSize = size;
    if (!isSlice) {
      image = MangaPageImage(
        page: widget.page,
        settings: widget.settings,
        fit: BoxFit.contain,
        expand: true,
        onImageSize: _onImageSize,
      );
    } else {
      final halfWidth = size.width / 2;
      contentSize = Size(halfWidth, size.height);
      image = SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: halfWidth,
            height: size.height,
            child: ClipRect(
              child: Align(
                alignment: widget.slice == MangaReaderPageSlice.left
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                widthFactor: 0.5,
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: MangaPageImage(
                    page: widget.page,
                    settings: widget.settings,
                    fit: BoxFit.fill,
                    expand: true,
                    onImageSize: _onImageSize,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (!widget.zoomable) return image;
    return MangaZoomablePage(
      settings: widget.settings,
      contentSize: contentSize,
      rtl: widget.rtl,
      child: image,
    );
  }

  void _onImageSize(Size size) {
    widget.onImageSize(size);
    if (!mounted || size == _imageSize) return;
    setState(() => _imageSize = size);
  }
}
