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
