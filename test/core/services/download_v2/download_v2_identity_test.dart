import 'package:flutter_test/flutter_test.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_identity.dart';

void main() {
  test('logical id is stable for the same logical episode', () {
    final first = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
    );
    final second = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
    );

    expect(first, second);
    expect(first.value, isNotEmpty);
  });

  test('logical id changes when episode or variant changes', () {
    final base = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
    );
    final otherEpisode = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '13',
      variantKey: 'sub:1080p',
    );
    final otherVariant = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'dub:1080p',
    );

    expect(base, isNot(otherEpisode));
    expect(base, isNot(otherVariant));
  });

  test('task id is deterministic per generation and changes across generations', () {
    final logical = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
    );

    final generationOne = taskIdForGeneration(logical, 1);
    final generationOneAgain = taskIdForGeneration(logical, 1);
    final generationTwo = taskIdForGeneration(logical, 2);

    expect(generationOne, generationOneAgain);
    expect(generationOne, isNot(generationTwo));
    expect(generationOne, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
  });

  test('task id rejects non-positive generations', () {
    final logical = logicalDownloadIdFor(
      animeId: 'anilist:21',
      episodeKey: '12',
      variantKey: 'sub:1080p',
    );

    expect(() => taskIdForGeneration(logical, 0), throwsArgumentError);
    expect(() => taskIdForGeneration(logical, -1), throwsArgumentError);
  });


  test('manga logical id uses stable manga and chapter ids only', () {
    final first = logicalDownloadIdForMangaChapter(
      mangaId: 'manga-42',
      chapterId: '12.5',
    );
    final rotatedPageUrls = logicalDownloadIdForMangaChapter(
      mangaId: 'manga-42',
      chapterId: '12.5',
    );
    final nextChapter = logicalDownloadIdForMangaChapter(
      mangaId: 'manga-42',
      chapterId: '13',
    );

    expect(first, rotatedPageUrls);
    expect(first, isNot(nextChapter));
    expect(first.value, startsWith('manga_'));
  });

  test('generated task parser preserves exact parents and zero-based manga pages', () {
    final video = logicalDownloadIdFor(animeId: 'a', episodeKey: 'e', variantKey: 'sub');
    final manga = logicalDownloadIdForMangaChapter(mangaId: 'm', chapterId: 'c');
    expect(parseDownloadTaskIdentityV2(taskIdForGeneration(video, 3)),
        (logicalId: video, generation: 3, pageIndex: null));
    expect(parseDownloadTaskIdentityV2(taskIdForGeneration(manga, 7)),
        (logicalId: manga, generation: 7, pageIndex: null));
    expect(parseDownloadTaskIdentityV2('${taskIdForGeneration(manga, 7)}_p0001'),
        (logicalId: manga, generation: 7, pageIndex: 0));
    expect(parseDownloadTaskIdentityV2('${taskIdForGeneration(manga, 7)}_p12345'),
        (logicalId: manga, generation: 7, pageIndex: 12344));
  });

  test('generated task parser rejects malformed IDs without broad prefix ownership', () {
    final manga = taskIdForGeneration(logicalDownloadIdForMangaChapter(mangaId: 'm', chapterId: 'c'), 1);
    final video = taskIdForGeneration(logicalDownloadIdFor(animeId: 'a', episodeKey: 'e', variantKey: 'sub'), 1);
    for (final id in [
      'unrelated', 'prefix_$manga', '${manga}_suffix', '${manga}_p0000',
      '${manga}_p001', '${manga}_p0001_extra', '${video}_p0001',
      manga.replaceFirst('_g1', '_g0'), manga.replaceFirst('_g1', '_g-1'),
      manga.replaceFirst('_g1', '_g01'), manga.toUpperCase(),
      manga.replaceFirst('_g1', '_g99999999999999999999999999999999999'),
    ]) {
      expect(parseDownloadTaskIdentityV2(id), isNull, reason: id);
    }
  });

}