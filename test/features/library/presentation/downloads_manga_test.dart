import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
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
}
