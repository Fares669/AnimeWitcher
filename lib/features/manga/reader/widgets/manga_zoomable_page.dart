import 'package:flutter/material.dart';

class MangaZoomablePage extends StatefulWidget {
  const MangaZoomablePage({
    super.key,
    required this.child,
    this.transformationController,
    this.minScale = 1,
    this.maxScale = 4,
    this.doubleTapScale = 2.5,
  });

  final Widget child;
  final TransformationController? transformationController;
  final double minScale;
  final double maxScale;
  final double doubleTapScale;

  @override
  State<MangaZoomablePage> createState() => _MangaZoomablePageState();
}

class _MangaZoomablePageState extends State<MangaZoomablePage> {
  late final TransformationController _controller;
  late final bool _ownsController;
  TapDownDetails? _doubleTapDetails;
  bool _panEnabled = false;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.transformationController == null;
    _controller =
        widget.transformationController ?? TransformationController();
    _controller.addListener(_onTransformChanged);
    _onTransformChanged();
  }

  @override
  void dispose() {
    _controller.removeListener(_onTransformChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final enabled = _controller.value.getMaxScaleOnAxis() > 1.01;
    if (enabled == _panEnabled || !mounted) return;
    setState(() => _panEnabled = enabled);
  }

  void _handleDoubleTap() {
    final currentScale = _controller.value.getMaxScaleOnAxis();
    if (currentScale > 1.01) {
      _controller.value = Matrix4.identity();
      return;
    }

    final position = _doubleTapDetails?.localPosition ?? Offset.zero;
    final targetScale = widget.doubleTapScale
        .clamp(widget.minScale, widget.maxScale)
        .toDouble();
    _controller.value = Matrix4.identity()
      ..translate(
        -position.dx * (targetScale - 1),
        -position.dy * (targetScale - 1),
      )
      ..scale(targetScale);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onDoubleTapDown: (details) => _doubleTapDetails = details,
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _controller,
        minScale: widget.minScale,
        maxScale: widget.maxScale,
        panEnabled: _panEnabled,
        scaleEnabled: true,
        child: widget.child,
      ),
    );
  }
}
