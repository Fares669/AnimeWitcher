import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'zero-byte signed source replacement delegates stale generation cleanup to Transfers',
    () {
      final service = File('lib/core/services/download_service.dart')
          .readAsStringSync();
      final transport = File(
        'lib/core/services/background_downloader_transport.dart',
      ).readAsStringSync();
      final lock = File('pubspec.lock').readAsStringSync();

      expect(lock, contains('version: "9.6.2"'));
      expect(service, contains('partialBytes <= 0'));
      expect(service, contains('_nativeTransport.restartFromZero(updated)'));
      expect(service, contains('source.refreshPluginRestart'));
      expect(transport, contains('Future<bool> restartFromZero('));
      expect(transport, contains('await existing.cancel()'));
      expect(transport, contains('await existing.result.timeout('));
      expect(transport, contains('_downloader.transfers.remove(task.taskId)'));
      expect(transport, contains('_downloader.transfers.getOrStart('));
      expect(transport, contains('reEnqueueIfFailed: true'));
      expect(
        service,
        isNot(contains('BackgroundDownloaderCompat.clearResumeStateForTaskIds(')),
        reason:
            'pause/resume state cleanup must remain owned by background_downloader',
      );
    },
  );

  test('parent reconciliation asks the transport for targeted ownership', () {
    final source = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final start = source.indexOf('Future<void> _reconcileTransferOwnership()');
    final end = source.indexOf('Future<Set<String>> _livePartIds()', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final reconcile = source.substring(start, end);

    expect(
      reconcile,
      contains('final ownership = await _runtimeOwnershipFor(record.taskId);'),
    );
    expect(
      reconcile,
      contains('ownership != DownloadRuntimeOwnership.notOwned'),
    );
    expect(
      reconcile,
      isNot(contains('liveIds.contains(record.taskId)')),
      reason:
          'plugin parallel writers use child ids, so parent liveness must come from transport ownership',
    );
  });

  test(
    'parallel parent ownership requires runtime inventory, not projection alone',
    () {
      final transport = File(
        'lib/core/services/background_downloader_transport.dart',
      ).readAsStringSync();

      expect(transport, contains('final transfer = handleFor(taskId);'));
      expect(
        transport,
        contains('final runtimeTasks = await _downloader.allTasks(allGroups: true);'),
      );
      expect(transport, contains('final runtimeOwner = runtimeTasks.any((task)'));
      expect(transport, contains('downloadInternalParentTaskId(task)'));
      expect(
        transport,
        contains('if (projectedOwnership == DownloadRuntimeOwnership.owned)'),
      );
      expect(
        transport,
        isNot(contains('transfer?.task is ParallelDownloadTask')),
        reason: 'a rehydrated parent projection is not runtime ownership proof',
      );
    },
  );
}
