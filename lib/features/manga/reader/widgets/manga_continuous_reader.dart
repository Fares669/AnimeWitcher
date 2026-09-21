// Adapted from Mangayomi's continuous reader behavior (Apache-2.0).
import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/domain/entity/manga.dart';
import '../manga_reader_settings.dart';
import 'manga_page_image.dart';
import 'manga_continuous_zoom_surface.dart';

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

  @override
  State<MangaContinuousReader> createState() => _MangaContinuousReaderState();
}

class _MangaContinuousReaderState extends State<MangaContinuousReader> {
  late final ScrollController _controller =
      widget.controller ?? ScrollController();
  late final bool _ownsController = widget.controller == null;
  final Map<int, double> _visibility = <int, double>{};
  late int _lastReported = widget.pages.isEmpty
      ? 0
      : widget.initialPage.clamp(0, widget.pages.length - 1).toInt();
  bool _scheduled = false;

  bool get _doublePageActive =>
      widget.doublePage && widget.scrollDirection == Axis.vertical;

  List<List<int>> get _spreads => _doublePageActive
      ? mangaReaderPageSpreads(
          pageCount: widget.pages.length,
          singleFirst: widget.settings.doublePageSingleFirstPage,
        )
      : <List<int>>[
          for (var index = 0; index < widget.pages.length; index++)
            <int>[index],
        ];

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

  Widget _pageContent(BuildContext context, int index) {
    final page = widget.pages[index];
    return widget.pageBuilder?.call(context, page) ??
        MangaPageImage(
          page: page,
          settings: widget.settings,
          fit: widget.scrollDirection == Axis.horizontal
              ? BoxFit.contain
              : null,
        );
  }

  Widget _spread(BuildContext context, List<int> indices) {
    final primaryIndex = indices.first;
    Widget child = indices.length == 1
        ? _pageContent(context, primaryIndex)
        : Row(
            key: const ValueKey<String>('manga-reader-continuous-double-page'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final index in indices)
                Expanded(child: _pageContent(context, index)),
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
        'manga-continuous-$primaryIndex-${indices.join('-')}',
      ),
      onVisibilityChanged: (info) => _changed(primaryIndex, info),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pages.isEmpty) return const SizedBox.shrink();
    final side = MediaQuery.sizeOf(context).width *
        (widget.settings.webtoonSidePadding.clamp(0, 50) / 100);
    final spreads = _spreads;
    final scrollable = Padding(
      key: const ValueKey('manga-reader-continuous-padding'),
      padding: widget.scrollDirection == Axis.vertical
          ? EdgeInsets.symmetric(horizontal: side)
          : EdgeInsets.zero,
      child: ListView.builder(
        controller: _controller,
        scrollDirection: widget.scrollDirection,
        reverse: widget.reverse,
        itemCount: spreads.length + (widget.trailingPage == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (index >= spreads.length) return widget.trailingPage!;
          return _spread(context, spreads[index]);
        },
      ),
    );
    return MangaContinuousZoomSurface(
      scrollController: _controller,
      scrollDirection: widget.scrollDirection,
      settings: widget.settings,
      child: scrollable,
    );
  }
}
