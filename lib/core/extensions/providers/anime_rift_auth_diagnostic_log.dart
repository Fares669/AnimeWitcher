import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'anime_rift_api_client.dart' show AnimeRiftAuthDiagnostic;

/// Small, bounded, best-effort authentication diagnostic journal.
///
/// Accepts *only* sanitized diagnostic events (known enum, status number,
/// known failure enum). There is no entry point for URLs, codes, tokens,
/// arbitrary server replies, device identifiers or error.toString().
class AnimeRiftAuthDiagnosticLog {
  AnimeRiftAuthDiagnosticLog({Future<Directory> Function()? directory})
    : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;
  Future<void> _pending = Future<void>.value();

  static final AnimeRiftAuthDiagnosticLog shared = AnimeRiftAuthDiagnosticLog();

  static Future<Directory> _defaultDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}log');
  }

  void record(AnimeRiftAuthDiagnostic diagnostic) {
    final line = jsonEncode(<String, Object?>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'event': diagnostic.event.name,
      if (diagnostic.statusCode case final code?) 'httpStatus': code,
      if (diagnostic.failure case final failure?) 'failure': failure.name,
      if (diagnostic.knownReason case final reason?) 'knownReason': reason.name,
    });
    _pending = _pending.then((_) async {
      try {
        final directory = await _directory();
        await directory.create(recursive: true);
        final file = File(
          '${directory.path}${Platform.pathSeparator}animerift_auth.jsonl',
        );
        // Keep logs bounded on mobile. Old diagnostics are disposable.
        if (await file.exists() && await file.length() >= 256 * 1024) {
          await file.writeAsString('');
        }
        await file.writeAsString('$line\n', mode: FileMode.append);
      } catch (_) {
        // Never block a sign-in because the diagnostics filesystem is locked.
      }
    });
  }

  Future<void> flush() => _pending;
}
