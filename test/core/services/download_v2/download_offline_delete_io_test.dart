import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production offline deletion survives a saturated DNS pool',
    () async {
      final temp = Directory.systemTemp.createTempSync('offline-delete-dns-');
      try {
        final library = '${temp.path}/stalled_dns.so';
        final compile = await Process.run('cc', [
          '-shared',
          '-fPIC',
          '-o',
          library,
          'test/support/stalled_dns.c',
        ]);
        expect(
          compile.exitCode,
          0,
          reason: '${compile.stdout}\n${compile.stderr}',
        );
        final process = await Process.start(
          'flutter',
          [
            'test',
            '--no-pub',
            '--dart-define=ANIMEWITCHER_FIREBASE_API_KEY=test-api-key',
            'test/support/offline_download_delete_check.dart',
          ],
          environment: {'LD_PRELOAD': library},
        );
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        try {
          final code = await process.exitCode.timeout(
            const Duration(seconds: 90),
          );
          expect(code, 0, reason: '${await output}\n${await errors}');
          expect(
            await output,
            contains('PASS: downloaded episode deletion bypasses stalled DNS'),
          );
        } finally {
          process.kill(ProcessSignal.sigkill);
        }
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(seconds: 100)),
  );
}
