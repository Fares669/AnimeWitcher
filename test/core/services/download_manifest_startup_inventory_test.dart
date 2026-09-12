import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup unions trusted multipart manifests before recovery inventory', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();

    final recoveryStart = source.indexOf('Future<void> _recoverPersistedDownloads()');
    final manifestScan = source.indexOf(
      'discoverParallelManifestRecoveryEvidence',
      recoveryStart,
    );
    final inventoryBuild = source.indexOf(
      'buildDownloadRecoveryInventory(',
      recoveryStart,
    );

    expect(recoveryStart, greaterThanOrEqualTo(0));
    expect(manifestScan, greaterThan(recoveryStart));
    expect(inventoryBuild, greaterThan(manifestScan));
    expect(
      source,
      contains(
        "p.join(await _getPublicDownloadsPath(), 'AnimeWitcher', 'Downloads')",
      ),
    );
    expect(
      source,
      contains(
        'final manifestEvidenceById = '
        '<String, ParallelManifestRecoveryEvidence>{',
      ),
    );
    expect(
      source,
      contains('await _parallel.restore(manifestEvidence.parentTask!)'),
    );
  });

  test('manifest is descriptor fallback and never overrides stronger sources', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();

    expect(
      source,
      contains(
        'job.restoreTaskSnapshot() ??\n'
        '          _downloadTaskFromMetadataSnapshot(metadata) ??\n'
        '          manifestEvidenceById[job.taskId]?.parentTask',
      ),
    );
    expect(
      source,
      contains(
        '_downloadTaskFromMetadataSnapshot(metadata) ??\n'
        '          manifestEvidenceById[taskId]?.parentTask',
      ),
    );
    expect(
      source,
      contains("diagnosticLog.record('recovery.unresolvedManifest'"),
    );
    expect(
      source,
      contains('manifestEvidence.durableBytes / manifestEvidence.expectedBytes'),
    );
  });

  test('manifest-only recoverable parents enter durable inventory exactly once', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();
    final metadataLoop = source.indexOf('for (final entry in metadataById.entries)');
    final inventoryBuild = source.indexOf('buildDownloadRecoveryInventory(');
    final manifestOnlyLoop = source.indexOf(
      'for (final manifestEvidence in manifestEvidenceById.values)',
      metadataLoop,
    );

    expect(manifestOnlyLoop, greaterThan(metadataLoop));
    expect(manifestOnlyLoop, lessThan(inventoryBuild));
    expect(
      source,
      contains('knownExecutorIds.contains(manifestEvidence.parentTaskId)'),
    );
    expect(source, contains('jobById.containsKey(manifestEvidence.parentTaskId)'));
    expect(
      source,
      contains('metadataById.containsKey(manifestEvidence.parentTaskId)'),
    );
    expect(
      source,
      contains('TaskRecord(\n          parentTask,\n          TaskStatus.paused,'),
    );
  });

  test('unresolved legacy manifests settle known child writers before ignore', () {
    final source = File('lib/core/services/download_service.dart').readAsStringSync();

    expect(
      source,
      contains("diagnosticLog.record('recovery.unresolvedManifestOwnership'"),
    );
    expect(source, contains('await _pauseTransfer(childTask)'));
  });
}
