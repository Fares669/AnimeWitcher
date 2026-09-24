// Adapted from Mangayomi's continuous/webtoon zoom surface (Apache-2.0).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../manga_reader_settings.dart';

/// Rejects one-finger scale/pan gestures while the continuous reader is
/// unzoomed so its Scrollable keeps native drag ownership.
class MangaContinuousScaleGestureRecognizer extends ScaleGestureRecognizer {
  MangaContinuousScaleGestureRecognizer({
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter,
    this.canPanCallback,
  });

  bool Function()? canPanCallback;

  @visibleForTesting
  GestureDisposition resolveDisposition(GestureDisposition disposition) {
    if (disposition == GestureDisposition.accepted) {
      final canPan = canPanCallback?.call() ?? false;
      if (!canPan && pointerCount < 2) {
        return GestureDisposition.rejected;
      }
    }
    return disposition;
  }

  @override
  void resolve(GestureDisposition disposition) {
    super.resolve(resolveDisposition(disposition));
  }
}

class MangaContinuousZoomSurface extends StatefulWidget {
  const MangaContinuousZoomSurface({
    super.key,
    required this.child,
    required this.scrollController,
    required this.scrollDirection,
    required this.settings,
    this.onDoubleTap,
  });

  final Widget child;
  final ScrollController scrollController;
  final Axis scrollDirection;
  final MangaReaderSettings settings;
  final VoidCallback? onDoubleTap;

  @override
  State<MangaContinuousZoomSurface> createState() =>
      _MangaContinuousZoomSurfaceState();
}

class _MangaContinuousZoomSurfaceState
    extends State<MangaContinuousZoomSurface>
    with TickerProviderStateMixin {
  double _scale = 1;
  double _baseScale = 1;
  Offset _offset = Offset.zero;
  Offset _baseOffset = Offset.zero;
  Offset _pinchStartFocalPoint = Offset.zero;
  int _previousPointerCount = 0;

  bool _isQuickScaling = false;
  double _quickScaleLastY = 0;
  double _quickScaleLastDistance = -1;
  Offset? _quickScaleCenter;
  Offset _doubleTapPosition = Offset.zero;

  late final ValueNotifier<Matrix4> _transformNotifier;
  late final AnimationController _zoomAnimationController;

  double _animStartScale = 1;
  double _animTargetScale = 1;
  Offset _animStartOffset = Offset.zero;
  Offset _animTargetOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _transformNotifier = ValueNotifier<Matrix4>(Matrix4.identity());
    _zoomAnimationController = AnimationController(
      vsync: this,
      duration: mangaReaderDoubleTapAnimationDuration(
        widget.settings.doubleTapAnimationSpeed,
      ),
    )..addListener(_onAnimationTick);
  }

  @override
  void didUpdateWidget(covariant MangaContinuousZoomSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.doubleTapAnimationSpeed !=
        widget.settings.doubleTapAnimationSpeed) {
      _zoomAnimationController.duration = mangaReaderDoubleTapAnimationDuration(
        widget.settings.doubleTapAnimationSpeed,
      );
    }
  }

  @override
  void dispose() {
    _zoomAnimationController
      ..removeListener(_onAnimationTick)
      ..dispose();
    _transformNotifier.dispose();
    super.dispose();
  }

  void _onAnimationTick() {
    final curve = Curves.easeOutCubic.transform(
      _zoomAnimationController.value,
    );
    _scale = _animStartScale + (_animTargetScale - _animStartScale) * curve;
    _offset =
        Offset.lerp(_animStartOffset, _animTargetOffset, curve) ?? _offset;
    _updateMatrix();
  }

  void _updateMatrix() {
    _transformNotifier.value = Matrix4.diagonal3Values(_scale, _scale, 1)
      ..setTranslationRaw(_offset.dx, _offset.dy, 0);
  }

  void _animateTo(
    double targetScale,
    Offset targetOffset, {
    Duration? duration,
  }) {
    if (_zoomAnimationController.isAnimating) {
      _zoomAnimationController.stop();
    }
    _animStartScale = _scale;
    _animTargetScale = targetScale;
    _animStartOffset = _offset;
    _animTargetOffset = targetOffset;
    _zoomAnimationController.duration =
        duration ??
        mangaReaderDoubleTapAnimationDuration(
          widget.settings.doubleTapAnimationSpeed,
        );
    _zoomAnimationController.forward(from: 0);
  }

  void _animateZoomToFocalPoint(double targetScale, Offset focalPoint) {
    final size = MediaQuery.sizeOf(context);
    final focalX = focalPoint.dx - size.width / 2;
    final focalY = focalPoint.dy - size.height / 2;

    double targetDx;
    double targetDy;
    if (targetScale <= 1) {
      targetDx = 0;
      targetDy = 0;
    } else {
      targetDx = focalX - (focalX - _offset.dx) * (targetScale / _scale);
      targetDy = focalY - (focalY - _offset.dy) * (targetScale / _scale);
      final maxDx = (size.width * (targetScale - 1)) / 2;
      final maxDy = (size.height * (targetScale - 1)) / 2;
      targetDx = targetDx.clamp(-maxDx, maxDx).toDouble();
      targetDy = targetDy.clamp(-maxDy, maxDy).toDouble();
    }
    _animateTo(targetScale, Offset(targetDx, targetDy));
  }

  void _handleScaleStart(ScaleStartDetails details) {
    if (_zoomAnimationController.isAnimating) {
      _zoomAnimationController.stop();
    }
    _baseScale = _scale;
    _baseOffset = _offset;
    _pinchStartFocalPoint = details.localFocalPoint;
    _previousPointerCount = details.pointerCount;
    if (details.pointerCount > 1) _isQuickScaling = false;
    _quickScaleLastDistance = -1;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (_zoomAnimationController.isAnimating) return;
    if (_scale <= 1.01 &&
        details.pointerCount <= 1 &&
        !_isQuickScaling) {
      return;
    }

    if (details.pointerCount != _previousPointerCount) {
      _baseScale = _scale;
      _baseOffset = _offset;
      _pinchStartFocalPoint = details.localFocalPoint;
      _previousPointerCount = details.pointerCount;
    }

    final size = MediaQuery.sizeOf(context);
    final isVertical = widget.scrollDirection == Axis.vertical;
    var newScale = _scale;
    var newDx = _offset.dx;
    var newDy = _offset.dy;

    if (_isQuickScaling && _quickScaleCenter != null) {
      final dy = details.localFocalPoint.dy;
      final distance = (dy - _pinchStartFocalPoint.dy).abs() * 2 + 20;
      if (_quickScaleLastDistance < 0) _quickScaleLastDistance = distance;
      final isUpwards = dy < _quickScaleLastY;
      _quickScaleLastY = dy;
      final spanDiff =
          (1 - (distance / _quickScaleLastDistance)).abs() * 0.5;
      if (spanDiff > 0.02) {
        final multiplier = isUpwards ? 1 + spanDiff : 1 - spanDiff;
        newScale = (_scale * multiplier)
            .clamp(widget.settings.webtoonDisableZoomOut ? 1.0 : 0.5, 5.0)
            .toDouble();
        final focalX = _quickScaleCenter!.dx - size.width / 2;
        final focalY = _quickScaleCenter!.dy - size.height / 2;
        newDx =
            focalX - (focalX - _baseOffset.dx) * (newScale / _baseScale);
        newDy =
            focalY - (focalY - _baseOffset.dy) * (newScale / _baseScale);
      }
      _quickScaleLastDistance = distance;
    } else if (details.pointerCount > 1 && details.scale != 1) {
      newScale = (_baseScale * details.scale)
          .clamp(widget.settings.webtoonDisableZoomOut ? 1.0 : 0.5, 5.0)
          .toDouble();
      final focalX = details.localFocalPoint.dx - size.width / 2;
      final focalY = details.localFocalPoint.dy - size.height / 2;
      newDx = focalX - (focalX - _baseOffset.dx) * (newScale / _baseScale);
      newDy = focalY - (focalY - _baseOffset.dy) * (newScale / _baseScale);
    } else if (details.pointerCount == 1 && !_isQuickScaling) {
      final deltaX =
          details.localFocalPoint.dx - _pinchStartFocalPoint.dx;
      final deltaY =
          details.localFocalPoint.dy - _pinchStartFocalPoint.dy;
      final tempDx = _baseOffset.dx + deltaX;
      final tempDy = _baseOffset.dy + deltaY;
      final maxDx = (size.width * (_scale - 1)) / 2;
      final maxDy = (size.height * (_scale - 1)) / 2;

      if (_scale <= 1) {
        newDx = 0;
        newDy = 0;
      } else if (isVertical) {
        newDx = tempDx.clamp(-maxDx, maxDx).toDouble();
        if (tempDy > maxDy) {
          newDy = maxDy;
          _scrollOverflow(tempDy - maxDy);
        } else if (tempDy < -maxDy) {
          newDy = -maxDy;
          _scrollOverflow(tempDy + maxDy);
        } else {
          newDy = tempDy;
        }
      } else {
        newDy = tempDy.clamp(-maxDy, maxDy).toDouble();
        if (tempDx > maxDx) {
          newDx = maxDx;
          _scrollOverflow(tempDx - maxDx);
        } else if (tempDx < -maxDx) {
          newDx = -maxDx;
          _scrollOverflow(tempDx + maxDx);
        } else {
          newDx = tempDx;
        }
      }
    }

    final maxDx = (size.width * (newScale - 1)) / 2;
    final maxDy = (size.height * (newScale - 1)) / 2;
    final clampedDx = newScale > 1
        ? newDx.clamp(-maxDx, maxDx).toDouble()
        : 0.0;
    final clampedDy = newScale > 1
        ? newDy.clamp(-maxDy, maxDy).toDouble()
        : 0.0;
    _scale = newScale;
    _offset = Offset(clampedDx, clampedDy);
    _updateMatrix();
  }

  void _scrollOverflow(double overflow) {
    if (!widget.scrollController.hasClients) return;
    final position = widget.scrollController.position;
    final target = (widget.scrollController.offset - overflow * 0.1)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    widget.scrollController.jumpTo(target);
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _isQuickScaling = false;
    if (_scale < 1) {
      _animateTo(
        1,
        Offset.zero,
        duration: const Duration(milliseconds: 250),
      );
      return;
    }

    if (_scale <= 1) return;
    final velocity = details.velocity.pixelsPerSecond;
    if (velocity.distance <= 350) return;

    final size = MediaQuery.sizeOf(context);
    final maxDx = (size.width * (_scale - 1)) / 2;
    final maxDy = (size.height * (_scale - 1)) / 2;
    final target = Offset(
      (_offset.dx + velocity.dx * 0.15)
          .clamp(-maxDx, maxDx)
          .toDouble(),
      (_offset.dy + velocity.dy * 0.15)
          .clamp(-maxDy, maxDy)
          .toDouble(),
    );
    if ((target - _offset).distance > 8) {
      _animateTo(
        _scale,
        target,
        duration: const Duration(milliseconds: 400),
      );
    }
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _doubleTapPosition = details.localPosition;
    _isQuickScaling = true;
    _quickScaleLastY = details.localPosition.dy;
    _quickScaleLastDistance = -1;
    _quickScaleCenter = details.localPosition;
  }

  void _toggleScale() {
    final onDoubleTap = widget.onDoubleTap;
    if (onDoubleTap != null) {
      _isQuickScaling = false;
      onDoubleTap();
      return;
    }
    if (!widget.settings.webtoonDoubleTapZoomEnabled || !mounted) return;
    if (_zoomAnimationController.isAnimating) return;
    _isQuickScaling = false;
    _animateZoomToFocalPoint(
      _scale <= 1.05 ? 2.5 : 1.0,
      _doubleTapPosition,
    );
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        MangaContinuousScaleGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
                MangaContinuousScaleGestureRecognizer>(
          MangaContinuousScaleGestureRecognizer.new,
          (instance) {
            instance.canPanCallback = () => _scale > 1.01 || _isQuickScaling;
            instance
              ..onStart = _handleScaleStart
              ..onUpdate = _handleScaleUpdate
              ..onEnd = _handleScaleEnd;
          },
        ),
        if (widget.onDoubleTap != null ||
            widget.settings.webtoonDoubleTapZoomEnabled)
          DoubleTapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                  DoubleTapGestureRecognizer>(
            DoubleTapGestureRecognizer.new,
            (instance) {
              instance
                ..onDoubleTapDown = _handleDoubleTapDown
                ..onDoubleTap = _toggleScale
                ..onDoubleTapCancel = () {
                  _isQuickScaling = false;
                };
            },
          ),
      },
      child: ValueListenableBuilder<Matrix4>(
        valueListenable: _transformNotifier,
        child: widget.child,
        builder: (context, matrix, child) => Transform(
          transform: matrix,
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}
