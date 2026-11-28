import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// The Linux path provider launches xdg-user-dir synchronously for every
// Documents lookup. Share just the resolved path during a burst of startup
// and navigation records from the two diagnostic writers.
final _clock = Stopwatch()..start();
final _linuxDirectory = ShortLivedLogDirectory(
  resolve: _resolveLogDirectory,
  elapsed: () => _clock.elapsed,
);

/// Shared storage folder for both application and Download V2 diagnostics.
/// Individual log files remain separate inside this directory.
Future<Directory> applicationLogDirectory() =>
    Platform.isLinux ? _linuxDirectory.get() : _resolveLogDirectory();

Future<Directory> _resolveLogDirectory() async {
  final documents = await getApplicationDocumentsDirectory();
  return Directory(p.join(documents.path, 'log'));
}

/// Resolves the path only: callers still check/create the directory and
/// rotate/write every record. Refresh after a short fixed interval even if
/// access continues, so a moved Documents folder isn't pinned for a session.
@visibleForTesting
final class ShortLivedLogDirectory {
  ShortLivedLogDirectory({
    required Future<Directory> Function() resolve,
    required Duration Function() elapsed,
  }) : _resolve = resolve,
       _elapsed = elapsed;

  static const _reuseFor = Duration(seconds: 2);
  final Future<Directory> Function() _resolve;
  final Duration Function() _elapsed;
  Future<Directory>? _lookup;
  Duration? _expiresAt;

  Future<Directory> get() {
    final lookup = _lookup;
    final expiresAt = _expiresAt;
    if (lookup != null && (expiresAt == null || _elapsed() < expiresAt)) {
      return lookup;
    }
    _expiresAt = null;
    return _lookup = _load();
  }

  Future<Directory> _load() async {
    try {
      final directory = await Future<Directory>.sync(_resolve);
      _expiresAt = _elapsed() + _reuseFor;
      return directory;
    } catch (_) {
      // Never turn a temporary platform failure into a stuck path lookup.
      _lookup = null;
      rethrow;
    }
  }
}
