import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_controller.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_paged_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const pages = <MangaPage>[
  MangaPage(index: 0, imageUrl: 'https://example.test/1.webp'),
  MangaPage(index: 1, imageUrl: 'https://example.test/2.webp'),
  MangaPage(index: 2, imageUrl: 'https://example.test/3.webp'),
];

void main() {
  test('reader exposes webtoon, paged LTR and paged RTL modes', () {
    expect(
      MangaReaderMode.values,
      <MangaReaderMode>[
        MangaReaderMode.webtoon,
        MangaReaderMode.pagedLtr,
        MangaReaderMode.pagedRtl,
      ],
    );
  });

  testWidgets('paged RTL reader reverses page direction', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaPagedReader(
          pages: pages,
          initialPage: 0,
          rtl: true,
          onPageChanged: (_) {},
          pageBuilder: (_, page) => Text('page-${page.index}'),
        ),
      ),
    );

    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.reverse, isTrue);
    expect(find.text('page-0'), findsOneWidget);
  });

  testWidgets('webtoon reader is a lazy vertical list', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaWebtoonReader(
          pages: pages,
          initialPage: 0,
          onPageChanged: (_) {},
          pageBuilder: (_, page) => SizedBox(
            height: 300,
            child: Text('page-${page.index}'),
          ),
        ),
      ),
    );

    final scroll = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scroll.scrollDirection, Axis.vertical);
  });
}
