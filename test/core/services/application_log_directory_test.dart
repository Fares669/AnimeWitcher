import 'dart:io';

import 'package:animewitcher/core/services/app_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app and download logs share a folder and export safe JSONL', () async {
    final root = await Directory.systemTemp.createTemp('animewitcher-logs-');
    addTearDown(() => root.delete(recursive: true));
    final appSink = FileDownloadDiagnosticsV2(
      directoryProvider: () async => root,
      enabled: () => true,
      fileName: 'app.jsonl',
    );
    final downloadSink = FileDownloadDiagnosticsV2(
      directoryProvider: () async => root,
      enabled: () => true,
    );
    final app = AppDiagnostics(sink: appSink);
    app.record('rift.auth.registrationFailed', {
      'status': 'deviceSuspended',
      'httpStatus': 403,
      'delayMs': 60000,
      'authorization': 'Bearer private',
      'url': 'https://example.test/secret',
    });
    downloadSink.recordTransport('download.test', {'status': 'paused'});
    await Future.wait([app.flush(), downloadSink.flush()]);
    final files = await downloadSink.listFiles();
    expect(files.map((file) => file.uri.pathSegments.last).toSet(), {
      'app.jsonl',
      'download_v2.jsonl',
    });
    final text = await File('${root.path}/app.jsonl').readAsString();
    expect(text, contains('rift.auth.registrationFailed'));
    expect(text, contains('60000'));
    expect(text, isNot(contains('Bearer private')));
    expect(text, isNot(contains('example.test')));
  });
}
