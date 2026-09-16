import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'startup recovery reconciles authoritative downward byte corrections',
    () {
      final source = File('lib/core/services/download_service.dart')
          .readAsStringSync();
      expect(source, contains('reconcileDurableBytes('));
      expect(
        source,
        contains('DownloadByteReconciliationReason.noSurvivingBytes'),
      );
      expect(
        source,
        contains('DownloadByteReconciliationReason.exactDiskLoss'),
      );
      expect(
        source,
        contains('DownloadByteReconciliationReason.multipartManifestRollback'),
      );
    },
  );

  test('logical runtime ownership is delegated to transfer adapter', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final ownershipStart = source.indexOf(
      'Future<DownloadRuntimeOwnership> _runtimeOwnershipFor(String taskId)',
    );
    final ownershipEnd = source.indexOf(
      'Future<DownloadRuntimeOwnership> _waitForCancelOwnershipRelease(',
      ownershipStart,
    );

    expect(ownershipStart, greaterThanOrEqualTo(0));
    expect(ownershipEnd, greaterThan(ownershipStart));
    final ownershipSource = source.substring(ownershipStart, ownershipEnd);
    expect(ownershipSource, contains('_nativeTransport.ownershipFor(taskId)'));
    expect(ownershipSource, isNot(contains('_liveTransferTasks()')));
    expect(ownershipSource, isNot(contains('activeTasks.any')));
  });

  test('transport ownership requires runtime inventory evidence', () {
    final source = File(
      'lib/core/services/background_downloader_transport.dart',
    ).readAsStringSync();
    final ownershipStart = source.indexOf(
      'Future<DownloadRuntimeOwnership> ownershipFor(String taskId)',
    );
    final ownershipEnd = source.indexOf(
      '@override\n  Future<bool> start(',
      ownershipStart,
    );

    expect(ownershipStart, greaterThanOrEqualTo(0));
    expect(ownershipEnd, greaterThan(ownershipStart));
    final ownershipSource = source.substring(ownershipStart, ownershipEnd);
    expect(
      ownershipSource,
      contains('final projectedStatus = transfer?.status;'),
    );
    expect(
      ownershipSource,
      contains('final runtimeTasks = await _downloader.allTasks(allGroups: true);'),
    );
    expect(ownershipSource, contains('downloadInternalParentTaskId(task)'));
    expect(ownershipSource, contains('runtimeOwner'));
    expect(ownershipSource, isNot(contains('_downloader.taskForId(taskId)')));
    expect(
      ownershipSource,
      contains('return DownloadRuntimeOwnership.unknown;'),
    );

  test('parallel resume fails closed when runtime inventory query fails', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final methodStart = source.indexOf('Future<bool> _resumeDownloadTask(');
    final methodEnd = source.indexOf(
      'Future<bool> _resumeUsingPartialFile(',
      methodStart,
    );
    expect(methodStart, greaterThanOrEqualTo(0));
    expect(methodEnd, greaterThan(methodStart));
    final body = source.substring(methodStart, methodEnd);
    final parallelStart = body.indexOf('if (task is ParallelDownloadTask) {');
    final parallelEnd = body.indexOf(
      '// Only a validated source replacement may cross the custom Range seam.',
      parallelStart,
    );
    expect(parallelStart, greaterThanOrEqualTo(0));
    expect(parallelEnd, greaterThan(parallelStart));
    final parallel = body.substring(parallelStart, parallelEnd);

    final queryFlag = parallel.indexOf(
      'var pluginChunkEvidenceQuerySucceeded = false;',
    );
    final querySuccess = parallel.indexOf(
      'pluginChunkEvidenceQuerySucceeded = true;',
    );
    final queryFailure = parallel.indexOf(
      'if (!pluginChunkEvidenceQuerySucceeded) {',
    );
    final legacyImport = parallel.indexOf(
      'BackgroundDownloaderCompat.resumeDataForTaskId',
    );
    final freshEnqueue = parallel.indexOf(
      '_enqueueTransfer(task, saved.totalSize)',
    );

    expect(queryFlag, greaterThanOrEqualTo(0));
    expect(querySuccess, greaterThan(queryFlag));
    expect(queryFailure, greaterThan(querySuccess));
    expect(
      queryFailure,
      lessThan(legacyImport),
      reason:
          'an unavailable runtime inventory must not fall through to legacy adoption',
    );
    expect(
      queryFailure,
      lessThan(freshEnqueue),
      reason:
          'an unavailable runtime inventory must not create a replacement writer',
    );
  });

  });
}
