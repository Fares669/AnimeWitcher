import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DM-31 keeps refresh descriptor lifecycle inside DownloadService', () {
    final launcher = File(
      'lib/features/details/presentation/download_launcher.dart',
    ).readAsStringSync();
    final service = File('lib/core/services/download_service.dart')
        .readAsStringSync();
    final store = File('lib/core/services/download_url_refresh.dart')
        .readAsStringSync();

    // The launcher only supplies a draft. It must never independently persist
    // or delete the descriptor because that races the service start owner.
    expect(launcher, isNot(contains('await refreshStore.save(')));
    expect(launcher, isNot(contains('await refreshStore.remove(resolveUrl)')));
    expect(
      launcher,
      contains('refreshDescriptor: DownloadUrlRefreshDescriptor('),
    );

    expect(
      service,
      contains('DownloadUrlRefreshDescriptor? refreshDescriptor,'),
    );
    expect(service, contains('_commitRefreshDescriptorForGeneration('));

    // A task-local generation can reset when a replacement task is created,
    // so ownership must include the logical download and concrete task id.
    expect(store, contains('final String? ownerTaskId;'));
    expect(store, contains('final String? logicalId;'));
    expect(store, contains('Future<bool> claimOwnership('));
    expect(store, contains('Future<bool> removeForOwnerGeneration('));
    expect(store, contains('existingLogicalId != logicalId'));
    expect(store, contains('descriptor.ownerTaskId?.trim() != ownerTaskId.trim()'));

    // DownloadService is the sole authority that claims the owner while its
    // logical-start serialization is active.
    expect(service, contains('ownerTaskId: transferTask.taskId,'));
    expect(service, contains('logicalId: logicalId,'));
    expect(service, contains('claimOwnership: true,'));

    // Rollback must carry the owner outside the inner transfer-task scope so a
    // delayed failed start cannot delete a replacement task's descriptor.
    expect(service, contains('String? refreshDescriptorOwnerTaskId;'));
    expect(
      service,
      contains('refreshDescriptorOwnerTaskId = transferTask.taskId;'),
    );
    expect(service, contains('refreshDescriptorOwnerTaskId,'));

    // Destructive cleanup paths must prove descriptor ownership too. An old
    // cancel or tombstone GC pass cannot erase the descriptor of a newer task.
    expect(
      service,
      isNot(contains(
        'await _ref.read(downloadUrlRefreshStoreProvider).remove(trackingUrl);',
      )),
    );
    expect(
      service,
      isNot(contains('await refreshStore.remove(job.trackingUrl);')),
    );
    expect(service, contains('.removeForOwnerGeneration('));
    expect(service, contains('cancelJob?.generation ?? 0,'));
    expect(
      service,
      contains('job.taskId,\n          job.generation,'),
    );

    // Legacy generation-only cleanup remains available only for descriptors
    // that predate owner metadata; owned rows reject that weaker proof.
    expect(store, contains('Future<bool> removeForGeneration('));
    expect(store, contains('if (descriptor.ownerTaskId != null) return false;'));
  });
}
