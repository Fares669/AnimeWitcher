import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';

import 'player_pip.dart';

class PlayerPlatformService {
  PlayerPlatformService({MethodChannel? pipChannel, bool? nativePip})
    : _pipChannel = pipChannel ?? PlayerPip.channel,
      _nativePip = nativePip;

  final MethodChannel _pipChannel;
  final bool? _nativePip;

  Future<double> getVolumeLevel() async {
    final value = await FlutterVolumeController.getVolume();
    if (value == null || !value.isFinite) {
      throw StateError('Device volume is unavailable');
    }
    return value.clamp(0.0, 1.0);
  }

  Future<double> setVolumeLevel(
    double value, {
    required Future<void> Function(double) setEngineVolume,
  }) async {
    if (!value.isFinite) throw ArgumentError.value(value, 'volume');
    final target = value.clamp(0.0, 1.0);
    // Keep one volume control: engine attenuation must not multiply OS volume.
    await setEngineVolume(1.0);
    await FlutterVolumeController.setVolume(target);
    // iOS applies MPVolumeView asynchronously; its listener reports the actual
    // level later. An immediate read here would return the previous value.
    return target;
  }

  Future<double> changeVolume(
    double step, {
    required Future<void> Function(double) setEngineVolume,
  }) async {
    if (!step.isFinite) throw ArgumentError.value(step, 'step');
    if (step == 0) return getVolumeLevel();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await setEngineVolume(1.0);
      // A fixed 5% increment rounds down to zero on 15-step Android outputs.
      if (step > 0) {
        await FlutterVolumeController.raiseVolume(null);
      } else {
        await FlutterVolumeController.lowerVolume(null);
      }
      return getVolumeLevel();
    }
    return setVolumeLevel(
      await getVolumeLevel() + step,
      setEngineVolume: setEngineVolume,
    );
  }

  bool get _usesNativePip {
    if (_nativePip != null) return _nativePip;
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.nativePip: $e');
      return false;
    }
  }

  Map<String, dynamic> _pipPayload({
    required bool isPlaying,
    bool? active,
    bool? enabled,
    int? width,
    int? height,
  }) {
    final aspect = PlayerPip.clampAspectRatio(width ?? 16, height ?? 9);
    return <String, dynamic>{
      'isPlaying': isPlaying,
      'width': aspect.$1,
      'height': aspect.$2,
      'active': ?active,
      'enabled': ?enabled,
    };
  }

  /// Enters Android system Picture-in-Picture.
  /// Returns `false` when unavailable (including iOS).
  Future<bool> enterPip({
    required bool isPlaying,
    int? width,
    int? height,
  }) async {
    if (!_usesNativePip) return false;
    try {
      final result = await _pipChannel.invokeMethod<bool>(
        'enterPip',
        _pipPayload(isPlaying: isPlaying, width: width, height: height),
      );
      return result ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('PIP Error: $e');
      return false;
    }
  }

  /// Keeps native PiP params in sync (auto-enter, aspect, session).
  /// Call while the player is open and with [active] false on dispose.
  Future<void> updatePipSession({
    required bool active,
    required bool enabled,
    required bool isPlaying,
    int? width,
    int? height,
  }) async {
    if (!_usesNativePip) return;
    try {
      await _pipChannel.invokeMethod<void>(
        'updatePip',
        _pipPayload(
          isPlaying: isPlaying,
          active: active,
          enabled: enabled,
          width: width,
          height: height,
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('PIP session error: $e');
    }
  }

  Future<bool> isPipAvailable() async {
    if (!_usesNativePip) return false;
    try {
      final result = await _pipChannel.invokeMethod<bool>('isPipAvailable');
      return result ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('PIP availability error: $e');
      return false;
    }
  }

  void toggleOrientation(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    if (orientation == Orientation.landscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  void updateOrientation(int? width, int? height) {
    try {
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) return;
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.updateOrientation: $e');
    }

    if (width != null && height != null && width > 0 && height > 0) {
      if (width >= height) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
      }
    }
  }

  Future<bool> toggleFullscreen() async {
    if (Platform.isAndroid || Platform.isIOS) return false;
    try {
      final isFull = await windowManager.isFullScreen();
      if (!isFull) {
        await windowManager.setFullScreen(true);
        return true;
      } else {
        await windowManager.setFullScreen(false);
        return false;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.toggleFullscreen: $e');
    }
    return false;
  }
}
