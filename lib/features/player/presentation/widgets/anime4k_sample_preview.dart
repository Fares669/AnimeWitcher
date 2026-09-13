import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:animewitcher/core/utils/localized_text.dart';

import '../../data/anime4k.dart';
import '../../data/anime4k_metal_ffi.dart';
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
/// Apple first sends the still image through the same native Metal runtime as
/// playback, writes one PNG, caches it, then tears the one-shot work down. mpv
/// remains a fail-safe fallback for unsupported/older builds. This avoids both
/// a continuously active second renderer and Flutter external-texture capture,
/// which can produce an all-black image on Apple devices.
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
  Uint8List? _processedPreviewBytes;
  String? _error;
  bool _ready = false;
  int _previewRequest = 0;

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
    unawaited(player?.dispose());
    super.dispose();
  }

  bool _isCurrentRequest(int request) => mounted && request == _previewRequest;

  Future<void> _disposeSpecificPreviewPlayer(Player player) async {
    if (identical(_player, player)) {
      _player = null;
    }
    await player.dispose();
  }

  Future<void> _disposePreviewPlayer() async {
    final player = _player;
    _player = null;
    if (player != null) await player.dispose();
  }

  Future<void> _start() async {
    final request = ++_previewRequest;
    await _disposePreviewPlayer();
    if (!_isCurrentRequest(request)) return;
    setState(() {
      _ready = false;
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

      await _startMpvFallback(request: request, file: file, pipeline: pipeline);
    } catch (error) {
      if (!_isCurrentRequest(request)) return;
      setState(() => _error = '$error');
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
        return true;
      }
      return false;
    }

    final shaderDirectory = widget.shaderDirectory.trim();
    final shaderPaths = pipeline.files
        .map((name) => p.join(shaderDirectory, name))
        .toList(growable: false);
    if (shaderPaths.isEmpty || pipeline.pipelineHash.isEmpty) return false;

    final directory = await getApplicationSupportDirectory();
    final outputFile = File(
      p.join(directory.path, 'anime4k_preview_metal_$request.png'),
    );
    try {
      if (await outputFile.exists()) await outputFile.delete();
      final inputPath = file.path;
      final outputPath = outputFile.path;
      final pipelineHash = pipeline.pipelineHash;

      // Native Metal compilation/processing can take noticeable time on the
      // first preview. Keep it off the UI isolate so the dialog and spinner
      // remain responsive while the one-shot command buffer completes.
      final succeeded = await Isolate.run(() {
        final bindings = Anime4kMetalFfiBindings.tryCreate();
        return bindings?.processPreview(
              inputPath: inputPath,
              outputPath: outputPath,
              shaderPaths: shaderPaths,
              pipelineHash: pipelineHash,
            ) ??
            false;
      });
      if (!succeeded || !_isCurrentRequest(request)) return false;
      if (!await outputFile.exists() || await outputFile.length() <= 0) {
        return false;
      }

      final bytes = await outputFile.readAsBytes();
      if (!_isCurrentRequest(request)) return false;
      _metalPreviewCache.store(key, bytes);
      setState(() {
        _processedPreviewBytes = bytes;
        _ready = true;
        _error = null;
      });
      return true;
    } catch (_) {
      // Fail closed to the existing mpv one-shot path. A preview failure must
      // never disable or mutate the real player backend.
      return false;
    } finally {
      try {
        if (await outputFile.exists()) await outputFile.delete();
      } catch (_) {
        // A stale preview file is harmless and uses a per-request filename.
      }
    }
  }

  Future<void> _startMpvFallback({
    required int request,
    required File file,
    required Anime4kPipeline pipeline,
  }) async {
    final key = Anime4kPreviewCacheKey(
      mode: widget.mode,
      quality: widget.quality,
      backend: Anime4kPreviewBackend.mpv,
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
      return;
    }

    final player = Player();
    final controller = VideoController(player);
    if (!_isCurrentRequest(request)) {
      await player.dispose();
      return;
    }
    _player = player;
    setState(() {
      _processedPreviewBytes = null;
      _ready = false;
    });

    File? captureFile;
    try {
      final platform = player.platform;
      if (platform is! NativePlayer) {
        throw StateError('Anime4K requires the native mpv player.');
      }

      await platform.setProperty('image-display-duration', 'inf');
      await platform.setProperty('mute', 'yes');
      await platform.setProperty('glsl-shaders', pipeline.value);
      await player.open(Media(file.path), play: true);
      await controller.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 5),
      );

      if (!_isCurrentRequest(request)) {
        await _disposeSpecificPreviewPlayer(player);
        return;
      }

      final currentVo = (await platform.getProperty('current-vo')).trim();
      if (!anime4kGpuRendererSupportsShaders(currentVo)) {
        throw StateError(
          'Anime4K GPU shaders are unavailable on this renderer '
          '(vo=$currentVo).',
        );
      }
      final applied = (await platform.getProperty('glsl-shaders')).trim();
      if (pipeline.value.isNotEmpty && applied.isEmpty) {
        throw StateError('mpv did not accept the Anime4K shader chain.');
      }
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

      final directory = await getApplicationSupportDirectory();
      captureFile = File(
        p.join(directory.path, 'anime4k_preview_capture_$request.png'),
      );
      if (await captureFile.exists()) {
        await captureFile.delete();
      }
      await platform.command(['screenshot-to-file', captureFile.path, 'video']);

      var captured = false;
      for (var attempt = 0; attempt < 40; attempt++) {
        if (await captureFile.exists() && await captureFile.length() > 0) {
          captured = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      if (!captured) {
        throw StateError('Anime4K preview screenshot was not produced.');
      }

      final bytes = await captureFile.readAsBytes();
      if (!_isCurrentRequest(request)) {
        await _disposeSpecificPreviewPlayer(player);
        return;
      }

      _metalPreviewCache.store(key, bytes);
      setState(() {
        _processedPreviewBytes = bytes;
        _ready = true;
        _error = null;
      });
      await _disposeSpecificPreviewPlayer(player);
    } catch (_) {
      await _disposeSpecificPreviewPlayer(player);
      rethrow;
    } finally {
      final fileToDelete = captureFile;
      if (fileToDelete != null) {
        try {
          if (await fileToDelete.exists()) await fileToDelete.delete();
        } catch (_) {
          // A stale preview file is harmless and will be overwritten next run.
        }
      }
    }
  }

  /// Copies the bundled sample somewhere native Metal/mpv can open by path.
  Future<File> _writeSample() async {
    final bytes = await rootBundle.load(Anime4kSamplePreview.assetPath);
    final directory = await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, 'anime4k_sample.jpg'));
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
    return file;
  }

  @override
  Widget build(BuildContext context) {
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
