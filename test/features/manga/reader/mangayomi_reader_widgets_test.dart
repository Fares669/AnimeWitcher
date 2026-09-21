import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_continuous_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_paged_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

const _pages = <MangaPage>[
  MangaPage(index: 0, imageUrl: 'https://example.test/0.webp'),
  MangaPage(index: 1, imageUrl: 'https://example.test/1.webp'),
  MangaPage(index: 2, imageUrl: 'https://example.test/2.webp'),
];

void main() {
  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('vertical reader pages along the vertical axis', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaPagedReader(
          pages: _pages,
          initialPage: 0,
          rtl: false,
          scrollDirection: Axis.vertical,
          onPageChanged: (_) {},
          pageBuilder: (_, page) => Text('page-${page.index}'),
        ),
      ),
    );

    final view = tester.widget<PageView>(find.byType(PageView));
    expect(view.scrollDirection, Axis.vertical);
  });

  testWidgets('horizontal continuous RTL reader reverses its list', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaContinuousReader(
          pages: _pages,
          initialPage: 0,
          scrollDirection: Axis.horizontal,
          reverse: true,
          settings: const MangaReaderSettings(),
          onPageChanged: (_) {},
          pageBuilder: (_, page) => Text('page-${page.index}'),
        ),
      ),
    );

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.scrollDirection, Axis.horizontal);
    expect(list.reverse, isTrue);
  });

  testWidgets('double page renders a pair in one paged viewport', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaPagedReader(
          pages: _pages,
          initialPage: 0,
          rtl: true,
          doublePage: true,
          settings: const MangaReaderSettings(),
          onPageChanged: (_) {},
          pageBuilder: (_, page) => Text('page-${page.index}'),
        ),
      ),
    );

    expect(find.text('page-0'), findsOneWidget);
    expect(find.text('page-1'), findsOneWidget);
  });

  testWidgets('webtoon applies side padding and optional page gaps', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaWebtoonReader(
          pages: _pages,
          initialPage: 0,
          settings: const MangaReaderSettings(
            webtoonSidePadding: 10,
            showPageGaps: false,
          ),
          onPageChanged: (_) {},
          pageBuilder: (_, page) => SizedBox(
            height: 300,
            child: Text('page-${page.index}'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('manga-reader-webtoon-padding')), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-reader-page-gap')), findsNothing);
  });
}
