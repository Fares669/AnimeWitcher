import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
// [ScrollDirection] is defined in the rendering layer and is not re-exported
// by material.dart, so it must be imported explicitly.
import 'package:flutter/rendering.dart' show ScrollDirection;

/// A horizontal list whose cards snap into view whenever the user lifts
/// their finger.
///
/// Drop-in replacement for [ListView.builder] (uniform stride) and
/// [ListView.separated] (separator stride). Once a drag ends, the rail
/// computes the nearest card extent and animates the list so that card's
/// leading edge aligns with the viewport's content padding.
///
/// Pass [itemExtent] = cardWidth + trailingGap so the snap unit matches the
/// natural stride of the underlying ListView. When [separatorBuilder] is
/// provided, [itemExtent] must still equal cardWidth + sepWidth; this widget
/// does not auto-measure separators.
class PagedRail extends StatefulWidget {
  /// Width of every card including its trailing gap. Snaps to multiples of
  /// this value.
  final double itemExtent;

  /// Total item count. Standard [ListView] semantic.
  final int itemCount;

  /// Builder for each card.
  final IndexedWidgetBuilder itemBuilder;

  /// Builder for separators between cards. Pass null for a uniform list.
  final IndexedWidgetBuilder? separatorBuilder;

  /// Padding applied to the scrollable content. Snaps respect padding by
  /// clamping to [ScrollMetrics.minScrollExtent].
  final EdgeInsets padding;

  /// External controller (lets parents drive the rail from header arrows).
  final ScrollController? controller;

  /// Physics for the underlying scroll view. Defaults to
  /// [BouncingScrollPhysics] for a natural iOS/Android feel.
  final ScrollPhysics? physics;

  /// Whether the list is reversed (useful for RTL datasets).
  final bool reverse;

  /// Clipping of the underlying scroll view. Defaults to [Clip.hardEdge];
  /// pass [Clip.none] when cards paint shadows or hover effects that must
  /// bleed outside the viewport bounds.
  final Clip clipBehavior;

  /// Duration of the snap-back animation after a drag release.
  final Duration snapDuration;

  /// Curve of the snap-back animation.
  final Curve snapCurve;

  const PagedRail({
    super.key,
    required this.itemExtent,
    required this.itemCount,
    required this.itemBuilder,
    this.separatorBuilder,
    this.padding = EdgeInsets.zero,
    this.controller,
    this.physics = const BouncingScrollPhysics(),
    this.reverse = false,
    this.clipBehavior = Clip.hardEdge,
    this.snapDuration = const Duration(milliseconds: 280),
    this.snapCurve = Curves.easeOutCubic,
  });

  @override
  State<PagedRail> createState() => _PagedRailState();
}

class _PagedRailState extends State<PagedRail> {
  late ScrollController _controller;
  bool _ownsController = false;

  /// True while a programmatic snap-back animation is in flight. Without
  /// this flag, the snap-back would trigger another snap-back (because
  /// [UserScrollNotification.direction] becomes idle on completion) and
  /// we'd recurse forever.
  bool _snapping = false;
  int? _dragPointer;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? ScrollController();
  }

  @override
  void didUpdateWidget(PagedRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      if (_ownsController) _controller.dispose();
      _ownerReset(newController: widget.controller ?? ScrollController());
    }
  }

  void _ownerReset({required ScrollController newController}) {
    _controller = newController;
    _ownsController = widget.controller == null;
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _snapToNearest() {
    if (!_controller.hasClients) return;
    if (_snapping) return;
    if (widget.itemExtent <= 0) return;

    final position = _controller.position;
    final px = position.pixels;

    final stride = widget.itemExtent;
    final pageIdx = px / stride;
    final rounded = pageIdx.roundToDouble();
    final frac = pageIdx - rounded;

    final double targetIdx;
    if (frac.abs() > 0.5) {
      targetIdx = frac.isNegative ? rounded - 1 : rounded + 1;
    } else {
      targetIdx = rounded;
    }

    final rawPx = targetIdx * stride;
    final clamped = rawPx.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((clamped - px).abs() < 0.5) return;

    _snapping = true;
    _controller
        .animateTo(
          clamped,
          duration: widget.snapDuration,
          curve: widget.snapCurve,
        )
        .whenComplete(() {
          if (mounted) _snapping = false;
        });
  }

  bool _onUserScroll(UserScrollNotification notification) {
    if (notification.direction == ScrollDirection.idle) {
      // Defer to post-frame so position is settled by the time we read it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _snapToNearest();
      });
    }
    return false;
  }

  // Dragging the rail sideways with the mouse held down. The listener is
  // raw rather than a recognizer in the gesture arena, which is what lets a
  // card underneath still take a plain click: a tap is dropped as soon as the
  // pointer travels further than a mouse's hair-thin slop, so a drag scrolls
  // and a click opens.
  void _onPointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons & kPrimaryMouseButton == 0) {
      return;
    }
    _dragPointer = event.pointer;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_dragPointer != event.pointer ||
        event.buttons & kPrimaryMouseButton == 0 ||
        !_controller.hasClients) {
      return;
    }

    final position = _controller.position;
    final delta = position.axisDirection == AxisDirection.right
        ? -event.delta.dx
        : event.delta.dx;
    final target = (_controller.offset + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - _controller.offset).abs() >= 0.1) {
      _controller.jumpTo(target);
    }
  }

  void _finishMouseDrag(PointerEvent event) {
    if (_dragPointer != event.pointer) return;
    _dragPointer = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _snapToNearest();
    });
  }

  /// Cards this far past either edge are built, so their posters are on
  /// their way before the rail is scrolled to them.
  static const double _aheadExtent = 1200;

  @override
  Widget build(BuildContext context) {
    final Widget listView = widget.separatorBuilder != null
        ? ListView.separated(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            itemCount: widget.itemCount,
            separatorBuilder: widget.separatorBuilder!,
            padding: widget.padding,
            physics: widget.physics,
            reverse: widget.reverse,
            clipBehavior: widget.clipBehavior,
            cacheExtent: _aheadExtent,
            itemBuilder: widget.itemBuilder,
          )
        : ListView.builder(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            itemCount: widget.itemCount,
            itemExtent: widget.itemExtent,
            padding: widget.padding,
            physics: widget.physics,
            reverse: widget.reverse,
            clipBehavior: widget.clipBehavior,
            cacheExtent: _aheadExtent,
            itemBuilder: widget.itemBuilder,
          );

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _finishMouseDrag,
      onPointerCancel: _finishMouseDrag,
      child: NotificationListener<UserScrollNotification>(
        onNotification: _onUserScroll,
        child: listView,
      ),
    );
  }
}
