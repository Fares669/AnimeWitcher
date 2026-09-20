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

    test('one-second progress refresh stays memory-only', () {
      final source = File(
        'lib/features/library/presentation/downloads_provider.dart',
      ).readAsStringSync();
      final start = source.indexOf('void _refreshPresentationState()');
      final end = source.indexOf('Future<void> _reloadDurableState()', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      expect(body, isNot(contains('logicalDownloadStoreV2Provider')));
      expect(body, isNot(contains('getAllDownloadMetadata')));
      expect(body, contains('_projectList()'));
    });

    test('slow safety refresh is the only periodic durable scan', () {
      final source = File(
        'lib/features/library/presentation/downloads_provider.dart',
      ).readAsStringSync();
      expect(
        source,
        contains(
          'static const Duration _durableRefreshInterval = Duration(seconds: 30);',
        ),
      );
      final start = source.indexOf('Future<void> _reloadDurableState()');
      final end = source.indexOf('List<DownloadItem> _projectList()', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);

      expect(body, contains('logicalDownloadStoreV2Provider'));
      expect(body, contains('getAllDownloadMetadata'));
    });

    test('completed artwork work is not relaunched on every progress tick', () {
      final source = File(
        'lib/features/library/presentation/downloads_provider.dart',
      ).readAsStringSync();

      expect(source, contains('final Set<String> _artworkScheduledIds'));
      expect(
        source,
        contains('_artworkScheduledIds.add(projected.id)'),
      );
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
