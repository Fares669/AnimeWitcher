from pathlib import Path
import re

path = Path('lib/features/player/presentation/widgets/anime4k_sample_preview.dart')
text = path.read_text()

for needle in [
    "import 'dart:ui' as ui;\n",
    "import 'package:flutter/rendering.dart';\n",
    "import '../../data/anime4k_metal_bridge.dart';\n",
    "import '../../data/anime4k_metal_ffi.dart';\n",
    "import '../../data/anime4k_performance.dart';\n",
]:
    if needle not in text:
        raise SystemExit(f'missing expected import: {needle!r}')
    text = text.replace(needle, '', 1)

old_comment = (
    "/// Apple uses the same native Metal backend as playback, but only long enough\n"
    "/// to render and capture one processed frame. The encoded result is cached by\n"
    "/// mode, quality, effective backend, and shader pipeline hash, so reopening the\n"
    "/// settings does not keep a second renderer alive. Other platforms, or an\n"
    "/// unavailable Apple Metal backend, keep the existing mpv preview as fallback.\n"
)
new_comment = (
    "/// The preview renders one still through mpv's final video-output window,\n"
    "/// captures that processed result once, caches it by mode/quality/backend/hash,\n"
    "/// and disposes the renderer. This intentionally avoids rasterizing Flutter's\n"
    "/// external Texture, which can produce an all-black image on Apple devices.\n"
)
if old_comment not in text:
    raise SystemExit('preview documentation marker changed')
text = text.replace(old_comment, new_comment, 1)

if '  bool _capturingMetal = false;\n' not in text:
    raise SystemExit('capture state marker changed')
text = text.replace('  bool _capturingMetal = false;\n', '', 1)
if '\n  final GlobalKey _metalCaptureKey = GlobalKey();\n' not in text:
    raise SystemExit('capture key marker changed')
text = text.replace('\n  final GlobalKey _metalCaptureKey = GlobalKey();\n', '\n', 1)
text = text.replace('      _capturingMetal = false;\n', '')

method_start = text.index('  Future<Anime4kProcessingDimensions> _sampleDimensions')
start_method = text.index('  Future<void> _start() async {', method_start)
text = text[:method_start] + text[start_method:]

apple_block = """      if ((Platform.isIOS || Platform.isMacOS) &&
          await _startAppleMetalOneShot(
            request: request,
            file: file,
            pipeline: pipeline,
          )) {
        return;
      }
      if (!_isCurrentRequest(request)) return;
"""
if apple_block not in text:
    raise SystemExit('Apple Metal preview call block changed')
text = text.replace(apple_block, '      if (!_isCurrentRequest(request)) return;\n', 1)

fallback_start = text.index('  Future<void> _startMpvFallback({')
fallback_end = text.index(
    '  /// Copies the bundled sample somewhere mpv can open by path.',
    fallback_start,
)
fallback = """  Future<void> _startMpvFallback({
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
    _controller = controller;
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
      await platform.command(['screenshot-to-file', captureFile.path, 'window']);

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

"""
text = text[:fallback_start] + fallback + text[fallback_end:]

if '    final controller = _controller;\n' not in text:
    raise SystemExit('build controller marker changed')
text = text.replace('    final controller = _controller;\n', '', 1)
live_start = text.find('                              else if (controller != null &&\n')
if live_start < 0:
    raise SystemExit('live external-texture preview block changed')
live_end = text.find('                              if (!_ready)', live_start)
if live_end < 0:
    raise SystemExit('preview loading marker changed')
text = text[:live_start] + text[live_end:]

for forbidden in [
    'RenderRepaintBoundary',
    'toImage(',
    '_metalCaptureKey',
    '_startAppleMetalOneShot(',
]:
    if forbidden in text:
        raise SystemExit(f'unsafe preview capture marker remains: {forbidden}')

path.write_text(text)
