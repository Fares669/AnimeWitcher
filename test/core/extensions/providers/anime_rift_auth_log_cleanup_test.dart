import 'dart:io';

import 'package:animewitcher/core/extensions/providers/anime_rift_auth_log_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'removes only the legacy authentication logs in both locations',
    () async {
      final root = await Directory.systemTemp.createTemp('rift-cleanup-');
      try {
        final documents = Directory('${root.path}/Documents');
        final support = Directory('${root.path}/Application Support');
        for (final directory in [documents, support]) {
          final logDirectory = Directory('${directory.path}/log');
          await logDirectory.create(recursive: true);
          await File('${logDirectory.path}/animerift_auth.jsonl')
              .writeAsString('{"event":"registrationAccepted"}\n');
          await File('${logDirectory.path}/download_v2.jsonl')
              .writeAsString('keep downloads\n');
        }
        await removeLegacyAnimeRiftAuthLogs(
          documentsDirectory: () async => documents,
          supportDirectory: () async => support,
        );
        for (final directory in [documents, support]) {
          expect(
            await File('${directory.path}/log/animerift_auth.jsonl').exists(),
            isFalse,
          );
          expect(
            await File('${directory.path}/log/download_v2.jsonl')
                .readAsString(),
            'keep downloads\n',
          );
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'cleanup tolerates inaccessible locations and missing auth log',
    () async {
      final root = await Directory.systemTemp.createTemp('rift-cleanup-empty-');
      try {
        await removeLegacyAnimeRiftAuthLogs(
          documentsDirectory: () async =>
              throw const FileSystemException('unavailable'),
          supportDirectory: () async => root,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
