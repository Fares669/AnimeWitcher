import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Activates a focused player control once for a select, enter, or space press.
KeyEventResult handlePlayerActivationKey(
  KeyEvent event,
  VoidCallback activate,
) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.space) {
    activate();
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}
