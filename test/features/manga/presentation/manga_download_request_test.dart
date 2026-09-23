import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/services/download_v2/download_file_planner_v2.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  final originalPathProvider = PathProviderPlatform.instance;

  setUp(() {
    PathProviderPlatform.instance = _FakePathProviderPlatform('/tmp/Downloads');
  });

  tearDown(() {
    PathProviderPlatform.instance = originalPathProvider;
  });
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
    expect(request.parallelChunks, 4);
    expect(request.sourceDescriptor['chapterUrl'], chapter.url);
    expect(request.sourceDescriptor['mangaUrl'], manga.url);
    expect(
      p.normalize(request.destinationPath),
      endsWith(p.join('manga', 'Manga', 'الفصل 12.5')),
    );
  });

  test('anime episodes stay directly in Downloads/anime/title', () async {
    final seasonOne = Episode(
      name: 'حلقة 1',
      url: 'https://anime.test/one-piece/1',
      season: 1,
      episode: 1,
    );
    final seasonTwo = Episode(
      name: 'حلقة 1',
      url: 'https://anime.test/one-piece/season-2/1',
      season: 2,
      episode: 1,
    );
    final anime = MultimediaItem(
      title: 'ون بيس',
      url: 'https://anime.test/one-piece',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      episodes: <Episode>[seasonOne, seasonTwo],
    );

    final destination = await downloadDestinationPathV2(
      anime,
      episode: seasonTwo,
      filename: 'حلقة 1.mp4',
    );

    expect(
      p.normalize(destination),
      p.join('/tmp/Downloads', 'anime', 'ون بيس', 'حلقة 1.mp4'),
    );
  });
}

final class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.downloadsPath);

  final String downloadsPath;

  @override
  Future<String?> getDownloadsPath() async => downloadsPath;
}
