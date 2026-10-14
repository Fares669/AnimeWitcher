import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

Future<void> stopPlayerBeforeExit(Player player) async {
  Future<void> stop() async {
    final native = player.platform;
    if (native is NativePlayer) {
      await native.waitForPlayerInitialization;
      // Cancel a dead load without waiting behind media_kit's shared lock.
      await native.setProperty('mute', 'yes', waitForInitialization: false);
      await native.command(['stop'], waitForInitialization: false);
      await native.waitForVideoControllerInitializationIfAttached;
    }
    await player.stop();
  }

  try {
    await stop().timeout(const Duration(seconds: 2));
  } catch (error) {
    if (kDebugMode) debugPrint('Player stop before exit: $error');
  }
}

Future<void> disposePlayerAfterExit(Player player) async {
  try {
    final native = player.platform;
    if (native is NativePlayer) {
      // Waiting inside dispose's global lock would block every later player.
      await native.waitForPlayerInitialization;
      await native.waitForVideoControllerInitializationIfAttached;
    }
    await player.dispose();
  } catch (error) {
    if (kDebugMode) debugPrint('Player dispose after exit: $error');
  }
}
