import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:screen_brightness/screen_brightness.dart';

import '../../settings/presentation/player_settings_provider.dart';

part 'player_gesture_handler.g.dart';

enum PlayerDragMode { none, vertical, horizontal }

@immutable
class PlayerGestureState {
  final PlayerGesture? currentGesture;
  final bool showOSD;
  final IconData osdIcon;
  final double? osdValue;
  final String osdLabel;
  final Alignment osdAlignment;
  final PlayerDragMode activeDragMode;
  final Duration? swipeSeekValue;
  final Duration? swipeSeekStartValue;
  final bool? swipeSeekForward;

  const PlayerGestureState({
    this.currentGesture,
    this.showOSD = false,
    this.osdIcon = Icons.settings,
    this.osdValue,
    this.osdLabel = "",
    this.osdAlignment = Alignment.center,
    this.activeDragMode = PlayerDragMode.none,
    this.swipeSeekValue,
    this.swipeSeekStartValue,
    this.swipeSeekForward,
  });

  static const Object _keep = Object();

  PlayerGestureState copyWith({
    PlayerGesture? currentGesture,
    bool? showOSD,
    IconData? osdIcon,
    Object? osdValue = _keep,
    String? osdLabel,
    Alignment? osdAlignment,
    PlayerDragMode? activeDragMode,
    Object? swipeSeekValue = _keep,
    Object? swipeSeekStartValue = _keep,
    Object? swipeSeekForward = _keep,
  }) {
    return PlayerGestureState(
      currentGesture: currentGesture ?? this.currentGesture,
      showOSD: showOSD ?? this.showOSD,
      osdIcon: osdIcon ?? this.osdIcon,
      osdValue: identical(osdValue, _keep)
          ? this.osdValue
          : osdValue as double?,
      osdLabel: osdLabel ?? this.osdLabel,
      osdAlignment: osdAlignment ?? this.osdAlignment,
      activeDragMode: activeDragMode ?? this.activeDragMode,
      swipeSeekValue: identical(swipeSeekValue, _keep)
          ? this.swipeSeekValue
          : swipeSeekValue as Duration?,
      swipeSeekStartValue: identical(swipeSeekStartValue, _keep)
          ? this.swipeSeekStartValue
          : swipeSeekStartValue as Duration?,
      swipeSeekForward: identical(swipeSeekForward, _keep)
          ? this.swipeSeekForward
          : swipeSeekForward as bool?,
    );
  }
}

@Riverpod(keepAlive: true)
class PlayerGestureHandler extends _$PlayerGestureHandler {
  // We will initialize these via a setup method since they depend on the specific player instance
  Future<PlayerSettings> Function()? getSettings;
  bool? isTv;
  bool? isDesktop;

  // State from player
  Duration Function()? getDuration;
  Duration Function()? getPosition;
  bool Function()? canSeek;
  double Function()? getMaxVolumeLevel;

  // Callbacks to interact with UI
  VoidCallback? onInteraction;
  VoidCallback? onHideControls;
  Future<void> Function(Duration)? onSeekRelative;
  Future<void> Function(Duration)? onSeekTo;
  Future<double> Function()? getVolumeLevel;
  Future<double> Function(double value)? setVolumeLevel;
  Future<double> Function(double step)? onVolumeChange;
  Future<double> Function()? toggleMuteLevel;
  void Function(bool isLeft, Offset tapPos, int seekSeconds)?
  onDoubleTapAnimationStart;

  double _boostLevel = 1.0;
  Timer? _osdTimer;
  int _deviceSession = 0;
  int _dragSerial = 0;
  double? _deviceVolume;
  bool _writingLevel = false;
  (PlayerGesture, double)? _pendingLevel;

  bool get supportsVolumeBoost =>
      getMaxVolumeLevel?.call() != null && getMaxVolumeLevel!() > 1.0;

  @override
  PlayerGestureState build() {
    ref.onDispose(() {
      _deviceSession++;
      _pendingLevel = null;
      _osdTimer?.cancel();
    });
    return const PlayerGestureState();
  }

  int init({
    required Future<PlayerSettings> Function() getSettings,
    required bool isTv,
    required bool isDesktop,
    required Duration Function() getDuration,
    required Duration Function() getPosition,
    required bool Function() canSeek,
    required double Function() getMaxVolumeLevel,
    required VoidCallback onInteraction,
    required VoidCallback onHideControls,
    required Future<void> Function(Duration) onSeekRelative,
    required Future<void> Function(Duration) onSeekTo,
    required Future<double> Function() getVolumeLevel,
    required Future<double> Function(double value) setVolumeLevel,
    required Future<double> Function(double step) onVolumeChange,
    required Future<double> Function() toggleMuteLevel,
    required void Function(bool isLeft, Offset tapPos, int seekSeconds)
    onDoubleTapAnimationStart,
  }) {
    _deviceSession++;
    _dragSerial++;
    _writingLevel = false;
    _pendingLevel = null;
    this.getSettings = getSettings;
    this.isTv = isTv;
    this.isDesktop = isDesktop;
    this.getDuration = getDuration;
    this.getPosition = getPosition;
    this.canSeek = canSeek;
    this.getMaxVolumeLevel = getMaxVolumeLevel;
    this.onInteraction = onInteraction;
    this.onHideControls = onHideControls;
    this.onSeekRelative = onSeekRelative;
    this.onSeekTo = onSeekTo;
    this.getVolumeLevel = getVolumeLevel;
    this.setVolumeLevel = setVolumeLevel;
    this.onVolumeChange = onVolumeChange;
    this.toggleMuteLevel = toggleMuteLevel;
    this.onDoubleTapAnimationStart = onDoubleTapAnimationStart;
    return _deviceSession;
  }

  void detachDeviceControls({int? session}) {
    if (session != null && session != _deviceSession) return;
    _deviceSession++;
    _dragSerial++;
    _writingLevel = false;
    _pendingLevel = null;
    _osdTimer?.cancel();
    final detachedSession = _deviceSession;
    Future.microtask(() {
      if (ref.mounted && detachedSession == _deviceSession) {
        state = const PlayerGestureState();
      }
    });
  }

  void syncDeviceVolume(double value) {
    if (!value.isFinite) return;
    _deviceVolume = value.clamp(0.0, 1.0);
    if (state.activeDragMode == PlayerDragMode.vertical) return;
    _showVolumeOsd(_deviceVolume!);
  }

  void syncDeviceBrightness(double value) {
    if (!value.isFinite ||
        !state.showOSD ||
        state.osdLabel != 'Brightness' ||
        state.activeDragMode == PlayerDragMode.vertical) {
      return;
    }
    state = state.copyWith(osdValue: value.clamp(0.0, 1.0));
  }

  Future<void> _writeDeviceLevel(PlayerGesture gesture, double value) async {
    _pendingLevel = (gesture, value);
    if (_writingLevel) return;
    _writingLevel = true;
    final session = _deviceSession;
    var writingGesture = gesture;
    try {
      while (_pendingLevel != null && session == _deviceSession) {
        final (type, target) = _pendingLevel!;
        writingGesture = type;
        _pendingLevel = null;
        if (type == PlayerGesture.brightness) {
          await ScreenBrightness().setSystemScreenBrightness(target);
        } else {
          await setVolumeLevel?.call(target);
        }
      }
      if (session == _deviceSession &&
          writingGesture == PlayerGesture.volume &&
          state.activeDragMode == PlayerDragMode.none &&
          _deviceVolume != null) {
        _showVolumeOsd(_deviceVolume!);
      }
    } catch (error) {
      if (session != _deviceSession) return;
      _pendingLevel = null;
      state = state.copyWith(activeDragMode: PlayerDragMode.none);
      var message = writingGesture == PlayerGesture.brightness
          ? 'تعذّر تغيير سطوع الجهاز'
          : 'تعذّر تغيير صوت الجهاز';
      if (writingGesture == PlayerGesture.brightness &&
          error is PlatformException) {
        try {
          if (!await ScreenBrightness().canChangeSystemBrightness) {
            message =
                'اسمح بتعديل إعدادات النظام، ثم اسحب لتغيير السطوع مجددًا';
          }
        } catch (_) {
          // An unsupported platform still shows the original failure.
        }
      }
      if (session == _deviceSession) showToast(message, Icons.error_outline);
    } finally {
      if (session == _deviceSession) _writingLevel = false;
    }
  }

  void _triggerOSDTimer() {
    _osdTimer?.cancel();
    _osdTimer = Timer(const Duration(seconds: 1), () {
      state = state.copyWith(showOSD: false);
    });
  }

  void dismissOSD() {
    state = state.copyWith(showOSD: false);
  }

  void showToast(String message, IconData icon) {
    state = state.copyWith(
      showOSD: true,
      osdIcon: icon,
      osdLabel: message,
      osdValue: null,
      osdAlignment: Alignment.bottomCenter,
    );

    _osdTimer?.cancel();
    _osdTimer = Timer(const Duration(seconds: 2), () {
      state = state.copyWith(showOSD: false);
    });
  }

  // Pixels from each edge that are reserved for system gestures.
  static const double _edgeExclusionHorizontal = 48.0; // left/right
  static const double _edgeExclusionTop = 48.0; // top

  Future<void> handleDragStart(
    DragStartDetails details,
    double screenWidth,
    double screenHeight,
  ) async {
    if ((isTv ?? false) || (isDesktop ?? false)) return;
    if (state.activeDragMode == PlayerDragMode.horizontal) return;

    final x = details.globalPosition.dx;
    final y = details.globalPosition.dy;

    if (x < _edgeExclusionHorizontal ||
        x > screenWidth - _edgeExclusionHorizontal ||
        y < _edgeExclusionTop) {
      return;
    }

    final isLeftHalf = x < screenWidth / 2;
    final type = isLeftHalf ? PlayerGesture.brightness : PlayerGesture.volume;
    final alignment = isLeftHalf
        ? Alignment.centerRight
        : Alignment.centerLeft; // Opposite side

    final session = _deviceSession;
    final drag = ++_dragSerial;
    double startVal;
    try {
      if (type == PlayerGesture.brightness) {
        // Clear a reader/older-player override before following device brightness.
        await ScreenBrightness().resetApplicationScreenBrightness();
        startVal = await ScreenBrightness().system;
      } else {
        if (getVolumeLevel == null) return;
        startVal = await getVolumeLevel!();
        _deviceVolume = startVal;
      }
    } catch (_) {
      if (session == _deviceSession) {
        showToast('تعذّر قراءة مستوى الجهاز', Icons.error_outline);
      }
      return;
    }
    if (session != _deviceSession || drag != _dragSerial) return;

    state = state.copyWith(
      activeDragMode: PlayerDragMode.vertical,
      currentGesture: type,
      showOSD: true,
      osdIcon: _getIconForValue(type, startVal),
      osdValue: startVal,
      osdLabel: type == PlayerGesture.brightness ? "Brightness" : "Volume",
      osdAlignment: alignment,
      swipeSeekValue: null,
      swipeSeekStartValue: null,
      swipeSeekForward: null,
    );

    _osdTimer?.cancel();
  }

  void handleDragUpdate(DragUpdateDetails details) {
    if (state.activeDragMode != PlayerDragMode.vertical) return;
    if (state.currentGesture == null ||
        state.currentGesture == PlayerGesture.none) {
      return;
    }

    final delta = -(details.primaryDelta ?? 0) / 300;
    if (delta == 0) return;

    final newVal = ((state.osdValue ?? 0.0) + delta).clamp(0.0, 1.0);
    final type = state.currentGesture!;
    state = state.copyWith(
      osdValue: newVal,
      osdIcon: _getIconForValue(type, newVal),
      osdLabel: type == PlayerGesture.brightness ? 'Brightness' : 'Volume',
    );
    unawaited(_writeDeviceLevel(type, newVal));
  }

  void handleDragEnd(DragEndDetails details) {
    _dragSerial++;
    if (state.activeDragMode != PlayerDragMode.vertical) return;
    final wasVolume = state.currentGesture == PlayerGesture.volume;
    state = state.copyWith(
      activeDragMode: PlayerDragMode.none,
      currentGesture: null,
    );
    if (wasVolume && !_writingLevel && _deviceVolume != null) {
      _showVolumeOsd(_deviceVolume!);
    }
    _triggerOSDTimer();
  }

  Future<void> handleHorizontalDragStart(
    DragStartDetails details,
    bool isControlsVisible,
    double screenWidth,
    double screenHeight,
    double bottomPadding,
  ) async {
    if (state.activeDragMode == PlayerDragMode.vertical) return;
    if (getDuration == null ||
        getDuration!() == Duration.zero ||
        canSeek == null ||
        !canSeek!()) {
      return;
    }

    if ((isTv ?? false) || (isDesktop ?? false)) return;

    final x = details.globalPosition.dx;
    if (x < _edgeExclusionHorizontal ||
        x > screenWidth - _edgeExclusionHorizontal) {
      return;
    }

    if (isControlsVisible) {
      if (details.globalPosition.dy > (screenHeight - 56 - bottomPadding)) {
        return;
      }
    }

    final startPosition = getPosition?.call() ?? Duration.zero;
    state = state.copyWith(
      activeDragMode: PlayerDragMode.horizontal,
      currentGesture: null,
      showOSD: false,
      osdValue: null,
      swipeSeekValue: startPosition,
      swipeSeekStartValue: startPosition,
      swipeSeekForward: null,
    );
  }

  void handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (state.activeDragMode != PlayerDragMode.horizontal) return;
    if (state.swipeSeekValue == null) return;

    final delta = details.primaryDelta ?? 0;
    final newMs = (state.swipeSeekValue!.inMilliseconds + (delta * 200))
        .toInt();
    final clamped = newMs.clamp(0, getDuration?.call().inMilliseconds ?? 0);

    state = state.copyWith(
      swipeSeekValue: Duration(milliseconds: clamped),
      swipeSeekForward: delta == 0 ? state.swipeSeekForward : delta > 0,
    );
  }

  void handleHorizontalDragEnd(DragEndDetails details) {
    if (state.activeDragMode != PlayerDragMode.horizontal) return;
    if (state.swipeSeekValue == null) return;
    final target = state.swipeSeekValue!;
    state = state.copyWith(
      activeDragMode: PlayerDragMode.none,
      swipeSeekValue: null,
      swipeSeekStartValue: null,
      swipeSeekForward: null,
    );
    unawaited(onSeekTo?.call(target) ?? Future.value());
  }

  Future<void> handleDoubleTap(Offset tapPosition, double screenWidth) async {
    if (getDuration?.call() == Duration.zero || getSettings == null) return;

    final settings = await getSettings!();
    final isLeft = tapPosition.dx < screenWidth / 2;
    final seconds = settings.seekDuration;

    onDoubleTapAnimationStart?.call(isLeft, tapPosition, seconds);

    if (isLeft) {
      unawaited(
        onSeekRelative?.call(Duration(seconds: -seconds)) ?? Future.value(),
      );
    } else {
      unawaited(
        onSeekRelative?.call(Duration(seconds: seconds)) ?? Future.value(),
      );
    }
  }

  Future<void> toggleMute() async {
    final session = _deviceSession;
    try {
      final value = await toggleMuteLevel?.call();
      if (value == null || session != _deviceSession) return;
      _showVolumeOsd(value);
    } catch (_) {
      if (session == _deviceSession) {
        showToast('تعذّر تغيير صوت الجهاز', Icons.error_outline);
      }
    }
  }

  Future<void> changeVolume(double step) async {
    final session = _deviceSession;
    try {
      final value = await onVolumeChange?.call(step);
      if (value == null || session != _deviceSession) return;
      _showVolumeOsd(value);
    } catch (_) {
      if (session == _deviceSession) {
        showToast('تعذّر تغيير صوت الجهاز', Icons.error_outline);
      }
    }
  }

  void _showVolumeOsd(double value) {
    _boostLevel = supportsVolumeBoost && value > 1.0 ? value : 1.0;
    final double effectiveValue = (supportsVolumeBoost && _boostLevel > 1.0)
        ? _boostLevel
        : value;
    final String label = "Volume ${(effectiveValue * 100).toInt()}%";

    state = state.copyWith(
      showOSD: true,
      osdIcon: _getIconForValue(PlayerGesture.volume, value),
      osdValue: effectiveValue,
      osdLabel: label,
    );
    _triggerOSDTimer();
  }

  IconData _getIconForValue(PlayerGesture type, double value) {
    if (type == PlayerGesture.brightness) {
      if (value <= 0.0) return Icons.brightness_low;
      if (value < 0.3) return Icons.brightness_low;
      if (value < 0.7) return Icons.brightness_medium;
      return Icons.brightness_high;
    } else if (type == PlayerGesture.volume) {
      if (value <= 0.0) return Icons.volume_off;
      if (value < 0.3) return Icons.volume_mute;
      if (value < 0.7) return Icons.volume_down;
      if (!supportsVolumeBoost || value <= 1.0) return Icons.volume_up;
      return Icons.campaign;
    }
    return Icons.settings;
  }
}
