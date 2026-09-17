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
  });
}
