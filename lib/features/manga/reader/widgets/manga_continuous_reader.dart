// Adapted from Mangayomi's continuous reader behavior (Apache-2.0).
import 'package:flutter/material.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/domain/entity/manga.dart';
import '../manga_reader_settings.dart';
import 'manga_chapter_transition_page.dart';
import 'manga_page_image.dart';
import 'manga_continuous_zoom_surface.dart';

class _ContinuousPagePart {
  const _ContinuousPagePart(this.pageIndex, this.slice);

  final int pageIndex;
  final MangaReaderPageSlice slice;
}

class _ContinuousEntry {
  const _ContinuousEntry(this.parts);

  final List<_ContinuousPagePart> parts;
  int get primaryIndex => parts.first.pageIndex;
}

class MangaContinuousReader extends StatefulWidget {
  const MangaContinuousReader({
    super.key,
    required this.pages,
    required this.initialPage,
    required this.scrollDirection,
    required this.reverse,
    required this.settings,
    required this.onPageChanged,
    this.doublePage = false,
    this.controller,
    this.pageBuilder,
    this.trailingPage,
    this.onTrailingAdvance,
  });

  final List<MangaPage> pages;
  final int initialPage;
  final Axis scrollDirection;
  final bool reverse;
  final MangaReaderSettings settings;
  final ValueChanged<int> onPageChanged;
  final bool doublePage;
  final ScrollController? controller;
  final MangaPageBuilder? pageBuilder;
  final Widget? trailingPage;
  final VoidCallback? onTrailingAdvance;

  @override
  State<MangaContinuousReader> createState() => _MangaContinuousReaderState();
}

class _MangaContinuousReaderState extends State<MangaContinuousReader> {
  late final ScrollController _controller =
      widget.controller ?? ScrollController();
  late final bool _ownsController = widget.controller == null;
  final ListController _listController = ListController();
  final Map<int, double> _visibility = <int, double>{};
  final Map<int, Size> _imageSizes = <int, Size>{};
  late int _lastReported = widget.pages.isEmpty
      ? 0
      : widget.initialPage.clamp(0, widget.pages.length - 1).toInt();
  late bool _initialJumpPending =
      widget.pages.isNotEmpty && widget.initialPage > 0;
  bool _scheduled = false;
  bool _trailingAdvanceRequested = false;

  bool get _doublePageActive =>
      widget.doublePage && widget.scrollDirection == Axis.vertical;

  List<_ContinuousEntry> get _entries {
    if (_doublePageActive) {
      return <_ContinuousEntry>[
        for (final spread in mangaReaderPageSpreads(
          pageCount: widget.pages.length,
          singleFirst: widget.settings.doublePageSingleFirstPage,
        ))
          _ContinuousEntry(<_ContinuousPagePart>[
            for (final index in spread)
              _ContinuousPagePart(index, MangaReaderPageSlice.full),
          ]),
      ];
    }

    final entries = <_ContinuousEntry>[];
    for (var index = 0; index < widget.pages.length; index++) {
      final size = _imageSizes[index];
      final slices = widget.pageBuilder == null
          ? mangaReaderWidePageSlices(
              settings: widget.settings,
              isWide: size != null && size.width > size.height * 1.2,
              isRtl: widget.reverse,
              doublePageActive: false,
            )
          : const <MangaReaderPageSlice>[MangaReaderPageSlice.full];
      for (final slice in slices) {
        entries.add(
          _ContinuousEntry(<_ContinuousPagePart>[
            _ContinuousPagePart(index, slice),
          ]),
        );
      }
    }
    return entries;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToInitialSpread();
    });
  }

  int _spreadIndexForPage(int pageIndex) {
    final entries = _entries;
    for (var index = 0; index < entries.length; index++) {
      if (entries[index].parts.any((part) => part.pageIndex == pageIndex)) {
        return index;
      }
    }
    return 0;
  }

  void _jumpToInitialSpread([int attempt = 0]) {
    if (!mounted || widget.pages.isEmpty || widget.initialPage <= 0) return;
    final targetPage = widget.initialPage
        .clamp(0, widget.pages.length - 1)
        .toInt();
    final targetSpread = _spreadIndexForPage(targetPage);
    if (_listController.isAttached && _controller.hasClients) {
      _listController.jumpToItem(
        index: targetSpread,
        scrollController: _controller,
        alignment: 0,
      );
      return;
    }
    if (attempt >= 5) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToInitialSpread(attempt + 1);
    });
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _changed(int pageIndex, VisibilityInfo info) {
    _visibility[pageIndex] = info.visibleFraction;
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || _visibility.isEmpty) return;
      if (_initialJumpPending) {
        final targetPage = widget.initialPage
            .clamp(0, widget.pages.length - 1)
            .toInt();
        final targetSpread = _spreadIndexForPage(targetPage);
        final entries = _entries;
        final targetAnchor = targetSpread < entries.length
            ? entries[targetSpread].primaryIndex
            : targetPage;
        if ((_visibility[targetAnchor] ?? 0) <= 0) return;
        _initialJumpPending = false;
        // Keep the persisted index as the progress anchor for this frame.
        // A later user/visibility update may advance it normally.
        return;
      }
      var best = _lastReported;
      var fraction = -1.0;
      for (final entry in _visibility.entries) {
        if (entry.value > fraction) {
          best = entry.key;
          fraction = entry.value;
        }
      }
      if (fraction > 0 && best != _lastReported) {
        _lastReported = best;
        widget.onPageChanged(best);
      }
    });
  }

  void _imageSizeChanged(int index, Size size) {
    if (!mounted || size.width <= 0 || size.height <= 0) return;
    final previous = _imageSizes[index];
    if (previous == size) return;
    setState(() => _imageSizes[index] = size);
  }

  Rect? _sourceRectFor(_ContinuousPagePart part) {
    if (part.slice == MangaReaderPageSlice.full) return null;
    final size = _imageSizes[part.pageIndex];
    if (size == null || size.width <= 0 || size.height <= 0) return null;
    final halfWidth = size.width / 2;
    return switch (part.slice) {
      MangaReaderPageSlice.left => Rect.fromLTWH(
          0,
          0,
          halfWidth,
          size.height,
        ),
      MangaReaderPageSlice.right => Rect.fromLTWH(
          halfWidth,
          0,
          halfWidth,
          size.height,
        ),
      MangaReaderPageSlice.full => null,
    };
  }

  Widget _pageContent(BuildContext context, _ContinuousPagePart part) {
    final page = widget.pages[part.pageIndex];
    final custom = widget.pageBuilder;
    if (custom != null) return custom(context, page);
    return MangaPageImage(
      page: page,
      settings: widget.settings,
      fit: widget.scrollDirection == Axis.horizontal ? BoxFit.contain : null,
      sourceRect: _sourceRectFor(part),
      onImageSize: part.slice == MangaReaderPageSlice.full
          ? (size) => _imageSizeChanged(part.pageIndex, size)
          : null,
    );
  }

  Widget _spread(BuildContext context, _ContinuousEntry entry) {
    final primaryIndex = entry.primaryIndex;
    Widget child = entry.parts.length == 1
        ? _pageContent(context, entry.parts.first)
        : Row(
            key: const ValueKey<String>('manga-reader-continuous-double-page'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final part in entry.parts)
                Expanded(child: _pageContent(context, part)),
            ],
          );

    if (widget.scrollDirection == Axis.horizontal) {
      child = SizedBox(width: MediaQuery.sizeOf(context).width, child: child);
    }
    if (widget.settings.showPageGaps) {
      child = Padding(
        key: const ValueKey('manga-reader-page-gap'),
        padding: widget.scrollDirection == Axis.vertical
            ? const EdgeInsets.only(bottom: 8)
            : const EdgeInsets.only(right: 8),
        child: child,
      );
    }
    return VisibilityDetector(
      key: ValueKey<String>(
        'manga-continuous-$primaryIndex-'
        '${entry.parts.map((part) => '${part.pageIndex}:${part.slice.name}').join('-')}',
      ),
      onVisibilityChanged: (info) => _changed(primaryIndex, info),
      child: child,
    );
  }

  bool _handleOverscroll(OverscrollNotification notification) {
    final callback = widget.onTrailingAdvance;
    if (_trailingAdvanceRequested ||
        widget.trailingPage == null ||
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
    if (widget.pages.isEmpty) return const SizedBox.shrink();
    final side = MediaQuery.sizeOf(context).width *
        (widget.settings.webtoonSidePadding.clamp(0, 50) / 100);
    final entries = _entries;
    final viewport = MediaQuery.sizeOf(context);
    final cacheExtent =
        widget.settings.pagePreloadAmount.clamp(1, 3) *
        1.5 *
        (widget.scrollDirection == Axis.horizontal
            ? viewport.width
            : viewport.height);
    final scrollable = Padding(
      key: const ValueKey('manga-reader-continuous-padding'),
      padding: widget.scrollDirection == Axis.vertical
          ? EdgeInsets.symmetric(horizontal: side)
          : EdgeInsets.zero,
      child: SuperListView.builder(
        cacheExtent: cacheExtent,
        controller: _controller,
        listController: _listController,
        scrollDirection: widget.scrollDirection,
        reverse: widget.reverse,
        itemCount: entries.length + (widget.trailingPage == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (index >= entries.length) return widget.trailingPage!;
          return _spread(context, entries[index]);
        },
      ),
    );
    return MangaContinuousZoomSurface(
      scrollController: _controller,
      scrollDirection: widget.scrollDirection,
      settings: widget.settings,
      child: NotificationListener<OverscrollNotification>(
        onNotification: _handleOverscroll,
        child: scrollable,
      ),
    );
  }
}
