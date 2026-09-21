// Adapted from Mangayomi's continuous reader behavior (Apache-2.0).
import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../../core/domain/entity/manga.dart';
import '../manga_reader_settings.dart';
import 'manga_page_image.dart';
import 'manga_zoomable_page.dart';

class MangaContinuousReader extends StatefulWidget {
  const MangaContinuousReader({
    super.key,
    required this.pages,
    required this.initialPage,
    required this.scrollDirection,
    required this.reverse,
    required this.settings,
    required this.onPageChanged,
    this.controller,
    this.pageBuilder,
  });

  final List<MangaPage> pages;
  final int initialPage;
  final Axis scrollDirection;
  final bool reverse;
  final MangaReaderSettings settings;
  final ValueChanged<int> onPageChanged;
  final ScrollController? controller;
  final MangaPageBuilder? pageBuilder;

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

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _changed(int index, VisibilityInfo info) {
    _visibility[index] = info.visibleFraction;
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

  Widget _page(BuildContext context, int index) {
    final page = widget.pages[index];
    final custom = widget.pageBuilder;
    Widget child = custom?.call(context, page) ??
        MangaZoomablePage(
          settings: widget.settings,
          continuous: true,
          child: MangaPageImage(
            page: page,
            settings: widget.settings,
            fit: widget.scrollDirection == Axis.horizontal
                ? BoxFit.contain
                : null,
          ),
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
      key: ValueKey<String>('manga-continuous-$index-${page.imageUrl}'),
      onVisibilityChanged: (info) => _changed(index, info),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pages.isEmpty) return const SizedBox.shrink();
    final side = MediaQuery.sizeOf(context).width *
        (widget.settings.webtoonSidePadding.clamp(0, 50) / 100);
    return Padding(
      key: const ValueKey('manga-reader-continuous-padding'),
      padding: widget.scrollDirection == Axis.vertical
          ? EdgeInsets.symmetric(horizontal: side)
          : EdgeInsets.zero,
      child: ListView.builder(
        controller: _controller,
        scrollDirection: widget.scrollDirection,
        reverse: widget.reverse,
        itemCount: widget.pages.length,
        itemBuilder: _page,
      ),
    );
  }
}
