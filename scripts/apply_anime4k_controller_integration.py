from pathlib import Path

path = Path('lib/features/player/presentation/player_controller.dart')
source = path.read_text()

imports_old = """import '../data/anime4k.dart';
import '../data/anime4k_shader_library.dart';
"""
imports_new = """import '../data/anime4k.dart';
import '../data/anime4k_shader_library.dart';
import '../data/anime4k_performance.dart';
import '../data/anime4k_metal_bridge.dart';
import '../data/anime4k_metal_ffi.dart';
"""
if imports_old not in source:
    raise SystemExit('Anime4K import marker changed')
source = source.replace(imports_old, imports_new, 1)

field_old = """  String _anime4kApplied = '';

  /// Hands mpv the Anime4K pipeline the settings ask for, or clears it.
"""
field_new = """  String _anime4kApplied = '';
  Anime4kMetalBridge? _anime4kMetalBridge;
  int? _anime4kMetalHandle;
  Anime4kProcessingDimensions? _anime4kProcessingDimensions;

  void _disableAnime4kMetal() {
    final bridge = _anime4kMetalBridge;
    final handle = _anime4kMetalHandle;
    if (bridge != null && handle != null) {
      bridge.disable(handle: handle);
    }
    _anime4kMetalHandle = null;
    _anime4kProcessingDimensions = null;
  }

  /// Hands the selected Anime4K pipeline to the platform backend, or clears it.
"""
if field_old not in source:
    raise SystemExit('Anime4K field marker changed')
source = source.replace(field_old, field_new, 1)

start = source.index("  /// Hands the selected Anime4K pipeline to the platform backend, or clears it.\n")
end = source.index("  Future<void> seekTo(Duration position, {bool fast = false}) async {\n", start)
replacement = r'''  /// Hands the selected Anime4K pipeline to the platform backend, or clears it.
  ///
  /// Apple media_kit playback prefers the native Metal renderer. Metal and
  /// mpv's `glsl-shaders` are mutually exclusive: a ready Metal runtime clears
  /// the mpv property, while any unavailable/failed Metal setup falls back to
  /// the exact same resolved GLSL pipeline. Non-Apple behavior is unchanged.
  Future<Anime4kProcessingDimensions?> _resolveAnime4kMetalDimensions(
    NativePlayer platform,
  ) async {
    Future<int?> positiveProperty(String name) async {
      try {
        final value = num.tryParse((await platform.getProperty(name)).trim());
        final rounded = value?.round();
        return rounded != null && rounded > 0 ? rounded : null;
      } catch (_) {
        return null;
      }
    }

    int? sourceWidth;
    int? sourceHeight;
    int? drawableWidth;
    int? drawableHeight;
    // mpv may expose dimensions a few frames after open(). Anime4K setup is
    // already unawaited by playback, so a short bounded retry avoids treating
    // normal decoder startup as permanent Metal unavailability.
    for (var attempt = 0; attempt < 5; attempt++) {
      sourceWidth = await positiveProperty('width');
      sourceHeight = await positiveProperty('height');
      drawableWidth = await positiveProperty('dwidth');
      drawableHeight = await positiveProperty('dheight');
      if (sourceWidth != null && sourceHeight != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (_isDisposed) return null;
    }
    if (sourceWidth == null || sourceHeight == null) return null;

    final resolved = resolveAnime4kProcessingDimensions(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      drawableWidth: drawableWidth ?? sourceWidth,
      drawableHeight: drawableHeight ?? sourceHeight,
      previous: _anime4kProcessingDimensions,
    );
    _anime4kProcessingDimensions = resolved;
    return resolved;
  }

  Anime4kMetalBridge? _appleAnime4kMetalBridge() {
    if (!Platform.isIOS && !Platform.isMacOS) return null;
    final existing = _anime4kMetalBridge;
    if (existing != null) return existing;
    final bindings = Anime4kMetalFfiBindings.tryCreate();
    if (bindings == null) return null;
    final bridge = Anime4kMetalBridge(bindings: bindings);
    _anime4kMetalBridge = bridge;
    return bridge;
  }

  /// Called when a file opens and again when the setting changes, so turning
  /// a mode on takes effect on what is already playing.
  Future<void> applyAnime4kShaders() async {
    if (_isDisposed) return;
    if (!anime4kAvailableOn(
      isNativePlatform:
          Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux ||
          Platform.isAndroid ||
          Platform.isIOS,
      usingAdaptiveBackend: state.useExoPlayer,
    )) {
      _disableAnime4kMetal();
      return;
    }
    final platform = _player.platform;
    if (platform is! NativePlayer) {
      _disableAnime4kMetal();
      return;
    }

    try {
      final settings = ref.read(playerSettingsProvider).asData?.value;
      final anime4kEnabled = settings?.anime4kEnabled ?? false;
      final shaderDirectory = settings?.anime4kShaderDirectory.trim() ?? '';
      final pipeline = await ref
          .read(anime4kShaderLibraryProvider)
          .pipeline(
            mode: anime4kEnabled
                ? (settings?.anime4kMode ?? Anime4kMode.off)
                : Anime4kMode.off,
            quality: settings?.anime4kQuality ?? Anime4kQuality.m,
            directory: shaderDirectory,
          );
      if (_isDisposed) return;

      final isApple = Platform.isIOS || Platform.isMacOS;
      var metalState = Anime4kNativeMetalState.unavailable;
      Anime4kMetalBridge? metalBridge;
      int? metalHandle;
      if (isApple && anime4kEnabled && !pipeline.isEmpty) {
        metalBridge = _appleAnime4kMetalBridge();
        if (metalBridge != null) {
          metalHandle = await platform.handle;
          final dimensions = await _resolveAnime4kMetalDimensions(platform);
          if (_isDisposed) return;
          if (dimensions != null && shaderDirectory.isNotEmpty) {
            final shaderPaths = pipeline.files
                .map((name) => p.join(shaderDirectory, name))
                .toList(growable: false);
            metalState = metalBridge.configure(
              handle: metalHandle,
              shaderPaths: shaderPaths,
              pipelineHash: pipeline.pipelineHash,
              source: Anime4kProcessingDimensions(
                width: dimensions.width,
                height: dimensions.height,
              ),
              output: dimensions,
            );
          }
        }
      }

      final route = resolveAnime4kBackendRoute(
        isApplePlatform: isApple,
        anime4kEnabled: anime4kEnabled,
        hasResolvedPipeline: !pipeline.isEmpty,
        metalState: metalState,
      );

      if (route.enableMetal && metalBridge != null && metalHandle != null) {
        // Never run both implementations for the same frame.
        await platform.setProperty('glsl-shaders', '');
        _anime4kApplied = '';
        _anime4kMetalHandle = metalHandle;
        if (kDebugMode) {
          debugPrint(
            'Anime4K: Metal ready for ${pipeline.files.length} shaders '
            'at ${_anime4kProcessingDimensions?.width}x'
            '${_anime4kProcessingDimensions?.height}',
          );
        }
        return;
      }

      // Metal is optional. A failed/unavailable setup must relinquish the
      // player before the exact same resolved pipeline is handed to mpv.
      if (metalBridge != null && metalHandle != null) {
        metalBridge.disable(handle: metalHandle);
      }
      _anime4kMetalHandle = null;
      if (!anime4kEnabled || pipeline.isEmpty) {
        _anime4kProcessingDimensions = null;
      }

      String currentVo = '';
      if (route.enableMpvShaders && !pipeline.isEmpty) {
        currentVo = (await platform.getProperty('current-vo')).trim();
        if (!anime4kGpuRendererSupportsShaders(currentVo)) {
          await platform.setProperty('glsl-shaders', '');
          _anime4kApplied = '';
          if (kDebugMode) {
            debugPrint(
              'Anime4K: GPU shader stage unavailable (vo="$currentVo")',
            );
          }
          return;
        }
      }

      final glslValue = route.enableMpvShaders ? pipeline.value : '';
      await platform.setProperty('glsl-shaders', glslValue);
      final applied = await platform.getProperty('glsl-shaders');
      _anime4kApplied = applied.trim();
      if (glslValue.isNotEmpty && _anime4kApplied.isEmpty) {
        if (kDebugMode) {
          debugPrint('Anime4K: mpv did not accept the shader chain');
        }
        return;
      }

      if (route.enableMpvShaders && !pipeline.isEmpty) {
        final gpuDumbMode = (await platform.getProperty('gpu-dumb-mode'))
            .trim()
            .toLowerCase();
        if (gpuDumbMode == 'yes') {
          await platform.setProperty('glsl-shaders', '');
          _anime4kApplied = '';
          if (kDebugMode) {
            debugPrint(
              'Anime4K: GPU shader stage unavailable '
              '(vo="$currentVo", gpu-dumb-mode="$gpuDumbMode")',
            );
          }
          return;
        }
      }
      if (kDebugMode) {
        debugPrint(
          'Anime4K: backend=${route.backend.name}, asked for '
          '${pipeline.files.length} shaders, mpv holds "$_anime4kApplied"'
          '${pipeline.missing.isEmpty ? '' : ', missing '
                    '${pipeline.missing.join(", ")}'}',
        );
      }
    } catch (e) {
      // Metal/GLSL setup is optional and must never take playback down.
      _disableAnime4kMetal();
      if (kDebugMode) debugPrint('Anime4K shaders not applied: $e');
    }
  }

'''
source = source[:start] + replacement + source[end:]

on_dispose_old = """    ref.onDispose(() {
      _isDisposed = true;
      ++_sourceSessionSerial;
"""
on_dispose_new = """    ref.onDispose(() {
      _isDisposed = true;
      _disableAnime4kMetal();
      ++_sourceSessionSerial;
"""
if on_dispose_old not in source:
    raise SystemExit('ref.onDispose marker changed')
source = source.replace(on_dispose_old, on_dispose_new, 1)

dispose_old = """    if (_isDisposed) return;
    _isDisposed = true;
    final closingSession = ++_sourceSessionSerial;
"""
dispose_new = """    if (_isDisposed) return;
    _isDisposed = true;
    _disableAnime4kMetal();
    final closingSession = ++_sourceSessionSerial;
"""
if dispose_old not in source:
    raise SystemExit('disposeController marker changed')
source = source.replace(dispose_old, dispose_new, 1)

path.write_text(source)
print('Anime4K controller integration applied')
