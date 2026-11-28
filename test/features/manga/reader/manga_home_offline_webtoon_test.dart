import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/services/artwork_fallback_service.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_models.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_screen.dart';
import 'package:animewitcher/features/manga/presentation/manga_home_screen.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_cover_provider.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_screen.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/features/manga/reader/subsampling/src/subsampling_image_painter.dart'
    show SubsamplingImageRenderWidget;
import 'package:animewitcher/features/manga/reader/widgets/manga_chapter_transition_page.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_paged_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:visibility_detector/visibility_detector.dart';

const _pageCount = 96;
const _resumePage = _pageCount - 3;
const _first = MangaChapter(
  id: 'offline-c1',
  mangaId: 'offline-manga',
  name: 'الفصل ١',
  url: 'https://example.test/chapter/1',
  number: 1,
);
const _second = MangaChapter(
  id: 'offline-c2',
  mangaId: 'offline-manga',
  name: 'الفصل ٢',
  url: 'https://example.test/chapter/2',
  number: 2,
);

final class _Storage extends StorageService {
  final _values = <String, String>{};

  @override
  String? getString(String key) => _values[key];

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
  }

  @override
  Future<void> remove(String key) async => _values.remove(key);

  @override
  T? getPlayerSetting<T>(String key, {T? defaultValue}) => defaultValue;
}

final class _Source extends AnimeWitcherNativeProvider {
  _Source(_Storage storage, {this.chapters = const [_first, _second]})
    : super(Dio(), SettingsRepository(storage));

  final List<MangaChapter> chapters;

  final remotePageRequests = <String>[];
  late final work = MultimediaItem(
    title: 'قصة بلا اتصال',
    url: 'https://example.test/manga/offline-manga',
    posterUrl: '',
    contentType: MultimediaContentType.manga,
    provider: packageName,
    syncData: const {'mangaId': 'offline-manga'},
  );

  @override
  Future<ProviderMediaPage> searchMangaPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async => ProviderMediaPage(items: [work], nextOffset: 1, hasMore: false);

  @override
  Future<MangaLatestChapterPage> getLatestMangaPage({
    int offset = 0,
    int limit = 30,
  }) async => MangaLatestChapterPage(
    items: [MangaLatestChapter(manga: work, chapter: _second)],
    nextOffset: 1,
    hasMore: false,
  );

  @override
  Future<MultimediaItem> getMangaDetails(String url) async => work;

  @override
  Future<List<MangaChapter>> getMangaChapters(String url) async => chapters;

  @override
  Future<List<MangaPage>> getMangaChapterPages(
    String mangaUrl,
    MangaChapter chapter,
  ) async {
    remotePageRequests.add(chapter.id);
    throw StateError('A downloaded chapter must not request remote pages');
  }
}

final class _Manager extends ExtensionManager {
  _Manager(this.source);
  final _Source source;

  @override
  List<AnimeWitcherProvider> build() => [source];
}

final class _NoArtwork extends ArtworkFallbackService {
  _NoArtwork(_Storage storage) : super(Dio(), storage);

  @override
  Future<({String? cover, String? banner})> mangaArtwork({
    int? malId,
    String title = '',
  }) async => (cover: null, banner: null);
}

final class _NoCovers extends MangaReaderCustomCoversNotifier {
  @override
  Map<String, String> build() => const {};
}

final class _Settings extends MangaReaderSettingsNotifier {
  _Settings([this.defaultMode = MangaReaderMode.webtoon]);

  final MangaReaderMode defaultMode;

  @override
  MangaReaderSettings build() => MangaReaderSettings(
    defaultMode: defaultMode,
    fullScreen: false,
    showReadingMode: false,
    keepScreenOn: false,
    pagePreloadAmount: 4,
  );

  @override
  Future<void> setSettings(MangaReaderSettings value) async => state = value;
}

final class _Downloads extends DownloadsNotifier {
  _Downloads(this.rows);
  final List<DownloadItem> rows;

  @override
  Future<List<DownloadItem>> build() async => rows;
}

List<int> _color(MangaChapter chapter, int page) => [
  32 + page % 128,
  chapter == _first ? 71 : 158,
  103,
  255,
];

Future<DownloadItem> _download(
  Directory folder,
  MangaChapter chapter,
  MultimediaItem work,
) async {
  await folder.create();
  for (var page = 0; page < _pageCount; page++) {
    final color = _color(chapter, page);
    final picture = img.Image(width: 22, height: 26);
    img.fill(picture, color: img.ColorRgb8(color[0], color[1], color[2]));
    final prefix = (page + 1).toString().padLeft(4, '0');
    File('${folder.path}/$prefix.png').writeAsBytesSync(img.encodePng(picture));
  }
  await MangaChapterManifestV2(
    version: MangaChapterManifestV2.currentVersion,
    mangaId: chapter.mangaId,
    chapterId: chapter.id,
    pageCount: _pageCount,
    completedIndexes: {for (var p = 0; p < _pageCount; p++) p},
    isComplete: true,
  ).writeTo(folder);
  return DownloadItem(
    task: DownloadTask(taskId: chapter.id, url: chapter.url, filename: 'manga'),
    status: TaskStatus.complete,
    progress: 1,
    item: work,
    chapter: chapter,
    mediaKind: DownloadMediaKind.mangaChapter,
    timestamp: 1,
    destinationPath: folder.path,
  );
}

GoRouter _offlineRouter() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const MangaHomeScreen()),
    GoRoute(
      path: '/manga-details',
      builder: (context, state) =>
          MangaDetailsRoute($extra: state.extra! as MangaDetailsRouteExtra)
              .build(context, state),
    ),
    GoRoute(
      path: '/manga-reader',
      builder: (context, state) =>
          MangaReaderRoute($extra: state.extra! as MangaReaderRouteExtra)
              .build(context, state),
    ),
  ],
);

Widget _offlineApp({
  required GoRouter router,
  required _Storage storage,
  required _Source source,
  required List<DownloadItem> downloads,
  required GlobalKey boundaryKey,
  MangaReaderMode mode = MangaReaderMode.webtoon,
}) => ProviderScope(
  overrides: [
    extensionManagerProvider.overrideWith(() => _Manager(source)),
    storageServiceProvider.overrideWithValue(storage),
    mangaReadingRepositoryProvider.overrideWith(
      (ref) => MangaReadingRepository(
        storage,
        onChanged: () => ref.read(mangaReadingRevisionProvider.notifier).bump(),
      ),
    ),
    mangaReaderSettingsProvider.overrideWith(() => _Settings(mode)),
    mangaReaderCustomCoversProvider.overrideWith(_NoCovers.new),
    artworkFallbackServiceProvider.overrideWithValue(_NoArtwork(storage)),
    downloadsProvider.overrideWith(() => _Downloads(downloads)),
  ],
  child: RepaintBoundary(
    key: boundaryKey,
    child: MaterialApp.router(
      routerConfig: router,
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  ),
);

void main() {
  testWidgets(
    'single-page Webtoon centers the persisted page with multiple seams',
    (tester) async {
      const opening = SizedBox(height: 25);
      const preceding = SizedBox(height: 26);
      const centered = SizedBox(height: 27);
      const following = SizedBox(height: 28);
      const invalid = SizedBox(height: 29);
      final oldInterval = VisibilityDetectorController.instance.updateInterval;
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      addTearDown(
        () =>
            VisibilityDetectorController.instance.updateInterval = oldInterval,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MangaWebtoonReader(
            pages: List.generate(
              8,
              (i) => MangaPage(index: i, imageUrl: 'page:$i'),
            ),
            initialPage: 3,
            onPageChanged: (_) {},
            pageBuilder: (_, _) => const SizedBox(height: 80),
            sectionDividers: const {
              6: following,
              3: centered,
              2: preceding,
              0: opening,
              8: invalid,
              -1: invalid,
            },
          ),
        ),
      );
      final scrollView = find.byType(CustomScrollView);
      final scroll = tester.widget<CustomScrollView>(scrollView);
      final lists = scroll.slivers.whereType<SliverList>().toList();
      expect(lists.map((sliver) => sliver.delegate.estimatedChildCount), [
        6,
        6,
      ]);
      expect(scroll.center, lists.last.key);
      final context = tester.element(scrollView);
      Object? rowIdentity(Widget? row) =>
          row is KeepAlive ? row.child.key : row;
      Iterable<Object?> rows(SliverList list) sync* {
        final delegate = list.delegate as SliverChildBuilderDelegate;
        for (var i = 0; i < delegate.childCount!; i++) {
          yield rowIdentity(delegate.builder(context, i));
        }
      }

      const page = 'manga-webtoon';
      expect(rows(lists.first), [
        opening,
        const ValueKey('$page-0-0'),
        const ValueKey('$page-1-1'),
        preceding,
        const ValueKey('$page-2-2'),
        centered,
      ]);
      expect(rows(lists.last), [
        const ValueKey('$page-3-3'),
        const ValueKey('$page-4-4'),
        const ValueKey('$page-5-5'),
        following,
        const ValueKey('$page-6-6'),
        const ValueKey('$page-7-7'),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'Arabic Manga Home resumes offline Webtoon and scrolls through its chapter seam',
    (tester) async {
      tester.view.physicalSize = const Size(390, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final visibility = VisibilityDetectorController.instance;
      final visibilityInterval = visibility.updateInterval;
      visibility.updateInterval = Duration.zero;
      addTearDown(() => visibility.updateInterval = visibilityInterval);
      final root = Directory.systemTemp.createTempSync('aw_manga_home_seam_');
      addTearDown(() => root.delete(recursive: true));
      final storage = _Storage();
      final source = _Source(storage);
      final progress = MangaReadingRepository(storage);
      final downloads = (await tester.runAsync(
        () async => [
          for (final chapter in [_first, _second])
            await _download(
              Directory('${root.path}/${chapter.id}'),
              chapter,
              source.work,
            ),
        ],
      ))!;
      await progress.save(
        MangaReadingProgress(
          mangaId: _first.mangaId,
          chapterId: _first.id,
          pageIndex: _resumePage,
          pageCount: _pageCount,
          updatedAt: 1,
        ),
      );

      final router = _offlineRouter();
      addTearDown(router.dispose);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        _offlineApp(
          router: router,
          storage: storage,
          source: source,
          downloads: downloads,
          boundaryKey: boundaryKey,
        ),
      );

      final webtoon = find.byType(MangaWebtoonReader);
      final scrollView = find.descendant(
        of: webtoon,
        matching: find.byType(CustomScrollView),
      );
      final mangaReader = find.byType(MangaReaderScreen);
      final details = find.byType(MangaDetailsScreen);
      final home = find.byType(MangaHomeScreen);

      MangaWebtoonReader reader() => tester.widget<MangaWebtoonReader>(webtoon);
      int? savedPage(MangaChapter chapter) =>
          progress.get(chapter.mangaId, chapter.id)?.pageIndex;
      Finder row(int index) =>
          find.byKey(ValueKey('manga-webtoon-$index-$index'));

      Future<void> waitFor(String stage, bool Function() done) async {
        for (var i = 0; i < 280; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 4)),
          );
          await tester.pump(const Duration(milliseconds: 24));
          if (done()) return;
        }
        fail(
          '$stage did not arrive; remote=${source.remotePageRequests}, '
          'chapter 1=${savedPage(_first)}, chapter 2=${savedPage(_second)}',
        );
      }

      Future<List<int>?> renderedPixel(int index) =>
          tester.runAsync<List<int>?>(() async {
            final rowFinder = row(index);
            if (rowFinder.evaluate().isEmpty) return null;
            final visible = tester
                .getRect(rowFinder)
                .intersect(tester.getRect(scrollView));
            if (visible.width < 20 || visible.height < 20) return null;
            final point = visible.center;
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(boundaryKey),
            );
            if (boundary.debugNeedsPaint) return null;
            final image = await boundary.toImage();
            try {
              final rgba = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final offset =
                  (point.dy.floor() * image.width + point.dx.floor()) * 4;
              return [for (var i = 0; i < 4; i++) rgba.getUint8(offset + i)];
            } finally {
              image.dispose();
            }
          });

      Future<void> expectPainted(
        int flatPage,
        MangaChapter chapter,
        int page,
      ) async {
        // Mounting a row is not the readiness signal for a local PNG.
        // The real decode isolate and engine upload must publish its tile
        // before this page owns an image painter, even if fake frames pass.
        final pageRow = row(flatPage);
        final painter = find.descendant(
          of: pageRow,
          matching: find.byType(SubsamplingImageRenderWidget),
        );
        final retry = find.descendant(
          of: pageRow,
          matching: find.text('إعادة المحاولة'),
        );
        final clock = Stopwatch()..start();
        var painterSeen = false;
        List<int>? painted;
        final wanted = _color(chapter, page);
        do {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 8)),
          );
          await tester.pump(const Duration(milliseconds: 32));
          expect(retry, findsNothing, reason: 'local page ${chapter.id}:$page');
          if (painter.evaluate().isEmpty) continue;
          painterSeen = true;
          painted = await renderedPixel(flatPage);
          if (listEquals(painted, wanted)) return;
        } while (clock.elapsed < const Duration(seconds: 4));
        expect(painterSeen, isTrue, reason: 'decoded ${chapter.id}:$page');
        expect(
          painted,
          wanted,
          reason: 'painted RGBA of page $page in ${chapter.id}',
        );
      }

      void expectLayout(int behind, int ahead, {Key? center}) {
        final scroll = tester.widget<CustomScrollView>(scrollView);
        final lists = scroll.slivers.whereType<SliverList>().toList();
        expect(
          lists.map((list) => list.delegate.estimatedChildCount),
          behind == 0 ? [ahead] : [behind, ahead],
        );
        expect(scroll.center, lists.last.key);
        if (center != null) expect(scroll.center, same(center));
      }

      await waitFor(
        'Manga Home',
        () => find.text(source.work.title).evaluate().isNotEmpty,
      );
      final rail = find.text('فصول جديدة');
      expect(rail, findsOneWidget);
      final latest = find.text(source.work.title).first;
      expect(Directionality.of(tester.element(latest)), TextDirection.rtl);
      await tester.tap(latest);
      final chapterToggle = find.byKey(const ValueKey('manga-chapters-toggle'));
      await waitFor(
        'Details chapter section',
        () => chapterToggle.evaluate().isNotEmpty,
      );
      await Scrollable.ensureVisible(
        tester.element(chapterToggle),
        alignment: .25,
      );
      await tester.pump();
      await tester.tap(chapterToggle.hitTestable());
      final readPill = find.byKey(const ValueKey('manga-read-pill'));
      await waitFor(
        'Details read action',
        () => readPill.evaluate().isNotEmpty,
      );
      await Scrollable.ensureVisible(tester.element(readPill), alignment: .25);
      await tester.pump(const Duration(milliseconds: 260));
      final continueFirst = find.text('تابع · ${_first.name}');
      await waitFor(
        'Details resume',
        () => continueFirst.hitTestable().evaluate().isNotEmpty,
      );
      await tester.tap(continueFirst);
      await waitFor('Initial download', () => webtoon.evaluate().isNotEmpty);
      expect(Directionality.of(tester.element(webtoon)), TextDirection.rtl);
      expect(reader().initialPage, _resumePage);
      final anchorPages = reader().pages;
      expect(anchorPages, hasLength(_pageCount));
      final readerState = tester.state(webtoon);
      final center = tester.widget<CustomScrollView>(scrollView).center!;
      final controller = reader().controller!;
      expectLayout(_resumePage, 3, center: center);
      await expectPainted(_resumePage, _first, _resumePage);

      for (var i = 0; i < 10 && reader().pages.length == _pageCount; i++) {
        await tester.timedDrag(
          scrollView,
          const Offset(0, -410),
          const Duration(milliseconds: 420),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 9)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
      await waitFor(
        'Append second download',
        () => reader().pages.length == 2 * _pageCount,
      );
      final appendedPages = reader().pages;
      expect(appendedPages, isNot(same(anchorPages)));
      expect(appendedPages.take(_pageCount), orderedEquals(anchorPages));
      expect(reader().sectionDividers.keys, [_pageCount]);
      final seam = find.byWidgetPredicate(
        (widget) =>
            widget is MangaReaderChapterDivider &&
            widget.currentChapter.id == _first.id &&
            widget.nextChapter?.id == _second.id,
      );
      expect(seam, findsOneWidget);
      expect(
        find.descendant(of: seam, matching: find.text('الفصل التالي')),
        findsOneWidget,
      );
      expect(tester.state(webtoon), same(readerState));
      expect(reader().controller, same(controller));
      expectLayout(_resumePage, _pageCount + 4, center: center);

      for (var i = 0; i < 16 && (savedPage(_second) ?? -1) < 1; i++) {
        await tester.timedDrag(
          scrollView,
          const Offset(0, -250),
          const Duration(milliseconds: 390),
        );
        await tester.pump(const Duration(milliseconds: 1100));
      }
      // Advance beyond the first page's height change before sampling the
      // persisted anchor. Native image completion can otherwise settle
      // between the last screenshot and the navigation flush.
      await tester.timedDrag(
        scrollView,
        const Offset(0, -350),
        const Duration(milliseconds: 450),
      );
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 350));
      }
      final secondPage = savedPage(_second);
      expect(secondPage, greaterThanOrEqualTo(1));
      await expectPainted(_pageCount + secondPage!, _second, secondPage);
      final settledOffset = controller.offset;
      final scope = ProviderScope.containerOf(tester.element(webtoon));
      final settings = scope.read(mangaReaderSettingsProvider.notifier);
      final standardSettings = scope.read(mangaReaderSettingsProvider);
      var changedPageLists = 0;
      var copiedPageReferences = 0;
      for (var i = 0; i < 12; i++) {
        final before = reader();
        await settings.setSettings(
          standardSettings.copyWith(showPageNumber: i.isOdd),
        );
        await tester.pump(const Duration(milliseconds: 32));
        final after = reader();
        expect(after, isNot(same(before)), reason: 'reader actually rebuilt');
        if (!identical(after.pages, before.pages)) {
          changedPageLists++;
          copiedPageReferences += after.pages.length;
        }
        expect(after.pages, orderedEquals(appendedPages));
      }
      expect(
        changedPageLists,
        0,
        reason: 'unchanged stream keeps its page list',
      );
      expect(copiedPageReferences, 0);
      expect(controller.offset, settledOffset);
      expectLayout(_resumePage, _pageCount + 4, center: center);
      expect(tester.state(webtoon), same(readerState));
      expect(savedPage(_second), secondPage);
      await expectPainted(_pageCount + secondPage, _second, secondPage);

      expect(source.remotePageRequests, isEmpty);
      router.pop();
      await waitFor(
        'Back to Details',
        () => mangaReader.evaluate().isEmpty && details.evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      final reopenPage = savedPage(_second)!;
      expect(reopenPage, greaterThan(0));
      final continueSecond = find.text('تابع · ${_second.name}');
      await waitFor(
        'Details saved chapter two',
        () => continueSecond.hitTestable().evaluate().isNotEmpty,
      );
      await tester.tap(continueSecond);
      await waitFor(
        'Reopen second download',
        () => webtoon.evaluate().isNotEmpty,
      );
      expect(reader().initialPage, reopenPage);
      expect(reader().pages, isNot(same(appendedPages)));
      expect(
        reader().pages.map((page) => page.imageUrl),
        orderedEquals(
          appendedPages.skip(_pageCount).map((page) => page.imageUrl),
        ),
      );
      expect(reader().sectionDividers, isEmpty);
      expectLayout(reopenPage, _pageCount - reopenPage);
      await expectPainted(reopenPage, _second, reopenPage);

      router.pop();
      await waitFor(
        'Back to Details again',
        () => mangaReader.evaluate().isEmpty && details.evaluate().isNotEmpty,
      );
      router.pop();
      await waitFor(
        'Back to Manga Home',
        () => details.evaluate().isEmpty && home.evaluate().isNotEmpty,
      );
      expect(rail, findsOneWidget);
      expect(source.remotePageRequests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );

  testWidgets(
    'Arabic Manga Home opens local paged chapters, follows RTL keys and restores progress',
    (tester) async {
      tester.view.physicalSize = const Size(390, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('aw_manga_paged_');
      addTearDown(() => root.delete(recursive: true));
      final storage = _Storage();
      final source = _Source(storage, chapters: const [_second, _first]);
      final progress = MangaReadingRepository(storage);
      final downloads = (await tester.runAsync(
        () async => [
          for (final chapter in [_second, _first])
            await _download(
              Directory('${root.path}/${chapter.id}'),
              chapter,
              source.work,
            ),
        ],
      ))!;
      await progress.save(
        const MangaReadingProgress(
          mangaId: 'offline-manga',
          chapterId: 'offline-c1',
          pageIndex: _resumePage,
          pageCount: _pageCount,
          updatedAt: 2,
          isBookmarked: true,
        ),
      );
      await progress.save(
        const MangaReadingProgress(
          mangaId: 'offline-manga',
          chapterId: 'offline-c2',
          pageIndex: 13,
          pageCount: _pageCount,
          updatedAt: 1,
        ),
      );

      final router = _offlineRouter();
      addTearDown(router.dispose);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        _offlineApp(
          router: router,
          storage: storage,
          source: source,
          downloads: downloads,
          boundaryKey: boundaryKey,
          mode: MangaReaderMode.pagedRtl,
        ),
      );

      final paged = find.byType(MangaPagedReader);
      final pageView = find.descendant(
        of: paged,
        matching: find.byType(PageView),
      );
      final details = find.byType(MangaDetailsScreen);
      final home = find.byType(MangaHomeScreen);
      final visited = <String>[];
      MangaPagedReader reader() => tester.widget<MangaPagedReader>(paged);
      Future<void> waitFor(String stage, bool Function() ready) async {
        final clock = Stopwatch()..start();
        do {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 6)),
          );
          await tester.pump(const Duration(milliseconds: 20));
          if (ready()) return;
        } while (clock.elapsed < const Duration(seconds: 5));
        fail(
          '$stage not reached; visited=$visited, remote=${source.remotePageRequests}',
        );
      }

      final retry = find.text('إعادة المحاولة');
      Future<void> expectPage(
        MangaChapter chapter,
        int index, {
        required MangaChapter? next,
      }) async {
        await waitFor('${chapter.id}:$index with a mounted page', () {
          if (paged.evaluate().length != 1) return false;
          final value = reader();
          final transition =
              value.trailingPage! as MangaReaderChapterTransitionPage;
          final controller = tester.widget<PageView>(pageView).controller!;
          return transition.currentChapter.id == chapter.id &&
              controller.hasClients &&
              controller.page == index.toDouble();
        });
        final value = reader();
        final transition =
            value.trailingPage! as MangaReaderChapterTransitionPage;
        expect(transition.nextChapter?.id, next?.id);
        expect(value.onTrailingAdvance != null, next != null);
        expect(value.rtl, isTrue);
        expect(value.doublePage, isFalse);
        expect(value.settings.splitWidePages, isFalse);
        expect(Directionality.of(tester.element(paged)), TextDirection.rtl);
        expect(
          value.pages.map((page) => page.index),
          orderedEquals(List<int>.generate(_pageCount, (i) => i)),
        );
        for (final page in value.pages) {
          final uri = Uri.parse(page.imageUrl);
          expect(uri.scheme, 'file');
          expect(uri.pathSegments.reversed.take(2), [
            '${(page.index + 1).toString().padLeft(4, '0')}.png',
            chapter.id,
          ]);
        }
        final expected = _color(chapter, index);
        List<int>? painted;
        final clock = Stopwatch()..start();
        do {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 8)),
          );
          await tester.pump(const Duration(milliseconds: 24));
          expect(retry, findsNothing);
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(boundaryKey),
          );
          if (boundary.debugNeedsPaint) continue;
          painted = await tester.runAsync(() async {
            final image = await boundary.toImage();
            try {
              final rgba = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final offset =
                  (image.height ~/ 2 * image.width + image.width ~/ 2) * 4;
              return [for (var i = 0; i < 4; i++) rgba.getUint8(offset + i)];
            } finally {
              image.dispose();
            }
          });
          if (listEquals(painted, expected)) break;
        } while (clock.elapsed < const Duration(seconds: 5));
        expect(
          painted,
          expected,
          reason: 'offline RGBA of ${chapter.id}:$index',
        );
        visited.add('${chapter.id}:$index:${painted!.join(',')}');
      }

      await waitFor(
        'Manga Home',
        () => find.text(source.work.title).evaluate().isNotEmpty,
      );
      await tester.tap(find.text(source.work.title).first);
      final chapterToggle = find.byKey(const ValueKey('manga-chapters-toggle'));
      await waitFor('Details', () => chapterToggle.evaluate().isNotEmpty);
      await Scrollable.ensureVisible(
        tester.element(chapterToggle),
        alignment: .25,
      );
      await tester.pump();
      await tester.tap(chapterToggle.hitTestable());
      Future<void> resume(MangaChapter chapter) async {
        final readPill = find.byKey(const ValueKey('manga-read-pill'));
        await waitFor(
          'Details read action',
          () => readPill.evaluate().isNotEmpty,
        );
        await Scrollable.ensureVisible(
          tester.element(readPill),
          alignment: .25,
        );
        await tester.pump(const Duration(milliseconds: 260));
        final action = find.text('تابع · ${chapter.name}').hitTestable();
        await waitFor(
          'Resume ${chapter.id}',
          () => action.evaluate().isNotEmpty,
        );
        await tester.tap(action);
      }

      await resume(_first);
      await expectPage(_first, _resumePage, next: _second);
      for (final (key, index) in [
        (LogicalKeyboardKey.arrowLeft, _resumePage + 1),
        (LogicalKeyboardKey.arrowRight, _resumePage),
        (LogicalKeyboardKey.arrowRight, _resumePage - 1),
      ]) {
        await tester.sendKeyEvent(key);
        await expectPage(_first, index, next: _second);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await expectPage(_second, 13, next: null);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await expectPage(_second, 14, next: null);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await expectPage(_first, _resumePage - 1, next: _second);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await expectPage(_second, 14, next: null);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await waitFor(
        'Back to Details',
        () => paged.evaluate().isEmpty && details.evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 320));
      // The Details resume pill intentionally points to the first
      // unfinished chapter. Here choose the second chapter explicitly.
      final firstAction = find.text('تابع · ${_first.name}');
      await waitFor(
        'First unfinished chapter',
        () => firstAction.evaluate().isNotEmpty,
      );
      await Scrollable.ensureVisible(
        tester.element(firstAction),
        alignment: .25,
      );
      await tester.pump();
      final secondRow = find.byKey(ValueKey('manga-chapter-row-${_second.id}'));
      await waitFor(
        'Second chapter row',
        () => secondRow.evaluate().isNotEmpty,
      );
      await Scrollable.ensureVisible(tester.element(secondRow), alignment: .5);
      await tester.pump();
      await tester.tap(secondRow.hitTestable());
      await expectPage(_second, 14, next: null);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await waitFor(
        'Restored Details',
        () => paged.evaluate().isEmpty && details.evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 320));

      final saved = Map<String, Object?>.fromEntries(
        storage._values.entries
            .where((e) => e.key.startsWith('manga_progress:'))
            .map((e) {
              final row = jsonDecode(e.value) as Map<String, dynamic>;
              expect(row.remove('updatedAt'), greaterThan(2));
              return MapEntry(e.key, row);
            }),
      );
      expect(saved, {
        'manga_progress:5d627ffeb08abfe290f60a6db6fc1d2b:3ec63289e41198a4c121c057aa9b6cad':
            {
              'mangaId': 'offline-manga',
              'chapterId': 'offline-c1',
              'pageIndex': _resumePage - 1,
              'pageCount': _pageCount,
              'isRead': false,
              'isBookmarked': true,
            },
        'manga_progress:5d627ffeb08abfe290f60a6db6fc1d2b:299bcd3c884984ce35fe0046afa6bd99':
            {
              'mangaId': 'offline-manga',
              'chapterId': 'offline-c2',
              'pageIndex': 14,
              'pageCount': _pageCount,
              'isRead': false,
              'isBookmarked': false,
            },
      });
      expect(source.remotePageRequests, isEmpty);
      router.pop();
      await waitFor(
        'Back to Manga Home',
        () => details.evaluate().isEmpty && home.evaluate().isNotEmpty,
      );
      expect(find.text('فصول جديدة'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
    },
  );
}
