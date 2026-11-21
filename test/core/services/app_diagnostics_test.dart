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
      900, // Worst suppressed frame is preserved in a bounded summary.
      200,
    ]);
    expect(sink.transportEvents.map((event) => event['event']), [
      'app.frame.jank',
      'app.frame.jankSummary',
      'app.frame.jank',
    ]);
    expect(sink.transportEvents[1]['count'], 1);
  });

  test(
    'frame logs distinguish build from raster and sanitize screen',
    () async {
      var now = 40000;
      final sink = InMemoryDownloadDiagnosticsV2();
      final diagnostics = AppDiagnostics(sink: sink, clockMillis: () => now);
      diagnostics.setCurrentScreen('/details/private-anime-id?token=hidden');
      diagnostics.recordFrameDuration(const Duration(milliseconds: 45));
      expect(sink.transportEvents, isEmpty);
      diagnostics.recordFrameDuration(
        const Duration(milliseconds: 95),
        buildDuration: const Duration(milliseconds: 80),
        rasterDuration: const Duration(milliseconds: 9),
        vsyncOverhead: const Duration(milliseconds: 4),
      );
      expect(sink.transportEvents.single['status'], 'build');
      expect(sink.transportEvents.single['action'], 'details');
      expect(sink.transportEvents.single['buildMs'], 80);
      expect(sink.transportEvents.single['rasterMs'], 9);
      expect(sink.transportEvents.single['vsyncMs'], 4);

      diagnostics.recordFrameDuration(
        const Duration(milliseconds: 180),
        buildDuration: const Duration(milliseconds: 13),
        rasterDuration: const Duration(milliseconds: 153),
      );
      now += 300;
      diagnostics.recordFrameDuration(
        const Duration(milliseconds: 210),
        buildDuration: const Duration(milliseconds: 17),
        rasterDuration: const Duration(milliseconds: 190),
      );
      await diagnostics.flush();
      expect(sink.transportEvents, hasLength(2));
      expect(sink.transportEvents.last['event'], 'app.frame.jankSummary');
      expect(sink.transportEvents.last['status'], 'raster');
      expect(sink.transportEvents.last['action'], 'details');
      expect(sink.transportEvents.last['count'], 2);
      expect(sink.transportEvents.last['durationMs'], 210);
      expect(sink.transportEvents.last['rasterMs'], 190);
      expect(
        sink.transportEvents.toString(),
        isNot(contains('private-anime-id')),
      );
      expect(sink.transportEvents.toString(), isNot(contains('token')));
    },
  );
}
