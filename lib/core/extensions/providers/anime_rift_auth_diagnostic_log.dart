import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'anime_rift_api_client.dart' show AnimeRiftAuthDiagnostic;

/// Small, bounded, best-effort authentication diagnostic journal.
///
/// Accepts only sanitized diagnostic events, bounded server error identifiers
/// and known enums; never stores response bodies, tokens or device identifiers.
class AnimeRiftAuthDiagnosticLog {
  AnimeRiftAuthDiagnosticLog({
    Future<Directory> Function()? directory,
    Future<Directory> Function()? legacyDirectory,
  }) : _directory = directory ?? _defaultDirectory,
       _legacyDirectory =
           legacyDirectory ??
           (directory == null ? _defaultLegacyDirectory : null);

  final Future<Directory> Function() _directory;
  final Future<Directory> Function()? _legacyDirectory;
  Future<void> _pending = Future<void>.value();
  bool _migrationChecked = false;
  static const _fileName = 'animerift_auth.jsonl';
  static const _maxBytes = 256 * 1024;

  static String? _safeServerCode(String? code) {
    if (code == null || code.length < 3 || code.length > 64) return null;
    if (!RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(code) ||
        !code.contains('_') ||
        RegExp(r'TOKEN|PASSWORD|SECRET|API_KEY|JWT|BEARER|AUTHORIZATION')
            .hasMatch(code)) {
      return null;
    }
    return code;
  }

  static final AnimeRiftAuthDiagnosticLog shared = AnimeRiftAuthDiagnosticLog();

  static Future<Directory> _defaultDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    return Directory('${base.path}${Platform.pathSeparator}log');
  }

  static Future<Directory> _defaultLegacyDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}log');
  }

  /// Migrate an existing login journal from Application Support to Documents,
  /// alongside Download V2 logs. A failed migration never deletes the old log.
  Future<void> _migrateIfNeeded(Directory destination) async {
    final legacyDirectory = _legacyDirectory;
    if (_migrationChecked || legacyDirectory == null) return;
    final legacy = await legacyDirectory();
    final oldFile = File('${legacy.path}${Platform.pathSeparator}$_fileName');
    if (!await oldFile.exists()) {
      _migrationChecked = true;
      return;
    }
    final newFile = File(
      '${destination.path}${Platform.pathSeparator}$_fileName',
    );
    final previous = await oldFile.readAsBytes();
    final current = await newFile.exists()
        ? await newFile.readAsBytes()
        : <int>[];
    var merged = <int>[...previous, ...current];
    // Retain complete recent JSONL records rather than splitting UTF-8 data.
    if (merged.length > _maxBytes - 1024) {
      final start = merged.length - (_maxBytes - 1024);
      final firstNewline = merged.indexOf(10, start);
      merged = firstNewline < 0 ? <int>[] : merged.sublist(firstNewline + 1);
    }
    final temporary = File('${newFile.path}.migration');
    await temporary.writeAsBytes(merged, flush: true);
    await temporary.rename(newFile.path);
    await oldFile.delete();
    _migrationChecked = true;
  }

  void record(AnimeRiftAuthDiagnostic diagnostic) {
    final serverCode = _safeServerCode(diagnostic.serverCode);
    final line = jsonEncode(<String, Object?>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'event': diagnostic.event.name,
      if (diagnostic.statusCode case final code?) 'httpStatus': code,
      if (diagnostic.failure case final failure?) 'failure': failure.name,
      if (diagnostic.knownReason case final reason?) 'knownReason': reason.name,
      if (serverCode != null) 'serverCode': serverCode,
      if (diagnostic.responseKind case final kind?) 'responseKind': kind.name,
      if (diagnostic.edgeRejected) 'edgeRejected': true,
      if (diagnostic.transportKind case final kind?) 'transportKind': kind.name,
      if (diagnostic.durationMs case final duration?) 'durationMs': duration,
      if (diagnostic.retryAfterSeconds case final retry?)
        'retryAfterSeconds': retry,
      if (diagnostic.mode case final mode?) 'mode': mode.name,
      if (diagnostic.attempt case final attempt?) 'attempt': attempt,
      if (diagnostic.cooldownSeconds case final cooldown?)
        'cooldownSeconds': cooldown,
      if (diagnostic.nativeMode case final native?) 'nativeMode': native.name,
      if (diagnostic.localModel case final model?) 'localModel': model.name,
      if (diagnostic.advertisedModel case final model?)
        'advertisedModel': model.name,
      if (diagnostic.deviceMismatch case final mismatch?)
        'deviceMismatch': mismatch,
      if (diagnostic.serverSessionCount case final count?)
        'serverSessionCount': count,
      if (diagnostic.serverIphoneCount case final count?)
        'serverIphoneCount': count,
      if (diagnostic.serverPixel8ProCount case final count?)
        'serverPixel8ProCount': count,
      if (diagnostic.serverUnknownCount case final count?)
        'serverUnknownCount': count,
    });
    _pending = _pending.then((_) async {
      try {
        final directory = await _directory();
        await directory.create(recursive: true);
        await _migrateIfNeeded(directory);
        final file = File(
          '${directory.path}${Platform.pathSeparator}$_fileName',
        );
        // Keep logs bounded on mobile. Old diagnostics are disposable.
        if (await file.exists() && await file.length() >= _maxBytes) {
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
