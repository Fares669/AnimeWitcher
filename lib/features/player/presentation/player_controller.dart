import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../settings/presentation/player_settings_provider.dart';
import '../data/anime4k.dart';
import '../data/anime4k_color_signal.dart';
import '../data/anime4k_metal_bridge.dart';
import '../data/anime4k_metal_ffi.dart';
import '../data/anime4k_shader_library.dart';
import 'player_controller_base.dart' as base;

export 'player_controller_base.dart'
    hide PlayerController, playerControllerProvider;

/// Apple-specific safety wrapper around the established player.
///
/// The native Anime4K path remains SDR-only until HDR output is
/// validated end-to-end. HDR or ambiguous color metadata therefore
/// restores the exact resolved mpv GLSL pipeline before native Metal
/// can process a frame.
class PlayerController extends base.PlayerController {
  Anime4kMetalBridge? _anime4kMetalBridge;
  int _anime4kApplySerial = 0;

  bool get _isApplePlatform => Platform.isIOS || Platform.isMacOS;

  @override
  base.PlayerState build() {
    final initial = super.build();
    ref.listen(playerSettingsProvider, (previous, next) {
      final before = previous?.asData?.value;
      final after = next.asData?.value;
      if (!_anime4kSettingsChanged(before, after)) return;
      unawaited(applyAnime4kShaders());
    });
    return initial;
  }

  bool _anime4kSettingsChanged(PlayerSettings? previous, PlayerSettings? next) {
    if (identical(previous, next)) return false;
    if (previous == null || next == null) return previous != next;
    return previous.anime4kEnabled != next.anime4kEnabled ||
        previous.anime4kMode != next.anime4kMode ||
        previous.anime4kQuality != next.anime4kQuality ||
        previous.anime4kShaderDirectory != next.anime4kShaderDirectory;
  }

  Anime4kMetalBridge? _metalBridge() {
    final existing = _anime4kMetalBridge;
    if (existing != null) return existing;
    if (!_isApplePlatform) return null;
    final bindings = Anime4kMetalFfiBindings.tryCreate();
    if (bindings == null) return null;
    final bridge = Anime4kMetalBridge(bindings: bindings);
    _anime4kMetalBridge = bridge;
    return bridge;
  }

  Future<PlayerSettings?> _readAnime4kSettingsReady() async {
    final current = ref.read(playerSettingsProvider).asData?.value;
    if (current != null) return current;
    try {
      return await ref.read(playerSettingsProvider.future);
    } catch (_) {
      return null;
    }
  }

  bool _isCurrentAnime4kApply({
    required int applySerial,
    required int sourceSessionId,
  }) {
    return !isDisposed &&
        applySerial == _anime4kApplySerial &&
        currentState.sourceSessionId == sourceSessionId;
  }

  /// Opening a media item returns before mpv is guaranteed to have selected a
  /// GPU VO and decoded the first video's dimensions. Applying a saved Anime4K
  /// setting during that window used to clear the shader chain and never retry,
  /// which is why toggling the setting later inside the player appeared to fix
  /// it. Wait for the same concrete prerequisites the real apply path needs.
  Future<bool> _waitForAnime4kPlaybackReadiness(
    NativePlayer platform, {
    required int applySerial,
    required int sourceSessionId,
    int maxAttempts = 150,
    Duration retryDelay = const Duration(milliseconds: 100),
  }) async {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (!_isCurrentAnime4kApply(
        applySerial: applySerial,
        sourceSessionId: sourceSessionId,
      )) {
        return false;
      }

      String currentVo = '';
      num width = 0;
      num height = 0;
      try {
        currentVo = (await platform.getProperty('current-vo')).trim();
      } catch (_) {
        currentVo = '';
      }
      try {
        width = num.tryParse((await platform.getProperty('width')).trim()) ?? 0;
      } catch (_) {
        width = 0;
      }
      try {
        height = num.tryParse((await platform.getProperty('height')).trim()) ?? 0;
      } catch (_) {
        height = 0;
      }

      if (anime4kGpuRendererSupportsShaders(currentVo) &&
          width > 0 &&
          height > 0) {
        return true;
      }

      if (attempt + 1 < maxAttempts) {
        await Future<void>.delayed(retryDelay);
      }
    }
    return false;
  }

  Future<Anime4kColorSignal> _readAnime4kColorSignal(
    NativePlayer platform, {
    required int applySerial,
    required int sourceSessionId,
  }) {
    return waitForAnime4kColorSignal(
      isCancelled: () => !_isCurrentAnime4kApply(
        applySerial: applySerial,
        sourceSessionId: sourceSessionId,
      ),
      read: () async {
        String? gamma;
        String? colorSystem;

        try {
          gamma = (await platform.getProperty('video-params/gamma')).trim();
        } catch (_) {
          gamma = null;
        }
        try {
          colorSystem =
              (await platform.getProperty('video-params/colormatrix')).trim();
        } catch (_) {
          colorSystem = null;
        }

        return classifyAnime4kColorSignal(
          transfer: gamma,
          colorSystem: colorSystem,
        );
      },
    );
  }

  @override
  Future<void> applyAnime4kShaders() async {
    final applySerial = ++_anime4kApplySerial;
    final sourceSessionId = currentState.sourceSessionId;

    try {
      if (_isApplePlatform && !currentState.useExoPlayer) {
        final settings = await _readAnime4kSettingsReady();
        if (!_isCurrentAnime4kApply(
          applySerial: applySerial,
          sourceSessionId: sourceSessionId,
        )) {
          return;
        }

        final platform = player.platform;
        if (settings != null &&
            settings.anime4kEnabled &&
            settings.anime4kMode != Anime4kMode.off &&
            platform is NativePlayer) {
          final playbackReady = await _waitForAnime4kPlaybackReadiness(
            platform,
            applySerial: applySerial,
            sourceSessionId: sourceSessionId,
          );
          if (!_isCurrentAnime4kApply(
            applySerial: applySerial,
            sourceSessionId: sourceSessionId,
          )) {
            return;
          }
          if (!playbackReady) {
            await _applyResolvedMpvFallback(
              platform: platform,
              settings: settings,
            );
            return;
          }

          final colorSignal = await _readAnime4kColorSignal(
            platform,
            applySerial: applySerial,
            sourceSessionId: sourceSessionId,
          );
          if (!_isCurrentAnime4kApply(
            applySerial: applySerial,
            sourceSessionId: sourceSessionId,
          )) {
            return;
          }
          if (colorSignal != Anime4kColorSignal.sdr) {
            await _applyResolvedMpvFallback(
              platform: platform,
              settings: settings,
            );
            return;
          }
        }
      }

      if (!_isCurrentAnime4kApply(
        applySerial: applySerial,
        sourceSessionId: sourceSessionId,
      )) {
        return;
      }
      await super.applyAnime4kShaders();
    } catch (error) {
      // Anime4K is optional and settings can become available before
      // playback initialization. Never turn a reapply into a player
      // failure; the established mpv path remains authoritative.
      if (kDebugMode) {
        debugPrint('Anime4K setup skipped: $error');
      }
    }
  }

  Future<void> _applyResolvedMpvFallback({
    NativePlayer? platform,
    PlayerSettings? settings,
  }) async {
    final nativePlatform =
        platform ??
        (player.platform is NativePlayer
            ? player.platform as NativePlayer
            : null);
    if (nativePlatform == null) return;
    final resolvedSettings =
        settings ??
        ref.read(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    final pipeline = await ref
        .read(anime4kShaderLibraryProvider)
        .pipeline(
          mode: resolvedSettings.anime4kEnabled
              ? resolvedSettings.anime4kMode
              : Anime4kMode.off,
          quality: resolvedSettings.anime4kQuality,
          directory: resolvedSettings.anime4kShaderDirectory,
        );

    final metalBridge = _metalBridge();
    if (metalBridge != null) {
      try {
        final handle = await nativePlatform.handle;
        if (handle > 0) metalBridge.disable(handle: handle);
      } catch (_) {
        // The native backend is optional; continue with mpv fallback.
      }
    }

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
}

final playerControllerProvider =
    NotifierProvider.autoDispose<PlayerController, base.PlayerState>(
      PlayerController.new,
    );
