import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final mode in ['behavior', 'starvation']) {
    test(
      'native single-local-media open: $mode',
      () async {
        final temp = Directory.systemTemp.createTempSync('media-kit-open-');
        try {
          final config = File('.dart_tool/package_config.json').absolute;
          final packages =
              (jsonDecode(config.readAsStringSync())
                      as Map<String, dynamic>)['packages']
                  as List<dynamic>;
          final mediaKit = packages.cast<Map<String, dynamic>>().singleWhere(
            (entry) => entry['name'] == 'media_kit',
          );
          final root = Directory.fromUri(
            config.uri.resolve(mediaKit['rootUri'] as String),
          ).uri;
          final source = File.fromUri(
            root.resolve('lib/src/player/native/player/real.dart'),
          ).readAsStringSync();
          final open = source.substring(
            source.indexOf('  Future<void> open('),
            source.indexOf('  /// Stops the [Player].'),
          );
          final sanitize = source.substring(
            source.indexOf('  String _sanitizeUri('),
            source.indexOf('  /// Generated libmpv C API bindings.'),
          );
          // Execute the production methods, replacing only native FFI commands.
          final script = File('${temp.path}/check.dart');
          script.writeAsStringSync(
            File('test/support/media_kit_native_open_check.dart.template')
                .readAsStringSync()
                .replaceFirst('// PRODUCTION_OPEN', open)
                .replaceFirst('// PRODUCTION_SANITIZE', sanitize),
          );
          final environment = <String, String>{};
          if (mode == 'starvation') {
            final library = '${temp.path}/stalled_dns.so';
            final compile = await Process.run('cc', [
              '-shared',
              '-fPIC',
              '-o',
              library,
              'test/support/stalled_dns.c',
            ]);
            expect(compile.exitCode, 0, reason: '${compile.stderr}');
            environment['LD_PRELOAD'] = library;
          }
          final process = await Process.start('dart', [
            '--packages=${config.path}',
            script.path,
            mode,
          ], environment: environment);
          final output = process.stdout.transform(utf8.decoder).join();
          final errors = process.stderr.transform(utf8.decoder).join();
          try {
            final code = await process.exitCode.timeout(
              const Duration(seconds: 20),
            );
            expect(code, 0, reason: '${await output}\n${await errors}');
            expect(await output, contains('PASS:'));
          } finally {
            process.kill(ProcessSignal.sigkill);
          }
        } finally {
          temp.deleteSync(recursive: true);
        }
      },
      skip: mode == 'starvation' && !Platform.isLinux,
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}
