import 'dart:convert';

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
        'failureCategory',
        'holdCategory',
        'sourceRefreshReason',
        'integrityResult',
      }),
    );
    for (final forbidden in <String>[
      'url',
      'token=',
      'authorization',
      'bearer ',
      'header',
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
}
