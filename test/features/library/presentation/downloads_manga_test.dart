import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manga download item carries media kind and chapter metadata', () {
    final item = DownloadItem(
      task: DownloadTask(
        taskId: 'manga-task',
        url: 'https://example.test/chapter',
        filename: 'chapter',
      ),
      status: TaskStatus.complete,
      progress: 1,
      item: MultimediaItem(
        title: 'Manga',
        url: 'manga://m1',
        posterUrl: '',
        contentType: MultimediaContentType.manga,
      ),
      mediaKind: DownloadMediaKind.mangaChapter,
      chapter: const MangaChapter(
        id: '12.5',
        mangaId: 'm1',
        url: 'chapter://12.5',
        name: 'الفصل 12.5',
        number: 12.5,
      ),
      timestamp: 1,
    );

    expect(item.mediaKind, DownloadMediaKind.mangaChapter);
    expect(item.chapter?.id, '12.5');
    expect(item.episode, isNull);
  });

  test('chapter list resolves the same completed V2 record as Downloads', () {
    const chapter = MangaChapter(
      id: '32',
      mangaId: 'm1',
      url: 'https://animewitcher.com/manga/m1/chapters/32',
      name: 'الفصل 32',
      number: 32,
    );
    final logicalId = logicalDownloadIdForMangaChapter(
      mangaId: chapter.mangaId,
      chapterId: chapter.id,
    ).value;
    final completed = DownloadItem(
      task: DownloadTask(
        taskId: 'manga-c32',
        url: chapter.url,
        filename: 'chapter-32',
      ),
      status: TaskStatus.complete,
      progress: 1,
      item: MultimediaItem(
        title: 'Manga',
        url: 'https://animewitcher.com/manga/m1',
        posterUrl: '',
        contentType: MultimediaContentType.manga,
      ),
      mediaKind: DownloadMediaKind.mangaChapter,
      logicalId: logicalId,
      chapter: chapter,
      destinationPath: '/Downloads/manga/Manga/الفصل 32',
      timestamp: 1,
    );

    final resolved = completedMangaChapterDownload(
      <DownloadItem>[completed],
      chapter,
    );

    expect(resolved, same(completed));
    expect(resolved?.destinationPath, completed.destinationPath);
  });

}
