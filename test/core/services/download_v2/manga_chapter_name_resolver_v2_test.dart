import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ChapterProvider implements AnimeWitcherProvider {
  MangaChapter? receivedChapter;

  @override
  Future<List<MangaPage>> refreshMangaChapterPages(
    String mangaUrl,
    MangaChapter chapter,
  ) async {
    receivedChapter = chapter;
    return const <MangaPage>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final name in <String>['  ٠١٢.٥ &amp; <b>خاص</b>  ', '   ']) {
    test('chapter page refresh preserves nonblank name "$name"', () async {
      final provider = _ChapterProvider();
      final resolver = ProviderMangaChapterPageResolverV2((_) => provider);

      await resolver.resolve(<String, Object?>{
        'providerId': 'manga-provider',
        'mangaUrl': 'https://example.test/manga/m1',
        'mangaId': 'm1',
        'chapterId': 'c12.5',
        'chapterUrl': 'https://example.test/manga/m1/c12.5',
        'chapterName': name,
        'chapterNumber': 12.5,
      });

      expect(
        provider.receivedChapter?.name,
        name.trim().isEmpty ? 'c12.5' : name,
      );
    });
  }
}
