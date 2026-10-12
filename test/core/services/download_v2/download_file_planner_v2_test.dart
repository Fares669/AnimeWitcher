import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_file_planner_v2.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  test('chapters sharing a display number have distinct destinations', () async {
    final temp = await Directory.systemTemp.createTemp('aw-chapter-identity-');
    addTearDown(() => temp.delete(recursive: true));
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(temp.path);
    addTearDown(() => PathProviderPlatform.instance = previous);

    final manga = MultimediaItem(title: 'Example', url: '/manga', posterUrl: '');
    const first = MangaChapter(
      id: 'chapter-first', mangaId: 'm1', url: '/chapter/first',
      name: 'Chapter one', number: 1,
    );
    const second = MangaChapter(
      id: 'chapter-second', mangaId: 'm1', url: '/chapter/second',
      name: 'Chapter one alt', number: 1,
    );

    final firstPath = await mangaChapterDestinationDirectoryV2(manga, first);
    final secondPath = await mangaChapterDestinationDirectoryV2(manga, second);
    expect(firstPath, isNot(secondPath));
    expect(p.basename(firstPath), contains('الفصل 1'));
    expect(p.basename(secondPath), contains('الفصل 1'));
  });

  test('existing chapter manifest keeps its legacy destination', () async {
    final temp = await Directory.systemTemp.createTemp('aw-chapter-legacy-');
    addTearDown(() => temp.delete(recursive: true));
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(temp.path);
    addTearDown(() => PathProviderPlatform.instance = previous);

    final manga = MultimediaItem(title: 'Example', url: '/manga', posterUrl: '');
    const chapter = MangaChapter(
      id: 'chapter-first', mangaId: 'm1', url: '/chapter/first',
      name: 'Chapter one', number: 1,
    );
    final oldPath = p.join(temp.path, 'manga', 'Example', 'الفصل 1');
    await MangaChapterManifestV2(
      version: MangaChapterManifestV2.currentVersion,
      mangaId: 'm1',
      chapterId: 'chapter-first',
      pageCount: 1,
      completedIndexes: const <int>{0},
      isComplete: true,
    ).writeTo(Directory(oldPath));

    expect(await mangaChapterDestinationDirectoryV2(manga, chapter), oldPath);
  });
}

final class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getDownloadsPath() async => path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}
