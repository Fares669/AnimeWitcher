import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

const mouseDragRefreshListenerKey = ValueKey<String>(
  'mouse-drag-refresh-listener',
);

/// A [RefreshIndicator] that a mouse can also pull.
///
/// A phone refreshes by dragging the list down past its top, which a mouse
/// wheel cannot express — a wheel at the top of a list simply does nothing.
/// So the same gesture is offered to the pointer: press and hold at the top
/// of the list and drag downward.
///
/// The listener is raw rather than a recognizer in the gesture arena, so
/// whatever lies under the pointer keeps its own click. A tap is dropped as
/// soon as the pointer travels further than a mouse's hair-thin slop, well
/// before the pull is long enough to count.
class MouseDragRefreshIndicator extends StatefulWidget {
  const MouseDragRefreshIndicator({
    super.key,
    this.indicatorKey,
    required this.onRefresh,
    required this.child,
  });

  final RefreshCallback onRefresh;
  final GlobalKey<RefreshIndicatorState>? indicatorKey;
  final Widget child;

  @override
  State<MouseDragRefreshIndicator> createState() =>
      _MouseDragRefreshIndicatorState();
}

class _MouseDragRefreshIndicatorState extends State<MouseDragRefreshIndicator> {
  static const double _triggerDistance = 72;

  final GlobalKey<RefreshIndicatorState> _indicatorKey =
      GlobalKey<RefreshIndicatorState>();
  int? _dragPointer;
  Offset? _dragStart;
  bool _isAtTop = true;
  bool _isRefreshing = false;

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
      _isAtTop = notification.metrics.extentBefore <= 0.5;
    }
    return false;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons & kPrimaryMouseButton == 0 ||
        !_isAtTop ||
        _isRefreshing) {
      return;
    }
    _dragPointer = event.pointer;
    _dragStart = event.position;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_dragPointer != event.pointer || _dragStart == null) return;
    if (event.buttons & kPrimaryMouseButton == 0) {
      _resetGesture(event.pointer);
      return;
    }

    final delta = event.position - _dragStart!;
    if (delta.dy >= _triggerDistance && delta.dy > delta.dx.abs()) {
      _dragPointer = null;
      _dragStart = null;
      _showRefreshIndicator();
    }
  }

  void _showRefreshIndicator() {
    if (_isRefreshing) return;
    final refresh = (widget.indicatorKey ?? _indicatorKey).currentState?.show(
      atTop: true,
    );
    if (refresh == null) return;
    _isRefreshing = true;
    refresh.whenComplete(() {
      if (mounted) _isRefreshing = false;
    });
  }

  void _resetGesture(int pointer) {
    if (_dragPointer != pointer) return;
    _dragPointer = null;
    _dragStart = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      key: mouseDragRefreshListenerKey,
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (event) => _resetGesture(event.pointer),
      onPointerCancel: (event) => _resetGesture(event.pointer),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: RefreshIndicator(
          key: widget.indicatorKey ?? _indicatorKey,
          onRefresh: widget.onRefresh,
          child: widget.child,
        ),
      ),
    );
  }
}
