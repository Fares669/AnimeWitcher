import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_auth_diagnostic_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'auth log persists only allowlisted event and numeric HTTP status',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'rift-auth-logs-',
      );
      try {
        final journal = AnimeRiftAuthDiagnosticLog(
          directory: () async => directory,
        );
        journal.record(
          const AnimeRiftAuthDiagnostic(
            event: AnimeRiftAuthEvent.registrationRejected,
            statusCode: 422,
          ),
        );
        journal.record(
          const AnimeRiftAuthDiagnostic(
            event: AnimeRiftAuthEvent.compatibilityAccepted,
          ),
        );
        await journal.flush();
        final file = File('${directory.path}/animerift_auth.jsonl');
        final raw = await file.readAsString();
        final lines = raw.trim().split('\n');
        expect(lines, hasLength(2));
        final rejection = jsonDecode(lines.first) as Map<String, dynamic>;
        expect(rejection.keys, containsAll(['time', 'event', 'httpStatus']));
        expect(rejection.keys, hasLength(3));
        expect(rejection['httpStatus'], 422);
        expect(rejection['event'], 'registrationRejected');
        expect(
          jsonDecode(lines.last),
          containsPair('event', 'compatibilityAccepted'),
        );
        expect(raw, isNot(contains('token')));
        expect(raw, isNot(contains('deviceId')));
        expect(raw, isNot(contains('code')));
        expect(raw, isNot(contains('://')));
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('diagnostics include safe rejection details but never arbitrary server data', () async {
    final directory = await Directory.systemTemp.createTemp(
      'rift-auth-detail-',
    );
    try {
      final journal = AnimeRiftAuthDiagnosticLog(
        directory: () async => directory,
      );
      journal.record(
        const AnimeRiftAuthDiagnostic(
          event: AnimeRiftAuthEvent.registrationFailed,
          statusCode: 403,
          knownReason: AnimeRiftServerReason.deviceSuspended,
          serverCode: 'DEVICE_SUSPENDED',
          responseKind: AnimeRiftResponseKind.json,
          edgeRejected: true,
          mode: AnimeRiftRegistrationMode.nativeIos,
          attempt: 1,
          durationMs: 124,
          cooldownSeconds: 600,
        ),
      );
      journal.record(
        const AnimeRiftAuthDiagnostic(
          event: AnimeRiftAuthEvent.registrationRejected,
          serverCode: 'Bearer very-private-token',
        ),
      );
      await journal.flush();
      final raw = await File('${directory.path}/animerift_auth.jsonl')
          .readAsString();
      final lines = raw.trim().split('\n').map(jsonDecode).toList();
      expect(lines[0], containsPair('serverCode', 'DEVICE_SUSPENDED'));
      expect(lines[0], containsPair('knownReason', 'deviceSuspended'));
      expect(lines[0], containsPair('responseKind', 'json'));
      expect(lines[0], containsPair('edgeRejected', true));
      expect(lines[0], containsPair('mode', 'nativeIos'));
      expect(lines[0], containsPair('durationMs', 124));
      expect(lines[0], containsPair('cooldownSeconds', 600));
      expect(lines[1], isNot(contains('serverCode')));
      expect(raw, isNot(contains('very-private')));
      expect(raw, isNot(contains('://')));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('device-session diagnostics store categories only, never private device details', () async {
    final directory = await Directory.systemTemp.createTemp(
      'rift-session-log-',
    );
    try {
      final journal = AnimeRiftAuthDiagnosticLog(
        directory: () async => directory,
      );
      journal.record(
        const AnimeRiftAuthDiagnostic(
          event: AnimeRiftAuthEvent.sessionIdentityChecked,
          nativeMode: AnimeRiftRegistrationMode.nativeIos,
          mode: AnimeRiftRegistrationMode.androidFallback,
          localModel: AnimeRiftDeviceModelKind.iphone,
          advertisedModel: AnimeRiftDeviceModelKind.pixel8Pro,
          deviceMismatch: true,
        ),
      );
      journal.record(
        const AnimeRiftAuthDiagnostic(
          event: AnimeRiftAuthEvent.serverSessionsChecked,
          serverSessionCount: 1,
          serverIphoneCount: 0,
          serverPixel8ProCount: 1,
          serverUnknownCount: 0,
        ),
      );
      await journal.flush();
      final raw = await File('${directory.path}/animerift_auth.jsonl')
          .readAsString();
      final entries = raw.trim().split('\n').map(jsonDecode).toList();
      expect(entries[0], containsPair('deviceMismatch', true));
      expect(entries[0], containsPair('advertisedModel', 'pixel8Pro'));
      expect(entries[1], containsPair('serverPixel8ProCount', 1));
      expect(raw, isNot(contains('deviceId')));
      expect(raw, isNot(contains('"sessionId":')));
      expect(raw, isNot(contains('private')));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('moves previous Application Support log into Documents/log', () async {
    final root = await Directory.systemTemp.createTemp('rift-auth-migrate-');
    final legacy = Directory(
      'ROOT/Library/Application Support/log'.replaceFirst('ROOT', root.path),
    );
    final documents = Directory(
      'ROOT/Documents/log'.replaceFirst('ROOT', root.path),
    );
    try {
      await legacy.create(recursive: true);
      final old = File(
        'LEGACY/animerift_auth.jsonl'.replaceFirst('LEGACY', legacy.path),
      );
      await old.writeAsString('{"event":"registrationRejected"}\n');
      final journal = AnimeRiftAuthDiagnosticLog(
        directory: () async => documents,
        legacyDirectory: () async => legacy,
      );
      journal.record(
        const AnimeRiftAuthDiagnostic(
          event: AnimeRiftAuthEvent.compatibilityAccepted,
        ),
      );
      await journal.flush();
      expect(await old.exists(), isFalse);
      final current = File(
        'DOCS/animerift_auth.jsonl'.replaceFirst('DOCS', documents.path),
      );
      final text = await current.readAsString();
      final entries = text.trim().split('\n').map(jsonDecode).toList();
      expect(entries, hasLength(2));
      expect(entries.first['event'], 'registrationRejected');
      expect(entries.last['event'], 'compatibilityAccepted');
      journal.record(
        const AnimeRiftAuthDiagnostic(
          event: AnimeRiftAuthEvent.codeSignInAccepted,
        ),
      );
      await journal.flush();
      final next = await current.readAsLines();
      expect(next, hasLength(3));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test(
    'migrates and combines old log with a preexisting Documents log',
    () async {
      final root = await Directory.systemTemp.createTemp('rift-auth-combine-');
      final legacy = Directory(
        'ROOT/Library/Application Support/log'.replaceFirst('ROOT', root.path),
      );
      final documents = Directory(
        'ROOT/Documents/log'.replaceFirst('ROOT', root.path),
      );
      try {
        await legacy.create(recursive: true);
        await documents.create(recursive: true);
        final old = File(
          'LEGACY/animerift_auth.jsonl'.replaceFirst('LEGACY', legacy.path),
        );
        final current = File(
          'DOCS/animerift_auth.jsonl'.replaceFirst('DOCS', documents.path),
        );
        await old.writeAsString('{"event":"registrationStart"}\n');
        await current.writeAsString('{"event":"registrationAccepted"}\n');
        final journal = AnimeRiftAuthDiagnosticLog(
          directory: () async => documents,
          legacyDirectory: () async => legacy,
        );
        journal.record(
          const AnimeRiftAuthDiagnostic(
            event: AnimeRiftAuthEvent.codeSignInStart,
          ),
        );
        await journal.flush();
        final entries = (await current.readAsLines())
            .map((line) => jsonDecode(line)['event'])
            .toList();
        expect(entries, [
          'registrationStart',
          'registrationAccepted',
          'codeSignInStart',
        ]);
        expect(await old.exists(), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('auth log failures do not prevent sign-in operations', () async {
    final journal = AnimeRiftAuthDiagnosticLog(
      directory: () async => throw const FileSystemException('unavailable'),
    );
    journal.record(
      const AnimeRiftAuthDiagnostic(
        event: AnimeRiftAuthEvent.codeSignInRejected,
        statusCode: 400,
      ),
    );
    await journal.flush();
  });
}
