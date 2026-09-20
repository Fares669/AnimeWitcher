import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manga chapter request is always one-connection and durable', () {
    final manga = MultimediaItem(
      title: 'Manga',
      url: 'https://animewitcher.com/manga/m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: 'animewitcher.native',
      syncData: const <String, String>{'mangaId': 'm1'},
    );
    const chapter = MangaChapter(
      id: '12.5',
      mangaId: 'm1',
      url: 'https://manga.test/chapter-12-5/',
      name: 'الفصل 12.5',
      number: 12.5,
    );

    final request = mangaChapterDownloadRequest(manga, chapter);

    expect(request.mediaKind, DownloadMediaKind.mangaChapter);
    expect(request.mediaId, 'm1');
    expect(request.unitKey, '12.5');
    expect(request.parallelChunks, 1);
    expect(request.sourceDescriptor['chapterUrl'], chapter.url);
    expect(request.sourceDescriptor['mangaUrl'], manga.url);
    expect(request.destinationPath, startsWith('manga/'));
  });
}
