import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String methodBody(String source, String signature, String nextSignature) {
  final start = source.indexOf(signature);
  final end = source.indexOf(nextSignature, start + signature.length);
  expect(start, greaterThanOrEqualTo(0), reason: 'missing $signature');
  expect(end, greaterThan(start), reason: 'missing boundary $nextSignature');
  return source.substring(start, end);
}

void main() {
  test('all public mutating download controls join readiness first', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();

    final controls = <(String, String, String)>[
      (
        'setDiagnosticLogging',
        'Future<void> setDiagnosticLogging(',
        'static StreamSubscription<TaskUpdate>?',
      ),
      (
        'applyQueueSettings',
        'Future<void> applyQueueSettings(',
        'Future<void> applyNotificationSettings(',
      ),
      (
        'cancelDownload',
        'Future<void> cancelDownload(',
        'Future<void> pauseDownload(',
      ),
      (
        'pauseDownload',
        'Future<void> pauseDownload(',
        'Future<void> resumeDownload(',
      ),
      (
        'resumeDownload',
        'Future<void> resumeDownload(',
        'Future<void> _resumeUserPausedUnlocked(',
      ),
      (
        'startDownload',
        'Future<bool> startDownload(',
        'Future<String> _getPublicDownloadsPath(',
      ),
    ];

    for (final (name, signature, nextSignature) in controls) {
      final body = methodBody(source, signature, nextSignature);
      expect(
        body,
        contains("await _awaitCommandReadiness('$name')"),
        reason: '$name bypasses initialization/recovery readiness',
      );
    }
  });

  test('notification preferences do not wait for download recovery', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final body = methodBody(
      source,
      'Future<void> applyNotificationSettings(',
      'void _configureDownloadNotifications(',
    );

    expect(
      body,
      isNot(contains("_awaitCommandReadiness('applyNotificationSettings')")),
      reason: 'notification configuration must not be blocked by job recovery',
    );
    final persist = body.indexOf('.setDownloadNotificationPrefs(prefs)');
    final configure = body.indexOf('_configureDownloadNotifications(prefs)');
    expect(persist, greaterThanOrEqualTo(0));
    expect(configure, greaterThan(persist));
  });

  test(
    'foreground reconciliation joins initialization instead of returning early',
    () {
      final source = File('lib/core/services/download_service.dart')
          .readAsStringSync();
      final body = methodBody(
        source,
        'Future<void> onAppForegrounded() async {',
        'List<String> _queueOrder()',
      );

      expect(body, contains("await _awaitLifecycleReadiness('foreground')"));
      expect(body, isNot(contains('if (!_isInitialized) return;')));
      expect(
        body.indexOf("await _awaitLifecycleReadiness('foreground')"),
        lessThan(body.indexOf('await _serializeQueue(')),
      );
    },
  );

  test(
    'startup init failure is explicitly observed while commands can retry',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final callback = methodBody(
        source,
        'WidgetsBinding.instance.addPostFrameCallback((_) {',
        '  @override\n  void dispose()',
      );
      expect(callback, contains('unawaited('));
      expect(
        callback,
        contains('ref.read(downloadServiceProvider).init().catchError('),
      );
    },
  );
}
