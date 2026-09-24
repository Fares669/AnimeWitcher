import 'package:flutter/material.dart';

import '../manga_reader_settings.dart';

class MangaZoomNavigationController extends ChangeNotifier {
  _MangaZoomablePageState? _state;

  bool tryPan({required bool forward, required bool rtl}) {
    final state = _state;
    if (state == null) return false;
    return state._tryPan(forward: forward, rtl: rtl);
  }

  void _attach(_MangaZoomablePageState state) => _state = state;

  void _detach(_MangaZoomablePageState state) {
    if (identical(_state, state)) _state = null;
  }

  @override
  void dispose() {
    _state = null;
    super.dispose();
  }
}

class MangaZoomablePage extends StatefulWidget {
  const MangaZoomablePage({
    super.key,
    required this.child,
    this.transformationController,
    this.navigationController,
    this.minScale = 1,
    this.maxScale = 4,
    this.doubleTapScale = 2.5,
    this.settings = const MangaReaderSettings(),
    this.onDoubleTap,
    this.continuous = false,
    this.contentSize,
    this.rtl = false,
  });

  final Widget child;
  final TransformationController? transformationController;
  final MangaZoomNavigationController? navigationController;
  final double minScale;
  final double maxScale;
  final double doubleTapScale;
  final MangaReaderSettings settings;
  final VoidCallback? onDoubleTap;
  final bool continuous;
  final Size? contentSize;
  final bool rtl;

  @override
  State<MangaZoomablePage> createState() => _MangaZoomablePageState();
}

class _MangaZoomablePageState extends State<MangaZoomablePage>
    with SingleTickerProviderStateMixin {
  late final TransformationController _controller;
  late final bool _ownsController;
  late final AnimationController _animationController;
  Animation<Matrix4>? _animation;
  TapDownDetails? _doubleTapDetails;
  bool _panEnabled = false;
  bool _landscapeZoomApplied = false;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.transformationController == null;
    _controller =
        widget.transformationController ?? TransformationController();
    _animationController = AnimationController(
      vsync: this,
      duration: _animationDuration,
    )..addListener(() {
        final animation = _animation;
        if (animation != null) _controller.value = animation.value;
      });
    _controller.addListener(_onTransformChanged);
    widget.navigationController?._attach(this);
    _onTransformChanged();
  }

  Duration get _animationDuration =>
      mangaReaderDoubleTapAnimationDuration(
        widget.settings.doubleTapAnimationSpeed,
      );

  @override
  void didUpdateWidget(covariant MangaZoomablePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.navigationController, widget.navigationController)) {
      oldWidget.navigationController?._detach(this);
      widget.navigationController?._attach(this);
    }
    if (oldWidget.contentSize != widget.contentSize ||
        oldWidget.settings.landscapeZoom != widget.settings.landscapeZoom ||
        oldWidget.settings.zoomStartPosition !=
            widget.settings.zoomStartPosition ||
        oldWidget.settings.scaleType != widget.settings.scaleType) {
      _landscapeZoomApplied = false;
      _scheduleLandscapeZoom();
    }
  }

  Matrix4 _zoomMatrix({
    required double scale,
    required Offset focalPoint,
  }) {
    final matrix = Matrix4.identity();
    matrix
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setTranslationRaw(
        -focalPoint.dx * (scale - 1),
        -focalPoint.dy * (scale - 1),
        0,
      );
    return matrix;
  }

  void _scheduleLandscapeZoom() {
    if (_landscapeZoomApplied || widget.contentSize == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _landscapeZoomApplied) return;
      final viewport = context.size;
      final contentSize = widget.contentSize;
      if (viewport == null || contentSize == null) return;
      final target = mangaReaderLandscapeZoomTarget(
        settings: widget.settings,
        imageSize: contentSize,
        viewport: viewport,
      );
      if (target == null) return;
      _landscapeZoomApplied = true;
      final scale = target.scale;
      final focal = target.focalPoint;
      _animate(_zoomMatrix(scale: scale, focalPoint: focal));
    });
  }


  @override
  void dispose() {
    widget.navigationController?._detach(this);
    _controller.removeListener(_onTransformChanged);
    _animationController.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final enabled = _controller.value.getMaxScaleOnAxis() > 1.01;
    if (enabled == _panEnabled || !mounted) return;
    setState(() => _panEnabled = enabled);
  }

  void _animate(Matrix4 target) {
    _animationController.stop();
    _animationController.duration = _animationDuration;
    if (_animationDuration == Duration.zero) {
      _controller.value = target;
      return;
    }
    _animation = Matrix4Tween(
      begin: Matrix4.copy(_controller.value),
      end: target,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    ));
    _animationController.forward(from: 0);
  }

  void _handleDoubleTap() {
    if (widget.continuous &&
        !widget.settings.webtoonDoubleTapZoomEnabled) {
      return;
    }
    final currentScale = _controller.value.getMaxScaleOnAxis();
    if (currentScale > 1.01) {
      _animate(Matrix4.identity());
      return;
    }

    final position = _doubleTapDetails?.localPosition ?? Offset.zero;
    final targetScale = widget.doubleTapScale
        .clamp(widget.minScale, widget.maxScale)
        .toDouble();
    _animate(
      _zoomMatrix(scale: targetScale, focalPoint: position),
    );
  }

  bool _tryPan({required bool forward, required bool rtl}) {
    final scale = _controller.value.getMaxScaleOnAxis();
    final viewport = context.size;
    if (scale <= 1.01 || viewport == null || viewport.width <= 0) return false;

    const edgeSlack = 15.0;
    final translation = _controller.value.getTranslation();
    final minX = viewport.width - (viewport.width * scale);
    final towardPositive = forward ? rtl : !rtl;
    final currentX = translation.x;

    final double targetX;
    if (towardPositive) {
      if (currentX >= -edgeSlack) return false;
      targetX = (currentX + viewport.width).clamp(minX, 0).toDouble();
    } else {
      if (currentX <= minX + edgeSlack) return false;
      targetX = (currentX - viewport.width).clamp(minX, 0).toDouble();
    }

    final next = Matrix4.copy(_controller.value)
      ..setTranslationRaw(targetX, translation.y, translation.z);
    _controller.value = next;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    _scheduleLandscapeZoom();
    final minScale = widget.continuous && !widget.settings.webtoonDisableZoomOut
        ? 0.5
        : widget.minScale;
    final maxScale = widget.continuous ? 5.0 : widget.maxScale;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onDoubleTapDown: widget.onDoubleTap == null
          ? (details) => _doubleTapDetails = details
          : null,
      onDoubleTap: widget.onDoubleTap ?? _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: minScale,
        maxScale: maxScale,
        panEnabled: _panEnabled,
        scaleEnabled: true,
        child: widget.child,
      ),
    );
  }
}
