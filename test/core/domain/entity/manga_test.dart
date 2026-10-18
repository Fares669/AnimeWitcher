import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final name in <String>[
    '201',
    '12.5',
    '٠١٢.٥',
    '(Extra)',
    'Chapter 12.5 (Extra)',
    'MangaLek: الفصل ١٢.٥ (خاص)',
    '  ٠١٢.٥ &amp; <b>خاص</b>  ',
  ]) {
    test('MangaChapter preserves exact server name "$name"', () {
      final chapter = MangaChapter(
        id: '12.5',
        mangaId: 'm1',
        url: 'chapter://12.5',
        name: name,
        number: 12.5,
      );

      expect(MangaChapter.fromJson(chapter.toJson())?.name, name);
      expect(chapter.displayName, name);
    });
  }

  test('MangaChapter display falls back only for a missing name', () {
    MangaChapter chapter(String name, {double? number}) => MangaChapter(
      id: 'c1',
      mangaId: 'm1',
      url: 'chapter://c1',
      name: name,
      number: number,
    );

    expect(chapter('201', number: 201).displayName, '201');
    expect(chapter('Special A').displayName, 'Special A');
    expect(chapter('  ').displayName, 'الفصل');
    expect(chapter('', number: 12).displayName, 'الفصل 12');
    expect(chapter('', number: 12.5).displayName, 'الفصل 12.5');
  });

  test('MangaChapter keeps decimal and special chapter identity', () {
    const decimal = MangaChapter(
      id: '12.5',
      mangaId: 'm1',
      url: 'chapter://12.5',
      name: 'الفصل 12.5',
      number: 12.5,
    );
    const special = MangaChapter(
      id: 'extra-a',
      mangaId: 'm1',
      url: 'chapter://extra-a',
      name: 'Extra A',
    );

    expect(decimal.number, 12.5);
    expect(special.number, isNull);
  });

  test('MangaPage keeps ordered page identity and request headers', () {
    const page = MangaPage(
      index: 7,
      imageUrl: 'https://images.example/008.webp',
      headers: <String, String>{'Referer': 'https://animewitcher.com/'},
    );

    expect(page.index, 7);
    expect(page.headers['Referer'], 'https://animewitcher.com/');
  });

  test('manga and manhwa content labels parse as manga', () {
    expect(
      MultimediaItem.parseContentType('manga'),
      MultimediaContentType.manga,
    );
    expect(
      MultimediaItem.parseContentType('مانجا'),
      MultimediaContentType.manga,
    );
    expect(
      MultimediaItem.parseContentType('مانهوا'),
      MultimediaContentType.manga,
    );
  });

  test('manga content type survives JSON round trip', () {
    final item = MultimediaItem(
      title: 'Title',
      url: 'https://animewitcher.com/manga/m1',
      posterUrl: 'https://images.example/m1.webp',
      contentType: MultimediaContentType.manga,
      catalogType: 'مانهوا',
    );

    final decoded = MultimediaItem.fromJson(item.toJson());

    expect(decoded.contentType, MultimediaContentType.manga);
    expect(decoded.catalogType, 'مانهوا');
  });
}
