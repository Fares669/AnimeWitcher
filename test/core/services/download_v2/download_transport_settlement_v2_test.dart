import 'dart:async';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'single-task settlement uses Transfer.result, not cancel acceptance',
    () async {
      final fixture = await _PackageFixture.create();
      addTearDown(fixture.transfer.dispose);
      final observation = StreamIterator(fixture.handle.settlement());
      addTearDown(observation.cancel);
      var settled = false;
      final result = observation.moveNext().then((value) {
        settled = value;
        return value;
      });

      expect(fixture.transfer.resultReads, 1);
      expect(await fixture.handle.cancel(), isTrue);
      await _turn();
      expect(settled, isFalse);
      for (final status in [
        TaskStatus.paused,
        TaskStatus.enqueued,
        TaskStatus.running,
        TaskStatus.waitingToRetry,
      ]) {
        fixture.status(status);
        await _turn();
        expect(settled, isFalse, reason: '$status is not terminal');
      }

      fixture.status(TaskStatus.canceled);
      expect(await result, isTrue);
      expect(fixture.handle.isSettled, isTrue);
    },
  );

  for (final status in TaskStatus.values.where(
    (status) => status.isFinalState,
  )) {
    test('restored $status result is immediately observable', () async {
      final fixture = await _PackageFixture.create(initialStatus: status);
      addTearDown(fixture.transfer.dispose);
      final observation = StreamIterator(fixture.handle.settlement());
      addTearDown(observation.cancel);

      expect(await observation.moveNext(), isTrue);
      expect(fixture.handle.isSettled, isTrue);
      expect(fixture.transfer.resultReads, 1);
    });
  }

  test(
    'pause and exact resume retain bytes and the pending package result',
    () async {
      final fixture = await _PackageFixture.create(
        initialStatus: TaskStatus.paused,
      );
      addTearDown(fixture.transfer.dispose);
      fixture.transfer.updateProgress(
        TaskProgressUpdate(fixture.task, .4, 100),
      );
      await _turn();
      final observation = StreamIterator(fixture.handle.settlement());
      addTearDown(observation.cancel);
      var settled = false;
      final result = observation.moveNext().then((value) => settled = value);

      fixture.downloader.resumeAccepted = false;
      expect(await fixture.handle.resume(), isFalse);
      expect(fixture.downloader.resumeCalls, 1);
      expect(fixture.downloader.enqueueCalls, 0);
      expect(fixture.handle.current.transferredBytes, 40);
      expect(fixture.handle.current.progress, .4);
      await _turn();
      expect(settled, isFalse);

      fixture.downloader.resumeAccepted = true;
      expect(await fixture.handle.resume(), isTrue);
      fixture.status(TaskStatus.running);
      expect(fixture.handle.current.progress, .4);
      fixture.status(TaskStatus.complete);
      expect(await result, isTrue);
      expect(fixture.downloader.enqueueCalls, 0);
    },
  );

  test(
    'observation reads the fresh result after a final task is re-enqueued',
    () async {
      final fixture = await _PackageFixture.create(
        initialStatus: TaskStatus.failed,
      );
      addTearDown(fixture.transfer.dispose);
      final previous = StreamIterator(fixture.handle.settlement());
      expect(await previous.moveNext(), isTrue);
      await previous.cancel();

      fixture.status(TaskStatus.enqueued);
      final next = StreamIterator(fixture.handle.settlement());
      addTearDown(next.cancel);
      var settled = false;
      final result = next.moveNext().then((value) => settled = value);
      await _turn();
      expect(settled, isFalse);
      expect(fixture.transfer.resultReads, 2);
      fixture.status(TaskStatus.canceled);
      expect(await result, isTrue);
    },
  );

  test(
    'unresolved resume can demand a fresh snapshot instead of an old result',
    () async {
      final fixture = await _PackageFixture.create(
        initialStatus: TaskStatus.failed,
      );
      addTearDown(fixture.transfer.dispose);
      final observation = StreamIterator(
        fixture.handle.settlement(requireNewSnapshot: true),
      );
      addTearDown(observation.cancel);
      var settled = false;
      final result = observation.moveNext().then((value) => settled = value);
      await _turn();
      expect(settled, isFalse);
      expect(fixture.transfer.resultReads, 0);
      fixture.status(TaskStatus.running);
      await _turn();
      expect(settled, isFalse);
      fixture.status(TaskStatus.canceled);
      expect(await result, isTrue);
    },
  );

  test('parallel package parents keep snapshot settlement', () async {
    final fixture = await _PackageFixture.create(parallel: true);
    addTearDown(fixture.transfer.dispose);
    expect(fixture.handle, isNot(isA<CompletingDownloadTransportHandleV2>()));
    final observation = StreamIterator(fixture.handle.settlement());
    addTearDown(observation.cancel);
    final result = observation.moveNext();
    fixture.status(TaskStatus.canceled);
    expect(await result, isTrue);
    expect(fixture.transfer.resultReads, 0);
  });

  test(
    'custom parents wait for zero writers and release their observer',
    () async {
      final handle = _SnapshotHandle();
      addTearDown(handle.controller.close);
      final observation = StreamIterator(handle.settlement());
      var settled = false;
      final result = observation.moveNext().then((value) => settled = value);
      expect(handle.controller.hasListener, isTrue);
      handle.emit(DownloadTransportStatus.canceled, activeConnections: 2);
      await _turn();
      expect(settled, isFalse);
      expect(handle.isSettled, isFalse);
      handle.emit(DownloadTransportStatus.canceled, activeConnections: 0);
      expect(await result, isTrue);
      await observation.cancel();
      expect(handle.controller.hasListener, isFalse);
    },
  );

  test(
    'timeout releases the observer without reporting settled ownership',
    () async {
      final handle = _SnapshotHandle();
      addTearDown(handle.controller.close);
      final observation = StreamIterator(handle.settlement());
      final result = observation.moveNext()..ignore();
      await expectLater(
        result.timeout(const Duration(milliseconds: 1)),
        throwsA(isA<TimeoutException>()),
      );
      await observation.cancel();
      expect(handle.controller.hasListener, isFalse);
      expect(handle.isSettled, isFalse);
    },
  );

  test(
    'rejected cancel releases the observer and preserves paused progress',
    () async {
      final handle = _SnapshotHandle()..emit(DownloadTransportStatus.paused);
      addTearDown(handle.controller.close);
      await expectLater(
        reusableMangaPageHandleV2(
          existing: handle,
          destinationPath: 'unused',
          removeTracking: () async => fail('Unsettled tracking must stay'),
        ),
        throwsStateError,
      );
      expect(handle.controller.hasListener, isFalse);
      expect(handle.current.status, DownloadTransportStatus.paused);
      expect(handle.current.progress, .4);
    },
  );

  test('a closed observation stream is not terminal evidence', () async {
    final handle = _SnapshotHandle();
    final observation = StreamIterator(handle.settlement());
    final result = observation.moveNext();
    await handle.controller.close();
    expect(await result, isFalse);
    expect(handle.isSettled, isFalse);
    await observation.cancel();
  });

  test(
    'completion errors are observed while cancellation ACK is pending',
    () async {
      final handle = _FailingCompletionHandle()
        ..emit(DownloadTransportStatus.paused);
      addTearDown(handle.controller.close);
      final failure = StateError('terminal observation failed');
      final result = reusableMangaPageHandleV2(
        existing: handle,
        destinationPath: 'unused',
        removeTracking: () async => fail('Unsettled tracking must stay'),
      );
      final expectation = expectLater(result, throwsA(same(failure)));
      await _turn();
      handle.terminal.completeError(failure);
      await _turn();
      handle.cancelAck.complete(true);
      await expectation;
      expect(handle.isSettled, isFalse);
    },
  );
}

Future<void> _turn() => Future<void>.delayed(Duration.zero);

final class _PackageFixture {
  _PackageFixture(this.downloader, this.transfer, this.handle);
  final _Downloader downloader;
  final _ObservedTransfer transfer;
  final DownloadTransportHandle handle;
  DownloadTask get task => transfer.task as DownloadTask;

  static Future<_PackageFixture> create({
    TaskStatus initialStatus = TaskStatus.running,
    bool parallel = false,
  }) async {
    final downloader = _Downloader();
    final task = parallel
        ? ParallelDownloadTask(
            taskId: 'test',
            url: 'https://example.invalid/video',
            filename: 'video',
            chunks: 2,
            allowPause: true,
          )
        : DownloadTask(
            taskId: 'test',
            url: 'https://example.invalid/video',
            filename: 'video',
            allowPause: true,
          );
    final transfer = _ObservedTransfer(task, downloader, initialStatus);
    downloader.transfers = _Transfers(transfer);
    final gateway = PackageBackgroundDownloaderGateway(
      downloader: downloader,
      initializePackage: () async {},
      isIOS: () => false,
    );
    final handle = (await gateway.attach(task.taskId))!;
    return _PackageFixture(downloader, transfer, handle);
  }

  void status(TaskStatus status) =>
      transfer.updateStatus(TaskStatusUpdate(task, status));
}

final class _ObservedTransfer extends Transfer {
  _ObservedTransfer(super.task, super.downloader, super.initialStatus);
  int resultReads = 0;
  @override
  Future<TaskStatusUpdate> get result {
    resultReads++;
    return super.result;
  }
}

final class _Downloader implements FileDownloader {
  @override
  late Transfers transfers;
  bool resumeAccepted = true;
  int resumeCalls = 0;
  int enqueueCalls = 0;
  @override
  bool get isConnected => true;
  @override
  bool get isWiFi => true;
  @override
  Future<bool> resume(DownloadTask task) async {
    resumeCalls++;
    return resumeAccepted;
  }

  @override
  Future<bool> enqueue(Task task) async {
    enqueueCalls++;
    return true;
  }

  @override
  Future<bool> cancelTaskWithId(String taskId) async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Transfers implements Transfers {
  _Transfers(this.transfer);
  final Transfer transfer;
  @override
  Transfer? forId(String taskId) => taskId == transfer.taskId ? transfer : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _SnapshotHandle implements DownloadTransportHandle {
  final controller = StreamController<DownloadTransportSnapshot>.broadcast(
    sync: true,
  );
  @override
  final taskId = 'custom';
  @override
  late DownloadTransportSnapshot current = DownloadTransportSnapshot(
    taskId: taskId,
    status: DownloadTransportStatus.running,
    progress: .4,
  );
  @override
  Stream<DownloadTransportSnapshot> get snapshots => controller.stream;
  @override
  Future<bool> pause() async => false;
  @override
  Future<bool> resume() async => false;
  @override
  Future<bool> cancel() async => false;
  void emit(DownloadTransportStatus status, {int? activeConnections}) {
    current = DownloadTransportSnapshot(
      taskId: taskId,
      status: status,
      progress: .4,
      activeConnections: activeConnections,
    );
    controller.add(current);
  }
}

final class _FailingCompletionHandle extends _SnapshotHandle
    implements CompletingDownloadTransportHandleV2 {
  final terminal = Completer<void>();
  final cancelAck = Completer<bool>();
  @override
  Future<void> get completion => terminal.future;
  @override
  Future<bool> cancel() => cancelAck.future;
}
