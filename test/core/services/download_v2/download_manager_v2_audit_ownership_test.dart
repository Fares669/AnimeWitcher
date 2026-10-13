import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'download_v2_test_support.dart';

void main() {
  test('canceled fence startup settles its older exact writer before replacement', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    final request = _request('fence');
    final old = f.gateway.add(taskIdForGeneration(request.logicalId, 1));
    final unrelated = f.gateway.add(taskIdForGeneration(_request('other').logicalId, 1));
    await f.store.put(_record(request, generation: 2, intent: DownloadUserIntent.canceled));
    final cancelEntered = Completer<void>();
    old.onCancel = () async {
      cancelEntered.complete();
      return true;
    };
    var initialized = false;
    final initialization = f.manager.initialize().whenComplete(() => initialized = true);
    await Future.any<void>([cancelEntered.future, initialization]);
    try {
      expect(cancelEntered.isCompleted, isTrue);
      expect(initialized, isFalse, reason: 'accepted cancel is not settled ownership');
      expect(f.gateway.startedSpecs, isEmpty);
      expect(f.resolver.calls, 0);
    } finally {
      old.emit(DownloadTransportStatus.canceled);
      await initialization;
    }
    await f.manager.restart(request.logicalId);
    expect(old.cancelCalls, 1);
    expect(unrelated.cancelCalls, 0);
    expect(f.gateway.startedSpecs, hasLength(1));
    expect(f.gateway.startedSpecs.single.taskId, taskIdForGeneration(request.logicalId, 3));
  });

  test('cancel crash boundary retains the real task ID and generation', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    final request = _request('crash');
    await f.manager.start(request);
    final oldTask = f.gateway.startedSpecs.single.taskId;
    final entered = Completer<void>();
    final release = Completer<void>();
    f.gateway.handles[oldTask]!.onCancel = () async {
      entered.complete();
      await release.future;
      f.gateway.handles[oldTask]!.emit(DownloadTransportStatus.canceled);
      return true;
    };
    final cancellation = f.manager.cancel(request.logicalId);
    await entered.future;
    try {
      final durable = (await f.store.get(request.logicalId))!;
      expect(durable.intent, DownloadUserIntent.canceled);
      expect(durable.taskId, oldTask);
      expect(durable.generation, 1);
    } finally {
      release.complete();
      await cancellation;
    }
    await f.manager.restart(request.logicalId);
    expect((await f.store.get(request.logicalId))?.generation, 2);
  });

  test('rejected older canceled writer retains live truth and admission', () async {
    final f = _Fixture(limit: 1);
    addTearDown(f.dispose);
    final request = _request('rejected-fence');
    final old = f.gateway.add(taskIdForGeneration(request.logicalId, 1));
    old.onCancel = () async => false;
    await f.store.put(_record(request, generation: 2, intent: DownloadUserIntent.canceled));
    await f.manager.initialize();
    expect(old.cancelCalls, 1);
    expect(f.manager.snapshotFor(request.logicalId)?.status, DownloadTransportStatus.running);
    final waiting = await f.manager.start(_request('wait-for-old'));
    expect(waiting.status, DownloadTransportStatus.queued);
    expect(f.gateway.startedSpecs, isEmpty);
    expect(f.gateway.removed, isNot(contains(old.taskId)));
  });

  for (final resumePaused in [false, true]) {
    test('${resumePaused ? 'paused resume' : 'fresh queued'} store publication wakes admission after the slot empties', () async {
      final store = _BlockedWaitingStore();
      final f = _Fixture(store: store, limit: 1);
      addTearDown(f.dispose);
      final waiting = _request('waiting-$resumePaused');
      if (resumePaused) {
        await f.manager.start(waiting);
        await f.manager.pause(waiting.logicalId);
      }
      final busy = _request('busy-$resumePaused');
      await f.manager.start(busy);
      final busyTask = (await store.get(busy.logicalId))!.taskId;
      store.blockId = waiting.logicalId;
      final queuedFuture = resumePaused
          ? f.manager.resume(waiting.logicalId)
          : f.manager.start(waiting);
      await store.entered.future;
      try {
        f.gateway.handles[busyTask]!.emit(DownloadTransportStatus.failed);
        await _until(() async => (await store.get(busy.logicalId))?.intent == DownloadUserIntent.failed);
        await f.manager.reconcileAdmission();
      } finally {
        store.release.complete();
      }
      expect((await queuedFuture).status, DownloadTransportStatus.queued);
      await _until(() async => resumePaused
          ? f.gateway.handles[taskIdForGeneration(waiting.logicalId, 1)]!.resumeCalls == 1
          : f.gateway.startedSpecs.any((spec) => spec.taskId == taskIdForGeneration(waiting.logicalId, 1)));
      final saved = (await store.get(waiting.logicalId))!;
      expect(saved.awaitingAdmission, isFalse);
      expect(saved.generation, 1);
      expect(saved.taskId, taskIdForGeneration(waiting.logicalId, 1));
    });
  }

  test('Pause on a failed final transfer preserves its Retry state', () async {
    final f = _Fixture();
    addTearDown(f.dispose);
    final request = _request('failed-pause');
    await f.manager.start(request);
    final taskId = f.gateway.startedSpecs.single.taskId;
    f.gateway.handles[taskId]!.emit(DownloadTransportStatus.failed);
    await _until(() async => (await f.store.get(request.logicalId))?.intent == DownloadUserIntent.failed);
    final before = (await f.store.get(request.logicalId))!;
    try {
      await f.manager.pause(request.logicalId);
    } on StateError {
      // Returning the final truth or rejecting Pause are both safe outcomes.
    }
    final after = (await f.store.get(request.logicalId))!;
    expect(after.intent, DownloadUserIntent.failed);
    expect(after.taskId, before.taskId);
    expect(after.generation, before.generation);
    expect(after.failureCategory, before.failureCategory);
    expect(after.failureMessage, before.failureMessage);
    await f.manager.restart(request.logicalId);
    expect((await f.store.get(request.logicalId))?.generation, 2);
    expect(f.gateway.startedSpecs, hasLength(2));
  });

  test('symlink alias with an absent final cannot admit a second writer', () async {
    final temp = await Directory.systemTemp.createTemp('aw-owner-alias-');
    addTearDown(() => temp.delete(recursive: true));
    final real = await Directory(p.join(temp.path, 'real')).create();
    final alias = Link(p.join(temp.path, 'alias'));
    await alias.create(real.path);
    final f = _Fixture();
    addTearDown(f.dispose);
    final first = _request('real', destination: p.join(real.path, 'missing', 'video.mp4'));
    final second = _request('alias', destination: p.join(alias.path, 'missing', 'video.mp4'));
    expect(await File(first.destinationPath).exists(), isFalse);
    await f.manager.start(first);
    await expectLater(f.manager.start(second), throwsStateError);
    expect(f.gateway.startedSpecs, hasLength(1));
    expect(await f.store.get(second.logicalId), isNull);
  }, skip: Platform.isWindows ? 'symlink creation needs platform privilege' : false);

  test('deleting a legacy symlink alias preserves another record final bytes', () async {
    final temp = await Directory.systemTemp.createTemp('aw-delete-alias-');
    addTearDown(() => temp.delete(recursive: true));
    final real = await Directory(p.join(temp.path, 'real')).create();
    final alias = Link(p.join(temp.path, 'alias'));
    await alias.create(real.path);
    final file = File(p.join(real.path, 'video.mp4'));
    const bytes = <int>[1, 2, 3, 4];
    await file.writeAsBytes(bytes);
    final f = _Fixture();
    addTearDown(f.dispose);
    final owner = _request('owner', destination: file.path);
    final legacy = _request('legacy', destination: p.join(alias.path, 'video.mp4'));
    await f.store.put(_record(owner).copyWith(completedAtMillis: 1, expectedBytes: bytes.length));
    await f.store.put(_record(legacy, intent: DownloadUserIntent.failed));
    await f.manager.initialize();
    await f.manager.delete(legacy.logicalId);
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), bytes);
    expect(await f.manager.hasCompletedDownload(owner.logicalId), isTrue);
    expect(await f.store.get(legacy.logicalId), isNull);
  }, skip: Platform.isWindows ? 'symlink creation needs platform privilege' : false);

  test('dangling existing symlink ancestor fails closed before source resolution', () async {
    final temp = await Directory.systemTemp.createTemp('aw-dangling-owner-');
    addTearDown(() => temp.delete(recursive: true));
    final link = Link(p.join(temp.path, 'dangling'));
    await link.create(p.join(temp.path, 'gone'));
    final f = _Fixture();
    addTearDown(f.dispose);
    final request = _request('dangling', destination: p.join(link.path, 'video.mp4'));
    await expectLater(f.manager.start(request), throwsA(isA<FileSystemException>()));
    expect(f.resolver.calls, 0);
    expect(f.gateway.startedSpecs, isEmpty);
    expect(await f.store.get(request.logicalId), isNull);
  }, skip: Platform.isWindows ? 'symlink creation needs platform privilege' : false);
}

DownloadStartRequestV2 _request(String unit, {String? destination}) {
  return DownloadStartRequestV2(
    logicalId: logicalDownloadIdFor(animeId: 'audit', episodeKey: unit, variantKey: 'sub'),
    mediaId: 'audit', unitKey: unit, variantKey: 'sub',
    destinationPath: destination ?? p.join(Directory.systemTemp.path, 'aw-audit-$unit.mp4'),
    sourceDescriptor: const <String, Object?>{}, allowPause: true, retries: 1,
    parallelChunks: 1, expectedBytes: 4,
  );
}

LogicalDownloadRecordV2 _record(
  DownloadStartRequestV2 request, {
  int generation = 1,
  DownloadUserIntent intent = DownloadUserIntent.active,
}) => LogicalDownloadRecordV2(
  schemaVersion: kLogicalDownloadSchemaVersionV2,
  logicalId: request.logicalId, mediaId: request.mediaId, unitKey: request.unitKey,
  variantKey: request.variantKey, generation: generation,
  taskId: taskIdForGeneration(request.logicalId, generation), intent: intent,
  destinationPath: request.destinationPath, sourceDescriptor: request.sourceDescriptor,
  expectedBytes: request.expectedBytes, updatedAtMillis: generation,
);

Future<void> _until(Future<bool> Function() done) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('expected ownership condition was not reached');
}

final class _Fixture {
  _Fixture({LogicalDownloadStoreV2? store, int limit = 10})
      : store = store ?? InMemoryLogicalDownloadStoreV2() {
    manager = DownloadManagerV2(
      store: this.store, gateway: gateway, sourceResolver: resolver,
      maxConcurrentDownloads: () => limit,
    );
  }
  final LogicalDownloadStoreV2 store;
  final gateway = _Gateway();
  final resolver = StaticSourceResolverV2(expectedBytes: 4);
  late final DownloadManagerV2 manager;
  Future<void> dispose() async {
    await manager.dispose();
    for (final handle in gateway.handles.values) {
      await handle.changes.close();
    }
  }
}

final class _BlockedWaitingStore implements LogicalDownloadStoreV2 {
  final inner = InMemoryLogicalDownloadStoreV2();
  DownloadLogicalId? blockId;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> put(LogicalDownloadRecordV2 record) async {
    if (record.logicalId == blockId && record.awaitingAdmission && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await inner.put(record);
  }
  @override
  Future<LogicalDownloadRecordV2?> get(DownloadLogicalId id) => inner.get(id);
  @override
  Future<List<LogicalDownloadRecordV2>> all() => inner.all();
  @override
  Future<void> remove(DownloadLogicalId id) => inner.remove(id);
  @override
  Future<LogicalDownloadRecordV2?> mutate(DownloadLogicalId id,
      LogicalDownloadRecordV2? Function(LogicalDownloadRecordV2?) change) => inner.mutate(id, change);
}

final class _Gateway implements BackgroundDownloaderGateway {
  final handles = <String, _Handle>{};
  final startedSpecs = <DownloadTaskSpecV2>[];
  final removed = <String>[];
  _Handle add(String taskId) => handles[taskId] = _Handle(taskId);
  @override
  Future<void> initialize() async {}
  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    startedSpecs.add(spec);
    return add(spec.taskId);
  }
  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => handles[taskId];
  @override
  Future<List<DownloadTransportHandle>> rehydrate() async => handles.values.toList();
  @override
  Future<void> removeTracking(String taskId) async => removed.add(taskId);
}

final class _Handle implements DownloadTransportHandle {
  _Handle(this.taskId);
  @override
  final String taskId;
  final changes = StreamController<DownloadTransportSnapshot>.broadcast(sync: true);
  DownloadTransportStatus status = DownloadTransportStatus.running;
  Future<bool> Function()? onCancel;
  int cancelCalls = 0;
  int resumeCalls = 0;
  @override
  DownloadTransportSnapshot get current => DownloadTransportSnapshot(
    taskId: taskId, status: status, progress: .5,
    failureCategory: status == DownloadTransportStatus.failed ? DownloadFailureCategory.transport : null,
    failureMessage: status == DownloadTransportStatus.failed ? 'audit transport failed' : null,
  );
  @override
  Stream<DownloadTransportSnapshot> get snapshots => changes.stream;
  void emit(DownloadTransportStatus next) {
    status = next;
    changes.add(current);
  }
  @override
  Future<bool> pause() async {
    emit(DownloadTransportStatus.paused);
    return true;
  }
  @override
  Future<bool> resume() async {
    resumeCalls++;
    emit(DownloadTransportStatus.running);
    return true;
  }
  @override
  Future<bool> cancel() async {
    cancelCalls++;
    if (onCancel != null) return onCancel!();
    emit(DownloadTransportStatus.canceled);
    return true;
  }
}
