import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/domain/entity/manga.dart';
import 'manga_page_image.dart';

class MangaWebtoonReader extends StatefulWidget {
  const MangaWebtoonReader({
    super.key,
    required this.pages,
    required this.initialPage,
    required this.onPageChanged,
    this.pageBuilder,
  });

  final List<MangaPage> pages;
  final int initialPage;
  final ValueChanged<int> onPageChanged;
  final MangaPageBuilder? pageBuilder;

  @override
  State<MangaWebtoonReader> createState() => _MangaWebtoonReaderState();
}

class _MangaWebtoonReaderState extends State<MangaWebtoonReader> {
  final GlobalKey _centerKey = GlobalKey();
  final Map<int, double> _visibleFractions = <int, double>{};
  bool _visibilityUpdateScheduled = false;
  late int _lastReported;

  int get _start => widget.pages.isEmpty
      ? 0
      : widget.initialPage.clamp(0, widget.pages.length - 1).toInt();

  @override
  void initState() {
    super.initState();
    _lastReported = _start;
  }

  void _visibilityChanged(int index, VisibilityInfo info) {
    _visibleFractions[index] = info.visibleFraction;
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

  Widget _page(BuildContext context, int index) {
    final page = widget.pages[index];
    final custom = widget.pageBuilder;
    return VisibilityDetector(
      key: ValueKey<String>(
        'manga-webtoon-' + index.toString() + '-' + page.imageUrl,
      ),
      onVisibilityChanged: (info) => _visibilityChanged(index, info),
      child: custom?.call(context, page) ?? MangaPageImage(page: page),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pages.isEmpty) return const SizedBox.shrink();

    final start = _start;
    return CustomScrollView(
      center: _centerKey,
      slivers: <Widget>[
        if (start > 0)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _page(context, index),
              childCount: start,
            ),
          ),
        SliverList(
          key: _centerKey,
          delegate: SliverChildBuilderDelegate(
            (context, localIndex) {
              final index = start + localIndex;
              return _page(context, index);
            },
            childCount: widget.pages.length - start,
          ),
        ),
      ],
    );
  }
}
