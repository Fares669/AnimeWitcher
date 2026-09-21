import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_continuous_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_continuous_zoom_surface.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_paged_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_navigation_overlay.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_gesture_handler.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_chapter_transition_page.dart';
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

  testWidgets('failed reader page exposes Mangayomi retry action', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MangaPageImage(
            page: MangaPage(
              index: 0,
              imageUrl: 'file:///definitely-missing-reader-page.webp',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
  });

  testWidgets('Mangayomi navigation overlay places RTL next zone on the left', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 600,
          height: 400,
          child: MangaReaderNavigationOverlay(
            navigationLayout: 4,
            tappingInversion: 0,
            isRtl: true,
            onClose: () {},
          ),
        ),
      ),
    );

    final next = tester.getCenter(find.text('NEXT'));
    final previous = tester.getCenter(find.text('PREV'));
    expect(next.dx, lessThan(previous.dx));
  });

  testWidgets('Mangayomi tap zones reverse page actions in RTL', (
    tester,
  ) async {
    var previous = 0;
    var next = 0;
    var menu = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 600,
          height: 400,
          child: MangaReaderGestureHandler(
            usePageTapZones: true,
            navigationLayout: 4,
            tappingInversion: 0,
            isRtl: true,
            hasImageError: false,
            isContinuousMode: false,
            onToggleUi: () => menu++,
            onPreviousPage: () => previous++,
            onNextPage: () => next++,
          ),
        ),
      ),
    );

    await tester.tapAt(const Offset(100, 200));
    await tester.pump();
    expect(next, 1);
    expect(previous, 0);
    expect(menu, 0);

    await tester.tapAt(const Offset(500, 200));
    await tester.pump();
    expect(previous, 1);
  });

  testWidgets('Mangayomi chapter transition shows current and next chapters', (
    tester,
  ) async {
    const current = MangaChapter(
      id: 'c1',
      mangaId: 'm1',
      url: 'https://example.test/c1',
      name: 'Chapter 1',
    );
    const next = MangaChapter(
      id: 'c2',
      mangaId: 'm1',
      url: 'https://example.test/c2',
      name: 'Chapter 2',
    );

    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('en'),
        home: MangaReaderChapterTransitionPage(
          currentChapter: current,
          nextChapter: next,
          mangaName: 'Reader Manga',
          readerMode: MangaReaderMode.vertical,
        ),
      ),
    );

    expect(find.text('End of chapter'), findsOneWidget);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 2'), findsOneWidget);
    expect(find.text('Next chapter'), findsOneWidget);
  });

  testWidgets('paged reader appends Mangayomi chapter transition page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaPagedReader(
          pages: _pages,
          initialPage: 0,
          rtl: false,
          onPageChanged: (_) {},
          pageBuilder: (_, page) => Text('page-${page.index}'),
          trailingPage: const Text('chapter-transition'),
        ),
      ),
    );

    final view = tester.widget<PageView>(find.byType(PageView));
    expect(view.childrenDelegate.estimatedChildCount, _pages.length + 1);
  });

  testWidgets('continuous reader appends Mangayomi chapter transition page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaContinuousReader(
          pages: _pages,
          initialPage: 0,
          scrollDirection: Axis.vertical,
          reverse: false,
          settings: const MangaReaderSettings(),
          onPageChanged: (_) {},
          pageBuilder: (_, page) => Text('page-${page.index}'),
          trailingPage: const Text('chapter-transition'),
        ),
      ),
    );

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.childrenDelegate.estimatedChildCount, _pages.length + 1);
  });

  testWidgets('webtoon appends Mangayomi chapter transition page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaWebtoonReader(
          pages: _pages,
          initialPage: 0,
          settings: const MangaReaderSettings(),
          onPageChanged: (_) {},
          pageBuilder: (_, page) => SizedBox(
            height: 300,
            child: Text('page-${page.index}'),
          ),
          trailingPage: const Text('chapter-transition'),
        ),
      ),
    );

    await tester.drag(
      find.byType(CustomScrollView),
      const Offset(0, -1200),
    );
    await tester.pumpAndSettle();

    expect(find.text('chapter-transition'), findsOneWidget);
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

  testWidgets('vertical continuous double page renders one spread', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaContinuousReader(
          pages: _pages,
          initialPage: 0,
          scrollDirection: Axis.vertical,
          reverse: false,
          doublePage: true,
          settings: const MangaReaderSettings(),
          onPageChanged: (_) {},
          pageBuilder: (_, page) => SizedBox(
            height: 300,
            child: Text('page-${page.index}'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(
        const ValueKey<String>('manga-reader-continuous-double-page'),
      ),
      findsOneWidget,
    );
    expect(find.text('page-0'), findsOneWidget);
    expect(find.text('page-1'), findsOneWidget);
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.childrenDelegate.estimatedChildCount, 2);
  });

  testWidgets('webtoon double page renders one vertical spread', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaWebtoonReader(
          pages: _pages,
          initialPage: 0,
          doublePage: true,
          settings: const MangaReaderSettings(),
          onPageChanged: (_) {},
          pageBuilder: (_, page) => SizedBox(
            height: 300,
            child: Text('page-${page.index}'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('manga-reader-webtoon-double-page')),
      findsOneWidget,
    );
    expect(find.text('page-0'), findsOneWidget);
    expect(find.text('page-1'), findsOneWidget);
  });

  testWidgets('double page shares one Mangayomi zoom surface', (tester) async {
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
    await tester.pump();

    expect(find.byType(MangaContinuousZoomSurface), findsOneWidget);
  });

  testWidgets('continuous reader uses one shared Mangayomi zoom surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaContinuousReader(
          pages: _pages,
          initialPage: 0,
          scrollDirection: Axis.vertical,
          reverse: false,
          settings: const MangaReaderSettings(),
          onPageChanged: (_) {},
          pageBuilder: (_, page) => SizedBox(
            height: 300,
            child: Text('page-${page.index}'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(MangaContinuousZoomSurface), findsOneWidget);
  });

  testWidgets('webtoon uses one shared Mangayomi zoom surface', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MangaWebtoonReader(
          pages: _pages,
          initialPage: 0,
          settings: const MangaReaderSettings(),
          onPageChanged: (_) {},
          pageBuilder: (_, page) => SizedBox(
            height: 300,
            child: Text('page-${page.index}'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(MangaContinuousZoomSurface), findsOneWidget);
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
