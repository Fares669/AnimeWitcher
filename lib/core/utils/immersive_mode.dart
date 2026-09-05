/// Hides the phone's own status bar while the app is open.
///
/// The app draws its own artwork to the top of the screen, and the clock,
/// battery and notification icons sit on top of it. This lets a viewer take
/// that strip back for the picture.
///
/// Desktop has no such bar, so this does nothing there.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show immutable, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Which phone the request is for. The two answer different calls.
enum ImmersivePlatform { android, ios }

/// Stands in for the host platform, for tests.
///
/// Everything here is a no-op off a phone, so without this a test on a
/// desktop machine can only watch it decline to do anything.
@visibleForTesting
ImmersivePlatform? debugImmersivePlatformOverride;

ImmersivePlatform? get _platform {
  if (debugImmersivePlatformOverride != null) {
    return debugImmersivePlatformOverride;
  }
  if (kIsWeb) return null;
  if (Platform.isIOS) return ImmersivePlatform.ios;
  if (Platform.isAndroid) return ImmersivePlatform.android;
  return null;
}

/// One request to the system, as a mode and the overlays that go with it.
@immutable
class ImmersiveStep {
  const ImmersiveStep(this.mode, {this.overlays});

  final SystemUiMode mode;
  final List<SystemUiOverlay>? overlays;

  @override
  bool operator ==(Object other) =>
      other is ImmersiveStep &&
      other.mode == mode &&
      _sameOverlays(other.overlays, overlays);

  static bool _sameOverlays(
    List<SystemUiOverlay>? a,
    List<SystemUiOverlay>? b,
  ) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(mode, Object.hashAll(overlays ?? const []));

  @override
  String toString() =>
      'ImmersiveStep($mode${overlays == null ? '' : ', $overlays'})';
}

/// What to ask the system for, in order.
///
/// The last step is the one that decides the outcome, so which call ends the
/// list matters more than which calls are in it:
///
///  * **iOS** understands only `manual`. Every other mode is sent over the
///    channel Android implements, so asking iOS for `immersiveSticky` — or
///    for edge-to-edge on the way back out — does nothing at all, and a bar
///    hidden by some other route is never asked to return. Naming the top
///    overlay shows the status bar; omitting it hides it.
///  * **Android** has two eras. Up to Android 14 the bars are governed by the
///    legacy overlay flags `manual` sets. From Android 15 the system enforces
///    edge-to-edge for an app targeting API 35, and from Android 16 it
///    ignores every mode except `edgeToEdge` outright — this app targets 36.
///    So the way back out asks both ways and ends on `edgeToEdge`, the one a
///    current phone honours; on an older phone the legacy call has already
///    done the work and the last step is a no-op.
///
/// Nothing here calls `restoreSystemUIOverlays`. That re-applies whatever
/// overlay state the embedder is holding, which after a spell of full screen
/// is the state being escaped from.
@visibleForTesting
List<ImmersiveStep> immersivePlan(bool enabled, ImmersivePlatform platform) {
  if (platform == ImmersivePlatform.ios) {
    return <ImmersiveStep>[
      ImmersiveStep(
        SystemUiMode.manual,
        overlays: enabled ? const <SystemUiOverlay>[] : SystemUiOverlay.values,
      ),
    ];
  }

  if (enabled) {
    return const <ImmersiveStep>[ImmersiveStep(SystemUiMode.immersiveSticky)];
  }

  return const <ImmersiveStep>[
    ImmersiveStep(SystemUiMode.manual, overlays: SystemUiOverlay.values),
    ImmersiveStep(SystemUiMode.edgeToEdge),
  ];
}

/// Applies [enabled] now.
void applyImmersiveFullScreen(bool enabled) {
  final platform = _platform;
  if (platform == null) return;
  unawaited(_apply(enabled, platform));
}

Future<void> _apply(bool enabled, ImmersivePlatform platform) async {
  for (final step in immersivePlan(enabled, platform)) {
    await SystemChrome.setEnabledSystemUIMode(
      step.mode,
      overlays: step.overlays,
    );
  }
}

/// The floor Android puts under changes to the system bars.
///
/// "On Android, the system UI cannot be changed until 1 second after the
/// previous change" — it is there so an app cannot permanently swallow the
/// navigation buttons, and it applies to honest requests too. A second
/// request sent inside that second is not queued, it is dropped, which is
/// what made the first attempt at this look like it did nothing.
@visibleForTesting
const Duration immersiveChangeFloor = Duration(milliseconds: 1100);

/// How long to keep watch after asking.
///
/// Long enough for several attempts once the floor is taken into account,
/// and over well before a viewer settles into whatever screen they landed on.
@visibleForTesting
const Duration immersiveHoldWindow = Duration(seconds: 6);

_ImmersiveHold? _currentHold;

/// Applies [enabled] and holds it while the app settles.
///
/// Leaving the player puts the orientation back, and a window that
/// reconfigures for a new orientation comes back with the system bars in
/// their default state — so a full-screen choice can be honoured and then
/// undone a moment later, which is how turning the setting on and closing an
/// episode gave the status bar back.
///
/// Asking again immediately does not help: that second request lands inside
/// Android's one-second floor and is dropped. So this waits out the floor,
/// and listens for both the window changing shape and the system reporting
/// the bars visible again — the second of which is the direct signal that
/// the request did not survive.
void holdImmersiveFullScreen(bool enabled) {
  applyImmersiveFullScreen(enabled);
  if (_platform == null) return;

  _currentHold?.stop();
  // Nothing to defend when the bars are meant to be visible: that is the
  // state everything else in the system is trying to get back to anyway.
  if (!enabled) {
    _currentHold = null;
    return;
  }
  _currentHold = _ImmersiveHold()..start();
}

/// Drops any hold in progress, so the next request is the last word.
@visibleForTesting
void cancelImmersiveHold() {
  _currentHold?.stop();
  _currentHold = null;
}

class _ImmersiveHold with WidgetsBindingObserver {
  Timer? _retry;
  Timer? _expiry;
  DateTime _lastSent = DateTime.now();
  bool _stopped = false;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    // The system saying the bars are visible again is the one signal that
    // means exactly what it says, whatever put them there.
    SystemChrome.setSystemUIChangeCallback((overlaysVisible) async {
      if (overlaysVisible) _reassert();
    });
    _expiry = Timer(immersiveHoldWindow, stop);
    // The relayout being waited for may raise neither signal, so try once on
    // the far side of the floor regardless.
    _scheduleRetry(immersiveChangeFloor);
  }

  @override
  void didChangeMetrics() => _reassert();

  void _reassert() {
    if (_stopped) return;
    final since = DateTime.now().difference(_lastSent);
    if (since >= immersiveChangeFloor) {
      _lastSent = DateTime.now();
      applyImmersiveFullScreen(true);
      // Something has just overwritten the choice once; it may do so again
      // while the screen behind is still settling.
      _scheduleRetry(immersiveChangeFloor);
      return;
    }
    // Too soon — Android would drop it. Wait out what is left of the floor.
    _scheduleRetry(immersiveChangeFloor - since);
  }

  void _scheduleRetry(Duration delay) {
    _retry?.cancel();
    _retry = Timer(delay, () {
      if (_stopped) return;
      _lastSent = DateTime.now();
      applyImmersiveFullScreen(true);
    });
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _retry?.cancel();
    _retry = null;
    _expiry?.cancel();
    _expiry = null;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(SystemChrome.setSystemUIChangeCallback(null));
    if (identical(_currentHold, this)) _currentHold = null;
  }
}
