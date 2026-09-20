import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_manga_mapping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps live AnimeWitcher manga hit without episode semantics', () {
    final item = mapAnimeWitcherMangaHit(<String, Object?>{
      'objectID': 'm-42',
      'name': 'Solo Leveling',
      'type': 'مانهوا',
      'story': '<p>Hunter story</p>',
      'poster_uri': 'https://img.example/cover.webp',
      'mangalek_page_url': 'https://mangalik.net/manga/solo-leveling/',
      'mal_id': 1234,
      'aniList_id': 5678,
      'tags': <Object?>['أكشن', 'خيال'],
      'details': <String, Object?>{
        'year': '2018',
        'state': 'مكتمل',
        'english_title': 'Solo Leveling',
      },
    });

    expect(item.contentType, MultimediaContentType.manga);
    expect(item.catalogType, 'مانهوا');
    expect(item.title, 'Solo Leveling');
    expect(item.url, 'https://animewitcher.com/manga/m-42');
    expect(item.posterUrl, 'https://img.example/cover.webp');
    expect(item.description, 'Hunter story');
    expect(item.year, 2018);
    expect(item.status, ShowStatus.completed);
    expect(item.tags, containsAll(<String>['أكشن', 'خيال']));
    expect(item.episodes, isNull);
    expect(item.syncData?['mangaId'], 'm-42');
    expect(
      item.syncData?['mangalekPageUrl'],
      'https://mangalik.net/manga/solo-leveling/',
    );
    expect(item.syncData?['malId'], '1234');
    expect(item.syncData?['anilistId'], '5678');
    expect(item.syncData?['englishTitle'], 'Solo Leveling');
  });

  test('maps localized Firestore text without map syntax leaking to UI', () {
    final item = mapAnimeWitcherMangaHit(<String, Object?>{
      'objectID': 'm-localized',
      'name': <String, Object?>{'ar': 'اسم عربي', 'en': 'English Name'},
      'story': <String, Object?>{
        'ar': '<p>قصة عربية</p>',
        'en': '<p>English story</p>',
      },
      'type': 'مانهوا',
      'poster_uri': 'https://img.example/localized.webp',
      'mangalek_page_url': 'https://mangalik.net/manga/localized/',
    });

    expect(item.title, 'اسم عربي');
    expect(item.description, 'قصة عربية');
    expect(item.description, isNot(contains('{ar:')));
  });

  test('parses MangaLek chapter list including decimal and special chapters', () {
    const html = '''
<ul class="main version-chap no-volumn">
  <li class="wp-manga-chapter">
    <a href="https://mangalik.net/manga/title/chapter-12-5/">الفصل 12.5</a>
    <span class="chapter-release-date">2026-09-20</span>
  </li>
  <li class="wp-manga-chapter">
    <a href="/manga/title/special-a/">Special A</a>
  </li>
</ul>
''';

    final chapters = parseMangaLekChapters(
      html: html,
      mangaId: 'm-42',
      documentUrl: 'https://mangalik.net/manga/title/',
    );

    expect(chapters, hasLength(2));
    expect(chapters[0].number, 12.5);
    expect(chapters[0].name, 'الفصل 12.5');
    expect(chapters[0].publishedAt, DateTime(2026, 9, 20));
    expect(chapters[1].number, isNull);
    expect(
      chapters[1].url,
      'https://mangalik.net/manga/title/special-a/',
    );
  });

  test('parses current MangaLek WordPress archive chapter links', () {
    const html = '''
<main>
  <article class="post">
    <h2 class="entry-title">
      <a href="https://manga-leko.net/shadow-of-the-reborn-rogues-dominion-30-%D9%85%D8%AA%D8%B1%D8%AC%D9%85/">
        !Shadow Of The Reborn Rogue's Dominion الفصل 30 مترجم
      </a>
    </h2>
  </article>
  <article class="post">
    <h2 class="entry-title">
      <a href="https://manga-leko.net/shadow-of-the-reborn-rogues-dominion-29-%D9%85%D8%AA%D8%B1%D8%AC%D9%85/">
        !Shadow Of The Reborn Rogue's Dominion 29 مترجم
      </a>
    </h2>
  </article>
  <a href="/tag/shadow-of-the-reborn-rogues-dominion/">Series category</a>
  <a class="next page-numbers"
     href="/tag/shadow-of-the-reborn-rogues-dominion/page/2/">Next</a>
</main>
''';

    final chapters = parseMangaLekArchiveChapters(
      html: html,
      mangaId: 'shadow',
      documentUrl:
          'https://manga-leko.net/tag/shadow-of-the-reborn-rogues-dominion/',
    );

    expect(chapters, hasLength(2));
    expect(chapters.map((chapter) => chapter.number), <double?>[30, 29]);
    expect(
      chapters.first.url,
      startsWith(
        'https://manga-leko.net/shadow-of-the-reborn-rogues-dominion-30-',
      ),
    );
  });

  test('parses WordPress chapter article images without site chrome', () {
    const html = '''
<html>
  <body>
    <img src="https://manga-leko.net/logo.png">
    <article class="post">
      <div class="entry-content">
        <p><img data-src="https://cdn.example/chapter/001.webp"></p>
        <p><img src="https://cdn.example/chapter/002.jpg"></p>
      </div>
      <footer class="entry-footer">
        <img src="https://manga-leko.net/avatar.png">
      </footer>
    </article>
  </body>
</html>
''';

    final pages = parseMangaLekPages(
      html: html,
      chapterUrl:
          'https://manga-leko.net/shadow-of-the-reborn-rogues-dominion-30-%D9%85%D8%AA%D8%B1%D8%AC%D9%85/',
    );

    expect(pages.map((page) => page.imageUrl).toList(), <String>[
      'https://cdn.example/chapter/001.webp',
      'https://cdn.example/chapter/002.jpg',
    ]);
  });

  test('parses only reader images and keeps referer header', () {
    const html = '''
<html>
<body>
  <img src="https://img.example/logo.png">
  <div class="reading-content">
    <div class="page-break"><img data-src=" https://cdn.example/001.webp "></div>
    <div class="page-break"><img src="https://cdn.example/002.jpg"></div>
  </div>
  <img src="https://img.example/footer.png">
</body>
</html>
''';

    final pages = parseMangaLekPages(
      html: html,
      chapterUrl: 'https://mangalik.net/manga/title/chapter-1/',
    );

    expect(pages.map((page) => page.imageUrl).toList(), <String>[
      'https://cdn.example/001.webp',
      'https://cdn.example/002.jpg',
    ]);
    expect(pages[0].index, 0);
    expect(
      pages[0].headers['Referer'],
      'https://mangalik.net/manga/title/chapter-1/',
    );
  });
}
