import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/domain/entity/manga.dart';
import '../manga_reader_settings.dart';
import 'manga_page_image.dart';
import 'manga_continuous_zoom_surface.dart';

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
  });

  final List<MangaPage> pages;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final MangaPageBuilder? pageBuilder;
  final MangaReaderSettings settings;
  final bool doublePage;
  final ScrollController? controller;
  final Widget? trailingPage;

  @override
  State<MangaWebtoonReader> createState() => _MangaWebtoonReaderState();
}

class _MangaWebtoonReaderState extends State<MangaWebtoonReader> {
  final GlobalKey _centerKey = GlobalKey();
  final Map<int, double> _visibleFractions = <int, double>{};
  bool _visibilityUpdateScheduled = false;
  late int _lastReported;
  late final ScrollController _controller =
      widget.controller ?? ScrollController();
  late final bool _ownsController = widget.controller == null;

  List<List<int>> get _spreads => widget.doublePage
      ? mangaReaderPageSpreads(
          pageCount: widget.pages.length,
          singleFirst: widget.settings.doublePageSingleFirstPage,
        )
      : <List<int>>[
          for (var index = 0; index < widget.pages.length; index++)
            <int>[index],
        ];

  int get _startPage => widget.pages.isEmpty
      ? 0
      : widget.initialPage.clamp(0, widget.pages.length - 1).toInt();

  int get _startSpread {
    final page = _startPage;
    final spreads = _spreads;
    for (var index = 0; index < spreads.length; index++) {
      if (spreads[index].contains(page)) return index;
    }
    return 0;
  }

  @override
  void initState() {
    super.initState();
    _lastReported = _startPage;
  }

  @override
  void dispose() {
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
    return widget.pageBuilder?.call(context, page) ??
        MangaPageImage(page: page, settings: widget.settings);
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
    return VisibilityDetector(
      key: ValueKey<String>(
        'manga-webtoon-$primaryIndex-${indices.join('-')}',
      ),
      onVisibilityChanged: (info) => _visibilityChanged(primaryIndex, info),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pages.isEmpty) return const SizedBox.shrink();

    final spreads = _spreads;
    final start = _startSpread;
    final side = MediaQuery.sizeOf(context).width *
        (widget.settings.webtoonSidePadding.clamp(0, 50) / 100);
    final scrollable = Padding(
      key: const ValueKey('manga-reader-webtoon-padding'),
      padding: EdgeInsets.symmetric(horizontal: side),
      child: CustomScrollView(
        controller: _controller,
        center: _centerKey,
        slivers: <Widget>[
          if (start > 0)
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _spread(context, spreads[index]),
                childCount: start,
              ),
            ),
          SliverList(
            key: _centerKey,
            delegate: SliverChildBuilderDelegate(
              (context, localIndex) {
                final index = start + localIndex;
                return _spread(context, spreads[index]);
              },
              childCount: spreads.length - start,
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
      child: scrollable,
    );
  }
}
