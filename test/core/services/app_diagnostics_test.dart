import 'package:animewitcher/core/services/app_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
