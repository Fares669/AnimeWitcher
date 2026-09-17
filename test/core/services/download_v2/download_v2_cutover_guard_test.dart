import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('V2 production cutover', () {
    test('production wiring uses the V2 manager and not V1 transport authority', () {
      final provider = _read(
        'lib/core/services/download_v2/download_v2_provider.dart',
      );
      final main = _read('lib/main.dart');
      final launcher = _read(
        'lib/features/details/presentation/download_launcher.dart',
      );
      final downloads = _read(
        'lib/features/library/presentation/downloads_provider.dart',
      );
      final downloadsTab = _read(
        'lib/features/library/presentation/widgets/downloads_tab.dart',
      );
      final progressDialog = _read(
        'lib/features/details/presentation/widgets/download_progress_dialog.dart',
      );
      final completed = _read(
        'lib/features/details/presentation/downloaded_file_provider.dart',
      );

      expect(provider, contains('downloadManagerV2Provider'));
      expect(main, contains('downloadManagerV2Provider'));
      expect(launcher, contains('downloadManagerV2Provider'));
      expect(downloads, contains('downloadManagerV2Provider'));
      expect(progressDialog, contains('downloadManagerV2Provider'));
      expect(completed, contains('downloadManagerV2Provider'));

      for (final source in <String>[
        provider,
        main,
        launcher,
        downloads,
        downloadsTab,
        progressDialog,
        completed,
      ]) {
        expect(source, isNot(contains('persistent_parallel_download.dart')));
        expect(source, isNot(contains('download_range_transfer.dart')));
        expect(source, isNot(contains('PersistentParallelDownload')));
        expect(source, isNot(contains('DownloadRangeTransfer')));
      }
    });

    test('production entry points no longer execute lifecycle through V1', () {
      final main = _read('lib/main.dart');
      final launcher = _read(
        'lib/features/details/presentation/download_launcher.dart',
      );
      final downloads = _read(
        'lib/features/library/presentation/downloads_provider.dart',
      );
      final downloadsTab = _read(
        'lib/features/library/presentation/widgets/downloads_tab.dart',
      );
      final progressDialog = _read(
        'lib/features/details/presentation/widgets/download_progress_dialog.dart',
      );
      final completed = _read(
        'lib/features/details/presentation/downloaded_file_provider.dart',
      );

      expect(main, isNot(contains("core/services/download_service.dart")));
      expect(main, isNot(contains('downloadServiceProvider')));
      expect(launcher, isNot(contains('downloadServiceProvider')));
      expect(launcher, isNot(contains('startDownloadOutcome')));
      expect(downloads, isNot(contains('downloadServiceProvider')));
      expect(downloadsTab, isNot(contains('downloadServiceProvider')));
      expect(downloadsTab, isNot(contains('core/services/download_service.dart')));
      expect(progressDialog, isNot(contains('downloadServiceProvider')));
      expect(progressDialog, isNot(contains('core/services/download_service.dart')));
      expect(progressDialog, isNot(contains('FileDownloader()')));
      expect(completed, isNot(contains('downloadServiceProvider')));
      expect(downloads, isNot(contains('FileDownloader().database')));
    });

    test('production manager receives the explicit integrity verifier provider', () {
      final provider = _read(
        'lib/core/services/download_v2/download_v2_provider.dart',
      );

      expect(
        provider,
        contains("import 'download_integrity_verifier_v2.dart';"),
      );
      expect(
        provider,
        contains('final downloadIntegrityVerifierV2Provider ='),
      );
      expect(provider, contains('Provider<DownloadIntegrityVerifierV2>'));
      expect(
        provider,
        contains(
          'integrityVerifier: ref.read(downloadIntegrityVerifierV2Provider)',
        ),
      );
    });

    test('iOS native multipart bridge is limited to legacy-owned parents', () {
      final native = _read(
        'ios/Runner/DownloadNativeWaitingQueue.swift',
      );
      final start = native.indexOf(
        'private static func postSupportedMultipartProgress',
      );
      final end = native.indexOf(
        'private static func parentTaskId(',
        start,
      );

      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = native.substring(start, end);
      expect(native, contains('private static func ownsLegacyMultipartParent('));
      expect(native, contains('state.multipartPlans.contains'));
      expect(body, contains('ownsLegacyMultipartParent(parentId)'));
    });

    test('V2 manager exposes logical observation and completed availability', () {
      final manager = _read(
        'lib/core/services/download_v2/download_manager_v2.dart',
      );

      expect(
        manager,
        contains('Stream<List<LogicalDownloadRecordV2>> get records'),
      );
      expect(manager, contains('Future<bool> hasCompletedDownload('));
    });
  });
}

String _read(String path) => File(path).readAsStringSync();
