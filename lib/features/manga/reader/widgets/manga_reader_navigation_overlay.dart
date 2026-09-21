// Adapted from Mangayomi's ReaderNavigationOverlay (Apache-2.0).
// See docs/third_party/MANGAYOMI_READER_NOTICE.md.
import 'package:flutter/material.dart';

class MangaReaderNavigationOverlay extends StatelessWidget {
  const MangaReaderNavigationOverlay({
    super.key,
    required this.navigationLayout,
    required this.tappingInversion,
    required this.isRtl,
    required this.onClose,
  });

  final int navigationLayout;
  final int tappingInversion;
  final bool isRtl;
  final VoidCallback onClose;

  bool get _invertHorizontal => tappingInversion == 1 || tappingInversion == 3;
  bool get _invertVertical => tappingInversion == 2 || tappingInversion == 3;

  static const _menuColor = Color(0xCC95818D);
  static const _prevColor = Color(0xCCFF7733);
  static const _nextColor = Color(0xCC84E296);

  Widget _zone(Color color, String text) => Container(
    decoration: BoxDecoration(
      color: color,
      border: Border.all(color: Colors.black26, width: 0.5),
    ),
    child: Center(
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 20,
          shadows: <Shadow>[
            Shadow(blurRadius: 4, color: Colors.black54, offset: Offset(1, 1)),
          ],
        ),
      ),
    ),
  );

  (Color, String) get _horizontalLeft =>
      isRtl ? (_nextColor, 'NEXT') : (_prevColor, 'PREV');
  (Color, String) get _horizontalRight =>
      isRtl ? (_prevColor, 'PREV') : (_nextColor, 'NEXT');
  (Color, String) get _left =>
      _invertHorizontal ? _horizontalRight : _horizontalLeft;
  (Color, String) get _right =>
      _invertHorizontal ? _horizontalLeft : _horizontalRight;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onTap: onClose,
    child: switch (navigationLayout) {
      1 => _lShaped(),
      2 => _kindle(),
      3 => _edge(),
      4 => _rightAndLeft(),
      5 => SizedBox.expand(child: _zone(_menuColor, 'MENU')),
      _ => _default(),
    },
  );

  Widget _default() {
    final top = _invertVertical
        ? (_nextColor, 'NEXT')
        : (_prevColor, 'PREV');
    final bottom = _invertVertical
        ? (_prevColor, 'PREV')
        : (_nextColor, 'NEXT');
    return Stack(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(flex: 2, child: _zone(_left.$1, _left.$2)),
            Expanded(flex: 2, child: _zone(_menuColor, 'MENU')),
            Expanded(flex: 2, child: _zone(_right.$1, _right.$2)),
          ],
        ),
        Column(
          children: <Widget>[
            Expanded(flex: 2, child: _zone(top.$1, top.$2)),
            const Expanded(flex: 5, child: SizedBox.shrink()),
            Expanded(flex: 2, child: _zone(bottom.$1, bottom.$2)),
          ],
        ),
      ],
    );
  }

  Widget _lShaped() {
    final invert = _invertHorizontal ^ _invertVertical;
    final left = invert ? (_nextColor, 'NEXT') : (_prevColor, 'PREV');
    final right = invert ? (_prevColor, 'PREV') : (_nextColor, 'NEXT');
    return Column(
      children: <Widget>[
        Expanded(
          child: Row(
            children: <Widget>[
              Expanded(child: _zone(left.$1, left.$2)),
              Expanded(flex: 2, child: _zone(_menuColor, 'MENU')),
            ],
          ),
        ),
        Expanded(flex: 2, child: _zone(_menuColor, 'MENU')),
        Expanded(
          child: Row(
            children: <Widget>[
              Expanded(flex: 2, child: _zone(_menuColor, 'MENU')),
              Expanded(child: _zone(right.$1, right.$2)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _kindle() => Column(
    children: <Widget>[
      Expanded(child: _zone(_menuColor, 'MENU')),
      Expanded(
        flex: 3,
        child: Row(
          children: <Widget>[
            Expanded(child: _zone(_left.$1, _left.$2)),
            Expanded(child: _zone(_right.$1, _right.$2)),
          ],
        ),
      ),
    ],
  );

  Widget _edge() => Row(
    children: <Widget>[
      Expanded(child: _zone(_left.$1, _left.$2)),
      Expanded(flex: 5, child: _zone(_menuColor, 'MENU')),
      Expanded(child: _zone(_right.$1, _right.$2)),
    ],
  );

  Widget _rightAndLeft() => Row(
    children: <Widget>[
      Expanded(child: _zone(_left.$1, _left.$2)),
      Expanded(child: _zone(_right.$1, _right.$2)),
    ],
  );
}
