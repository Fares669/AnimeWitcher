import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('V2 production cutover', () {
    test('production wiring uses the V2 manager and transport boundary', () {
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
      final progressDialog = _read(
        'lib/features/details/presentation/widgets/download_progress_dialog.dart',
      );
      final completed = _read(
        'lib/features/details/presentation/downloaded_file_provider.dart',
      );

      for (final source in <String>[
        provider,
        main,
        launcher,
        downloads,
        progressDialog,
        completed,
      ]) {
        expect(source, contains('downloadManagerV2Provider'));
      }

      expect(
        provider,
        contains('packageBackgroundDownloaderGatewayV2Provider'),
      );
      expect(
        provider,
        isNot(contains('_MigrationFirstBackgroundDownloaderGateway')),
      );
    });

    test('download support UI uses V2 diagnostics and lifecycle', () {
      final logDialog = _read(
        'lib/features/settings/presentation/widgets/download_log_dialog.dart',
      );
      final managementDialog = _read(
        'lib/features/details/presentation/widgets/download_management_dialog.dart',
      );

      expect(logDialog, contains('downloadDiagnosticsFileV2Provider'));
      expect(managementDialog, contains('deleteDownloadedVideo(file)'));
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

    test('iOS V2 background refill is plan-fenced and retry stays Dart-owned', () {
      final native = _read('ios/Runner/DownloadNativeWaitingQueue.swift');

      expect(
        native,
        contains('private static func ownsPromotableMultipartParent('),
      );
      expect(native, contains('private static func isPromotableMultipartPart('));
      expect(native, contains('private static func isV2DurableMultipartPart('));
      expect(native, contains('private static func isObservableMultipartPart('));
      expect(native, contains('state.multipartPlans.contains'));

      expect(
        native,
        contains('if isPromotableMultipartPart(task) {'),
      );
      expect(
        native,
        contains(
          'if isDownloadPart(task) {\n'
          '      return false\n'
          '    }',
        ),
        reason:
            'Multipart Range failures must return to V2 rather than being '
            'recreated by native retry ownership.',
      );

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
    });

    test('iOS durable parallel pause drains only launched immutable ranges', () {
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
      );
    });

    test(
      'single package fallback is self-settling when requested width is parallel',
      () {
        final gateway = _read(
          'lib/core/services/download_v2/background_downloader_gateway.dart',
        );

        expect(gateway, contains('transfer.task is ParallelDownloadTask'));
        expect(
          gateway,
          contains('_SelfSettlingPackageDownloadTransportHandle'),
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
