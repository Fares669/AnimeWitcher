import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/domain/entity/manga.dart';
import '../manga_reader_settings.dart';
import 'manga_page_image.dart';
import 'manga_reader_load_scheduler.dart';
import 'manga_reader_page_loading.dart';
import 'manga_reader_trailing_advance.dart';
import 'manga_reader_visible_pages.dart';
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

class _MangaWebtoonReaderState extends State<MangaWebtoonReader>
    with MangaReaderTrailingAdvance<MangaWebtoonReader> {
  final GlobalKey _centerKey = GlobalKey();
  final _visiblePages = MangaReaderVisiblePages();
  bool _visibilityUpdateScheduled = false;
  late int _lastReported;
  late final int _sessionInitialPage;
  final Set<int> _settledPages = <int>{};
  late final ScrollController _controller =
      widget.controller ?? ScrollController();
  late final bool _ownsController = widget.controller == null;
  MangaReaderLoadBatchController? _loadBatches;
  MangaReaderLoadBatchController? _deferredLoadBatchUpdate;
  bool _replayingSettledLoads = false;

  @override
  ScrollController get trailingScrollController => _controller;

  @override
  bool get hasTrailingChapterPage => widget.trailingPage != null;

  @override
  VoidCallback? get trailingAdvanceCallback => widget.onTrailingAdvance;

  /// Double-page spreads must honor the first page and chapter boundaries.
  List<_WebtoonItem> get _doublePageItems {
    final items = <_WebtoonItem>[];
    for (final spread in mangaReaderPageSpreads(
      pageCount: widget.pages.length,
      singleFirst: widget.settings.doublePageSingleFirstPage,
      sectionStarts: widget.sectionDividers.keys,
    )) {
      final divider = widget.sectionDividers[spread.first];
      if (divider != null) items.add(_WebtoonItem.dividerItem(divider));
      items.add(_WebtoonItem.spread(spread));
    }
    return items;
  }

  /// Only chapter dividers need entries in single-page mode. Each seam's
  /// row is its page index plus the number of earlier dividers.
  List<int> _singlePageDividerRows(Map<int, Widget> dividers) {
    if (dividers.isEmpty) return const <int>[];
    final rows =
        dividers.keys
            .where((page) => page >= 0 && page < widget.pages.length)
            .toList()
          ..sort();
    for (var index = 0; index < rows.length; index++) {
      rows[index] += index;
    }
    return rows;
  }

  int _singlePageStartRow(List<int> dividerRows) {
    var row = _startPage;
    for (final divider in dividerRows) {
      if (divider > row) break;
      row++;
    }
    return row;
  }

  // Find how many dividers precede the row, which is its displacement
  // from the original page index.
  int _dividersBeforeRow(List<int> dividerRows, int row) {
    var lo = 0;
    var hi = dividerRows.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (dividerRows[mid] < row) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
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
    checkTrailingProximitySoon();
  }

  void _resetLoadBatches() {
    _deferredLoadBatchUpdate = null;
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
    _replayingSettledLoads = true;
    try {
      for (final pageIndex in settled) {
        _loadBatches?.markSettled(pageIndex);
      }
    } finally {
      _replayingSettledLoads = false;
    }
  }

  void _onLoadBatchChanged() {
    if (!mounted) return;
    // A reset already has a build pending. Keep checking the tail as
    // settled pages are replayed, without scheduling another rebuild.
    if (_replayingSettledLoads) {
      checkTrailingProximitySoon();
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      setState(() {});
      checkTrailingProximitySoon();
      return;
    }

    // A cached image can settle synchronously while a sliver child is
    // being laid out. Keep its admission immediate, but invalidate this
    // ancestor once after the frame, while the same scheduler is active.
    final batches = _loadBatches;
    if (batches == null || identical(_deferredLoadBatchUpdate, batches)) {
      return;
    }
    _deferredLoadBatchUpdate = batches;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(_deferredLoadBatchUpdate, batches)) return;
      _deferredLoadBatchUpdate = null;
      if (!mounted || !identical(_loadBatches, batches)) return;
      setState(() {});
      if (_controller.hasClients) {
        checkTrailingProximity(_controller.position);
      }
    });
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
    _deferredLoadBatchUpdate = null;
    _loadBatches?.removeListener(_onLoadBatchChanged);
    _loadBatches?.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _visibilityChanged(int pageIndex, VisibilityInfo info) {
    _visiblePages.record(pageIndex, info.visibleFraction);
    if (_visibilityUpdateScheduled) return;
    _visibilityUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityUpdateScheduled = false;
      if (!mounted || _visiblePages.isEmpty) return;
      _visiblePages.advanceRound();
      final bestIndex = _visiblePages.mostVisiblePage;
      if (bestIndex == null || bestIndex == _lastReported) return;
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

  @override
  Widget build(BuildContext context) {
    if (widget.pages.isEmpty) return const SizedBox.shrink();

    // A single-page stream stays lazy after another chapter joins it:
    // a seam adds one row, not a descriptor for every page in the stream.
    final items = widget.doublePage ? _doublePageItems : null;
    final dividers = widget.sectionDividers;
    final dividerRows = items == null
        ? _singlePageDividerRows(dividers)
        : const <int>[];
    final start = items == null
        ? _singlePageStartRow(dividerRows)
        : _startItemIndex(items);
    final itemCount = items?.length ?? widget.pages.length + dividerRows.length;

    Widget buildRow(BuildContext context, int index) {
      if (items != null) return _item(context, items[index]);
      final offset = _dividersBeforeRow(dividerRows, index);
      final page = index - offset;
      if (offset < dividerRows.length && dividerRows[offset] == index) {
        return dividers[page]!;
      }
      return _spread(context, <int>[page]);
    }

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
                buildRow,
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
                return buildRow(context, index);
              },
              childCount: itemCount - start,
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
        onNotification: handleTrailingScrollNotification,
        child: scrollable,
      ),
    );
  }
}
