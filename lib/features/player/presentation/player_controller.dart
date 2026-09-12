import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import '../../settings/presentation/player_settings_provider.dart';
import '../data/anime4k.dart';
import '../data/anime4k_color_signal.dart';
import '../data/anime4k_eco_governor.dart';
import '../data/anime4k_metal_bridge.dart';
import '../data/anime4k_metal_ffi.dart';
import '../data/anime4k_performance.dart';
import '../data/anime4k_performance_log.dart';
import '../data/anime4k_shader_library.dart';
import 'player_controller_base.dart' as base;

export 'player_controller_base.dart'
    hide PlayerController, playerControllerProvider;

/// Publishes the most recent Apple Eco sample independently of player/dialog
/// lifetimes so settings can observe live diagnostics without polling or
/// creating another playback session.
class Anime4kDiagnosticsController
    extends Notifier<Anime4kPerformanceSnapshot?> {
  @override
  Anime4kPerformanceSnapshot? build() => null;

  void publish(Anime4kPerformanceSnapshot? snapshot) {
    state = snapshot;
  }
}

final anime4kDiagnosticsProvider =
    NotifierProvider<Anime4kDiagnosticsController, Anime4kPerformanceSnapshot?>(
      Anime4kDiagnosticsController.new,
    );

/// Adds the Apple Anime4K Eco runtime orchestration on top of the established
/// player implementation. Keeping the existing controller intact in
/// [player_controller_base.dart] makes the performance work narrowly scoped:
/// playback/source/recovery behavior remains unchanged while Eco owns only its
/// low-frequency Metal feedback loop and settings reapplication.
class PlayerController extends base.PlayerController {
  Timer? _anime4kEcoTimer;
  Anime4kEcoGovernor _anime4kEcoGovernor = Anime4kEcoGovernor();
  Anime4kMetalBridge? _anime4kEcoMetalBridge;
  int? _anime4kEcoHandle;
  Anime4kQuality? _anime4kEcoEffectiveQuality;
  Anime4kPerformanceSnapshot? _anime4kPerformanceSnapshot;
  late Anime4kDiagnosticsController _anime4kDiagnostics;
  late Anime4kPerformanceLog _anime4kPerformanceLog;
  bool _anime4kEcoSampleInFlight = false;
  bool _anime4kForceMpvFallback = false;
  String? _anime4kLastColorTransfer;
  String? _anime4kLastColorSystem;
  Anime4kColorSignal? _anime4kLastColorSignal;

  Anime4kPerformanceSnapshot? get anime4kPerformanceSnapshot =>
      _anime4kPerformanceSnapshot;

  bool get _isApplePlatform => Platform.isIOS || Platform.isMacOS;

  @override
  base.PlayerState build() {
    final initial = super.build();
    _anime4kDiagnostics = ref.read(anime4kDiagnosticsProvider.notifier);
    _anime4kPerformanceLog = ref.read(anime4kPerformanceLogProvider);

    ref.listen(playerSettingsProvider, (previous, next) {
      final before = previous?.asData?.value;
      final after = next.asData?.value;
      if (!_anime4kSettingsChanged(before, after)) return;

      // A user-visible setting change is an explicit retry boundary. Runtime
      // failure is sticky only until the viewer changes the requested setup.
      _anime4kForceMpvFallback = false;
      _anime4kEcoEffectiveQuality = null;
      _anime4kEcoGovernor = Anime4kEcoGovernor();
      _publishAnime4kPerformanceSnapshot(null);
      unawaited(applyAnime4kShaders());
    });

    ref.onDispose(_disableAnime4kMetal);
    return initial;
  }

  bool _anime4kSettingsChanged(
    PlayerSettings? previous,
    PlayerSettings? next,
  ) {
    if (identical(previous, next)) return false;
    if (previous == null || next == null) return previous != next;
    return previous.anime4kEnabled != next.anime4kEnabled ||
        previous.anime4kEcoEnabled != next.anime4kEcoEnabled ||
        previous.anime4kMode != next.anime4kMode ||
        previous.anime4kQuality != next.anime4kQuality ||
        previous.anime4kShaderDirectory != next.anime4kShaderDirectory;
  }

  Anime4kMetalBridge? _ecoMetalBridge() {
    final existing = _anime4kEcoMetalBridge;
    if (existing != null) return existing;
    if (!_isApplePlatform) return null;
    final bindings = Anime4kMetalFfiBindings.tryCreate();
    if (bindings == null) return null;
    final bridge = Anime4kMetalBridge(bindings: bindings);
    _anime4kEcoMetalBridge = bridge;
    return bridge;
  }

  Future<Anime4kColorSignal> _readAnime4kColorSignal(
    NativePlayer platform,
  ) async {
    String? gamma;
    String? colorSystem;

    // mpv can publish video metadata a few frames after open(). Use the same
    // bounded startup tolerance as the Metal dimension path, then fail closed
    // if the transfer is still ambiguous.
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        gamma = (await platform.getProperty('video-params/gamma')).trim();
      } catch (_) {
        gamma = null;
      }
      try {
        colorSystem = (await platform.getProperty('video-params/colormatrix'))
            .trim();
      } catch (_) {
        colorSystem = null;
      }

      _anime4kLastColorTransfer = gamma;
      _anime4kLastColorSystem = colorSystem;
      final signal = classifyAnime4kColorSignal(
        transfer: gamma,
        colorSystem: colorSystem,
      );
      _anime4kLastColorSignal = signal;
      if (signal != Anime4kColorSignal.unknown) return signal;
      if (attempt < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        if (isDisposed) return Anime4kColorSignal.unknown;
      }
    }
    return Anime4kColorSignal.unknown;
  }

  Future<String?> _readAnime4kPlayerBackend(NativePlayer platform) async {
    try {
      final backend = (await platform.getProperty('current-vo')).trim();
      return backend.isEmpty ? null : backend;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> applyAnime4kShaders() async {
    try {
      if (_anime4kForceMpvFallback && _isApplePlatform) {
        final fallbackSettings = ref.read(playerSettingsProvider).asData?.value;
        if (fallbackSettings != null) {
          unawaited(
            _anime4kPerformanceLog.recordRoute(
              backend: Anime4kBackend.mpvGlsl,
              mode: fallbackSettings.anime4kMode,
              requestedQuality: fallbackSettings.anime4kQuality,
              ecoEnabled: fallbackSettings.anime4kEcoEnabled,
              metalFxExperiment: _anime4kMetalFxExperimentEnabled,
              reason: 'runtime-fallback',
            ),
          );
        }
        await _applyResolvedMpvFallback();
        return;
      }

      // The native Apple path is intentionally SDR-only until HDR output is
      // validated end-to-end. Unknown metadata is treated like unsupported HDR
      // rather than risking silent clipping/tone shifts. This check happens
      // before base Metal configuration, so an HDR frame is never handed to
      // the native Anime4K pipeline first.
      if (_isApplePlatform && !currentState.useExoPlayer) {
        final settings = ref.read(playerSettingsProvider).asData?.value;
        final platform = player.platform;
        if (settings != null &&
            settings.anime4kEnabled &&
            settings.anime4kMode != Anime4kMode.off &&
            platform is NativePlayer) {
          final colorSignal = await _readAnime4kColorSignal(platform);
          if (isDisposed) return;
          final colorState = colorSignal == Anime4kColorSignal.sdr
              ? Anime4kNativeMetalState.ready
              : Anime4kNativeMetalState.unsupportedHdr;
          if (colorState == Anime4kNativeMetalState.unsupportedHdr) {
            unawaited(
              _anime4kPerformanceLog.recordRoute(
                backend: Anime4kBackend.mpvGlsl,
                mode: settings.anime4kMode,
                requestedQuality: settings.anime4kQuality,
                ecoEnabled: settings.anime4kEcoEnabled,
                metalFxExperiment: _anime4kMetalFxExperimentEnabled,
                colorSignal: colorSignal.name,
                reason: colorSignal == Anime4kColorSignal.hdr
                    ? 'hdr-fallback'
                    : 'unknown-color-fallback',
              ),
            );
            await _applyResolvedMpvFallback(platform: platform);
            return;
          }
        }
      }

      await super.applyAnime4kShaders();
      if (isDisposed) return;

      final settings = ref.read(playerSettingsProvider).asData?.value;
      if (settings != null) {
        await _recordAnime4kPostApplyRoute(settings);
      }
      if (!_isApplePlatform ||
          settings == null ||
          !settings.anime4kEnabled ||
          settings.anime4kMode == Anime4kMode.off ||
          settings.anime4kShaderDirectory.trim().isEmpty ||
          currentState.useExoPlayer) {
        await _stopAnime4kEco(clearNativeBypass: true);
        return;
      }

      final platform = player.platform;
      final metalBridge = _ecoMetalBridge();
      if (platform is! NativePlayer || metalBridge == null) {
        await _stopAnime4kEco(clearNativeBypass: false);
        return;
      }

      final handle = await platform.handle;
      if (handle <= 0 ||
          metalBridge.status(handle: handle) != Anime4kNativeMetalState.ready) {
        await _stopAnime4kEco(clearNativeBypass: false);
        return;
      }

      _anime4kEcoHandle = handle;
      _anime4kEcoEffectiveQuality ??= settings.anime4kQuality;
      if (settings.anime4kEcoEnabled) {
        _anime4kEcoTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
          unawaited(_sampleAnime4kEco());
        });
      } else {
        _anime4kEcoTimer?.cancel();
        _anime4kEcoTimer = null;
      }
      // One immediate sample is useful in both Manual Metal and Eco. Only Eco
      // keeps the periodic feedback loop alive after this diagnostic sample.
      unawaited(_sampleAnime4kEco());
    } catch (error) {
      // Settings can become available before a playback session initializes.
      // Anime4K is optional, so this must never turn a provider update into a
      // playback failure.
      if (kDebugMode) {
        debugPrint('Anime4K Eco setup skipped: $error');
      }
    }
  }

  bool get _anime4kMetalFxExperimentEnabled {
    final settings = ref.read(playerSettingsProvider).asData?.value;
    return const bool.fromEnvironment('ANIME4K_METALFX_EXPERIMENT') &&
        (settings?.anime4kEcoEnabled ?? false);
  }

  Future<void> _recordAnime4kPostApplyRoute(PlayerSettings settings) async {
    if (!settings.anime4kEnabled || settings.anime4kMode == Anime4kMode.off) {
      return;
    }

    var backend = Anime4kBackend.mpvGlsl;
    String? metalState;
    String? playerBackend;
    final platform = player.platform;
    if (_isApplePlatform && platform is NativePlayer) {
      playerBackend = await _readAnime4kPlayerBackend(platform);
      try {
        final bridge = _ecoMetalBridge();
        if (bridge == null) {
          metalState = 'ffi-unavailable';
        } else {
          final handle = await platform.handle;
          if (handle <= 0) {
            metalState = 'invalid-handle';
          } else {
            final state = bridge.status(handle: handle);
            metalState = state.name;
            if (state == Anime4kNativeMetalState.ready) {
              backend = settings.anime4kEcoEnabled
                  ? Anime4kBackend.metalEco
                  : Anime4kBackend.metal;
            }
          }
        }
      } catch (_) {
        backend = Anime4kBackend.mpvGlsl;
        metalState ??= 'status-error';
      }
    }

    if (backend != Anime4kBackend.mpvGlsl) {
      unawaited(
        _anime4kPerformanceLog.recordRoute(
          backend: backend,
          mode: settings.anime4kMode,
          requestedQuality: settings.anime4kQuality,
          ecoEnabled: settings.anime4kEcoEnabled,
          metalFxExperiment: _anime4kMetalFxExperimentEnabled,
          colorSignal: _anime4kLastColorSignal?.name,
          colorTransfer: _anime4kLastColorTransfer,
          colorSystem: _anime4kLastColorSystem,
          metalState: metalState,
          playerBackend: playerBackend,
          reason: 'metal-ready',
        ),
      );
      return;
    }

    unawaited(
      _anime4kPerformanceLog.recordRoute(
        backend: backend,
        mode: settings.anime4kMode,
        requestedQuality: settings.anime4kQuality,
        ecoEnabled: settings.anime4kEcoEnabled,
        metalFxExperiment: _anime4kMetalFxExperimentEnabled,
        colorSignal: _anime4kLastColorSignal?.name,
        colorTransfer: _anime4kLastColorTransfer,
        colorSystem: _anime4kLastColorSystem,
        metalState: metalState,
        playerBackend: playerBackend,
        reason: 'post-apply',
      ),
    );
  }

  Future<void> _sampleAnime4kEco() async {
    if (_anime4kEcoSampleInFlight || isDisposed || !_isApplePlatform) return;
    _anime4kEcoSampleInFlight = true;
    try {
      final settings = ref.read(playerSettingsProvider).asData?.value;
      final platform = player.platform;
      final metalBridge = _anime4kEcoMetalBridge;
      final handle = _anime4kEcoHandle;
      if (settings == null ||
          !settings.anime4kEnabled ||
          platform is! NativePlayer ||
          metalBridge == null ||
          handle == null) {
        return;
      }

      final metalState = metalBridge.status(handle: handle);
      if (metalState != Anime4kNativeMetalState.ready) {
        // A runtime that was ready and later failed must not leave Anime4K in
        // a fake active state. Re-enter apply through the forced mpv route so
        // the exact resolved GLSL pipeline is restored for this session.
        _anime4kForceMpvFallback = true;
        await applyAnime4kShaders();
        return;
      }

      final telemetry = metalBridge.telemetry(handle: handle);
      if (telemetry == null) return;

      // The Apple render hook owns the authoritative processing surface. Use
      // its live configuration rather than mpv dwidth/dheight estimates so Eco
      // decisions and quality reconfiguration cannot resurrect oversized work
      // after resize, rotation, or a media_kit surface change.
      final source = Anime4kProcessingDimensions(
        width: telemetry.inputWidth,
        height: telemetry.inputHeight,
      );
      final output = Anime4kProcessingDimensions(
        width: telemetry.processingWidth,
        height: telemetry.processingHeight,
      );

      double? fps;
      try {
        fps = double.tryParse(
          (await platform.getProperty('estimated-vf-fps')).trim(),
        );
      } catch (_) {
        fps = null;
      }

      final decision = _anime4kEcoGovernor.sample(
        ecoEnabled: settings.anime4kEcoEnabled,
        mode: settings.anime4kMode,
        requestedQuality: settings.anime4kQuality,
        telemetry: telemetry,
        frameBudgetMs: anime4kFrameBudgetMsFromFps(fps),
        source: source,
        output: output,
      );
      _publishAnime4kPerformanceSnapshot(decision.snapshot);

      if (decision.plan.effectiveQuality != _anime4kEcoEffectiveQuality) {
        final configured = await _applyAnime4kEcoQuality(
          settings: settings,
          quality: decision.plan.effectiveQuality,
          platform: platform,
          metalBridge: metalBridge,
          handle: handle,
          source: source,
          output: output,
        );
        if (!configured) {
          _anime4kForceMpvFallback = true;
          await applyAnime4kShaders();
          return;
        }
        _anime4kEcoEffectiveQuality = decision.plan.effectiveQuality;
      }

      final bypassApplied = metalBridge.setBypass(
        handle: handle,
        bypass: decision.plan.bypass,
      );
      if (!bypassApplied) {
        // setBypass is a safety control. If the active runtime cannot honor it,
        // fall back instead of claiming Eco protected the device when it did not.
        _anime4kForceMpvFallback = true;
        await applyAnime4kShaders();
      }
    } catch (error) {
      if (kDebugMode) debugPrint('Anime4K Eco sample failed: $error');
    } finally {
      _anime4kEcoSampleInFlight = false;
    }
  }

  void _publishAnime4kPerformanceSnapshot(
    Anime4kPerformanceSnapshot? snapshot,
  ) {
    _anime4kPerformanceSnapshot = snapshot;
    _anime4kDiagnostics.publish(snapshot);
    if (snapshot != null) {
      unawaited(
        _anime4kPerformanceLog.recordSnapshot(
          snapshot,
          metalFxExperiment: _anime4kMetalFxExperimentEnabled,
        ),
      );
    }
  }

  Future<bool> _applyAnime4kEcoQuality({
    required PlayerSettings settings,
    required Anime4kQuality quality,
    required NativePlayer platform,
    required Anime4kMetalBridge metalBridge,
    required int handle,
    required Anime4kProcessingDimensions source,
    required Anime4kProcessingDimensions output,
  }) async {
    final shaderDirectory = settings.anime4kShaderDirectory.trim();
    final pipeline = await ref
        .read(anime4kShaderLibraryProvider)
        .pipeline(
          mode: settings.anime4kMode,
          quality: quality,
          directory: shaderDirectory,
        );
    if (pipeline.isEmpty || shaderDirectory.isEmpty) return false;

    final shaderPaths = pipeline.files
        .map((name) => p.join(shaderDirectory, name))
        .toList(growable: false);
    final state = metalBridge.configure(
      handle: handle,
      shaderPaths: shaderPaths,
      pipelineHash: pipeline.pipelineHash,
      source: source,
      output: output,
    );
    if (state != Anime4kNativeMetalState.ready) return false;

    // Reassert the no-double-processing invariant after a quality reconfigure.
    await platform.setProperty('glsl-shaders', '');
    return true;
  }

  Future<void> _applyResolvedMpvFallback({NativePlayer? platform}) async {
    final nativePlatform = platform ??
        (player.platform is NativePlayer ? player.platform as NativePlayer : null);
    if (nativePlatform == null) return;
    final settings =
        ref.read(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    final pipeline = await ref
        .read(anime4kShaderLibraryProvider)
        .pipeline(
          mode: settings.anime4kEnabled
              ? settings.anime4kMode
              : Anime4kMode.off,
          quality: settings.anime4kQuality,
          directory: settings.anime4kShaderDirectory,
        );

    // Disable by the real per-player handle, not only the Eco-owned handle.
    // The base controller and this wrapper both speak to the same native C API,
    // so this also retires Metal left active by a previous SDR configuration.
    final metalBridge = _ecoMetalBridge();
    var handle = _anime4kEcoHandle;
    if (handle == null) {
      try {
        final resolvedHandle = await nativePlatform.handle;
        if (resolvedHandle > 0) handle = resolvedHandle;
      } catch (_) {
        handle = null;
      }
    }
    _anime4kEcoTimer?.cancel();
    _anime4kEcoTimer = null;
    if (metalBridge != null && handle != null) {
      metalBridge.disable(handle: handle);
    }
    _anime4kEcoHandle = null;
    _anime4kEcoEffectiveQuality = null;
    _publishAnime4kPerformanceSnapshot(null);

    if (pipeline.isEmpty) {
      await nativePlatform.setProperty('glsl-shaders', '');
      return;
    }

    String currentVo = '';
    try {
      currentVo = (await nativePlatform.getProperty('current-vo')).trim();
    } catch (_) {
      currentVo = '';
    }
    if (!anime4kGpuRendererSupportsShaders(currentVo)) {
      await nativePlatform.setProperty('glsl-shaders', '');
      return;
    }

    await nativePlatform.setProperty('glsl-shaders', pipeline.value);
    final applied = (await nativePlatform.getProperty('glsl-shaders')).trim();
    if (pipeline.value.isNotEmpty && applied.isEmpty) return;

    final gpuDumbMode = (await nativePlatform.getProperty('gpu-dumb-mode'))
        .trim()
        .toLowerCase();
    if (gpuDumbMode == 'yes') {
      await nativePlatform.setProperty('glsl-shaders', '');
    }
  }

  Future<void> _stopAnime4kEco({required bool clearNativeBypass}) async {
    _anime4kEcoTimer?.cancel();
    _anime4kEcoTimer = null;
    _anime4kEcoGovernor = Anime4kEcoGovernor();
    _anime4kEcoEffectiveQuality = null;
    _publishAnime4kPerformanceSnapshot(null);

    if (!clearNativeBypass) return;
    final metalBridge = _anime4kEcoMetalBridge;
    final handle = _anime4kEcoHandle;
    if (metalBridge != null && handle != null) {
      metalBridge.setBypass(handle: handle, bypass: false);
    }
  }

  void _disableAnime4kMetal() {
    _anime4kEcoTimer?.cancel();
    _anime4kEcoTimer = null;
    final metalBridge = _anime4kEcoMetalBridge;
    final handle = _anime4kEcoHandle;
    if (metalBridge != null && handle != null) {
      metalBridge.disable(handle: handle);
    }
    _anime4kEcoHandle = null;
    _anime4kEcoEffectiveQuality = null;
    _publishAnime4kPerformanceSnapshot(null);
    _anime4kEcoSampleInFlight = false;
  }

  @override
  void disposeController({Player? player}) {
    _disableAnime4kMetal();
    super.disposeController(player: player);
  }
}

final playerControllerProvider =
    NotifierProvider.autoDispose<PlayerController, base.PlayerState>(
      PlayerController.new,
    );
