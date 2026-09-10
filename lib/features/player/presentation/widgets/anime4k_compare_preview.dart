import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:animewitcher/core/utils/localized_text.dart';

import '../../data/anime4k_download.dart';
import '../../data/anime4k_reference.dart';

/// The same frame with Anime4K and without, split by a divider you drag.
///
/// Both halves come out of one picture the Anime4K project publishes, so they
/// are the same frame by construction — the easiest thing to get wrong when
/// building a comparison from two files, and the one that would make it a
/// lie. The "before" is plain bicubic upscaling, which is what a player does
/// when none of this is switched on.
///
/// Fetched rather than copied into this repository: it is their picture, and
/// it is cached after the first look.
class Anime4kComparePreview extends StatefulWidget {
  const Anime4kComparePreview({
    super.key,
    required this.titleColor,
    required this.bodyColor,
    this.fillColor,
    this.height = 180,
  });

  final Color titleColor;
  final Color bodyColor;
  final Color? fillColor;
  final double height;

  @override
  State<Anime4kComparePreview> createState() => _Anime4kComparePreviewState();
}

class _Anime4kComparePreviewState extends State<Anime4kComparePreview> {
  ui.Image? _image;
  bool _failed = false;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  /// Where the divider sits, as a fraction of the width.
  double _split = 0.5;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    const provider = CachedNetworkImageProvider(anime4kReferenceImageUrl);
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() => _image = info.image);
      },
      onError: (error, stack) {
        if (!mounted) return;
        setState(() => _failed = true);
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  @override
  void dispose() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _image?.dispose();
    super.dispose();
  }

  Future<void> _openProject() async {
    try {
      await launchUrl(
        Uri.parse(anime4kProjectUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // Not worth an error in a settings panel.
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          appText(context, english: 'Before and after', arabic: 'قبل وبعد'),
          style: TextStyle(
            color: widget.titleColor,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.fillColor ?? Colors.white.withValues(alpha: 0.04),
              ),
              child: image != null
                  ? _Split(
                      image: image,
                      split: _split,
                      onSplit: (value) => setState(() => _split = value),
                    )
                  : Center(child: _placeholder(context)),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                image != null
                    ? appText(
                        context,
                        english: 'Drag the divider. By the Anime4K project.',
                        arabic: 'اسحب الفاصل. من مشروع Anime4K.',
                      )
                    : appText(
                        context,
                        english: 'By the Anime4K project',
                        arabic: 'من مشروع Anime4K',
                      ),
                style: TextStyle(
                  color: widget.bodyColor,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _openProject,
              icon: const Icon(Icons.open_in_new_rounded, size: 15),
              label: Text(
                appText(context, english: 'More', arabic: 'المزيد'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _placeholder(BuildContext context) {
    if (!_failed) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Text(
        appText(
          context,
          english:
              'The example could not be loaded. It is fetched from the '
              'Anime4K project.',
          arabic: 'تعذّر تحميل المثال. يُجلب من مشروع Anime4K.',
        ),
        textAlign: TextAlign.center,
        style: TextStyle(color: widget.bodyColor, fontSize: 12, height: 1.4),
      ),
    );
  }
}

/// Draws the two panels, the enhanced one clipped to the divider.
class _Split extends StatelessWidget {
  const _Split({
    required this.image,
    required this.split,
    required this.onSplit,
  });

  final ui.Image image;
  final double split;
  final ValueChanged<double> onSplit;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void setFromDx(double dx) =>
            onSplit((dx / width).clamp(0.02, 0.98).toDouble());

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => setFromDx(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => setFromDx(d.localPosition.dx),
          onTapDown: (d) => setFromDx(d.localPosition.dx),
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _PanelsPainter(image: image, split: split),
              ),
              // The enhanced half is the one left of the divider, wherever the
              // page direction puts its text.
              const Positioned(left: 8, top: 8, child: _Tag(text: 'ANIME4K')),
              const Positioned(right: 8, top: 8, child: _Tag(text: 'BICUBIC')),
            ],
          ),
        );
      },
    );
  }
}

class _PanelsPainter extends CustomPainter {
  const _PanelsPainter({required this.image, required this.split});

  final ui.Image image;
  final double split;

  @override
  void paint(Canvas canvas, Size size) {
    final source = Size(image.width.toDouble(), image.height.toDouble());
    final paint = Paint()..filterQuality = FilterQuality.medium;

    final before = anime4kReferenceRect(source, Anime4kReferencePanel.bicubic);
    final after = anime4kReferenceRect(source, Anime4kReferencePanel.anime4k);
    final destination = anime4kReferenceCover(before.size, size);

    // The untouched picture across the whole box, then the enhanced one over
    // the part left of the divider.
    canvas.drawImageRect(image, before, destination, paint);

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * split, size.height));
    canvas.drawImageRect(image, after, destination, paint);
    canvas.restore();

    final x = size.width * split;
    canvas.drawRect(
      Rect.fromLTWH(x - 1, 0, 2, size.height),
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_PanelsPainter oldDelegate) =>
      oldDelegate.split != split || oldDelegate.image != image;
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}
