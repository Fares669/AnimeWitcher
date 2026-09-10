/// Keyboard shortcut arithmetic for the player.
///
/// The player's key handler is a long chain of focus, TV-remote and
/// back-button rules that only makes sense with a running engine underneath
/// it. The two calculations behind the newer shortcuts do not need any of
/// that, so they live here where they can be read on their own and tested.
library;

import 'package:flutter/services.dart';

/// The fraction of the episode a number key jumps to, or null for any other
/// key.
///
/// The convention every video player shares: 1 is a tenth of the way in, 5 is
/// halfway, 0 is the start. There is deliberately no key for the end — 9 stops
/// at nine tenths, because a key that skips the last of an episode would sit
/// next to the ones that do not.
double? seekFractionForKey(LogicalKeyboardKey key) => _digitKeys[key] == null
    ? null
    : _digitKeys[key]! / 10;

/// Built once at load rather than per keypress. It cannot be `const`:
/// [LogicalKeyboardKey] defines its own `==`, which a constant map may not
/// depend on.
final Map<LogicalKeyboardKey, int> _digitKeys = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.digit0: 0,
    LogicalKeyboardKey.digit1: 1,
    LogicalKeyboardKey.digit2: 2,
    LogicalKeyboardKey.digit3: 3,
    LogicalKeyboardKey.digit4: 4,
    LogicalKeyboardKey.digit5: 5,
    LogicalKeyboardKey.digit6: 6,
    LogicalKeyboardKey.digit7: 7,
    LogicalKeyboardKey.digit8: 8,
    LogicalKeyboardKey.digit9: 9,
    LogicalKeyboardKey.numpad0: 0,
    LogicalKeyboardKey.numpad1: 1,
    LogicalKeyboardKey.numpad2: 2,
    LogicalKeyboardKey.numpad3: 3,
    LogicalKeyboardKey.numpad4: 4,
    LogicalKeyboardKey.numpad5: 5,
    LogicalKeyboardKey.numpad6: 6,
    LogicalKeyboardKey.numpad7: 7,
    LogicalKeyboardKey.numpad8: 8,
    LogicalKeyboardKey.numpad9: 9,
};

/// The lowest speed the player will step down to.
const double minPlaybackSpeed = 0.25;

/// The step the `,` and `.` keys move by.
///
/// A quarter lands on every preset the speed sheet offers and on the slider's
/// own 0.05 grid, and it is coarse enough that one press is heard. All these
/// values are exact in binary, so stepping repeatedly does not drift.
const double playbackSpeedStep = 0.25;

/// The speed one step up or down from [current].
///
/// A speed dragged off the grid by the slider — 1.35, say — snaps to the grid
/// in the direction of travel rather than jumping past it: stepping up from
/// 1.35 gives 1.5, and stepping down gives 1.25. At either end the current
/// speed is returned unchanged, so holding the key does not wrap around.
double steppedPlaybackSpeed(
  double current, {
  required bool faster,
  required double maxSpeed,
}) {
  // The speed sheet caps its own slider the same way; a source that cannot be
  // sped up at all reports a maximum below the minimum, and then there is no
  // step to take.
  final ceiling = maxSpeed < 3.0 ? maxSpeed : 3.0;
  if (ceiling <= minPlaybackSpeed) return current;

  final steps = current / playbackSpeedStep;
  final target = faster ? steps.floor() + 1 : steps.ceil() - 1;
  final next = target * playbackSpeedStep;
  if (next < minPlaybackSpeed) {
    // Already at or below the floor: stay where we are rather than climbing
    // back up to it, which would make the slower key speed playback up.
    return current <= minPlaybackSpeed ? current : minPlaybackSpeed;
  }
  if (next > ceiling) {
    return current >= ceiling ? current : ceiling;
  }
  return next;
}

/// The label the speed toast shows: `1.5x`, not `1.50x`, and `1x`, not `1.00x`.
String playbackSpeedLabel(double speed) {
  final text = speed.toStringAsFixed(2);
  return '${text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')}x';
}
