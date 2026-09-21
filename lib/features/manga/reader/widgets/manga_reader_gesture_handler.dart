// Adapted from Mangayomi's ReaderGestureHandler (Apache-2.0).
// See docs/third_party/MANGAYOMI_READER_NOTICE.md.
import 'package:flutter/material.dart';

class MangaReaderGestureHandler extends StatelessWidget {
  const MangaReaderGestureHandler({
    super.key,
    required this.usePageTapZones,
    required this.isRtl,
    required this.hasImageError,
    required this.isContinuousMode,
    required this.onToggleUi,
    required this.onPreviousPage,
    required this.onNextPage,
    this.navigationLayout = 0,
    this.tappingInversion = 0,
  });

  final bool usePageTapZones;
  final bool isRtl;
  final bool hasImageError;
  final bool isContinuousMode;
  final int navigationLayout;
  final int tappingInversion;
  final VoidCallback onToggleUi;
  final VoidCallback onPreviousPage;
  final VoidCallback onNextPage;

  bool get _invertHorizontal =>
      tappingInversion == 1 || tappingInversion == 3;
  bool get _invertVertical =>
      tappingInversion == 2 || tappingInversion == 3;

  VoidCallback _previous() => isRtl ? onNextPage : onPreviousPage;
  VoidCallback _next() => isRtl ? onPreviousPage : onNextPage;

  Widget _zone(VoidCallback action) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onTap: usePageTapZones ? action : onToggleUi,
  );

  Widget _uiZone() => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onTap: onToggleUi,
  );

  @override
  Widget build(BuildContext context) {
    if (hasImageError && !isContinuousMode) {
      final size = MediaQuery.sizeOf(context);
      final topHeight = size.height * .25;
      final bottomHeight = size.height * .35;
      final sideWidth = size.width * .20;
      final previous = _invertHorizontal ? _next() : _previous();
      final next = _invertHorizontal ? _previous() : _next();
      return Stack(
        children: <Widget>[
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topHeight,
            child: Row(
              children: <Widget>[
                SizedBox(width: sideWidth, child: _zone(previous)),
                Expanded(child: _uiZone()),
                SizedBox(width: sideWidth, child: _zone(next)),
              ],
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: bottomHeight,
            child: Row(
              children: <Widget>[
                SizedBox(width: sideWidth, child: _zone(previous)),
                Expanded(child: _uiZone()),
                SizedBox(width: sideWidth, child: _zone(next)),
              ],
            ),
          ),
          Positioned(
            top: topHeight,
            bottom: bottomHeight,
            left: 0,
            width: sideWidth,
            child: _zone(previous),
          ),
          Positioned(
            top: topHeight,
            bottom: bottomHeight,
            right: 0,
            width: sideWidth,
            child: _zone(next),
          ),
        ],
      );
    }

    return switch (navigationLayout) {
      1 => _lShaped(),
      2 => _kindle(),
      3 => _edge(),
      4 => _rightAndLeft(),
      5 => SizedBox.expand(child: _uiZone()),
      _ => _default(),
    };
  }

  Widget _default() {
    final left = _invertHorizontal ? _next() : _previous();
    final right = _invertHorizontal ? _previous() : _next();
    final top = _invertVertical ? onNextPage : onPreviousPage;
    final bottom = _invertVertical ? onPreviousPage : onNextPage;
    return Stack(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(flex: 2, child: _zone(left)),
            Expanded(flex: 2, child: _uiZone()),
            Expanded(flex: 2, child: _zone(right)),
          ],
        ),
        Column(
          children: <Widget>[
            Expanded(flex: 2, child: _zone(top)),
            const Expanded(flex: 5, child: SizedBox.shrink()),
            Expanded(flex: 2, child: _zone(bottom)),
          ],
        ),
      ],
    );
  }

  Widget _lShaped() {
    final first = (_invertHorizontal ^ _invertVertical)
        ? _next()
        : _previous();
    final second = (_invertHorizontal ^ _invertVertical)
        ? _previous()
        : _next();
    return Column(
      children: <Widget>[
        Expanded(
          child: Row(
            children: <Widget>[
              Expanded(child: _zone(first)),
              Expanded(flex: 2, child: _uiZone()),
            ],
          ),
        ),
        Expanded(flex: 2, child: _uiZone()),
        Expanded(
          child: Row(
            children: <Widget>[
              Expanded(flex: 2, child: _uiZone()),
              Expanded(child: _zone(second)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _kindle() {
    final left = _invertHorizontal ? _next() : _previous();
    final right = _invertHorizontal ? _previous() : _next();
    return Column(
      children: <Widget>[
        Expanded(child: _uiZone()),
        Expanded(
          flex: 3,
          child: Row(
            children: <Widget>[
              Expanded(child: _zone(left)),
              Expanded(child: _zone(right)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _edge() {
    final left = _invertHorizontal ? _next() : _previous();
    final right = _invertHorizontal ? _previous() : _next();
    return Row(
      children: <Widget>[
        Expanded(child: _zone(left)),
        Expanded(flex: 5, child: _uiZone()),
        Expanded(child: _zone(right)),
      ],
    );
  }

  Widget _rightAndLeft() {
    final left = _invertHorizontal ? _next() : _previous();
    final right = _invertHorizontal ? _previous() : _next();
    return Row(
      children: <Widget>[
        Expanded(child: _zone(left)),
        Expanded(child: _zone(right)),
      ],
    );
  }
}
