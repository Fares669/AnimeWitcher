import 'dart:async';

import 'package:flutter/foundation.dart';

/// Logs failures from an already-started sync without blocking local writes.
void reportBackgroundSyncFailure(Future<void> operation, String label) {
  unawaited(
    operation.catchError((Object error) {
      if (kDebugMode) {
        debugPrint('[AnimeWitcherAccount] Could not $label: $error');
      }
    }),
  );
}
