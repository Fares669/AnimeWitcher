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
      final settings = _read(
        'lib/features/settings/presentation/general_settings_provider.dart',
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
        settings,
      ]) {
        expect(source, isNot(contains('persistent_parallel_download.dart')));
        expect(source, isNot(contains('download_range_transfer.dart')));
        expect(source, isNot(contains('PersistentParallelDownload')));
        expect(source, isNot(contains('DownloadRangeTransfer')));
      }
    });

    test('legacy DownloadService V1 manager source is removed', () {
      expect(
        File('lib/core/services/download_service.dart').existsSync(),
        isFalse,
      );
    });

    test('all feature-layer production code is sealed from V1 transport', () {
      final featureFiles = Directory('lib/features')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList(growable: false);

      expect(featureFiles, isNotEmpty);
      for (final file in featureFiles) {
        final source = file.readAsStringSync();
        expect(
          source,
          isNot(contains('download_service.dart')),
          reason: '${file.path} must not import the V1 transport service',
        );
        expect(
          source,
          isNot(contains('downloadServiceProvider')),
          reason: '${file.path} must not instantiate V1 transport',
        );
        expect(
          source,
          isNot(contains('PersistentParallelDownload')),
          reason: '${file.path} must not reach the V1 multipart writer',
        );
        expect(
          source,
          isNot(contains('DownloadRangeTransfer')),
          reason: '${file.path} must not reach the V1 range writer',
        );
      }
    });

    test('download support UI cannot instantiate V1 transport', () {
      final logDialog = _read(
        'lib/features/settings/presentation/widgets/download_log_dialog.dart',
      );
      final managementDialog = _read(
        'lib/features/details/presentation/widgets/download_management_dialog.dart',
      );

      for (final source in <String>[logDialog, managementDialog]) {
        expect(source, isNot(contains('download_service.dart')));
        expect(source, isNot(contains('downloadServiceProvider')));
      }
      expect(logDialog, contains('downloadDiagnosticsFileV2Provider'));
      expect(managementDialog, contains('deleteDownloadedVideo(file)'));
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
      final settings = _read(
        'lib/features/settings/presentation/general_settings_provider.dart',
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
      expect(settings, isNot(contains('downloadServiceProvider')));
      expect(settings, isNot(contains('core/services/download_service.dart')));
      expect(downloads, isNot(contains('FileDownloader().database')));
    });

    test('production legacy metadata migrates before package transport starts', () {
      final provider = _read(
        'lib/core/services/download_v2/download_v2_provider.dart',
      );

      expect(provider, contains("import 'legacy_download_migration_v2.dart';"));
      expect(provider, contains('LegacyDownloadMigrationV2('));
      expect(provider, contains('_migrateLegacyPresentationMetadata'));
      expect(provider, contains('_MigrationFirstBackgroundDownloaderGateway'));
      final migrationCall = provider.indexOf('await _migrate();');
      final transportInit = provider.indexOf('await _delegate.initialize();');
      expect(migrationCall, greaterThanOrEqualTo(0));
      expect(transportInit, greaterThan(migrationCall));
    });

    test('legacy playback fallback requires stored logical completion', () {
      final completed = _read(
        'lib/features/details/presentation/downloaded_file_provider.dart',
      );

      expect(completed, contains('downloadMetadataProgress(entry)'));
      expect(completed, contains('if (progress < 1) continue;'));
      expect(completed, contains('downloadMetadataExpectedBytes(entry)'));
      expect(completed, contains('length != expectedBytes'));
    });

    test('presentation metadata is durable before a V2 writer can start', () {
      final launcher = _read(
        'lib/features/details/presentation/download_launcher.dart',
      );
      final metadataWrite = launcher.indexOf('.saveDownloadMetadata(');
      final transportStart = launcher.indexOf('downloadManager.start(');

      expect(metadataWrite, greaterThanOrEqualTo(0));
      expect(transportStart, greaterThan(metadataWrite));
      expect(
        launcher.substring(metadataWrite, transportStart),
        contains('logicalId.value'),
      );
      expect(launcher, contains('removeDownloadMetadata(logicalId.value)'));
    });

    test('logical variant identity is semantic, never server/source identity', () {
      final launcher = _read(
        'lib/features/details/presentation/download_launcher.dart',
      );

      expect(launcher, contains('downloadVariantKeyV2('));
      expect(launcher, isNot(contains('final variantKey = <String>[')));
    });

    test('progress projection is keyed by logical identity instead of URL', () {
      final progress = _read(
        'lib/features/library/presentation/download_progress_v2_provider.dart',
      );

      expect(progress, contains('final key = logicalId;'));
      expect(progress, isNot(contains('final key = item.trackingUrl.trim();')));
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

    test(
      'iOS native multipart transport ownership stays legacy-only while V2 durable ranges are observable',
      () {
        final native = _read(
          'ios/Runner/DownloadNativeWaitingQueue.swift',
        );

        expect(native, contains('private static func ownsLegacyMultipartParent('));
        expect(native, contains('private static func isLegacyMultipartPart('));
        expect(native, contains('private static func isV2DurableMultipartPart('));
        expect(native, contains('private static func isObservableMultipartPart('));
        expect(native, contains('state.multipartPlans.contains'));

        // Native retry/promotion remains fenced to the dormant legacy path.
        expect(native, contains('let multipartPart = isLegacyMultipartPart(task)'));
        expect(native, contains('guard nativePromotionAvailable else { return }'));

        // Progress/completion telemetry for V2 durable children must still reach
        // Dart/native Continued Processing while the app is backgrounded.
        expect(
          native,
          contains('guard isObservableMultipartPart(task) else { return }'),
        );
        expect(
          native,
          contains(
            'guard isObservableMultipartPart(downloadTask) else { return }',
          ),
        );
        expect(
          native,
          contains(
            'guard isObservableMultipartParent(parentId) else { return }',
          ),
        );
      },
    );

    test('iOS durable parallel pause drains only already-launched immutable ranges', () {
      final gateway = _read(
        'lib/core/services/download_v2/background_downloader_gateway.dart',
      );

      expect(
        gateway,
        contains('shouldDrainPartOnPause: (_) => _isIOS()'),
      );
      expect(
        gateway,
        contains('preserveLiveParts: Platform.isIOS'),
        reason:
            'The durable iOS coordinator must stop scheduling new ranges while '
            'allowing only the already-launched immutable range tasks to finish. '
            'This avoids destructive native pause/resume-data failures.',
      );
    });

    test(
      'single package fallback is self-settling even when requested width is parallel',
      () {
        final gateway = _read(
          'lib/core/services/download_v2/background_downloader_gateway.dart',
        );

        expect(
          gateway,
          contains('transfer.task is ParallelDownloadTask'),
        );
        expect(
          gateway,
          contains('_SelfSettlingPackageDownloadTransportHandle'),
          reason:
              'an iOS 16-connection request can fall back to one package task '
              'when the origin has no Range support; that exact single task '
              'must not be mistaken for an old unsafe package-parallel parent',
        );
      },
    );

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
