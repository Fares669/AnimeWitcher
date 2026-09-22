import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/services/download_v2/background_downloader_gateway.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_transport_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
  test('manga page package tasks are silent child transfers', () async {
    final temp = await Directory.systemTemp.createTemp('aw_manga_silent_');
    addTearDown(() => temp.delete(recursive: true));

    final task = await packageMangaPageTaskForV2(
      MangaChapterPageTaskV2(
        taskId: 'chapter_p0001',
        pageIndex: 0,
        url: 'https://cdn.test/0001.webp',
        headers: const <String, String>{'Referer': 'https://manga.test/'},
        destinationPath: '${temp.path}/0001.webp',
        retries: 2,
      ),
      userInitiated: true,
    );

    expect(task.group, kDownloadV2SilentPackageGroup);
    expect(task.taskId, 'chapter_p0001');
  });

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
