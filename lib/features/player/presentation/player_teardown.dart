import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../../../../core/logger/app_diagnostics.dart';

Future<void> stopPlayerBeforeExit(
  Player player, {
  int sourceSessionId = 0,
}) async {
  final clock = appDiagnostics.enabled ? (Stopwatch()..start()) : null;
  appDiagnostics.record(
    'player.teardown_stop.begin',
    fields: {'sourceSessionId': sourceSessionId},
  );
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
    appDiagnostics.record(
      'player.teardown_stop.end',
      fields: {
        'sourceSessionId': sourceSessionId,
        'elapsedMs': clock?.elapsedMilliseconds,
      },
    );
  }

  try {
    await stop().timeout(const Duration(seconds: 2));
  } on TimeoutException {
    appDiagnostics.record(
      'player.teardown_stop.timeout',
      fields: {
        'sourceSessionId': sourceSessionId,
        'elapsedMs': clock?.elapsedMilliseconds,
      },
    );
    if (kDebugMode) debugPrint('Player stop before exit timed out');
  } catch (error, stack) {
    appDiagnostics.recordError(
      'player.teardown_stop.error',
      error,
      stack,
      fields: {
        'sourceSessionId': sourceSessionId,
        'elapsedMs': clock?.elapsedMilliseconds,
      },
    );
    if (kDebugMode) debugPrint('Player stop before exit: $error');
  }
}

Future<void> disposePlayerAfterExit(
  Player player, {
  int sourceSessionId = 0,
}) async {
  final clock = appDiagnostics.enabled ? (Stopwatch()..start()) : null;
  appDiagnostics.record(
    'player.teardown_dispose.begin',
    fields: {'sourceSessionId': sourceSessionId},
  );
  try {
    final native = player.platform;
    if (native is NativePlayer) {
      // Waiting inside dispose's global lock would block every later player.
      await native.waitForPlayerInitialization;
      await native.waitForVideoControllerInitializationIfAttached;
    }
    await player.dispose();
    appDiagnostics.record(
      'player.teardown_dispose.end',
      fields: {
        'sourceSessionId': sourceSessionId,
        'elapsedMs': clock?.elapsedMilliseconds,
      },
    );
  } catch (error, stack) {
    appDiagnostics.recordError(
      'player.teardown_dispose.error',
      error,
      stack,
      fields: {
        'sourceSessionId': sourceSessionId,
        'elapsedMs': clock?.elapsedMilliseconds,
      },
    );
    if (kDebugMode) debugPrint('Player dispose after exit: $error');
  }
}
