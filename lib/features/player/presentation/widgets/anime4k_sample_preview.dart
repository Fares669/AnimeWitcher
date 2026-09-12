import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:animewitcher/core/utils/localized_text.dart';

import '../../data/anime4k.dart';
import '../../data/anime4k_metal_bridge.dart';
import '../../data/anime4k_metal_ffi.dart';
import '../../data/anime4k_performance.dart';
import '../../data/anime4k_shader_library.dart';

enum Anime4kPreviewBackend { mpv, appleMetal }

class Anime4kPreviewCacheKey {
  const Anime4kPreviewCacheKey({
    required this.mode,
    required this.quality,
    required this.backend,
    required this.pipelineHash,
  });

  final Anime4kMode mode;
  final Anime4kQuality quality;
  final Anime4kPreviewBackend backend;
  final String pipelineHash;

  @override
  bool operator ==(Object other) {
    return other is Anime4kPreviewCacheKey &&
        other.mode == mode &&
        other.quality == quality &&
        other.backend == backend &&
        other.pipelineHash == pipelineHash;
  }

  @override
  int get hashCode => Object.hash(mode, quality, backend, pipelineHash);
}

class _Anime4kMetalPreviewCache {
  final Map<Anime4kPreviewCacheKey, Uint8List> _images =
      <Anime4kPreviewCacheKey, Uint8List>{};

  Uint8List? lookup(Anime4kPreviewCacheKey key) => _images[key];

  void store(Anime4kPreviewCacheKey key, Uint8List bytes) {
    // The preview has a tiny configuration space, but keep the process-wide
    // cache bounded in case a user cycles through many downloaded shader sets.
    if (_images.length >= 16 && !_images.containsKey(key)) {
      _images.remove(_images.keys.first);
    }
    _images[key] = bytes;
  }
}

final _metalPreviewCache = _Anime4kMetalPreviewCache();

/// A sample picture with the chosen mode running on it, beside the same
/// picture untouched.
///
/// Apple uses the same native Metal backend as playback, but only long enough
/// to render and capture one processed frame. The encoded result is cached by
/// mode, quality, effective backend, and shader pipeline hash, so reopening the
/// settings does not keep a second renderer alive. Other platforms, or an
/// unavailable Apple Metal backend, keep the existing mpv preview as fallback.
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
  Uint8List? _processedPreviewBytes;
  String? _error;
  bool _ready = false;
  bool _capturingMetal = false;
  int _previewRequest = 0;

  final GlobalKey _metalCaptureKey = GlobalKey();

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
      unawaited(_start());
    }
  }

  @override
  void dispose() {
    _previewRequest++;
    final player = _player;
    _player = null;
    _controller = null;
    unawaited(player?.dispose());
    super.dispose();
  }

  bool _isCurrentRequest(int request) => mounted && request == _previewRequest;

  Future<void> _disposeSpecificPreviewPlayer(Player player) async {
    if (identical(_player, player)) {
      _player = null;
      _controller = null;
      _capturingMetal = false;
    }
    await player.dispose();
  }

  Future<void> _disposePreviewPlayer() async {
    final player = _player;
    _player = null;
    _controller = null;
    _capturingMetal = false;
    if (player != null) await player.dispose();
  }

  Future<Anime4kProcessingDimensions> _sampleDimensions(File file) async {
    final codec = await ui.instantiateImageCodec(await file.readAsBytes());
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      try {
        return Anime4kProcessingDimensions(
          width: image.width,
          height: image.height,
        );
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  Future<Uint8List> _captureMetalPreview() async {
    final boundary = _metalCaptureKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      throw StateError('Anime4K preview capture surface is unavailable.');
    }
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('Anime4K preview capture returned no pixels.');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  }

  Future<bool> _startAppleMetalOneShot({
    required int request,
    required File file,
    required Anime4kPipeline pipeline,
  }) async {
    final key = Anime4kPreviewCacheKey(
      mode: widget.mode,
      quality: widget.quality,
      backend: Anime4kPreviewBackend.appleMetal,
      pipelineHash: pipeline.pipelineHash,
    );
    final cached = _metalPreviewCache.lookup(key);
    if (cached != null) {
      if (_isCurrentRequest(request)) {
        setState(() {
          _processedPreviewBytes = cached;
          _ready = true;
          _error = null;
        });
      }
      return true;
    }

    final bindings = Anime4kMetalFfiBindings.tryCreate();
    if (bindings == null || pipeline.isEmpty || pipeline.pipelineHash.isEmpty) {
      return false;
    }

    final dimensions = await _sampleDimensions(file);
    if (!_isCurrentRequest(request)) return false;

    final player = Player();
    final controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        width: dimensions.width,
        height: dimensions.height,
      ),
    );
    _player = player;
    _controller = controller;
    setState(() {
      _capturingMetal = true;
      _ready = false;
      _processedPreviewBytes = null;
      _error = null;
    });

    Anime4kMetalBridge? metalBridge;
    int? handle;
    try {
      // Mount the Video texture before opening the still image. This lets the
      // patched media_kit render path own the very first produced frame.
      await WidgetsBinding.instance.endOfFrame;
      if (!_isCurrentRequest(request)) {
        await _disposeSpecificPreviewPlayer(player);
        return false;
      }

      final platform = player.platform;
      if (platform is! NativePlayer) {
        await _disposeSpecificPreviewPlayer(player);
        return false;
      }

      handle = await platform.handle;
      metalBridge = Anime4kMetalBridge(bindings: bindings);
      final shaderPaths = pipeline.files
          .map((name) => p.join(widget.shaderDirectory.trim(), name))
          .toList(growable: false);
      final metalState = metalBridge.configure(
        handle: handle,
        shaderPaths: shaderPaths,
        pipelineHash: pipeline.pipelineHash,
        source: dimensions,
        output: dimensions,
      );
      if (metalState != Anime4kNativeMetalState.ready) {
        metalBridge.disable(handle: handle);
        await _disposeSpecificPreviewPlayer(player);
        return false;
      }

      // Metal and mpv must never process the same preview frame.
      await platform.setProperty('glsl-shaders', '');
      await platform.setProperty('image-display-duration', 'inf');
      await platform.setProperty('mute', 'yes');
      await player.open(Media(file.path), play: true);
      await controller.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 5),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (!_isCurrentRequest(request)) {
        metalBridge.disable(handle: handle);
        await _disposeSpecificPreviewPlayer(player);
        return false;
      }

      final bytes = await _captureMetalPreview();
      if (!_isCurrentRequest(request)) {
        metalBridge.disable(handle: handle);
        await _disposeSpecificPreviewPlayer(player);
        return false;
      }

      _metalPreviewCache.store(key, bytes);
      setState(() {
        _processedPreviewBytes = bytes;
        _ready = true;
        _capturingMetal = false;
        _error = null;
      });
      metalBridge.disable(handle: handle);
      await _disposePreviewPlayer();
      return true;
    } catch (_) {
      if (metalBridge != null && handle != null) {
        metalBridge.disable(handle: handle);
      }
      await _disposeSpecificPreviewPlayer(player);
      return false;
    }
  }

  Future<void> _start() async {
    final request = ++_previewRequest;
    await _disposePreviewPlayer();
    if (!_isCurrentRequest(request)) return;
    setState(() {
      _ready = false;
      _capturingMetal = false;
      _processedPreviewBytes = null;
      _error = null;
    });

    try {
      final file = await _writeSample();
      final pipeline = await const Anime4kShaderLibrary().pipeline(
        mode: widget.mode,
        quality: widget.quality,
        directory: widget.shaderDirectory,
      );
      if (!_isCurrentRequest(request)) return;

      if (pipeline.isEmpty) {
        final bytes = await file.readAsBytes();
        if (_isCurrentRequest(request)) {
          setState(() {
            _processedPreviewBytes = bytes;
            _ready = true;
          });
        }
        return;
      }

      if ((Platform.isIOS || Platform.isMacOS) &&
          await _startAppleMetalOneShot(
            request: request,
            file: file,
            pipeline: pipeline,
          )) {
        return;
      }
      if (!_isCurrentRequest(request)) return;
      await _startMpvFallback(
        request: request,
        file: file,
        pipeline: pipeline,
      );
    } catch (error) {
      if (!_isCurrentRequest(request)) return;
      setState(() => _error = '$error');
    }
  }

  Future<void> _startMpvFallback({
    required int request,
    required File file,
    required Anime4kPipeline pipeline,
  }) async {
    final player = Player();
    final controller = VideoController(player);
    if (!_isCurrentRequest(request)) {
      await player.dispose();
      return;
    }
    _player = player;
    _controller = controller;
    setState(() {
      _capturingMetal = false;
      _processedPreviewBytes = null;
      _ready = false;
    });

    try {
      final platform = player.platform;
      if (platform is! NativePlayer) {
        throw StateError('Anime4K requires the native mpv player.');
      }

      await platform.setProperty('image-display-duration', 'inf');
      await platform.setProperty('loop-file', 'inf');
      await platform.setProperty('mute', 'yes');
      await player.open(Media(file.path), play: true);

      String currentVo = '';
      if (!pipeline.isEmpty) {
        currentVo = (await platform.getProperty('current-vo')).trim();
        if (!anime4kGpuRendererSupportsShaders(currentVo)) {
          throw StateError(
            'Anime4K GPU shaders are unavailable on this renderer '
            '(vo=$currentVo).',
          );
        }
      }

      await platform.setProperty('glsl-shaders', pipeline.value);
      final applied = (await platform.getProperty('glsl-shaders')).trim();
      if (pipeline.value.isNotEmpty && applied.isEmpty) {
        throw StateError('mpv did not accept the Anime4K shader chain.');
      }
      if (!pipeline.isEmpty) {
        final gpuDumbMode = (await platform.getProperty('gpu-dumb-mode'))
            .trim()
            .toLowerCase();
        if (gpuDumbMode == 'yes') {
          await platform.setProperty('glsl-shaders', '');
          throw StateError(
            'Anime4K GPU shaders are unavailable on this renderer '
            '(vo=$currentVo, gpu-dumb-mode=$gpuDumbMode).',
          );
        }
      }

      if (!_isCurrentRequest(request)) {
        await _disposeSpecificPreviewPlayer(player);
        return;
      }
      setState(() {
        _ready = true;
        _error = null;
      });
    } catch (_) {
      await _disposeSpecificPreviewPlayer(player);
      rethrow;
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

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final processedBytes = _processedPreviewBytes;
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
                              if (processedBytes != null && _ready)
                                ClipRect(
                                  clipper: _LeftOf(_split),
                                  child: Image.memory(
                                    processedBytes,
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                  ),
                                )
                              else if (controller != null &&
                                  (_ready || _capturingMetal))
                                ClipRect(
                                  clipper: _LeftOf(_split),
                                  child: RepaintBoundary(
                                    key: _metalCaptureKey,
                                    child: Video(
                                      controller: controller,
                                      fit: BoxFit.cover,
                                      controls: null,
                                    ),
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
