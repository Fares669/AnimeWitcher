import 'dart:io';
import 'dart:typed_data';

import 'package:animewitcher/core/network/poster_cache.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;
  @override
  Future<String?> getTemporaryPath() async => '${root.path}/shared-temp';
  @override
  Future<String?> getApplicationSupportPath() async =>
      '${root.path}/app-support';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('clear and measure only indexed media, preserving shared temp and downloads', () async {
    final root = await Directory.systemTemp.createTemp('aw_media_clear_');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root);
    final temp = await Directory('${root.path}/shared-temp').create();
    await Directory('${root.path}/app-support').create();
    try {
      final defaultFile = await DefaultCacheManager().putFile(
        'https://example.test/default',
        Uint8List.fromList([1, 2, 3]),
        fileExtension: 'jpg',
      );
      final posterFile = await posterCacheManager.putFile(
        'https://example.test/poster',
        Uint8List.fromList([1, 2, 3, 4]),
        fileExtension: 'jpg',
      );
      final orphan = await File('${temp.path}/libCachedImageData/other-app.jpg')
          .writeAsBytes([1, 2, 3, 4, 5]);
      final download = await File('${temp.path}/episode.mp4')
          .writeAsBytes([1, 2, 3, 4, 5, 6]);
      final chapterDir = await Directory(
        '${temp.path}/manga_reader_chapter_cache',
      ).create();
      await File('${chapterDir.path}/chapter.json').writeAsBytes([1, 2]);
      final storage = StorageService();
      expect(await storage.computeImageVideoCacheBytes(), 9);
      await storage.clearImageVideoCache();
      expect(await storage.computeImageVideoCacheBytes(), 0);
      expect(await defaultFile.exists(), isFalse);
      expect(await posterFile.exists(), isFalse);
      expect(await orphan.length(), 5);
      expect(await download.length(), 6);
      expect(await temp.exists(), isTrue);
      await storage.clearImageVideoCache();
      await DefaultCacheManager().config.repo.insert(
        CacheObject(
          'https://example.test/corrupt',
          relativePath: '../episode.mp4',
          validTill: DateTime.now().add(const Duration(days: 1)),
        ),
      );
      await expectLater(
        storage.clearImageVideoCache(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await download.length(), 6);
    } finally {
      await DefaultCacheManager().dispose();
      await posterCacheManager.dispose();
      PathProviderPlatform.instance = previous;
      await root.delete(recursive: true);
    }
  });
}
