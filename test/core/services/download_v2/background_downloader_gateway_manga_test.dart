import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_transport_v2.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalPathProvider = PathProviderPlatform.instance;

  setUp(() {
    PathProviderPlatform.instance = _MangaTestPathProvider();
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProvider;
  });
  test('production background gateway exposes manga chapter transport', () {
    final gateway = PackageBackgroundDownloaderGateway(
      initializePackage: () async {},
    );

    expect(gateway, isA<MangaChapterGatewayV2>());
  });

  test('stale completed manga child is discarded when page file vanished', () async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_stale_child_');
    addTearDown(() => temp.delete(recursive: true));
    var removed = 0;

    final reusable = await reusableMangaPageHandleV2(
      existing: _CompleteHandle('chapter_p0001'),
      destinationPath: '${temp.path}/0001.webp',
      removeTracking: () async => removed++,
    );

    expect(reusable, isNull);
    expect(removed, 1);
  });

  test('completed manga child is reusable while page file is valid', () async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_valid_child_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/0001.webp');
    await file.writeAsBytes(<int>[1, 2, 3]);
    var removed = 0;
    final handle = _CompleteHandle('chapter_p0001');

    final reusable = await reusableMangaPageHandleV2(
      existing: handle,
      destinationPath: file.path,
      removeTracking: () async => removed++,
    );

    expect(reusable, same(handle));
    expect(removed, 0);
  });

  test('recovered paused manga child resumes before reuse', () async {
    final handle = _PausedHandle('chapter_p0001', resumeAccepted: true);
    var removed = 0;

    final reusable = await reusableMangaPageHandleV2(
      existing: handle,
      destinationPath: 'unused.webp',
      removeTracking: () async => removed++,
    );

    expect(reusable, same(handle));
    expect(handle.resumeCalls, 1);
    expect(handle.cancelCalls, 0);
    expect(removed, 0);
  });

  test('unresumable paused manga child is replaced instead of staying parked', () async {
    final handle = _PausedHandle('chapter_p0001', resumeAccepted: false);
    var removed = 0;

    final reusable = await reusableMangaPageHandleV2(
      existing: handle,
      destinationPath: 'unused.webp',
      removeTracking: () async => removed++,
    );

    expect(reusable, isNull);
    expect(handle.resumeCalls, 1);
    expect(handle.cancelCalls, 1);
    expect(removed, 1);
  });

  test(
    'manga page tasks share one running notification without page completions',
    () async {
      final firstPageTask = await packageMangaPageTaskForV2(
        const MangaChapterPageTaskV2(
          taskId: 'chapter_p0001',
          pageIndex: 0,
          url: 'https://cdn.test/0001.webp',
          headers: <String, String>{'Referer': 'https://manga.test/'},
          destinationPath: 'manga/test/0001.webp',
          retries: 2,
        ),
        userInitiated: true,
      );
      final secondPageTask = await packageMangaPageTaskForV2(
        const MangaChapterPageTaskV2(
          taskId: 'chapter_p0002',
          pageIndex: 1,
          url: 'https://cdn.test/0002.webp',
          headers: <String, String>{'Referer': 'https://manga.test/'},
          destinationPath: 'manga/test/0002.webp',
          retries: 2,
        ),
        userInitiated: true,
      );

      expect(firstPageTask, isA<DownloadTask>());
      expect(firstPageTask, isNot(isA<ParallelDownloadTask>()));
      expect(firstPageTask.group, kDownloadV2SilentPackageGroup);
      expect(firstPageTask.taskId, 'chapter_p0001');
      expect(firstPageTask.notificationConfig, isNotNull);
      expect(
        firstPageTask.notificationConfig!.groupNotificationId,
        'manga_chapter',
      );
      expect(firstPageTask.notificationConfig!.running, isNotNull);
      expect(firstPageTask.notificationConfig!.complete, isNull);
      expect(
        secondPageTask.notificationConfig!.groupNotificationId,
        'manga_chapter',
      );
      expect(secondPageTask.notificationConfig!.complete, isNull);
    },
  );
}

final class _CompleteHandle implements DownloadTransportHandle {
  _CompleteHandle(this.taskId);

  @override
  final String taskId;

  @override
  DownloadTransportSnapshot get current => DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.complete,
        progress: 1,
      );

  @override
  Stream<DownloadTransportSnapshot> get snapshots =>
      const Stream<DownloadTransportSnapshot>.empty();

  @override
  Future<bool> pause() async => false;

  @override
  Future<bool> resume() async => false;

  @override
  Future<bool> cancel() async => true;
}



final class _PausedHandle implements DownloadTransportHandle {
  _PausedHandle(this.taskId, {required this.resumeAccepted});

  @override
  final String taskId;
  final bool resumeAccepted;
  int resumeCalls = 0;
  int cancelCalls = 0;

  @override
  DownloadTransportSnapshot get current => DownloadTransportSnapshot(
        taskId: taskId,
        status: DownloadTransportStatus.paused,
        progress: 0.4,
      );

  @override
  Stream<DownloadTransportSnapshot> get snapshots =>
      const Stream<DownloadTransportSnapshot>.empty();

  @override
  Future<bool> pause() async => true;

  @override
  Future<bool> resume() async {
    resumeCalls++;
    return resumeAccepted;
  }

  @override
  Future<bool> cancel() async {
    cancelCalls++;
    return true;
  }
}

final class _MangaTestPathProvider extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async => Directory.systemTemp.path;
}
