import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadTaskSpecV2', () {
    test('one parent spec carries aggregate package parallelism only', () {
      const spec = DownloadTaskSpecV2(
        taskId: 'aw_v2_x_g1',
        url: 'https://example.invalid/video.mp4',
        destinationPath: 'downloads/a.mp4',
        headers: <String, String>{},
        allowPause: true,
        retries: 2,
        parallelChunks: 5,
      );

      expect(spec.taskId, 'aw_v2_x_g1');
      expect(spec.url, 'https://example.invalid/video.mp4');
      expect(spec.destinationPath, 'downloads/a.mp4');
      expect(spec.headers, isEmpty);
      expect(spec.allowPause, isTrue);
      expect(spec.retries, 2);
      expect(spec.parallelChunks, 5);
    });

    test('parallel chunk count must be positive', () {
      expect(
        () => DownloadTaskSpecV2(
          taskId: 'aw_v2_x_g1',
          url: 'https://example.invalid/video.mp4',
          destinationPath: 'downloads/a.mp4',
          headers: const <String, String>{},
          allowPause: true,
          retries: 2,
          parallelChunks: 0,
        ),
        throwsAssertionError,
      );
    });
  });

  test('transport handle contract exposes parent task identity only', () {
    const snapshot = DownloadTransportSnapshot(
      taskId: 'aw_v2_x_g1',
      status: DownloadTransportStatus.running,
      progress: 0.25,
      transferredBytes: 25,
      totalBytes: 100,
    );
    final handle = _FakeDownloadTransportHandle(snapshot);

    expect(handle.taskId, snapshot.taskId);
    expect(handle.current, same(snapshot));
    expect(handle.current.progress, 0.25);
  });

  test('package notFound maps to missing transport instead of failure', () {
    expect(
      transportStatusFromPackage(
        TaskStatus.notFound,
        TransferHoldReason.none,
      ),
      DownloadTransportStatus.missing,
    );
  });
}

final class _FakeDownloadTransportHandle implements DownloadTransportHandle {
  _FakeDownloadTransportHandle(this.current);

  @override
  final DownloadTransportSnapshot current;

  @override
  String get taskId => current.taskId;

  @override
  Stream<DownloadTransportSnapshot> get snapshots => const Stream.empty();

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async => true;

  @override
  Future<bool> cancel() async => true;
}
