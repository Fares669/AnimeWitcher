import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_file_planner_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('manga chapter request uses readable Downloads/manga folders', () async {
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

    final request = await mangaChapterDownloadRequest(manga, chapter);

    expect(request.mediaKind, DownloadMediaKind.mangaChapter);
    expect(request.mediaId, 'm1');
    expect(request.unitKey, '12.5');
    expect(request.parallelChunks, 1);
    expect(request.sourceDescriptor['chapterUrl'], chapter.url);
    expect(request.sourceDescriptor['mangaUrl'], manga.url);
    expect(
      p.normalize(request.destinationPath),
      endsWith(p.join('manga', 'Manga', 'الفصل 12.5')),
    );
  });

  test('anime destination uses anime/title without AnimeWitcher wrapper', () async {
    final anime = MultimediaItem(
      title: 'ون بيس',
      url: 'https://anime.test/one-piece',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
    );

    final destination = await downloadDestinationPathV2(
      anime,
      filename: 'حلقة 1.mp4',
    );
    final normalized = p.normalize(destination);

    expect(normalized, contains(p.join('anime', 'ون بيس')));
    expect(normalized, isNot(contains(p.join('AnimeWitcher', 'Downloads'))));
  });
}
