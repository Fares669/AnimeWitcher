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
import 'package:animewitcher/features/manga/reader/widgets/manga_chapter_transition_page.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  _Source(_Storage storage) : super(Dio(), SettingsRepository(storage));

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
  Future<List<MangaChapter>> getMangaChapters(String url) async => [
    _first,
    _second,
  ];

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
  @override
  MangaReaderSettings build() => const MangaReaderSettings(
    defaultMode: MangaReaderMode.webtoon,
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

      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const MangaHomeScreen()),
          GoRoute(
            path: '/manga-details',
            builder: (context, state) => MangaDetailsRoute(
              $extra: state.extra! as MangaDetailsRouteExtra,
            ).build(context, state),
          ),
          GoRoute(
            path: '/manga-reader',
            builder: (context, state) =>
                MangaReaderRoute($extra: state.extra! as MangaReaderRouteExtra)
                    .build(context, state),
          ),
        ],
      );
      addTearDown(router.dispose);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            extensionManagerProvider.overrideWith(() => _Manager(source)),
            storageServiceProvider.overrideWithValue(storage),
            mangaReadingRepositoryProvider.overrideWith(
              (ref) => MangaReadingRepository(
                storage,
                onChanged: () =>
                    ref.read(mangaReadingRevisionProvider.notifier).bump(),
              ),
            ),
            mangaReaderSettingsProvider.overrideWith(_Settings.new),
            mangaReaderCustomCoversProvider.overrideWith(_NoCovers.new),
            artworkFallbackServiceProvider.overrideWithValue(
              _NoArtwork(storage),
            ),
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
        List<int>? painted;
        final wanted = _color(chapter, page);
        for (var i = 0; i < 60; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
          await tester.pump(const Duration(milliseconds: 32));
          painted = await renderedPixel(flatPage);
          if (listEquals(painted, wanted)) return;
        }
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
}
