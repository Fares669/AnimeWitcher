import 'dart:convert';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/download_v2_diagnostics.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('diagnostic event serializes only allowlisted non-secret fields', () {
    final event = DownloadDiagnosticEventV2(
      logicalId: const DownloadLogicalId('logical-episode'),
      generation: 2,
      taskId: 'aw_v2_parent_g2',
      status: DownloadTransportStatus.failed,
      progress: 0.5,
      transferredBytes: 50,
      totalBytes: 100,
      networkSpeedMBps: 3.25,
      timeRemainingSeconds: 15,
      configuredConnections: 16,
      activeConnections: 8,
      failureCategory: DownloadFailureCategory.sourceExpired,
      holdCategory: DownloadV2HoldCategory.packageHeld,
      sourceRefreshReason: DownloadV2SourceRefreshReason.authorizationExpired,
      integrityResult: DownloadV2IntegrityResult.sizeMismatch,
    );

    final json = event.toJson();
    final encoded = jsonEncode(json).toLowerCase();

    expect(
      json.keys,
      unorderedEquals(<String>{
        'logicalId',
        'generation',
        'taskId',
        'status',
        'progress',
        'transferredBytes',
        'totalBytes',
        'networkSpeedMBps',
        'timeRemainingSeconds',
        'configuredConnections',
        'activeConnections',
        'failureCategory',
        'holdCategory',
        'sourceRefreshReason',
        'integrityResult',
      }),
    );
    expect(json['transferredBytes'], 50);
    expect(json['totalBytes'], 100);
    expect(json['networkSpeedMBps'], 3.25);
    expect(json['timeRemainingSeconds'], 15);
    expect(json['configuredConnections'], 16);
    expect(json['activeConnections'], 8);

    for (final forbidden in <String>[
      '"url"',
      'token=',
      'bearer ',
      '"headers"',
      'failuremessage',
    ]) {
      expect(encoded, isNot(contains(forbidden)));
    }
  });

  test('in-memory diagnostics records structured events without free-form data', () {
    final diagnostics = InMemoryDownloadDiagnosticsV2();
    final event = DownloadDiagnosticEventV2(
      logicalId: const DownloadLogicalId('logical-episode'),
      generation: 1,
      taskId: 'aw_v2_parent_g1',
      status: DownloadTransportStatus.running,
      progress: 0.25,
    );

    diagnostics.record(event);

    expect(diagnostics.events, <DownloadDiagnosticEventV2>[event]);
  });

  test('file diagnostics exposes support directory and files without V1', () async {
    final directory = await Directory.systemTemp.createTemp('aw-v2-support-log-');
    addTearDown(() => directory.delete(recursive: true));
    final diagnostics = FileDownloadDiagnosticsV2(
      directoryProvider: () async => directory,
      enabled: () => true,
      nowMillis: () => 7,
    );

    expect(await diagnostics.directory(), directory);
    expect(await diagnostics.listFiles(), isEmpty);
    expect(diagnostics.lastError, isNull);

    diagnostics.record(
      const DownloadDiagnosticEventV2(
        logicalId: DownloadLogicalId('support-episode'),
        generation: 1,
        taskId: 'aw_v2_support_g1',
        status: DownloadTransportStatus.running,
        progress: 0.1,
      ),
    );
    await diagnostics.flush();

    final files = await diagnostics.listFiles();
    expect(files, hasLength(1));
    expect(files.single.path, endsWith('download_v2.jsonl'));
    expect(diagnostics.lastError, isNull);
  });

  test('file diagnostics appends JSONL and honors the logging switch', () async {
    final directory = await Directory.systemTemp.createTemp('aw-v2-log-');
    addTearDown(() => directory.delete(recursive: true));
    var enabled = true;
    final diagnostics = FileDownloadDiagnosticsV2(
      directoryProvider: () async => directory,
      enabled: () => enabled,
      nowMillis: () => 42,
    );

    diagnostics.record(
      const DownloadDiagnosticEventV2(
        logicalId: DownloadLogicalId('logical-episode'),
        generation: 3,
        taskId: 'aw_v2_parent_g3',
        status: DownloadTransportStatus.running,
        progress: 0.75,
      ),
    );
    await diagnostics.flush();

    final file = File(
      '${directory.path}${Platform.pathSeparator}download_v2.jsonl',
    );
    final firstLines = await file.readAsLines();
    expect(firstLines, hasLength(1));
    final first = jsonDecode(firstLines.single) as Map<String, dynamic>;
    expect(first['timestampMillis'], 42);
    expect(first['logicalId'], 'logical-episode');
    expect(first['taskId'], 'aw_v2_parent_g3');
    expect(first.keys, isNot(contains('url')));
    expect(first.keys, isNot(contains('headers')));
    expect(first.keys, isNot(contains('failureMessage')));

    enabled = false;
    diagnostics.record(
      const DownloadDiagnosticEventV2(
        logicalId: DownloadLogicalId('logical-episode'),
        generation: 3,
        taskId: 'aw_v2_parent_g3',
        status: DownloadTransportStatus.complete,
        progress: 1,
      ),
    );
    await diagnostics.flush();

    expect(await file.readAsLines(), hasLength(1));
  });
}
