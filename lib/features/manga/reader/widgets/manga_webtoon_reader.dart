import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/domain/entity/manga.dart';
import '../manga_reader_settings.dart';
import 'manga_chapter_transition_page.dart';
import 'manga_page_image.dart';
import 'manga_reader_load_scheduler.dart';
import 'manga_reader_page_loading.dart';
import 'manga_continuous_zoom_surface.dart';

/// One row of the webtoon stream: a page spread, or a between-chapters
/// divider at a seam of a connected chapter stream.
class _WebtoonItem {
  const _WebtoonItem.spread(this.indices) : divider = null;
  const _WebtoonItem.dividerItem(this.divider) : indices = null;

  final List<int>? indices;
  final Widget? divider;

  bool get isDivider => divider != null;
}

class MangaWebtoonReader extends StatefulWidget {
  const MangaWebtoonReader({
    super.key,
    required this.pages,
    required this.initialPage,
    required this.onPageChanged,
    this.pageBuilder,
    this.settings = const MangaReaderSettings(),
    this.doublePage = false,
    this.controller,
    this.trailingPage,
    this.onTrailingAdvance,
    this.onDoubleTap,
    this.sectionDividers = const <int, Widget>{},
  });

  final List<MangaPage> pages;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final MangaPageBuilder? pageBuilder;
  final MangaReaderSettings settings;
  final bool doublePage;
  final ScrollController? controller;
  final Widget? trailingPage;
  final VoidCallback? onTrailingAdvance;
  final VoidCallback? onDoubleTap;

  /// Dividers inserted into the stream, keyed by the page index they
  /// precede — the seams of a connected chapter stream.
  final Map<int, Widget> sectionDividers;

  @override
  State<MangaWebtoonReader> createState() => _MangaWebtoonReaderState();
}

class _MangaWebtoonReaderState extends State<MangaWebtoonReader> {
  final GlobalKey _centerKey = GlobalKey();
  final Map<int, double> _visibleFractions = <int, double>{};
  bool _visibilityUpdateScheduled = false;
  late int _lastReported;
  late final int _sessionInitialPage;
  final Set<int> _settledPages = <int>{};
  late final ScrollController _controller =
      widget.controller ?? ScrollController();
  late final bool _ownsController = widget.controller == null;
  bool _trailingAdvanceRequested = false;
  MangaReaderLoadBatchController? _loadBatches;

  List<List<int>> get _spreads => widget.doublePage
      ? mangaReaderPageSpreads(
          pageCount: widget.pages.length,
          singleFirst: widget.settings.doublePageSingleFirstPage,
        )
      : <List<int>>[
          for (var index = 0; index < widget.pages.length; index++)
            <int>[index],
        ];

  /// Spreads with the section dividers woven in, in stream order.
  List<_WebtoonItem> get _items {
    final items = <_WebtoonItem>[];
    for (final spread in _spreads) {
      final divider = widget.sectionDividers[spread.first];
      if (divider != null) items.add(_WebtoonItem.dividerItem(divider));
      items.add(_WebtoonItem.spread(spread));
    }
    return items;
  }

  /// The item the session starts on: the spread holding the start page.
  int _startItemIndex(List<_WebtoonItem> items) {
    final page = _startPage;
    for (var index = 0; index < items.length; index++) {
      final indices = items[index].indices;
      if (indices != null && indices.contains(page)) return index;
    }
    return 0;
  }

  int get _startPage => widget.pages.isEmpty
      ? 0
      : _sessionInitialPage.clamp(0, widget.pages.length - 1).toInt();

  @override
  void initState() {
    super.initState();
    _sessionInitialPage = widget.pages.isEmpty
        ? 0
        : widget.initialPage.clamp(0, widget.pages.length - 1).toInt();
    _lastReported = _startPage;
    _resetLoadBatches();
    _checkTrailingProximitySoon();
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
    _checkTrailingProximitySoon();
  }

  @override
  void didUpdateWidget(covariant MangaWebtoonReader oldWidget) {
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

  void _visibilityChanged(int pageIndex, VisibilityInfo info) {
    _visibleFractions[pageIndex] = info.visibleFraction;
    if (_visibilityUpdateScheduled) return;
    _visibilityUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityUpdateScheduled = false;
      if (!mounted || _visibleFractions.isEmpty) return;
      var bestIndex = _lastReported;
      var bestFraction = -1.0;
      for (final entry in _visibleFractions.entries) {
        if (entry.value > bestFraction) {
          bestFraction = entry.value;
          bestIndex = entry.key;
        }
      }
      if (bestFraction <= 0 || bestIndex == _lastReported) return;
      _lastReported = bestIndex;
      widget.onPageChanged(bestIndex);
    });
  }

  Widget _pageContent(BuildContext context, int index) {
    final page = widget.pages[index];
    final custom = widget.pageBuilder;
    if (custom != null) return custom(context, page);
    final batches = _loadBatches;
    if (!_settledPages.contains(index) &&
        batches != null &&
        !batches.canLoad(index)) {
      return const MangaReaderPageLoadingPlaceholder();
    }
    return MangaPageImage(
      page: page,
      settings: widget.settings,
      onLoadSettled: () {
        _settledPages.add(index);
        _loadBatches?.markSettled(index);
      },
    );
  }

  Widget _spread(BuildContext context, List<int> indices) {
    final primaryIndex = indices.first;
    Widget child = indices.length == 1
        ? _pageContent(context, primaryIndex)
        : Row(
            key: const ValueKey<String>('manga-reader-webtoon-double-page'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final index in indices)
                Expanded(child: _pageContent(context, index)),
            ],
          );
    if (widget.settings.showPageGaps) {
      child = Padding(
        key: const ValueKey('manga-reader-page-gap'),
        padding: const EdgeInsets.only(bottom: 8),
        child: child,
      );
    }
    return KeepAlive(
      keepAlive: true,
      child: VisibilityDetector(
        key: ValueKey<String>(
          'manga-webtoon-$primaryIndex-${indices.join('-')}',
        ),
        onVisibilityChanged: (info) => _visibilityChanged(primaryIndex, info),
        child: child,
      ),
    );
  }

  Widget _item(BuildContext context, _WebtoonItem item) {
    if (item.isDivider) return item.divider!;
    return _spread(context, item.indices!);
  }

  void _requestTrailingAdvance() {
    final callback = widget.onTrailingAdvance;
    if (_trailingAdvanceRequested ||
        widget.trailingPage == null ||
        callback == null) {
      return;
    }
    _trailingAdvanceRequested = true;
    callback();
  }

  bool _handleOverscroll(OverscrollNotification notification) {
    if (!mangaReaderShouldAdvancePastTransition(
      extentAfter: notification.metrics.extentAfter,
      overscroll: notification.overscroll,
    )) {
      return false;
    }
    _requestTrailingAdvance();
    return true;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is OverscrollNotification) {
      return _handleOverscroll(notification);
    }
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      _checkTrailingProximity(notification.metrics);
    }
    return false;
  }

  /// The trailing divider is the end of the chapter: once less than a
  /// quarter of the viewport is left below the fold, the reader moves on
  /// by itself — no tap, no extra fling, and no dependence on a visibility
  /// report for the divider. Scrolling clearly away from the end re-arms
  /// the advance, so one that was dropped (a chapter navigation already
  /// in flight, a chapter list not ready yet) is retried on the next
  /// approach instead of never.
  void _checkTrailingProximity(ScrollMetrics metrics) {
    if (widget.trailingPage == null || widget.onTrailingAdvance == null) {
      return;
    }
    final threshold = metrics.viewportDimension * 0.25;
    if (metrics.extentAfter <= threshold) {
      _requestTrailingAdvance();
    } else if (metrics.extentAfter > threshold * 2) {
      _trailingAdvanceRequested = false;
    }
  }

  void _checkTrailingProximitySoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      _checkTrailingProximity(_controller.position);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pages.isEmpty) return const SizedBox.shrink();

    final items = _items;
    final start = _startItemIndex(items);
    final viewport = MediaQuery.sizeOf(context);
    final cacheExtent = mangaReaderPreloadCacheExtent(
      settings: widget.settings,
      viewport: viewport,
      axis: Axis.vertical,
    );
    final side =
        viewport.width *
        (widget.settings.webtoonSidePadding.clamp(0, 50) / 100);
    final scrollable = Padding(
      key: const ValueKey('manga-reader-webtoon-padding'),
      padding: EdgeInsets.symmetric(horizontal: side),
      child: CustomScrollView(
        controller: _controller,
        scrollCacheExtent: ScrollCacheExtent.pixels(cacheExtent),
        center: _centerKey,
        slivers: <Widget>[
          if (start > 0)
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _item(context, items[index]),
                childCount: start,
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: false,
                addSemanticIndexes: false,
              ),
            ),
          SliverList(
            key: _centerKey,
            delegate: SliverChildBuilderDelegate(
              (context, localIndex) {
                final index = start + localIndex;
                return _item(context, items[index]);
              },
              childCount: items.length - start,
              addAutomaticKeepAlives: false,
              addRepaintBoundaries: false,
              addSemanticIndexes: false,
            ),
          ),
          if (widget.trailingPage != null)
            SliverToBoxAdapter(child: widget.trailingPage),
        ],
      ),
    );
    return MangaContinuousZoomSurface(
      scrollController: _controller,
      scrollDirection: Axis.vertical,
      settings: widget.settings,
      onDoubleTap: widget.onDoubleTap,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: scrollable,
      ),
    );
  }
}
