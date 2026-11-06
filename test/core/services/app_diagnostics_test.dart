import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/app_diagnostics.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'nativeSync logs allowlisted error code but never server error text',
    () {
      final sink = InMemoryDownloadDiagnosticsV2();
      final diagnostics = AppDiagnostics(sink: sink);
      diagnostics.recordException(
        'nativeSync',
        const AnimeWitcherAccountException(
          'invalid-session',
          'token secret private-server-response',
        ),
      );
      expect(sink.transportEvents.last['status'], 'invalid-session');
      expect(sink.transportEvents.toString(), isNot(contains('secret')));
      diagnostics.recordException(
        'nativeSync',
        const AnimeWitcherAccountException(
          'private-account-id',
          'personal private information',
        ),
      );
      expect(sink.transportEvents.last['status'], 'other');
      expect(
        sink.transportEvents.toString(),
        isNot(contains('private-account-id')),
      );
    },
  );
  test('API log scopes never contain catalogue or user identifiers', () {
    expect(
      AppDiagnostics.safeRiftOperation(
        'https://example.org/api/v4/library/details/private123?token=secret',
      ),
      'library.details',
    );
    expect(
      AppDiagnostics.safeRiftOperation(
        'https://example.org/api/v4/comment/all?user=private123',
      ),
      'comment.all',
    );
    expect(
      AppDiagnostics.safeRiftOperation('https://example.org/api/v4/private123'),
      'other',
    );
    expect(
      AppDiagnostics.safeRiftOperation(
        'https://example.org/api/v4/comment/react/secret-comment-id?key=secret',
      ),
      'comment.react',
    );
  });

  test('Rift traffic counters expose local rejection context without IDs', () {
    var now = 100000;
    final sink = InMemoryDownloadDiagnosticsV2();
    final diagnostics = AppDiagnostics(sink: sink, clockMillis: () => now);
    const url =
        'https://example.org/api/v4/comment/react/secret-id?token=secret';
    diagnostics.recordRiftRequest(
      url: url,
      method: 'GET',
      durationMs: 10,
      httpStatus: 200,
    );
    expect(sink.transportEvents, isEmpty);
    diagnostics.recordRiftRequest(
      url: url,
      method: 'POST',
      durationMs: 12,
      httpStatus: 429,
      failureKind: 'access',
      retryAfterSeconds: 15,
      edgeRejected: true,
      accountLinked: true,
      serverReason: 'deviceSuspended',
      responseKind: 'html',
      redirectKind: 'external',
    );
    expect(sink.transportEvents.single, {
      'event': 'rift.api.complete',
      'status': 'comment.react',
      'action': 'POST',
      'durationMs': 12,
      'httpStatus': 429,
      'errorType': 'access',
      'delayMs': 15000,
      'count': 2,
      'result': true,
      'active': true,
      'reason': 'deviceSuspended',
      'responseKind': 'html',
      'redirectKind': 'external',
    });
    now += 61000;
    diagnostics.recordRiftRequest(
      url: url,
      method: 'PUT',
      durationMs: 1,
      httpStatus: 403,
      failureKind: 'access',
      serverReason: 'some-secret-server-message',
    );
    expect(sink.transportEvents.last['count'], 1);
    expect(sink.transportEvents.last.containsKey('reason'), isFalse);
    expect(sink.transportEvents.toString(), isNot(contains('secret')));
  });

  test('safe Rift rejection facts are written to local app.jsonl', () async {
    final directory = await Directory.systemTemp.createTemp('rift-safe-log-');
    addTearDown(() => directory.delete(recursive: true));
    final sink = FileDownloadDiagnosticsV2(
      enabled: () => true,
      fileName: 'app.jsonl',
      directoryProvider: () async => directory,
      buildIdentityProvider: () async => (version: '1.0.0', buildNumber: '1'),
    );
    final diagnostics = AppDiagnostics(sink: sink);
    diagnostics.recordRiftRequest(
      url: 'https://example.org/api/v4/comment/create?token=secret',
      method: 'POST',
      durationMs: 42,
      httpStatus: 403,
      failureKind: 'access',
      serverReason: 'accessDenied',
    );
    await diagnostics.flush();
    final text = await File('${directory.path}/app.jsonl').readAsString();
    final row = jsonDecode(text.trim()) as Map<String, dynamic>;
    expect(row['event'], 'rift.api.complete');
    expect(row['status'], 'comment.create');
    expect(row['httpStatus'], 403);
    expect(row['reason'], 'accessDenied');
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('example.org')));
  });

  test(
    'navigation labels are fixed categories rather than route arguments',
    () {
      expect(
        AppDiagnostics.safeScreen('/details/private123?session=secret'),
        'details',
      );
      expect(
        AppDiagnostics.safeScreen('/player/episode-id?token=secret'),
        'player',
      );
      expect(AppDiagnostics.safeScreen('/private-user-id'), 'other');
    },
  );
  test('application diagnostics permit safe metadata and reject secrets', () {
    final sink = InMemoryDownloadDiagnosticsV2();
    final diagnostics = AppDiagnostics(sink: sink);
    diagnostics.record('rift.api.complete', {
      'action': 'GET',
      'status': 'library.details',
      'durationMs': 1700,
      'httpStatus': 503,
      'memoryBytes': 2048,
      'url': 'https://example.org?token=private',
      'authorization': 'Bearer private',
      'reason': 'https://example.org?token=private',
    });
    expect(sink.transportEvents.single, {
      'event': 'rift.api.complete',
      'action': 'GET',
      'status': 'library.details',
      'durationMs': 1700,
      'httpStatus': 503,
      'memoryBytes': 2048,
    });
  });

  test('comment diagnostics preserve linked state without an account ID', () {
    final sink = InMemoryDownloadDiagnosticsV2();
    final diagnostics = AppDiagnostics(sink: sink);
    for (final linked in [true, false, 'private-account-id']) {
      diagnostics.record('rift.comments.page', {
        'active': linked,
        'parentActive': false,
        'count': 0,
      });
    }
    expect(sink.transportEvents[0]['active'], isTrue);
    expect(sink.transportEvents[1]['active'], isFalse);
    expect(sink.transportEvents[2].containsKey('active'), isFalse);
  });

  test('frame stutters are sampled, ordinary frames are not logged', () {
    var now = 100000;
    final sink = InMemoryDownloadDiagnosticsV2();
    final diagnostics = AppDiagnostics(sink: sink, clockMillis: () => now);
    diagnostics.recordFrameDuration(const Duration(milliseconds: 12));
    diagnostics.recordFrameDuration(const Duration(milliseconds: 180));
    now += 3000;
    diagnostics.recordFrameDuration(const Duration(milliseconds: 900));
    now += 12000;
    diagnostics.recordFrameDuration(const Duration(milliseconds: 200));
    expect(sink.transportEvents.map((event) => event['durationMs']), [
      180,
      200,
    ]);
  });
}
