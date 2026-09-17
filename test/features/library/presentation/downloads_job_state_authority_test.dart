import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('V2 downloads projection authority', () {
    test('downloads provider projects V2 records and snapshots only', () {
      final source = File(
        'lib/features/library/presentation/downloads_provider.dart',
      ).readAsStringSync();

      expect(source, contains('downloadManagerV2Provider'));
      expect(source, contains('logicalDownloadStoreV2Provider'));
      expect(source, contains('snapshotFor(record.logicalId)'));
      expect(source, contains('Timer.periodic'));

      expect(source, isNot(contains('downloadServiceProvider')));
      expect(source, isNot(contains('logicalDownloadSnapshots()')));
      expect(source, isNot(contains('logicalJobStateForTask')));
      expect(source, isNot(contains('downloadJobDisplayStatus')));
      expect(source, isNot(contains('FileDownloader().database')));
    });

    test('presentation lifecycle commands route through V2 logical IDs', () {
      final source = File(
        'lib/features/library/presentation/downloads_provider.dart',
      ).readAsStringSync();

      final pause = source.indexOf('Future<void> pauseDownload(');
      final resume = source.indexOf('Future<void> resumeDownload(', pause);
      expect(pause, greaterThanOrEqualTo(0));
      expect(resume, greaterThan(pause));

      final commandBody = source.substring(pause);
      expect(commandBody, contains('downloadManagerV2Provider'));
      expect(commandBody, contains('.pause(DownloadLogicalId(logical))'));
      expect(commandBody, contains('.resume(DownloadLogicalId(logical))'));

      final remove = source.indexOf('Future<void> removeDownloads(');
      expect(remove, greaterThanOrEqualTo(0));
      final removeBody = source.substring(remove, pause);
      expect(removeBody, contains('manager.delete(DownloadLogicalId(logical))'));
      expect(removeBody, isNot(contains('downloadServiceProvider')));
    });
  });
}
