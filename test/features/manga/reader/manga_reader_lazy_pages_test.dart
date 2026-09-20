import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('long webtoon does not eagerly build every page', (tester) async {
    final pages = List<MangaPage>.generate(
      120,
      (index) => MangaPage(
        index: index,
        imageUrl: 'https://example.test/$index.webp',
      ),
    );
    var builds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 800,
          child: MangaWebtoonReader(
            pages: pages,
            initialPage: 0,
            onPageChanged: (_) {},
            pageBuilder: (_, page) {
              builds++;
              return SizedBox(
                height: 500,
                child: Text('page-${page.index}'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(pages, hasLength(120));
    expect(builds, lessThan(10));
  });
}
