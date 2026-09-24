import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/domain/entity/manga.dart';
import '../manga_reader_settings.dart';
import 'manga_chapter_transition_page.dart';
import 'manga_page_image.dart';
import 'manga_reader_load_scheduler.dart';
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
    this.onTrailingAdvance,
    this.navigationController,
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
  final VoidCallback? onTrailingAdvance;
  final MangaZoomNavigationController? navigationController;

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
  late int _currentSpreadIndex;
  bool _onTrailingPage = false;
  bool _trailingAdvanceRequested = false;
  int _preloadGeneration = 0;

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

    return mangaReaderPageSpreads(
      pageCount: widget.pages.length,
      singleFirst: widget.settings.doublePageSingleFirstPage,
    )
        .map(
          (spread) => <_MangaPageUnit>[
            for (final index in spread)
              _MangaPageUnit(index, MangaReaderPageSlice.full),
          ],
        )
        .toList(growable: false);
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
    _currentSpreadIndex = _spreadForPage(_safeInitialPage);
    _controller = PageController(initialPage: _currentSpreadIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_preloadInOrderedBatches());
    });
  }

  @override
  void dispose() {
    _preloadGeneration++;
    _controller.dispose();
    super.dispose();
  }

  Future<void> _preloadInOrderedBatches() async {
    if (widget.pageBuilder != null || widget.pages.isEmpty) return;
    final generation = ++_preloadGeneration;
    final batches = mangaReaderOrderedPreloadBatches(
      pageCount: widget.pages.length,
      initialPage: _safeInitialPage,
      batchSize: widget.settings.pagePreloadAmount,
    );
    for (final batch in batches) {
      if (!mounted || generation != _preloadGeneration) return;
      await Future.wait(
        batch.map((index) async {
          final page = widget.pages[index];
          final uri = Uri.tryParse(page.imageUrl);
          if (uri?.scheme == 'file') return;
          try {
            await precacheImage(mangaPageImageProvider(page), context);
          } catch (_) {}
        }),
      );
    }
  }

  @override
  void didUpdateWidget(covariant MangaPagedReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pages.length != widget.pages.length ||
        oldWidget.initialPage != widget.initialPage ||
        oldWidget.settings.pagePreloadAmount !=
            widget.settings.pagePreloadAmount) {
      _preloadGeneration++;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_preloadInOrderedBatches());
      });
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
    MangaZoomNavigationController? navigationController,
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
      navigationController: navigationController,
    );
  }

  Widget _spread(
    BuildContext context,
    List<_MangaPageUnit> units,
    int spreadIndex,
  ) {
    final navigationController = spreadIndex == _currentSpreadIndex
        ? widget.navigationController
        : null;
    if (units.length == 1) {
      return _page(
        context,
        units.first,
        navigationController: navigationController,
      );
    }
    return MangaZoomablePage(
      settings: widget.settings,
      navigationController: navigationController,
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

  bool _handleOverscroll(OverscrollNotification notification) {
    final callback = widget.onTrailingAdvance;
    if (!_onTrailingPage ||
        _trailingAdvanceRequested ||
        callback == null ||
        !mangaReaderShouldAdvancePastTransition(
          extentAfter: notification.metrics.extentAfter,
          overscroll: notification.overscroll,
        )) {
      return false;
    }
    _trailingAdvanceRequested = true;
    callback();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final spreads = _spreads;
    return NotificationListener<OverscrollNotification>(
      onNotification: _handleOverscroll,
      child: PageView.builder(
      controller: _controller,
      scrollDirection: widget.scrollDirection,
      reverse: widget.rtl && widget.scrollDirection == Axis.horizontal,
      allowImplicitScrolling: true,
      physics: widget.settings.animatePageTransitions
          ? null
          : const PageScrollPhysics(),
      itemCount: spreads.length + (widget.trailingPage == null ? 0 : 1),
      onPageChanged: (spreadIndex) {
        if (spreadIndex >= spreads.length) {
          setState(() => _onTrailingPage = true);
          return;
        }
        final units = spreads[spreadIndex];
        final actual = units.isEmpty ? 0 : units.first.pageIndex;
        setState(() {
          _currentSpreadIndex = spreadIndex;
          _onTrailingPage = false;
          _trailingAdvanceRequested = false;
        });
        _lastActualPage = actual;
        widget.onPageChanged(actual);
      },
      itemBuilder: (context, index) {
        if (index >= spreads.length) return widget.trailingPage!;
        return _spread(context, spreads[index], index);
      },
    ),
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
    this.navigationController,
  });

  final MangaPage page;
  final MangaReaderSettings settings;
  final bool rtl;
  final MangaReaderPageSlice slice;
  final ValueChanged<Size> onImageSize;
  final bool zoomable;
  final MangaZoomNavigationController? navigationController;

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
      navigationController: widget.navigationController,
      child: image,
    );
  }

  void _onImageSize(Size size) {
    widget.onImageSize(size);
    if (!mounted || size == _imageSize) return;
    setState(() => _imageSize = size);
  }
}
