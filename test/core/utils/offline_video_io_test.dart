import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'download verification and payload probing survive stalled DNS',
    () async {
      final temp = Directory.systemTemp.createTempSync('offline-video-io-');
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
          'dart',
          ['test/support/offline_video_io_check.dart', temp.path],
          environment: {'LD_PRELOAD': library},
        );
        final output = process.stdout.transform(utf8.decoder).join();
        final errors = process.stderr.transform(utf8.decoder).join();
        try {
          final code = await process.exitCode.timeout(
            const Duration(seconds: 20),
          );
          expect(code, 0, reason: '${await output}\n${await errors}');
          expect(
            await output,
            contains('PASS: offline video checks bypass stalled DNS'),
          );
        } finally {
          process.kill(ProcessSignal.sigkill);
        }
      } finally {
        temp.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
