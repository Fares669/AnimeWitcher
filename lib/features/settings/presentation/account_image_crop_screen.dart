import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../../core/account/animewitcher_account_models.dart';
import '../../../core/utils/localized_text.dart';

const double _minimumCropScale = 0.2;
const double _initialCropScale = 0.88;

Future<Uint8List?> showAnimeWitcherAccountImageCropper(
  BuildContext context, {
  required Uint8List bytes,
  required AnimeWitcherProfileImageKind kind,
}) {
  return Navigator.of(context).push<Uint8List>(
    MaterialPageRoute<Uint8List>(
      fullscreenDialog: true,
      builder: (_) => _AnimeWitcherAccountImageCropScreen(
        bytes: bytes,
        kind: kind,
      ),
    ),
  );
}

class _AnimeWitcherAccountImageCropScreen extends StatefulWidget {
  const _AnimeWitcherAccountImageCropScreen({
    required this.bytes,
    required this.kind,
  });

  final Uint8List bytes;
  final AnimeWitcherProfileImageKind kind;

  @override
  State<_AnimeWitcherAccountImageCropScreen> createState() =>
      _AnimeWitcherAccountImageCropScreenState();
}

class _AnimeWitcherAccountImageCropScreenState
    extends State<_AnimeWitcherAccountImageCropScreen> {
  ui.Image? _image;
  Object? _decodeError;
  bool _saving = false;

  Offset _cropCenter = const Offset(0.5, 0.5);
  double _cropScale = _initialCropScale;

  Rect? _activeImageRect;
  Rect? _activeCropRect;
  Rect? _gestureImageRect;
  Rect? _gestureCropRect;
  bool _gestureActive = false;
  bool _resizingFromHandle = false;
  double _gestureStartRadius = 0;
  late Offset _gestureStartCenter;
  late Offset _gestureStartFocalPoint;
  late double _gestureStartScale;

  bool get _isAvatar =>
      widget.kind == AnimeWitcherProfileImageKind.avatar;

  double get _targetAspectRatio => _isAvatar ? 1 : 7 / 4;

  @override
  void initState() {
    super.initState();
    unawaited(_decodeImage());
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _decodeImage() async {
    if (mounted) {
      setState(() {
        _decodeError = null;
        _image = null;
      });
    }

    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      try {
        final frame = await codec.getNextFrame();
        if (!mounted) {
          frame.image.dispose();
          return;
        }
        setState(() {
          _image = frame.image;
          _cropCenter = const Offset(0.5, 0.5);
          _cropScale = _initialCropScale;
        });
      } finally {
        codec.dispose();
      }
    } catch (error) {
      if (mounted) setState(() => _decodeError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          appText(
            context,
            english: _isAvatar ? 'Crop account picture' : 'Crop cover',
            arabic: _isAvatar ? 'قص صورة الحساب' : 'قص الغلاف',
          ),
        ),
        actions: [
          IconButton(
            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: image == null
            ? _buildLoadingOrFailure(colors)
            : Column(
                children: [
                  Expanded(child: _buildCropCanvas(image, colors)),
                  _buildControls(image, colors),
                ],
              ),
      ),
    );
  }

  Widget _buildLoadingOrFailure(ColorScheme colors) {
    if (_decodeError == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 52, color: colors.error),
            const SizedBox(height: 14),
            Text(
              appText(
                context,
                english: 'The selected image could not be opened.',
                arabic: 'تعذّر فتح الصورة المحددة.',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => unawaited(_decodeImage()),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(
                appText(
                  context,
                  english: 'Try again',
                  arabic: 'إعادة المحاولة',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCropCanvas(ui.Image image, ColorScheme colors) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final imageRect = _resolveImageRect(image, constraints);
        final normalizedCrop = _normalizedCropRect(image);
        final cropRect = Rect.fromLTWH(
          imageRect.left + normalizedCrop.left * imageRect.width,
          imageRect.top + normalizedCrop.top * imageRect.height,
          normalizedCrop.width * imageRect.width,
          normalizedCrop.height * imageRect.height,
        );
        _activeImageRect = imageRect;
        _activeCropRect = cropRect;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _saving ? null : _onScaleStart,
          onScaleUpdate: _saving
              ? null
              : (details) => _onScaleUpdate(details, image),
          onDoubleTap: _saving ? null : _resetCrop,
          child: Semantics(
            label: appText(
              context,
              english: 'Movable and resizable image crop frame',
              arabic:
                  'إطار تحديد صورة قابل للتحريك وتغيير الحجم',
            ),
            child: CustomPaint(
              painter: _AccountImageCropPainter(
                image: image,
                imageRect: imageRect,
                cropRect: cropRect,
                isCircle: _isAvatar,
                accentColor: colors.primary,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildControls(ui.Image image, ColorScheme colors) {
    final ratioText = _isAvatar ? '1:1' : '7:4';
    return ColoredBox(
      color: Colors.black,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              appText(
                context,
                english:
                    'Drag the frame to move it. Pinch or use the slider to resize it.',
                arabic: 'حرّك إطار التحديد، وكبّره أو صغّره '
                    'بإصبعين أو باستخدام الشريط.',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.78)),
            ),
            const SizedBox(height: 4),
            Text(
              ratioText,
              style: TextStyle(
                color: colors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            Row(
              children: [
                const Icon(Icons.remove_rounded, color: Colors.white70),
                Expanded(
                  child: Slider(
                    min: _minimumCropScale,
                    max: 1,
                    value: _cropScale,
                    onChanged: _saving
                        ? null
                        : (value) {
                            setState(() {
                              _cropScale = value;
                              _cropCenter = _clampCropCenter(
                                image,
                                _cropCenter,
                                value,
                              );
                            });
                          },
                  ),
                ),
                const Icon(Icons.add_rounded, color: Colors.white70),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _resetCrop,
                    icon: const Icon(Icons.restart_alt_rounded),
                    label: Text(
                      appText(
                        context,
                        english: 'Reset',
                        arabic: 'إعادة الضبط',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _finishCrop,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(
                      appText(
                        context,
                        english: 'Use image',
                        arabic: 'استخدام الصورة',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Rect _resolveImageRect(ui.Image image, BoxConstraints constraints) {
    final availableWidth = math.max(1.0, constraints.maxWidth - 24);
    final availableHeight = math.max(1.0, constraints.maxHeight - 20);
    final fitScale = math.min(
      availableWidth / image.width,
      availableHeight / image.height,
    );
    final displaySize = Size(
      image.width * fitScale,
      image.height * fitScale,
    );
    return Rect.fromCenter(
      center: Offset(constraints.maxWidth / 2, constraints.maxHeight / 2),
      width: displaySize.width,
      height: displaySize.height,
    );
  }

  Size _maximumNormalizedCropSize(ui.Image image) {
    final sourceAspect = image.width / image.height;
    if (sourceAspect > _targetAspectRatio) {
      return Size(_targetAspectRatio / sourceAspect, 1);
    }
    return Size(1, sourceAspect / _targetAspectRatio);
  }

  Rect _normalizedCropRect(ui.Image image) {
    final maximum = _maximumNormalizedCropSize(image);
    final size = Size(
      maximum.width * _cropScale,
      maximum.height * _cropScale,
    );
    final center = _clampCropCenter(image, _cropCenter, _cropScale);
    return Rect.fromCenter(center: center, width: size.width, height: size.height);
  }

  Offset _clampCropCenter(
    ui.Image image,
    Offset center,
    double scale,
  ) {
    final maximum = _maximumNormalizedCropSize(image);
    final halfWidth = maximum.width * scale / 2;
    final halfHeight = maximum.height * scale / 2;
    return Offset(
      center.dx.clamp(halfWidth, 1 - halfWidth).toDouble(),
      center.dy.clamp(halfHeight, 1 - halfHeight).toDouble(),
    );
  }

  void _onScaleStart(ScaleStartDetails details) {
    final cropRect = _activeCropRect;
    _gestureActive =
        cropRect?.inflate(18).contains(details.localFocalPoint) ?? false;
    if (!_gestureActive || cropRect == null) return;
    _gestureImageRect = _activeImageRect;
    _gestureCropRect = cropRect;
    _gestureStartCenter = _cropCenter;
    _gestureStartFocalPoint = details.localFocalPoint;
    _gestureStartScale = _cropScale;
    _gestureStartRadius =
        (details.localFocalPoint - cropRect.center).distance;
    _resizingFromHandle = _cropHandlePoints(cropRect).any(
      (point) => (details.localFocalPoint - point).distance <= 34,
    );
  }

  void _onScaleUpdate(ScaleUpdateDetails details, ui.Image image) {
    final imageRect = _gestureImageRect;
    final gestureCropRect = _gestureCropRect;
    if (!_gestureActive ||
        imageRect == null ||
        imageRect.isEmpty ||
        gestureCropRect == null) {
      return;
    }
    var gestureScale = details.scale;
    if (_resizingFromHandle && _gestureStartRadius > 0) {
      gestureScale =
          (details.localFocalPoint - gestureCropRect.center).distance /
          _gestureStartRadius;
    }
    final nextScale = math.min(
      1.0,
      math.max(_minimumCropScale, _gestureStartScale * gestureScale),
    );
    final focalDelta = details.localFocalPoint - _gestureStartFocalPoint;
    final nextCenter = _resizingFromHandle
        ? _gestureStartCenter
        : _gestureStartCenter +
            Offset(
              focalDelta.dx / imageRect.width,
              focalDelta.dy / imageRect.height,
            );
    setState(() {
      _cropScale = nextScale;
      _cropCenter = _clampCropCenter(image, nextCenter, nextScale);
    });
  }

  List<Offset> _cropHandlePoints(Rect cropRect) {
    if (_isAvatar) {
      return <Offset>[
        Offset(cropRect.center.dx, cropRect.top),
        Offset(cropRect.right, cropRect.center.dy),
        Offset(cropRect.center.dx, cropRect.bottom),
        Offset(cropRect.left, cropRect.center.dy),
      ];
    }
    return <Offset>[
      cropRect.topLeft,
      cropRect.topRight,
      cropRect.bottomLeft,
      cropRect.bottomRight,
    ];
  }

  void _resetCrop() {
    setState(() {
      _cropCenter = const Offset(0.5, 0.5);
      _cropScale = _initialCropScale;
    });
  }

  Future<void> _finishCrop() async {
    final image = _image;
    if (image == null) return;
    setState(() => _saving = true);
    try {
      final normalized = _normalizedCropRect(image);
      final source = Rect.fromLTWH(
        normalized.left * image.width,
        normalized.top * image.height,
        normalized.width * image.width,
        normalized.height * image.height,
      );
      final targetWidth = _isAvatar ? 720 : 1400;
      final targetHeight = _isAvatar ? 720 : 800;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        image,
        source,
        Rect.fromLTWH(
          0,
          0,
          targetWidth.toDouble(),
          targetHeight.toDouble(),
        ),
        Paint()..filterQuality = FilterQuality.high,
      );
      final picture = recorder.endRecording();
      final rendered = await picture.toImage(targetWidth, targetHeight);
      picture.dispose();
      late final Uint8List pngBytes;
      try {
        final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw const FormatException('Could not encode image.');
        pngBytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
      } finally {
        rendered.dispose();
      }
      final result = await compute(_encodeAccountCrop, <String, Object>{
        'bytes': pngBytes,
        'kind': widget.kind.name,
      });
      if (mounted) Navigator.of(context).pop(result);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            appText(
              context,
              english: 'The selected part could not be saved. Try again.',
              arabic: 'تعذّر حفظ الجزء المحدد. حاول مرة أخرى.',
            ),
          ),
        ),
      );
    }
  }
}

class _AccountImageCropPainter extends CustomPainter {
  const _AccountImageCropPainter({
    required this.image,
    required this.imageRect,
    required this.cropRect,
    required this.isCircle,
    required this.accentColor,
  });

  final ui.Image image;
  final Rect imageRect;
  final Rect cropRect;
  final bool isCircle;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      ),
      imageRect,
      Paint()..filterQuality = FilterQuality.high,
    );

    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    if (isCircle) {
      mask.addOval(cropRect);
    } else {
      mask.addRect(cropRect);
    }
    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: 0.68),
    );

    canvas.save();
    if (isCircle) {
      canvas.clipPath(Path()..addOval(cropRect));
    } else {
      canvas.clipRect(cropRect);
    }
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.38)
      ..strokeWidth = 1;
    for (var index = 1; index < 3; index++) {
      final fraction = index / 3;
      canvas.drawLine(
        Offset(cropRect.left + cropRect.width * fraction, cropRect.top),
        Offset(cropRect.left + cropRect.width * fraction, cropRect.bottom),
        gridPaint,
      );
      canvas.drawLine(
        Offset(cropRect.left, cropRect.top + cropRect.height * fraction),
        Offset(cropRect.right, cropRect.top + cropRect.height * fraction),
        gridPaint,
      );
    }
    canvas.restore();

    final borderPaint = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    if (isCircle) {
      canvas.drawOval(cropRect, borderPaint);
      final handlePaint = Paint()..color = accentColor;
      for (final point in <Offset>[
        Offset(cropRect.center.dx, cropRect.top),
        Offset(cropRect.right, cropRect.center.dy),
        Offset(cropRect.center.dx, cropRect.bottom),
        Offset(cropRect.left, cropRect.center.dy),
      ]) {
        canvas.drawCircle(point, 5, handlePaint);
      }
    } else {
      canvas.drawRect(cropRect, borderPaint);
      _drawCornerHandles(canvas, cropRect, borderPaint);
    }
  }

  void _drawCornerHandles(Canvas canvas, Rect rect, Paint paint) {
    const length = 20.0;
    final handlePaint = Paint()
      ..color = paint.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.square;
    canvas
      ..drawLine(
        rect.topLeft,
        rect.topLeft + const Offset(length, 0),
        handlePaint,
      )
      ..drawLine(rect.topLeft, rect.topLeft + const Offset(0, length), handlePaint)
      ..drawLine(
        rect.topRight,
        rect.topRight + const Offset(-length, 0),
        handlePaint,
      )
      ..drawLine(rect.topRight, rect.topRight + const Offset(0, length), handlePaint)
      ..drawLine(
        rect.bottomLeft,
        rect.bottomLeft + const Offset(length, 0),
        handlePaint,
      )
      ..drawLine(
        rect.bottomLeft,
        rect.bottomLeft + const Offset(0, -length),
        handlePaint,
      )
      ..drawLine(
        rect.bottomRight,
        rect.bottomRight + const Offset(-length, 0),
        handlePaint,
      )
      ..drawLine(
        rect.bottomRight,
        rect.bottomRight + const Offset(0, -length),
        handlePaint,
      );
  }

  @override
  bool shouldRepaint(covariant _AccountImageCropPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.imageRect != imageRect ||
        oldDelegate.cropRect != cropRect ||
        oldDelegate.isCircle != isCircle ||
        oldDelegate.accentColor != accentColor;
  }
}

Uint8List _encodeAccountCrop(Map<String, Object> request) {
  final raw = request['bytes'];
  final kind = request['kind']?.toString();
  if (raw is! Uint8List) throw const FormatException('Missing image bytes.');
  final decoded = img.decodeImage(raw);
  if (decoded == null) throw const FormatException('Invalid image.');
  final isAvatar = kind == AnimeWitcherProfileImageKind.avatar.name;
  return img.encodeJpg(decoded, quality: isAvatar ? 84 : 82);
}
