import 'package:flutter/material.dart';

import '../manga_reader_settings.dart';

class MangaZoomablePage extends StatefulWidget {
  const MangaZoomablePage({
    super.key,
    required this.child,
    this.transformationController,
    this.minScale = 1,
    this.maxScale = 4,
    this.doubleTapScale = 2.5,
    this.settings = const MangaReaderSettings(),
    this.continuous = false,
    this.contentSize,
    this.rtl = false,
  });

  final Widget child;
  final TransformationController? transformationController;
  final double minScale;
  final double maxScale;
  final double doubleTapScale;
  final MangaReaderSettings settings;
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
    _onTransformChanged();
  }

  Duration get _animationDuration =>
      mangaReaderDoubleTapAnimationDuration(
        widget.settings.doubleTapAnimationSpeed,
      );

  @override
  void didUpdateWidget(covariant MangaZoomablePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.contentSize != widget.contentSize ||
        oldWidget.settings.landscapeZoom != widget.settings.landscapeZoom ||
        oldWidget.settings.zoomStartPosition !=
            widget.settings.zoomStartPosition ||
        oldWidget.settings.scaleType != widget.settings.scaleType) {
      _landscapeZoomApplied = false;
      _scheduleLandscapeZoom();
    }
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
      _animate(
        Matrix4.identity()
          ..translate(
            -focal.dx * (scale - 1),
            -focal.dy * (scale - 1),
          )
          ..scale(scale),
      );
    });
  }

  @override
  void dispose() {
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
    final target = Matrix4.identity()
      ..translate(
        -position.dx * (targetScale - 1),
        -position.dy * (targetScale - 1),
      )
      ..scale(targetScale);
    _animate(target);
  }

  @override
  Widget build(BuildContext context) {
    _scheduleLandscapeZoom();
    final minScale = widget.continuous && !widget.settings.webtoonDisableZoomOut
        ? 0.5
        : widget.minScale;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onDoubleTapDown: (details) => _doubleTapDetails = details,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: minScale,
        maxScale: widget.maxScale,
        panEnabled: _panEnabled,
        scaleEnabled: true,
        child: widget.child,
      ),
    );
  }
}
