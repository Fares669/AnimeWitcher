import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:animewitcher/core/utils/localized_text.dart';

import '../../data/anime4k.dart';
import '../../data/anime4k_shader_library.dart';

/// A sample picture with the chosen mode running on it, beside the same
/// picture untouched.
///
/// The shaders only exist inside mpv, so this is a second mpv holding a still
/// image rather than an episode: it opens the sample, is handed the same
/// shader chain the real player gets, and draws the result. The plain file
/// sits behind it as the other half of the split, so what moves when the
/// divider moves is exactly what the mode does — on a picture that is the
/// same every time, which is what makes two modes comparable at all.
///
/// It is a real decoder, so it is created when the panel opens and disposed
/// when it closes.
class Anime4kSamplePreview extends StatefulWidget {
  const Anime4kSamplePreview({
    super.key,
    required this.mode,
    required this.quality,
    required this.shaderDirectory,
    required this.titleColor,
    required this.bodyColor,
    this.fillColor,
    this.height = 190,
  });

  final Anime4kMode mode;
  final Anime4kQuality quality;
  final String shaderDirectory;
  final Color titleColor;
  final Color bodyColor;
  final Color? fillColor;
  final double height;

  static const String assetPath = 'assets/images/anime4k_sample.jpg';

  @override
  State<Anime4kSamplePreview> createState() => _Anime4kSamplePreviewState();
}

class _Anime4kSamplePreviewState extends State<Anime4kSamplePreview> {
  Player? _player;
  VideoController? _controller;
  String? _error;
  bool _ready = false;

  /// Where the divider sits, as a fraction of the width.
  double _split = 0.5;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void didUpdateWidget(Anime4kSamplePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode ||
        oldWidget.quality != widget.quality ||
        oldWidget.shaderDirectory != widget.shaderDirectory) {
      unawaited(_applyShaders());
    }
  }

  @override
  void dispose() {
    // Ordered: the controller owns the texture the player renders into.
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final file = await _writeSample();
      final player = Player();
      final controller = VideoController(player);
      _player = player;
      _controller = controller;

      final platform = player.platform;
      if (platform is NativePlayer) {
        // mpv gives a still image one second and then reports the end of the
        // file. This one has to sit there for as long as the panel is open.
        await platform.setProperty('image-display-duration', 'inf');
        await platform.setProperty('loop-file', 'inf');
        // Nothing here is watched, and a settings panel that made noise
        // would be a surprise.
        await platform.setProperty('mute', 'yes');
      }

      await player.open(Media(file.path), play: true);
      await _applyShaders();
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  /// Copies the bundled sample somewhere mpv can open by path.
  Future<File> _writeSample() async {
    final bytes = await rootBundle.load(Anime4kSamplePreview.assetPath);
    final directory = await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, 'anime4k_sample.jpg'));
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    return file;
  }

  /// Hands this player the same chain the real one would run.
  Future<void> _applyShaders() async {
    final player = _player;
    if (player == null) return;
    final platform = player.platform;
    if (platform is! NativePlayer) {
      if (mounted) {
        setState(() => _error = 'Anime4K requires the native mpv player.');
      }
      return;
    }
    try {
      final pipeline = await const Anime4kShaderLibrary().pipeline(
        mode: widget.mode,
        quality: widget.quality,
        directory: widget.shaderDirectory,
      );
      if (!pipeline.isEmpty) {
        final currentVo = (await platform.getProperty('current-vo')).trim();
        final gpuDumbMode = (await platform.getProperty('gpu-dumb-mode'))
            .trim()
            .toLowerCase();
        if (!anime4kGpuRendererSupportsShaders(currentVo) ||
            gpuDumbMode == 'yes') {
          throw StateError(
            'Anime4K GPU shaders are unavailable on this renderer '
            '(vo=$currentVo, gpu-dumb-mode=$gpuDumbMode).',
          );
        }
      }
      await platform.setProperty('glsl-shaders', pipeline.value);
      final applied = (await platform.getProperty('glsl-shaders')).trim();
      if (pipeline.value.isNotEmpty && applied.isEmpty) {
        throw StateError('mpv did not accept the Anime4K shader chain.');
      }
      if (mounted && _error != null) setState(() => _error = null);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final fill = widget.fillColor ?? Colors.white.withValues(alpha: 0.04);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          appText(
            context,
            english: 'This mode on a sample',
            arabic: 'هذا النمط على صورة تجريبية',
          ),
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
              decoration: BoxDecoration(color: fill),
              child: _error != null
                  ? Center(child: _errorText(context))
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        void setFromDx(double dx) => setState(
                          () => _split = (dx / width)
                              .clamp(0.02, 0.98)
                              .toDouble(),
                        );

                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: (d) =>
                              setFromDx(d.localPosition.dx),
                          onHorizontalDragUpdate: (d) =>
                              setFromDx(d.localPosition.dx),
                          onTapDown: (d) => setFromDx(d.localPosition.dx),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // Untouched, underneath.
                              Image.asset(
                                Anime4kSamplePreview.assetPath,
                                fit: BoxFit.cover,
                              ),
                              if (controller != null && _ready)
                                ClipRect(
                                  clipper: _LeftOf(_split),
                                  child: Video(
                                    controller: controller,
                                    fit: BoxFit.cover,
                                    // media_kit exports NoVideoControls as
                                    // an untyped null; passing it directly
                                    // says the same thing and type-checks.
                                    controls: null,
                                  ),
                                ),
                              if (!_ready)
                                const Center(
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                              CustomPaint(
                                painter: _DividerPainter(_split),
                                size: Size.infinite,
                              ),
                              Positioned(
                                left: 8,
                                top: 8,
                                child: _Tag(
                                  text: widget.mode == Anime4kMode.off
                                      ? appText(
                                          context,
                                          english: 'OFF',
                                          arabic: 'إيقاف',
                                        )
                                      : widget.mode.label.toUpperCase(),
                                ),
                              ),
                              Positioned(
                                right: 8,
                                top: 8,
                                child: _Tag(
                                  text: appText(
                                    context,
                                    english: 'ORIGINAL',
                                    arabic: 'الأصل',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          appText(
            context,
            english: 'Drag the divider. Switch mode above to compare.',
            arabic: 'اسحب الفاصل. غيّر النمط أعلاه للمقارنة.',
          ),
          style: TextStyle(color: widget.bodyColor, fontSize: 11, height: 1.4),
        ),
      ],
    );
  }

  Widget _errorText(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Text(
        appText(
          context,
          english:
              'The preview could not start. Anime4K still applies to what '
              'you play.',
          arabic: 'تعذّر تشغيل المعاينة. لا يزال Anime4K يعمل على ما تشاهده.',
        ),
        textAlign: TextAlign.center,
        style: TextStyle(color: widget.bodyColor, fontSize: 12, height: 1.4),
      ),
    );
  }
}

class _LeftOf extends CustomClipper<Rect> {
  const _LeftOf(this.split);
  final double split;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * split, size.height);

  @override
  bool shouldReclip(_LeftOf oldClipper) => oldClipper.split != split;
}

class _DividerPainter extends CustomPainter {
  const _DividerPainter(this.split);
  final double split;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width * split;
    canvas.drawRect(
      Rect.fromLTWH(x - 1, 0, 2, size.height),
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(_DividerPainter oldDelegate) => oldDelegate.split != split;
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
