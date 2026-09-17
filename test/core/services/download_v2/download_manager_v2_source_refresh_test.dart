import 'dart:async';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_manager_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_source_resolver_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('current-generation 403 resolves one fresh source and replaces task', () async {
    final store = InMemoryLogicalDownloadStoreV2();
    final gateway = _FakeGateway();
    final resolver = _FakeResolver(<ResolvedDownloadSourceV2>[
      const ResolvedDownloadSourceV2(
        url: 'https://cdn.example.invalid/first.mp4?token=old',
        headers: <String, String>{'authorization': 'old'},
        expectedBytes: 100,
      ),
      const ResolvedDownloadSourceV2(
        url: 'https://cdn.example.invalid/second.mp4?token=new',
        headers: <String, String>{'authorization': 'new'},
        expectedBytes: 100,
      ),
    ]);
    final manager = DownloadManagerV2(
      store: store,
      gateway: gateway,
      sourceResolver: resolver,
    );
    final request = _request();

    await manager.start(request);
    final oldTaskId = gateway.startedSpecs.single.taskId;
    expect(resolver.calls, 1);

    gateway.emitSourceExpired(oldTaskId);
    gateway.emitSourceExpired(oldTaskId);
    await gateway.waitForStarts(2);

    expect(resolver.calls, 2);
    expect(gateway.startedSpecs, hasLength(2));
    expect(gateway.startedSpecs.first.url, contains('token=old'));
    expect(gateway.startedSpecs.last.url, contains('token=new'));
    expect(gateway.startedSpecs.last.taskId, isNot(oldTaskId));
    expect(gateway.handleFor(oldTaskId)?.cancelCalls, 1);

    final current = await store.get(request.logicalId);
    expect(current, isNotNull);
    expect(current!.taskId, gateway.startedSpecs.last.taskId);
    expect(current.generation, 2);
    expect(current.expectedBytes, 100);
  });
}

DownloadStartRequestV2 _request() {
  final logicalId = logicalDownloadIdFor(
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
  );
  return DownloadStartRequestV2(
    logicalId: logicalId,
    animeId: 'anilist:21',
    episodeKey: '12',
    variantKey: 'sub:1080p',
    destinationPath: 'downloads/anime/episode-12.mp4',
    sourceDescriptor: const <String, Object?>{
      'providerId': 'provider.example',
      'trackingUrl': '/anime/21/12',
    },
    allowPause: true,
    retries: 2,
    parallelChunks: 1,
  );
}

final class _FakeResolver implements DownloadSourceResolverV2 {
  _FakeResolver(this._sources);

  final List<ResolvedDownloadSourceV2> _sources;
  int calls = 0;

  @override
  Future<ResolvedDownloadSourceV2> resolve(
    Map<String, Object?> descriptor,
  ) async {
    final index = calls++;
    return _sources[index];
  }
}

final class _FakeGateway implements BackgroundDownloaderGateway {
  final List<DownloadTaskSpecV2> startedSpecs = <DownloadTaskSpecV2>[];
  final Map<String, _FakeHandle> _handles = <String, _FakeHandle>{};
  final List<Completer<void>> _startWaiters = <Completer<void>>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<DownloadTransportHandle> start(DownloadTaskSpecV2 spec) async {
    startedSpecs.add(spec);
    final handle = _FakeHandle(
      DownloadTransportSnapshot(
        taskId: spec.taskId,
        status: DownloadTransportStatus.running,
        progress: 0,
      ),
    );
    _handles[spec.taskId] = handle;
    for (final waiter in List<Completer<void>>.from(_startWaiters)) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _startWaiters.clear();
    return handle;
  }

  @override
  Future<DownloadTransportHandle?> attach(String taskId) async => _handles[taskId];

  @override
  Future<List<DownloadTransportHandle>> rehydrate() async =>
      _handles.values.toList(growable: false);

  @override
  Future<void> removeTracking(String taskId) async {}

  _FakeHandle? handleFor(String taskId) => _handles[taskId];

  void emitSourceExpired(String taskId) {
    _handles[taskId]?.emit(
      DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.failed,
        progress: 0.5,
        failureCategory: DownloadFailureCategory.sourceExpired,
        failureMessage: 'HTTP 403',
      ),
    );
  }

  Future<void> waitForStarts(int count) async {
    while (startedSpecs.length < count) {
      final waiter = Completer<void>();
      _startWaiters.add(waiter);
      await waiter.future.timeout(const Duration(seconds: 2));
    }
  }
}

final class _FakeHandle implements DownloadTransportHandle {
  _FakeHandle(this._current);

  DownloadTransportSnapshot _current;
  final StreamController<DownloadTransportSnapshot> _controller =
      StreamController<DownloadTransportSnapshot>.broadcast(sync: true);
  int cancelCalls = 0;

  @override
  String get taskId => _current.taskId;

  @override
  DownloadTransportSnapshot get current => _current;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => _controller.stream;

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async {
    cancelCalls++;
    return true;
  }

  void emit(DownloadTransportSnapshot snapshot) {
    _current = snapshot;
    _controller.add(snapshot);
  }
}
