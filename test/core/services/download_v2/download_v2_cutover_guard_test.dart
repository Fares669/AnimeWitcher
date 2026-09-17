import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('V2 production cutover', () {
    test('production wiring uses the V2 manager and not V1 transport authority', () {
      final provider = _read('lib/core/services/download_v2/download_v2_provider.dart');
      final main = _read('lib/main.dart');
      final launcher = _read('lib/features/details/presentation/download_launcher.dart');
      final downloads = _read('lib/features/library/presentation/downloads_provider.dart');
      final completed = _read(
        'lib/features/details/presentation/downloaded_file_provider.dart',
      );

      expect(provider, contains('downloadManagerV2Provider'));
      expect(main, contains('downloadManagerV2Provider'));
      expect(launcher, contains('downloadManagerV2Provider'));
      expect(downloads, contains('downloadManagerV2Provider'));
      expect(completed, contains('downloadManagerV2Provider'));

      for (final source in <String>[provider, main, launcher, downloads, completed]) {
        expect(source, isNot(contains('persistent_parallel_download.dart')));
        expect(source, isNot(contains('download_range_transfer.dart')));
        expect(source, isNot(contains('PersistentParallelDownload')));
        expect(source, isNot(contains('DownloadRangeTransfer')));
      }
    });

    test('launcher and downloads UI no longer execute lifecycle through V1', () {
      final launcher = _read('lib/features/details/presentation/download_launcher.dart');
      final downloads = _read('lib/features/library/presentation/downloads_provider.dart');
      final completed = _read(
        'lib/features/details/presentation/downloaded_file_provider.dart',
      );

      expect(launcher, isNot(contains('downloadServiceProvider')));
      expect(launcher, isNot(contains('startDownloadOutcome')));
      expect(downloads, isNot(contains('downloadServiceProvider')));
      expect(completed, isNot(contains('downloadServiceProvider')));
      expect(downloads, isNot(contains('FileDownloader().database')));
    });

    test('V2 manager exposes logical observation and completed availability', () {
      final manager = _read('lib/core/services/download_v2/download_manager_v2.dart');

      expect(manager, contains('Stream<List<LogicalDownloadRecordV2>> get records'));
      expect(manager, contains('Future<bool> hasCompletedDownload('));
    });
  });
}

String _read(String path) => File(path).readAsStringSync();
