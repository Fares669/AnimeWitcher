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
  });
}
