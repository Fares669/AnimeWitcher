import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Remove the legacy AnimeRift authentication journal from both locations
/// used by earlier releases. Download V2 logs must never be affected.
Future<void> removeLegacyAnimeRiftAuthLogs({
  Future<Directory> Function()? documentsDirectory,
  Future<Directory> Function()? supportDirectory,
}) async {
  for (final resolve in [
    documentsDirectory ?? getApplicationDocumentsDirectory,
    supportDirectory ?? getApplicationSupportDirectory,
  ]) {
    try {
      final directory = await resolve();
      final file = File(
        '${directory.path}${Platform.pathSeparator}log'
        '${Platform.pathSeparator}animerift_auth.jsonl',
      );
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Log cleanup must never prevent the provider from starting.
    }
  }
}

bool _cleanupStarted = false;

/// Run once when the provider is instantiated, including after an app update.
void removeLegacyAnimeRiftAuthLogOnce() {
  if (_cleanupStarted) return;
  _cleanupStarted = true;
  unawaited(removeLegacyAnimeRiftAuthLogs());
}
