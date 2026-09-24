import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_continuous_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_continuous_zoom_surface.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_paged_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_load_scheduler.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_navigation_overlay.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_chapter_transition_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:visibility_detector/visibility_detector.dart';

void _ignorePage(int _) {}

const _pages = <MangaPage>[
  MangaPage(index: 0, imageUrl: 'https://example.test/0.webp'),
  MangaPage(index: 1, imageUrl: 'https://example.test/1.webp'),
  MangaPage(index: 2, imageUrl: 'https://example.test/2.webp'),
];

void main() {
  test('preload amount two unlocks pages in ordered pairs', () {
    final controller = MangaReaderLoadBatchController(
      pageCount: 6,
      initialPage: 0,
      batchSize: 2,
    );
    addTearDown(controller.dispose);

    expect(controller.unlockedPages, <int>{0, 1});
    expect(controller.canLoad(2), isFalse);
    expect(controller.canLoad(5), isFalse);

    controller.markSettled(0);
    expect(controller.canLoad(2), isFalse);
    controller.markSettled(1);
    expect(controller.unlockedPages, containsAll(<int>{0, 1, 2, 3}));
    expect(controller.canLoad(4), isFalse);

    controller.markSettled(2);
    controller.markSettled(3);
    expect(controller.canLoad(4), isTrue);
    expect(controller.canLoad(5), isTrue);
  });

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


  test(
    'chapter transition advances only on forward overscroll at the list end',
    () {
      expect(
        mangaReaderShouldAdvancePastTransition(
          extentAfter: 0,
          overscroll: 8,
        ),
        isTrue,
      );
      expect(
        mangaReaderShouldAdvancePastTransition(
          extentAfter: 24,
          overscroll: 8,
        ),
        isFalse,
      );
      expect(
        mangaReaderShouldAdvancePastTransition(
          extentAfter: 0,
          overscroll: -8,
        ),
        isFalse,
      );
    },
  );

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

  testWidgets('next chapter transition card continues reading', (tester) async {
    var continued = 0;
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
      MaterialApp(
        locale: const Locale('en'),
        home: MangaReaderChapterTransitionPage(
          currentChapter: current,
          nextChapter: next,
          mangaName: 'Reader Manga',
          readerMode: MangaReaderMode.vertical,
          onContinue: () => continued++,
        ),
      ),
    );

    await tester.tap(
      find.byKey(
        const ValueKey<String>('manga-reader-next-chapter-transition'),
      ),
    );
    await tester.pump();

    expect(continued, 1);
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

    expect(find.byType(SuperListView), findsOneWidget);
    expect(find.text('chapter-transition'), findsOneWidget);
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

    expect(find.byType(SuperListView), findsOneWidget);
    final scrollable = tester.widget<Scrollable>(
      find.descendant(
        of: find.byType(SuperListView),
        matching: find.byType(Scrollable),
      ).first,
    );
    expect(scrollable.axisDirection, AxisDirection.left);
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
    expect(find.byType(SuperListView), findsOneWidget);
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

    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('continuous zoom leaves one-finger scroll native', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 400,
          child: MangaContinuousReader(
            pages: _pages,
            initialPage: 0,
            scrollDirection: Axis.vertical,
            reverse: false,
            settings: const MangaReaderSettings(),
            controller: controller,
            onPageChanged: (_) {},
            pageBuilder: (_, page) => SizedBox(
              height: 320,
              child: Text('page-${page.index}'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(controller.offset, 0);
    await tester.drag(find.byType(SuperListView), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
  });

  testWidgets('continuous reader resumes at the persisted page index', (
    tester,
  ) async {
    final controller = ScrollController();
    final reported = <int>[];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 360,
          child: MangaContinuousReader(
            pages: _pages,
            initialPage: 2,
            scrollDirection: Axis.vertical,
            reverse: false,
            settings: const MangaReaderSettings(),
            controller: controller,
            onPageChanged: reported.add,
            pageBuilder: (_, page) => SizedBox(
              height: 500,
              child: Text('page-${page.index}'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(controller.hasClients, isTrue);
    expect(controller.offset, greaterThan(0));
    expect(find.text('page-2'), findsOneWidget);
    expect(reported, isNot(contains(0)));
  });

  testWidgets('continuous reader applies Mangayomi preload cache extent', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(400, 300)),
          child: SizedBox(
            width: 400,
            height: 300,
            child: MangaContinuousReader(
            pages: _pages,
            initialPage: 0,
            scrollDirection: Axis.vertical,
            reverse: false,
            settings: MangaReaderSettings(pagePreloadAmount: 6),
              onPageChanged: _ignorePage,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      mangaReaderPreloadCacheExtent(
        settings: const MangaReaderSettings(pagePreloadAmount: 6),
        viewport: const Size(400, 300),
        axis: Axis.vertical,
      ),
      closeTo(1440, 0.001),
    );
  });

  testWidgets('webtoon applies Mangayomi preload cache extent', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(400, 300)),
          child: SizedBox(
            width: 400,
            height: 300,
            child: MangaWebtoonReader(
            pages: _pages,
            initialPage: 0,
            settings: MangaReaderSettings(pagePreloadAmount: 6),
              onPageChanged: _ignorePage,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final scroll = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scroll.scrollCacheExtent?.value, closeTo(1440, 0.001));
  });

  test('continuous reader routes loaded wide pages through split logic', () {
    expect(
      mangaContinuousPageSlices(
        settings: const MangaReaderSettings(splitWidePages: true),
        imageSize: const Size(8, 4),
        isRtl: false,
        doublePageActive: false,
        hasCustomPageBuilder: false,
      ),
      const <MangaReaderPageSlice>[
        MangaReaderPageSlice.left,
        MangaReaderPageSlice.right,
      ],
    );
    expect(
      mangaContinuousPageSlices(
        settings: const MangaReaderSettings(splitWidePages: true),
        imageSize: const Size(8, 4),
        isRtl: true,
        doublePageActive: false,
        hasCustomPageBuilder: false,
      ),
      const <MangaReaderPageSlice>[
        MangaReaderPageSlice.right,
        MangaReaderPageSlice.left,
      ],
    );
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
