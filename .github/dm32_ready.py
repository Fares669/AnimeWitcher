from pathlib import Path
import sys

SERVICE = Path('lib/core/services/download_service.dart')
MAIN = Path('lib/main.dart')
PLAN = Path('DOWNLOAD_MANAGER_PLAN.md')
READINESS = Path('lib/core/services/download_service_readiness.dart')
TEST = Path('test/core/services/download_service_readiness_test.dart')
GUARD = Path('test/core/services/download_initialization_barrier_guard_test.dart')

mode = sys.argv[1]

READINESS_CONTENT = r'''import 'dart:async';

enum DownloadServiceReadinessState { idle, initializing, ready }

enum DownloadServiceUnavailableReason { initializationFailed, disposed }

final class DownloadServiceUnavailableException implements Exception {
  final DownloadServiceUnavailableReason reason;
  final Object? cause;
  final bool retryable;

  const DownloadServiceUnavailableException._({
    required this.reason,
    required this.retryable,
    this.cause,
  });

  factory DownloadServiceUnavailableException.initializationFailed(
    Object cause,
  ) => DownloadServiceUnavailableException._(
    reason: DownloadServiceUnavailableReason.initializationFailed,
    retryable: true,
    cause: cause,
  );

  factory DownloadServiceUnavailableException.disposed() =>
      const DownloadServiceUnavailableException._(
        reason: DownloadServiceUnavailableReason.disposed,
        retryable: false,
      );

  @override
  String toString() =>
      'DownloadServiceUnavailableException(${reason.name}, retryable: $retryable, cause: $cause)';
}

/// Coalesces every caller onto one initialization/recovery attempt.
///
/// A failed attempt is deliberately forgotten so the next command can retry.
/// The Future returned to concurrent callers is the exact same object, making
/// recovery completion a single ordering boundary for all public controls.
final class DownloadServiceReadinessBarrier {
  Future<void>? _inFlight;
  bool _ready = false;

  DownloadServiceReadinessState get state {
    if (_ready) return DownloadServiceReadinessState.ready;
    if (_inFlight != null) return DownloadServiceReadinessState.initializing;
    return DownloadServiceReadinessState.idle;
  }

  bool get isReady => _ready;

  Future<void> ensureReady(Future<void> Function() initialize) {
    if (_ready) return Future<void>.value();
    final existing = _inFlight;
    if (existing != null) return existing;

    final completer = Completer<void>();
    final attempt = completer.future;
    _inFlight = attempt;

    Future<void>.sync(initialize).then(
      (_) {
        _ready = true;
        if (identical(_inFlight, attempt)) _inFlight = null;
        completer.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_inFlight, attempt)) _inFlight = null;
        final unavailable = error is DownloadServiceUnavailableException
            ? error
            : DownloadServiceUnavailableException.initializationFailed(error);
        completer.completeError(unavailable, stack);
      },
    );

    return attempt;
  }
}
'''

TEST_CONTENT = r'''import 'dart:async';

import 'package:animewitcher/core/services/download_service_readiness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concurrent callers join the exact same initialization Future', () async {
    final barrier = DownloadServiceReadinessBarrier();
    final release = Completer<void>();
    var attempts = 0;

    Future<void> initialize() {
      attempts += 1;
      return release.future;
    }

    final first = barrier.ensureReady(initialize);
    final second = barrier.ensureReady(initialize);
    final third = barrier.ensureReady(initialize);

    expect(identical(first, second), isTrue);
    expect(identical(first, third), isTrue);
    expect(attempts, 1);
    expect(barrier.state, DownloadServiceReadinessState.initializing);

    release.complete();
    await Future.wait([first, second, third]);

    expect(barrier.state, DownloadServiceReadinessState.ready);
    await barrier.ensureReady(initialize);
    expect(attempts, 1);
  });

  test('failed initialization is typed, retryable, and next call retries', () async {
    final barrier = DownloadServiceReadinessBarrier();
    var attempts = 0;

    Future<void> initialize() async {
      attempts += 1;
      if (attempts == 1) throw StateError('storage unavailable');
    }

    await expectLater(
      barrier.ensureReady(initialize),
      throwsA(
        isA<DownloadServiceUnavailableException>()
            .having(
              (error) => error.reason,
              'reason',
              DownloadServiceUnavailableReason.initializationFailed,
            )
            .having((error) => error.retryable, 'retryable', isTrue)
            .having((error) => error.cause, 'cause', isA<StateError>()),
      ),
    );
    expect(barrier.state, DownloadServiceReadinessState.idle);

    await barrier.ensureReady(initialize);
    expect(attempts, 2);
    expect(barrier.state, DownloadServiceReadinessState.ready);
  });
}
'''

GUARD_CONTENT = r'''import 'dart:io';

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
    final source = File('lib/core/services/download_service.dart').readAsStringSync();

    final controls = <(String, String, String)>[
      ('setDiagnosticLogging', 'Future<void> setDiagnosticLogging(', 'static StreamSubscription<TaskUpdate>?'),
      ('applyQueueSettings', 'Future<void> applyQueueSettings(', 'Future<void> applyNotificationSettings('),
      ('applyNotificationSettings', 'Future<void> applyNotificationSettings(', 'void _configureDownloadNotifications('),
      ('cancelDownload', 'Future<void> cancelDownload(', 'Future<void> pauseDownload('),
      ('pauseDownload', 'Future<void> pauseDownload(', 'Future<void> resumeDownload('),
      ('resumeDownload', 'Future<void> resumeDownload(', 'Future<void> _resumeUserPausedUnlocked('),
      ('startDownload', 'Future<bool> startDownload(', 'Future<String> _getPublicDownloadsPath('),
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

  test('foreground reconciliation joins initialization instead of returning early', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();
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
  });

  test('startup init failure is explicitly observed while commands can retry', () {
    final source = File('lib/main.dart').readAsStringSync();
    final callback = methodBody(
      source,
      'WidgetsBinding.instance.addPostFrameCallback((_) {',
      '  @override\n  void dispose()',
    );
    expect(callback, contains('unawaited('));
    expect(callback, contains('ref.read(downloadServiceProvider).init().catchError('));
  });
}
'''


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected 1 match, got {count}')
    return text.replace(old, new, 1)


if mode == 'tests':
    READINESS.write_text(READINESS_CONTENT)
    TEST.write_text(TEST_CONTENT)
    GUARD.write_text(GUARD_CONTENT)
elif mode == 'apply':
    service = SERVICE.read_text()
    service = replace_once(
        service,
        "import 'download_job_store.dart';\n",
        "import 'download_job_store.dart';\nimport 'download_service_readiness.dart';\n",
        'readiness import',
    )
    service = replace_once(
        service,
        '  Future<void>? _initializing;\n',
        '  final DownloadServiceReadinessBarrier _readiness =\\n      DownloadServiceReadinessBarrier();\n',
        'readiness field',
    )
    service = replace_once(
        service,
        '''  Future<void> init() => _initializing ??= _initialize().catchError((\n    Object error,\n    StackTrace stack,\n  ) {\n    _initializing = null;\n    Error.throwWithStackTrace(error, stack);\n  });\n\n''',
        '''  Future<void> init() {\n    if (_disposed) {\n      return Future<void>.error(DownloadServiceUnavailableException.disposed());\n    }\n    return _readiness.ensureReady(_initialize);\n  }\n\n  Future<void> _awaitCommandReadiness(String command) async {\n    try {\n      await init();\n    } on DownloadServiceUnavailableException catch (error) {\n      diagnosticLog.record('command.serviceUnavailable', {\n        'command': command,\n        'reason': error.reason.name,\n        'retryable': error.retryable,\n        if (error.cause != null) 'causeType': error.cause.runtimeType.toString(),\n      });\n      rethrow;\n    }\n  }\n\n  Future<bool> _awaitLifecycleReadiness(String event) async {\n    try {\n      await init();\n      return true;\n    } on DownloadServiceUnavailableException catch (error) {\n      diagnosticLog.record('lifecycle.serviceUnavailable', {\n        'event': event,\n        'reason': error.reason.name,\n        'retryable': error.retryable,\n      });\n      return false;\n    }\n  }\n\n''',
        'init barrier',
    )
    service = replace_once(
        service,
        '    _updatesSubscription = _sharedEvents.stream.listen((update) {\n',
        '''    // A previous initialization attempt may have failed after installing\n    // this instance listener. Cancel it before retrying so deliberate retry\n    // cannot duplicate callback consumers.\n    await _updatesSubscription?.cancel();\n    _updatesSubscription = _sharedEvents.stream.listen((update) {\n''',
        'retry listener cleanup',
    )
    service = replace_once(
        service,
        '''  Future<void> setDiagnosticLogging(bool enabled) async {\n    await init();\n''',
        '''  Future<void> setDiagnosticLogging(bool enabled) async {\n    await _awaitCommandReadiness('setDiagnosticLogging');\n''',
        'logging readiness',
    )
    service = replace_once(
        service,
        '''  Future<void> applyQueueSettings({required int maxConcurrent}) async {\n    await applyDownloadQueueSettings(\n''',
        '''  Future<void> applyQueueSettings({required int maxConcurrent}) async {\n    if (configureHoldingQueueForTesting == null) {\n      await _awaitCommandReadiness('applyQueueSettings');\n    }\n    await applyDownloadQueueSettings(\n''',
        'queue settings readiness',
    )
    service = replace_once(
        service,
        '''  Future<void> applyNotificationSettings(\n    DownloadNotificationPrefs prefs,\n  ) async {\n    await _ref.read(storageServiceProvider).setDownloadNotificationPrefs(prefs);\n''',
        '''  Future<void> applyNotificationSettings(\n    DownloadNotificationPrefs prefs,\n  ) async {\n    await _awaitCommandReadiness('applyNotificationSettings');\n    await _ref.read(storageServiceProvider).setDownloadNotificationPrefs(prefs);\n''',
        'notification settings readiness',
    )
    service = replace_once(
        service,
        '''  Future<void> onAppForegrounded() async {\n    if (!_isInitialized) return;\n    await _serializeQueue(() async {\n''',
        '''  Future<void> onAppForegrounded() async {\n    if (!await _awaitLifecycleReadiness('foreground')) return;\n    await _serializeQueue(() async {\n''',
        'foreground coalescing',
    )
    service = replace_once(
        service,
        '''  Future<void> cancelDownload(\n    String taskId,\n    String trackingUrl, {\n    bool notifyContinuedProcessing = true,\n  }) async {\n    diagnosticLog.record('command.cancel', {'taskId': taskId});\n''',
        '''  Future<void> cancelDownload(\n    String taskId,\n    String trackingUrl, {\n    bool notifyContinuedProcessing = true,\n  }) async {\n    await _awaitCommandReadiness('cancelDownload');\n    diagnosticLog.record('command.cancel', {'taskId': taskId});\n''',
        'cancel readiness',
    )
    service = replace_once(
        service,
        '''  Future<void> pauseDownload(String taskId) async {\n    diagnosticLog.record('command.pauseDownload', {'taskId': taskId});\n''',
        '''  Future<void> pauseDownload(String taskId) async {\n    await _awaitCommandReadiness('pauseDownload');\n    diagnosticLog.record('command.pauseDownload', {'taskId': taskId});\n''',
        'pause readiness',
    )
    service = replace_once(
        service,
        '''  Future<void> resumeDownload(String taskId) async {\n    diagnosticLog.record('command.resumeDownload', {'taskId': taskId});\n''',
        '''  Future<void> resumeDownload(String taskId) async {\n    await _awaitCommandReadiness('resumeDownload');\n    diagnosticLog.record('command.resumeDownload', {'taskId': taskId});\n''',
        'resume readiness',
    )
    service = replace_once(
        service,
        '''  }) async {\n    diagnosticLog.record('command.start', {'total': totalBytes});\n    if (kDebugMode) {\n''',
        '''  }) async {\n    await _awaitCommandReadiness('startDownload');\n    diagnosticLog.record('command.start', {'total': totalBytes});\n    if (kDebugMode) {\n''',
        'start readiness',
    )
    SERVICE.write_text(service)

    main = MAIN.read_text()
    main = replace_once(
        main,
        '''    WidgetsBinding.instance.addPostFrameCallback((_) {\n      ref.read(downloadServiceProvider).init();\n      _checkAppUpdates();\n''',
        '''    WidgetsBinding.instance.addPostFrameCallback((_) {\n      unawaited(\n        ref.read(downloadServiceProvider).init().catchError((Object error) {\n          if (kDebugMode) {\n            debugPrint('[DownloadService] Startup initialization deferred: $error');\n          }\n        }),\n      );\n      _checkAppUpdates();\n''',
        'main init observer',
    )
    MAIN.write_text(main)

    plan = PLAN.read_text()
    plan = replace_once(
        plan,
        '- [ ] **DM-32 — Gate every public download control behind initialization/recovery readiness**',
        '- [x] **DM-32 — Gate every public download control behind initialization/recovery readiness**',
        'DM-32 checkbox',
    )
    anchor = '  - **Dependencies:** DM-21 for startup persistence failures; can be implemented early with conservative blocking.'
    notes = '''\n  - **Implementation notes (2026-09-11):** Added a single `DownloadServiceReadinessBarrier` shared by `init()` and every public state-mutating download command. Concurrent callers receive the same in-flight Future and cannot enter start/pause/resume/cancel/settings mutation until startup recovery has completed. Foreground reconciliation now joins that barrier instead of returning early and losing the event.\n  - **Failure/retry semantics:** Initialization failures surface as typed `DownloadServiceUnavailableException(initializationFailed, retryable: true)` and clear only the failed attempt so a later command deliberately retries. Retry cancels any listener installed by a partially completed prior init before attaching a replacement, preventing duplicate event consumers. Post-frame startup explicitly observes the failure instead of leaving an unhandled Future; later controls remain able to retry.\n  - **Confirmed root cause:** `init()` itself coalesced only callers that explicitly invoked it; command entry points and foreground reconciliation bypassed that Future, so they could mutate queue/native state while `_recoverPersistedDownloads` was still reconciling persisted ownership.\n  - **Verification passed:** readiness unit tests prove exact-Future coalescing and typed fail-then-retry behavior; source guards prove start/pause/resume/cancel and public settings controls await readiness before mutation, foreground reconciliation awaits the same barrier before queue work, and startup observes init failure; download lifecycle/recovery/ownership/multipart regression suites and `flutter analyze --no-fatal-warnings --no-fatal-infos` also pass.'''
    plan = replace_once(plan, anchor, anchor + notes, 'DM-32 notes')
    PLAN.write_text(plan)
else:
    raise SystemExit('usage: tests|apply')
