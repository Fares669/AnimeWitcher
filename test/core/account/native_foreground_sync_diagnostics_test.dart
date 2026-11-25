import 'dart:async';

import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/services/app_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('foreground sync records start before delayed completion', () async {
    final sink = InMemoryDownloadDiagnosticsV2();
    final pending = Completer<void>();
    var calls = 0;
    final operation = runNativeForegroundSync(() {
      calls++;
      return pending.future;
    }, diagnostics: AppDiagnostics(sink: sink));
    expect(calls, 1);
    expect(sink.transportEvents.single, {
      'event': 'native.sync.start',
      'status': 'foreground',
    });
    pending.complete();
    await operation;
    expect(sink.transportEvents.last, {
      'event': 'native.sync.complete',
      'status': 'foreground',
      'durationMs': isNonNegative,
      'result': true,
    });
  });

  test('failure preserves error and logs only allowlisted code', () async {
    final sink = InMemoryDownloadDiagnosticsV2();
    const error = AnimeWitcherAccountException(
      'invalid-session',
      'private token https://private.example/user',
    );
    await expectLater(
      runNativeForegroundSync(
        () => Future<void>.error(error),
        diagnostics: AppDiagnostics(sink: sink),
      ),
      throwsA(same(error)),
    );
    expect(sink.transportEvents.last['result'], false);
    expect(sink.transportEvents.last['durationMs'], isNonNegative);
    expect(sink.transportEvents[1]['status'], 'invalid-session');
    expect(sink.transportEvents.toString(), isNot(contains('private')));
  });
}
