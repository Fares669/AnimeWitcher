import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('download diagnostic setting no longer needs the v1 transport service', () {
    final settings = File(
      'lib/features/settings/presentation/general_settings_provider.dart',
    ).readAsStringSync();
    final repository = File(
      'lib/core/storage/settings_repository.dart',
    ).readAsStringSync();
    final v2Provider = File(
      'lib/core/services/download_v2/download_v2_provider.dart',
    ).readAsStringSync();
    final continuedProcessing = File(
      'lib/core/services/download_continued_processing_service.dart',
    ).readAsStringSync();
    final appDelegate = File(
      'ios/Runner/AppDelegate.swift',
    ).readAsStringSync();

    expect(
      settings,
      contains(
        'ref.read(settingsRepositoryProvider).setDownloadDiagnosticLog(enabled)',
      ),
    );
    expect(
      settings,
      isNot(contains('read(downloadServiceProvider).setDiagnosticLogging')),
    );
    expect(
      repository,
      contains('_storageService.setDownloadDiagnosticLog(enabled)'),
    );
    expect(v2Provider, contains('FileDownloadDiagnosticsV2'));
    expect(v2Provider, contains("p.join(documents.path, 'log')"));
    expect(v2Provider, contains('settings.getDownloadDiagnosticLog'));
    expect(
      settings,
      contains('configureNativeDownloadDiagnosticLog(enabled)'),
      reason:
          'The V2 setting must still toggle the native iOS diagnostic logger '
          'without constructing DownloadService V1.',
    );
    expect(
      continuedProcessing,
      contains("invokeMethod<void>('configureDiagnosticLog'"),
    );
    expect(
      appDelegate,
      contains('DownloadNativeDiagnosticLog.configure'),
    );
  });
}
