import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('continued-processing update reports whether native still owns a session', () {
    final manager = File(
      'ios/Runner/DownloadContinuedProcessingManager.swift',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final appDelegate = File(
      'ios/Runner/AppDelegate.swift',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(manager, contains('func update(\n'));
    expect(
      manager,
      contains(') -> Bool {'),
      reason: 'Dart must be able to detect a system task that expired or vanished',
    );
    expect(
      manager,
      contains('guard var snapshot = snapshot else { return false }'),
    );
    expect(appDelegate, contains('let active = manager.update('));
    expect(appDelegate, contains('"accepted": active'));
  });

  test('native ownership never masquerades as a Dart-applied update', () {
    final appDelegate = File(
      'ios/Runner/AppDelegate.swift',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    expect(
      appDelegate,
      contains(
        'let forcePresentation = arguments["foregroundHandoff"] as? Bool ?? false',
      ),
    );
    expect(
      appDelegate,
      contains(
        'if !forcePresentation && !DownloadNativeWaitingQueue.acceptsDartOverlayUpdates()',
      ),
      reason:
          'background/native ownership may suppress Dart presentation, but foreground handoff must be allowed through',
    );
    expect(appDelegate, contains('"owner": "native"'));
    expect(
      appDelegate,
      isNot(
        contains(
          'if !DownloadNativeWaitingQueue.acceptsDartOverlayUpdates() {\n          result(true)',
        ),
      ),
      reason:
          'returning bare true for a discarded Dart update leaves the app believing a stale iOS task is synchronized',
    );
  });

  test('foreground lifecycle forces an immediate Dart presentation handoff', () {
    final service = File(
      'lib/core/services/download_continued_processing_service.dart',
    ).readAsStringSync();
    final downloadService = File(
      'lib/core/services/download_service.dart',
    ).readAsStringSync();

    expect(service, contains('bool foregroundHandoff = false,'));
    expect(service, contains("'foregroundHandoff': foregroundHandoff"));
    expect(
      downloadService,
      contains('await _syncSessionOverlay(forceDartPresentation: true);'),
      reason:
          'Flutter resumed can race UIScene foregroundActive; the explicit handoff must not wait for another progress sample',
    );
    expect(
      downloadService,
      contains('foregroundHandoff: forceDartPresentation'),
    );
  });
}
