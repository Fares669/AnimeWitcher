// Adapted from Mangayomi's continuous reader behavior (Apache-2.0).
import 'package:flutter/material.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/domain/entity/manga.dart';
import '../manga_reader_settings.dart';
import 'manga_page_image.dart';
import 'manga_reader_load_scheduler.dart';
import 'manga_reader_page_loading.dart';
import 'manga_reader_trailing_advance.dart';
import 'manga_reader_visible_pages.dart';
import 'manga_continuous_zoom_surface.dart';

class _ContinuousPagePart {
  const _ContinuousPagePart(this.pageIndex, this.slice);

  final int pageIndex;
  final MangaReaderPageSlice slice;
}

class _ContinuousEntry {
  const _ContinuousEntry(this.parts) : divider = null, dividerPageIndex = null;

  const _ContinuousEntry.dividerEntry(this.divider, this.dividerPageIndex)
    : parts = const <_ContinuousPagePart>[];

  final List<_ContinuousPagePart> parts;

  /// A between-chapters divider shown in the stream instead of pages.
  final Widget? divider;
  final int? dividerPageIndex;

  bool get isDivider => divider != null;
  int get primaryIndex =>
      parts.isNotEmpty ? parts.first.pageIndex : dividerPageIndex!;
}

List<MangaReaderPageSlice> mangaContinuousPageSlices({
  required MangaReaderSettings settings,
  required Size? imageSize,
  required bool isRtl,
  required bool doublePageActive,
  required bool hasCustomPageBuilder,
}) {
  if (hasCustomPageBuilder) {
    return const <MangaReaderPageSlice>[MangaReaderPageSlice.full];
  }
  return mangaReaderWidePageSlices(
    settings: settings,
    isWide:
        imageSize != null &&
        imageSize.width > 0 &&
        imageSize.height > 0 &&
        imageSize.width > imageSize.height * 1.2,
    isRtl: isRtl,
    doublePageActive: doublePageActive,
  );
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
    this.onDoubleTap,
    this.sectionDividers = const <int, Widget>{},
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
  final VoidCallback? onDoubleTap;

  /// Dividers inserted into the stream, keyed by the page index they
  /// precede — the seams of a connected chapter stream.
  final Map<int, Widget> sectionDividers;

  @override
  State<MangaContinuousReader> createState() => _MangaContinuousReaderState();
}

class _MangaContinuousReaderState extends State<MangaContinuousReader>
    with MangaReaderTrailingAdvance<MangaContinuousReader> {
  late final ScrollController _controller =
      widget.controller ?? ScrollController();
  late final bool _ownsController = widget.controller == null;
  final ListController _listController = ListController();
  final _visiblePages = MangaReaderVisiblePages();
  final Map<int, Size> _imageSizes = <int, Size>{};
  final Set<int> _settledPages = <int>{};
  late final int _sessionInitialPage;
  late int _lastReported;
  late bool _initialJumpPending;
  bool _scheduled = false;
  MangaReaderLoadBatchController? _loadBatches;

  @override
  ScrollController get trailingScrollController => _controller;

  @override
  bool get hasTrailingChapterPage => widget.trailingPage != null;

  @override
  VoidCallback? get trailingAdvanceCallback => widget.onTrailingAdvance;

  bool get _doublePageActive =>
      widget.doublePage && widget.scrollDirection == Axis.vertical;

  List<_ContinuousEntry> get _entries {
    if (_doublePageActive) {
      return <_ContinuousEntry>[
        for (final spread in mangaReaderPageSpreads(
          pageCount: widget.pages.length,
          singleFirst: widget.settings.doublePageSingleFirstPage,
          sectionStarts: widget.sectionDividers.keys,
        )) ...<_ContinuousEntry>[
          if (widget.sectionDividers.containsKey(spread.first))
            _ContinuousEntry.dividerEntry(
              widget.sectionDividers[spread.first],
              spread.first,
            ),
          _ContinuousEntry(<_ContinuousPagePart>[
            for (final index in spread)
              _ContinuousPagePart(index, MangaReaderPageSlice.full),
          ]),
        ],
      ];
    }

    final entries = <_ContinuousEntry>[];
    for (var index = 0; index < widget.pages.length; index++) {
      final divider = widget.sectionDividers[index];
      if (divider != null) {
        entries.add(_ContinuousEntry.dividerEntry(divider, index));
      }
      final size = _imageSizes[index];
      final slices = mangaContinuousPageSlices(
        settings: widget.settings,
        imageSize: size,
        isRtl: widget.reverse,
        doublePageActive: false,
        hasCustomPageBuilder: widget.pageBuilder != null,
      );
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
    _sessionInitialPage = widget.pages.isEmpty
        ? 0
        : widget.initialPage.clamp(0, widget.pages.length - 1).toInt();
    _lastReported = _sessionInitialPage;
    _initialJumpPending = widget.pages.isNotEmpty && _sessionInitialPage > 0;
    _resetLoadBatches();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToInitialSpread();
      checkTrailingProximitySoon();
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
    if (!mounted || widget.pages.isEmpty || _sessionInitialPage <= 0) return;
    final targetPage = _sessionInitialPage
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

  void _resetLoadBatches() {
    _loadBatches?.removeListener(_onLoadBatchChanged);
    _loadBatches?.dispose();
    _loadBatches = MangaReaderLoadBatchController(
      pageCount: widget.pages.length,
      initialPage: _sessionInitialPage,
      batchSize: widget.settings.pagePreloadAmount,
    )..addListener(_onLoadBatchChanged);

    // Re-seed a rebuilt scheduler with pages already completed in this reader
    // session so a settings rebuild can never relock or stall them.
    final settled = _settledPages.toList()..sort();
    for (final pageIndex in settled) {
      _loadBatches?.markSettled(pageIndex);
    }
  }

  void _onLoadBatchChanged() {
    if (mounted) setState(() {});
    // Page extents settle as images arrive; the end may have come into
    // reach without any scrolling.
    checkTrailingProximitySoon();
  }

  @override
  void didUpdateWidget(covariant MangaContinuousReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pages.length != widget.pages.length ||
        oldWidget.settings.pagePreloadAmount !=
            widget.settings.pagePreloadAmount) {
      _resetLoadBatches();
    }
  }

  @override
  void dispose() {
    _loadBatches?.removeListener(_onLoadBatchChanged);
    _loadBatches?.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _changed(int pageIndex, VisibilityInfo info) {
    _visiblePages.record(pageIndex, info.visibleFraction);
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || _visiblePages.isEmpty) return;
      _visiblePages.advanceRound();
      if (_initialJumpPending) {
        final targetPage = _sessionInitialPage
            .clamp(0, widget.pages.length - 1)
            .toInt();
        final targetSpread = _spreadIndexForPage(targetPage);
        final entries = _entries;
        final targetAnchor = targetSpread < entries.length
            ? entries[targetSpread].primaryIndex
            : targetPage;
        if (_visiblePages.fractionOf(targetAnchor) <= 0) return;
        _initialJumpPending = false;
        // Keep the persisted index as the progress anchor for this frame.
        // A later user/visibility update may advance it normally.
        return;
      }
      final best = _visiblePages.mostVisiblePage;
      if (best != null && best != _lastReported) {
        _lastReported = best;
        widget.onPageChanged(best);
      }
    });
  }

  void _imageSizeChanged(int index, Size size) {
    if (!mounted || size.width <= 0 || size.height <= 0) return;
    final previous = _imageSizes[index];
    if (previous == size) return;
    _imageSizes[index] = size;
    if (!widget.settings.splitWidePages || _doublePageActive) return;

    // The image handles its own layout. Refresh the reader only if the old
    // or new dimensions affect the split spread or its crop rectangles.
    bool isSplit(Size? dimensions) =>
        mangaContinuousPageSlices(
          settings: widget.settings,
          imageSize: dimensions,
          isRtl: widget.reverse,
          doublePageActive: false,
          hasCustomPageBuilder: widget.pageBuilder != null,
        ).length >
        1;
    if (isSplit(previous) || isSplit(size)) setState(() {});
  }

  Rect? _sourceRectFor(_ContinuousPagePart part) {
    if (part.slice == MangaReaderPageSlice.full) return null;
    final size = _imageSizes[part.pageIndex];
    if (size == null || size.width <= 0 || size.height <= 0) return null;
    final halfWidth = size.width / 2;
    return switch (part.slice) {
      MangaReaderPageSlice.left => Rect.fromLTWH(0, 0, halfWidth, size.height),
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
    final batches = _loadBatches;
    if (!_settledPages.contains(part.pageIndex) &&
        batches != null &&
        !batches.canLoad(part.pageIndex)) {
      return const MangaReaderPageLoadingPlaceholder();
    }
    return MangaPageImage(
      page: page,
      settings: widget.settings,
      fit: widget.scrollDirection == Axis.horizontal ? BoxFit.contain : null,
      sourceRect: _sourceRectFor(part),
      onLoadSettled: () {
        _settledPages.add(part.pageIndex);
        _loadBatches?.markSettled(part.pageIndex);
      },
      onImageSize: part.slice == MangaReaderPageSlice.full
          ? (size) => _imageSizeChanged(part.pageIndex, size)
          : null,
    );
  }

  Widget _spread(BuildContext context, _ContinuousEntry entry) {
    if (entry.isDivider) return entry.divider!;
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
    return KeepAlive(
      keepAlive: true,
      child: VisibilityDetector(
        key: ValueKey<String>(
          'manga-continuous-$primaryIndex-'
          '${entry.parts.map((part) => '${part.pageIndex}:${part.slice.name}').join('-')}',
        ),
        onVisibilityChanged: (info) => _changed(primaryIndex, info),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pages.isEmpty) return const SizedBox.shrink();
    final side =
        MediaQuery.sizeOf(context).width *
        (widget.settings.webtoonSidePadding.clamp(0, 50) / 100);
    final entries = _entries;
    final viewport = MediaQuery.sizeOf(context);
    final cacheExtent = mangaReaderPreloadCacheExtent(
      settings: widget.settings,
      viewport: viewport,
      axis: widget.scrollDirection,
    );
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
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: false,
        addSemanticIndexes: false,
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
      onDoubleTap: widget.onDoubleTap,
      child: NotificationListener<ScrollNotification>(
        onNotification: handleTrailingScrollNotification,
        child: scrollable,
      ),
    );
  }
}
