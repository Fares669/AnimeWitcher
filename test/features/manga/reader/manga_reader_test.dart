import 'dart:async';
import 'dart:io';

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_controller.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_page_cache.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_screen.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_paged_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_page_image.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_navigation_overlay.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

const pages = <MangaPage>[
  MangaPage(index: 0, imageUrl: 'https://example.test/1.webp'),
  MangaPage(index: 1, imageUrl: 'https://example.test/2.webp'),
  MangaPage(index: 2, imageUrl: 'https://example.test/3.webp'),
];

final class _ReaderProvider extends AnimeWitcherProvider {
  _ReaderProvider({
    this.emptyPages = false,
    this.pageList = pages,
  });

  final bool emptyPages;
  final List<MangaPage> pageList;
  final List<String> requestedChapterIds = <String>[];
  final Map<String, Completer<void>> _requestWaiters =
      <String, Completer<void>>{};

  Future<void> waitUntilRequested(String chapterId) {
    if (requestedChapterIds.contains(chapterId)) return Future<void>.value();
    return _requestWaiters
        .putIfAbsent(chapterId, Completer<void>.new)
        .future
        .timeout(const Duration(seconds: 1));
  }

  @override
  String get packageName => 'test.reader.manga';

  @override
  String get name => 'Reader Manga Provider';

  @override
  String get mainUrl => 'https://example.test';

  @override
  String get version => '1';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const <ProviderType>{
    ProviderType.manga,
  };

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const <MultimediaItem>[];

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async =>
      const <String, List<MultimediaItem>>{};

  @override
  Future<MultimediaItem> getDetails(String url) =>
      throw UnsupportedError('Anime details must not be used');

  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnsupportedError('Streams must not be used');

  @override
  Future<List<MangaPage>> getMangaChapterPages(
    String mangaUrl,
    MangaChapter chapter,
  ) async {
    requestedChapterIds.add(chapter.id);
    final waiter = _requestWaiters[chapter.id];
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    return emptyPages ? const <MangaPage>[] : pageList;
  }
}

final class _ReaderManager extends ExtensionManager {
  _ReaderManager(this.provider);

  final AnimeWitcherProvider provider;

  @override
  List<AnimeWitcherProvider> build() => <AnimeWitcherProvider>[provider];
}

final class _ReaderSettingsNotifier extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() => const MangaReaderSettings();
}

final class _OverlayReaderSettingsNotifier
    extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() => const MangaReaderSettings(
    showNavigationOverlayOnStart: true,
  );
}

final class _PerMangaReaderSettingsNotifier
    extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() => const MangaReaderSettings(
    defaultMode: MangaReaderMode.vertical,
    personalReaderModes: <String, MangaReaderMode>{
      'm1': MangaReaderMode.webtoon,
    },
  );
}


final class _RecordingReaderProgressRepository
    extends MangaReadingRepository {
  _RecordingReaderProgressRepository() : super(StorageService());

  final Map<String, MangaReadingProgress> values =
      <String, MangaReadingProgress>{};

  String _key(String mangaId, String chapterId) => '$mangaId::$chapterId';

  @override
  MangaReadingProgress? get(String mangaId, String chapterId) =>
      values[_key(mangaId, chapterId)];

  @override
  Future<void> save(MangaReadingProgress progress) async {
    values[_key(progress.mangaId, progress.chapterId)] = progress;
  }
}

final class _ReaderProgressRepository extends MangaReadingRepository {
  _ReaderProgressRepository() : super(StorageService());

  @override
  MangaReadingProgress? get(String mangaId, String chapterId) => null;

  @override
  Future<void> save(MangaReadingProgress progress) async {}
}

void main() {
  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  test('reader exposes webtoon, paged LTR and paged RTL modes', () {
    expect(
      MangaReaderMode.values,
      <MangaReaderMode>[
        MangaReaderMode.vertical,
        MangaReaderMode.pagedLtr,
        MangaReaderMode.pagedRtl,
        MangaReaderMode.verticalContinuous,
        MangaReaderMode.webtoon,
        MangaReaderMode.horizontalContinuous,
        MangaReaderMode.horizontalContinuousRtl,
      ],
    );
  });

  test('reader reuses Mangayomi chapter page-list disk cache', () async {
    final temp = await Directory.systemTemp.createTemp('aw_reader_cache_');
    addTearDown(() => temp.delete(recursive: true));

    final provider = _ReaderProvider();
    const chapter = MangaChapter(
      id: 'cache-c1',
      mangaId: 'cache-m1',
      url: 'https://example.test/chapter/cache-1',
      name: 'Chapter cache',
      number: 1,
    );
    final manga = MultimediaItem(
      title: 'Cached Reader Manga',
      url: 'https://animewitcher.com/manga/cache-m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: provider.packageName,
    );
    final cache = MangaReaderPageCache(cacheDirectory: temp);

    final first = MangaReaderController(
      provider: provider,
      progressRepository: _ReaderProgressRepository(),
      manga: manga,
      chapter: chapter,
      chapters: const <MangaChapter>[chapter],
      pageCache: cache,
    );
    await first.load();
    first.dispose();
    expect(provider.requestedChapterIds, <String>['cache-c1']);

    final second = MangaReaderController(
      provider: provider,
      progressRepository: _ReaderProgressRepository(),
      manga: manga,
      chapter: chapter,
      chapters: const <MangaChapter>[chapter],
      pageCache: cache,
    );
    addTearDown(second.dispose);
    await second.load();

    expect(provider.requestedChapterIds, <String>['cache-c1']);
    expect(second.pages.map((page) => page.imageUrl), pages.map((page) => page.imageUrl));
  });

  test('reader refresh bypasses cached page URLs and refetches source', () async {
    final temp = await Directory.systemTemp.createTemp('aw_reader_refresh_');
    addTearDown(() => temp.delete(recursive: true));

    final provider = _ReaderProvider();
    const chapter = MangaChapter(
      id: 'refresh-c1',
      mangaId: 'refresh-m1',
      url: 'https://example.test/chapter/refresh-1',
      name: 'Chapter refresh',
      number: 1,
    );
    final manga = MultimediaItem(
      title: 'Refresh Reader Manga',
      url: 'https://animewitcher.com/manga/refresh-m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: provider.packageName,
    );
    final controller = MangaReaderController(
      provider: provider,
      progressRepository: _ReaderProgressRepository(),
      manga: manga,
      chapter: chapter,
      chapters: const <MangaChapter>[chapter],
      pageCache: MangaReaderPageCache(cacheDirectory: temp),
    );
    addTearDown(controller.dispose);

    await controller.load();
    expect(provider.requestedChapterIds, <String>['refresh-c1']);

    await controller.load();

    expect(
      provider.requestedChapterIds,
      <String>['refresh-c1', 'refresh-c1'],
    );
  });

  test('reader preloads the adjacent chapter after current chapter loads', () async {
    final temp = await Directory.systemTemp.createTemp('aw_reader_preload_');
    addTearDown(() => temp.delete(recursive: true));
    final provider = _ReaderProvider();
    const first = MangaChapter(
      id: 'c1',
      mangaId: 'm1',
      url: 'https://example.test/chapter/1',
      name: 'Chapter 1',
      number: 1,
    );
    const second = MangaChapter(
      id: 'c2',
      mangaId: 'm1',
      url: 'https://example.test/chapter/2',
      name: 'Chapter 2',
      number: 2,
    );
    final manga = MultimediaItem(
      title: 'Reader Manga',
      url: 'https://animewitcher.com/manga/m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: provider.packageName,
    );
    final controller = MangaReaderController(
      provider: provider,
      progressRepository: _ReaderProgressRepository(),
      manga: manga,
      chapter: first,
      chapters: const <MangaChapter>[first, second],
      pageCache: MangaReaderPageCache(cacheDirectory: temp),
    );
    addTearDown(controller.dispose);

    await controller.load();
    await provider.waitUntilRequested('c2');

    expect(provider.requestedChapterIds, containsAll(<String>['c1', 'c2']));
  });

  test('Mangayomi chapter read action toggles read and unread', () async {
    final progress = _RecordingReaderProgressRepository();

    expect(
      await progress.toggleRead('m1', 'c1', pageCount: 12),
      isTrue,
    );
    expect(progress.get('m1', 'c1')?.isRead, isTrue);

    expect(await progress.toggleRead('m1', 'c1'), isFalse);
    expect(progress.get('m1', 'c1')?.isRead, isFalse);
  });

  test('auto-read duplicate chapters follows Mangayomi reader completion', () async {
    final provider = _ReaderProvider();
    final progress = _RecordingReaderProgressRepository();
    const first = MangaChapter(
      id: 'c1-a',
      mangaId: 'm1',
      url: 'https://example.test/chapter/1-a',
      name: 'Chapter 1',
      number: 1,
    );
    const duplicate = MangaChapter(
      id: 'c1-b',
      mangaId: 'm1',
      url: 'https://example.test/chapter/1-b',
      name: 'Chapter 1 duplicate',
      number: 1,
    );
    const second = MangaChapter(
      id: 'c2',
      mangaId: 'm1',
      url: 'https://example.test/chapter/2',
      name: 'Chapter 2',
      number: 2,
    );
    final manga = MultimediaItem(
      title: 'Reader Manga',
      url: 'https://animewitcher.com/manga/m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: provider.packageName,
    );
    final controller = MangaReaderController(
      provider: provider,
      progressRepository: progress,
      manga: manga,
      chapter: first,
      chapters: const <MangaChapter>[first, duplicate, second],
      initialMode: MangaReaderMode.pagedRtl,
    );
    addTearDown(controller.dispose);

    await controller.load();
    controller.setPageIndex(1, autoReadDuplicateChapters: true);
    await controller.flushProgress();

    expect(progress.get('m1', 'c1-a')?.isRead, isTrue);
    expect(progress.get('m1', 'c1-b')?.isRead, isTrue);
    expect(progress.get('m1', 'c2'), isNull);
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

  testWidgets('long press opens Mangayomi image actions', (tester) async {
    final temp = await Directory.systemTemp.createTemp('aw_reader_actions_');
    addTearDown(() => temp.delete(recursive: true));
    final localPage = File('${temp.path}/page.webp');
    await localPage.writeAsBytes(<int>[1, 2, 3, 4]);
    final provider = _ReaderProvider(
      pageList: <MangaPage>[
        MangaPage(index: 0, imageUrl: localPage.uri.toString()),
      ],
    );
    const chapter = MangaChapter(
      id: 'actions-c1',
      mangaId: 'actions-m1',
      url: 'https://example.test/chapter/actions-1',
      name: 'Chapter actions',
      number: 1,
    );
    final manga = MultimediaItem(
      title: 'Actions Reader Manga',
      url: 'https://animewitcher.com/manga/actions-m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: provider.packageName,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          extensionManagerProvider.overrideWith(() => _ReaderManager(provider)),
          mangaReadingRepositoryProvider.overrideWithValue(
            _ReaderProgressRepository(),
          ),
          mangaReaderSettingsProvider.overrideWith(
            _ReaderSettingsNotifier.new,
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          home: MangaReaderScreen(
            manga: manga,
            chapter: chapter,
            chapters: const <MangaChapter>[chapter],
          ),
        ),
      ),
    );
    await provider.waitUntilRequested('actions-c1');
    await tester.pump();
    await tester.pump();

    expect(find.byType(MangaPageImage), findsWidgets);
    await tester.longPress(find.byType(MangaPageImage).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Set as cover'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('reader uses the Mangayomi per-manga reading mode', (tester) async {
    final provider = _ReaderProvider();
    const chapter = MangaChapter(
      id: 'c1',
      mangaId: 'm1',
      url: 'https://example.test/chapter/1',
      name: 'Chapter 1',
    );
    final manga = MultimediaItem(
      title: 'Reader Manga',
      url: 'https://animewitcher.com/manga/m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: provider.packageName,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          extensionManagerProvider.overrideWith(() => _ReaderManager(provider)),
          mangaReadingRepositoryProvider.overrideWithValue(
            _ReaderProgressRepository(),
          ),
          mangaReaderSettingsProvider.overrideWith(
            _PerMangaReaderSettingsNotifier.new,
          ),
        ],
        child: MaterialApp(
          home: MangaReaderScreen(
            manga: manga,
            chapter: chapter,
            chapters: const <MangaChapter>[chapter],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final modeMenu = tester.widget<PopupMenuButton<MangaReaderMode>>(
      find.byType(PopupMenuButton<MangaReaderMode>),
    );
    expect(modeMenu.initialValue, MangaReaderMode.webtoon);
  });

  testWidgets('reader uses Mangayomi navigation overlay widget', (tester) async {
    final provider = _ReaderProvider(emptyPages: true);
    const chapter = MangaChapter(
      id: 'c1',
      mangaId: 'm1',
      url: 'https://example.test/chapter/1',
      name: 'Chapter 1',
    );
    final manga = MultimediaItem(
      title: 'Reader Manga',
      url: 'https://animewitcher.com/manga/m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: provider.packageName,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          extensionManagerProvider.overrideWith(() => _ReaderManager(provider)),
          mangaReadingRepositoryProvider.overrideWithValue(
            _ReaderProgressRepository(),
          ),
          mangaReaderSettingsProvider.overrideWith(
            _OverlayReaderSettingsNotifier.new,
          ),
        ],
        child: MaterialApp(
          home: MangaReaderScreen(
            manga: manga,
            chapter: chapter,
            chapters: const <MangaChapter>[chapter],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(MangaReaderNavigationOverlay), findsOneWidget);
  });

  testWidgets('reader owns the persistent iOS header without details actions', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final staleHeader = applePersistentGlassHeaderController.value;
    if (staleHeader != null) {
      applePersistentGlassHeaderController.hide(staleHeader.owner);
    }

    final provider = _ReaderProvider(emptyPages: true);
    const chapter = MangaChapter(
      id: 'c1',
      mangaId: 'm1',
      url: 'https://example.test/chapter/1',
      name: 'الفصل 1',
      number: 1,
    );
    final manga = MultimediaItem(
      title: 'Reader Manga',
      url: 'https://animewitcher.com/manga/m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: provider.packageName,
    );

    try {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            extensionManagerProvider.overrideWith(() => _ReaderManager(provider)),
            mangaReadingRepositoryProvider.overrideWithValue(
              _ReaderProgressRepository(),
            ),
            mangaReaderSettingsProvider.overrideWith(
              _ReaderSettingsNotifier.new,
            ),
          ],
          child: MaterialApp(
            home: MangaReaderScreen(
              manga: manga,
              chapter: chapter,
              chapters: const <MangaChapter>[chapter],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final header = applePersistentGlassHeaderController.value;
      expect(header, isNotNull);
      expect(header!.route?.isCurrent, isTrue);
      expect(header.onBack, isNotNull);
      expect(header.trailingButtons, isEmpty);
    } finally {
      final header = applePersistentGlassHeaderController.value;
      if (header != null) {
        applePersistentGlassHeaderController.hide(header.owner);
      }
      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}
