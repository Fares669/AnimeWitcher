import 'dart:async';
import 'dart:convert';
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
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_settings_panel.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_paged_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_image_actions_sheet.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_navigation_overlay.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_page_indicator.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/apple_liquid_glass.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

const pages = <MangaPage>[
  MangaPage(index: 0, imageUrl: 'http://127.0.0.1:1/1.webp'),
  MangaPage(index: 1, imageUrl: 'http://127.0.0.1:1/2.webp'),
  MangaPage(index: 2, imageUrl: 'http://127.0.0.1:1/3.webp'),
];

Future<void> _doubleTap(WidgetTester tester, Finder finder) async {
  final position = tester.getCenter(finder);
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tapAt(position);
  await tester.pump(const Duration(milliseconds: 350));
}

final class _ReaderProvider extends AnimeWitcherProvider {
  _ReaderProvider({this.emptyPages = false});

  final bool emptyPages;
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
    return emptyPages ? const <MangaPage>[] : pages;
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

/// Keeps what the reader saves in memory, for reading back.
final class _MemoryReaderSettingsNotifier extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() => const MangaReaderSettings();

  @override
  Future<void> setSettings(MangaReaderSettings value) async => state = value;
}

final class _OverlayReaderSettingsNotifier extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() =>
      const MangaReaderSettings(showNavigationOverlayOnStart: true);
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

final class _ReaderStorage extends StorageService {
  final Map<String, String> values = <String, String>{};

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

final class _RecordingReaderProgressRepository extends MangaReadingRepository {
  _RecordingReaderProgressRepository() : super(_ReaderStorage());
}

final class _ReaderProgressRepository extends MangaReadingRepository {
  _ReaderProgressRepository() : super(_ReaderStorage());

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
    expect(MangaReaderMode.values, <MangaReaderMode>[
      MangaReaderMode.vertical,
      MangaReaderMode.pagedLtr,
      MangaReaderMode.pagedRtl,
      MangaReaderMode.verticalContinuous,
      MangaReaderMode.webtoon,
      MangaReaderMode.horizontalContinuous,
      MangaReaderMode.horizontalContinuousRtl,
    ]);
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
    expect(
      second.pages.map((page) => page.imageUrl),
      pages.map((page) => page.imageUrl),
    );
  });

  test(
    'reader refresh bypasses cached page URLs and refetches source',
    () async {
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

      expect(provider.requestedChapterIds, <String>[
        'refresh-c1',
        'refresh-c1',
      ]);
    },
  );

  test('expired chapter page lists are reloaded on next open', () async {
    final temp = await Directory.systemTemp.createTemp('aw_reader_expired_');
    addTearDown(() => temp.delete(recursive: true));
    final cache = MangaReaderPageCache(cacheDirectory: temp);
    const chapter = MangaChapter(
      id: 'expired-c1',
      mangaId: 'expired-m1',
      url: 'https://example.test/chapter/expired-1',
      name: 'Chapter 1',
    );
    await cache.put('expired-m1', chapter, const <MangaPage>[
      MangaPage(index: 0, imageUrl: 'https://cdn.example/expired.webp'),
    ]);
    final file = (await temp.list().first) as File;
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    data['timestamp'] = DateTime.now()
        .subtract(const Duration(days: 1))
        .millisecondsSinceEpoch;
    await file.writeAsString(jsonEncode(data));
    expect(await cache.get('expired-m1', chapter), isNull);
  });

  test(
    'reader preloads the adjacent chapter after current chapter loads',
    () async {
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
    },
  );

  test('Mangayomi chapter read action toggles read and unread', () async {
    final progress = _RecordingReaderProgressRepository();

    expect(await progress.toggleRead('m1', 'c1', pageCount: 12), isTrue);
    expect(progress.get('m1', 'c1')?.isRead, isTrue);

    expect(await progress.toggleRead('m1', 'c1'), isFalse);
    expect(progress.get('m1', 'c1')?.isRead, isFalse);
  });

  test(
    'auto-read duplicate chapters follows Mangayomi reader completion',
    () async {
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

      expect(progress.get('m1', 'c1-a')?.isRead, isFalse);
      expect(progress.get('m1', 'c1-b'), isNull);

      controller.setPageIndex(2, autoReadDuplicateChapters: true);
      await controller.flushProgress();

      expect(progress.get('m1', 'c1-a')?.isRead, isTrue);
      expect(progress.get('m1', 'c1-b')?.isRead, isTrue);
      expect(progress.get('m1', 'c2'), isNull);
    },
  );

  test('reader screen rebuilds from controller notifications', () {
    final source = File('lib/features/manga/reader/manga_reader_screen.dart')
        .readAsStringSync();

    expect(
      source,
      contains('_controller.addListener(_handleControllerChanged)'),
    );
    expect(
      source,
      contains('_controller.removeListener(_handleControllerChanged)'),
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
          pageBuilder: (_, page) =>
              SizedBox(height: 300, child: Text('page-${page.index}')),
        ),
      ),
    );

    final scroll = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    expect(scroll.scrollDirection, Axis.vertical);
  });

  testWidgets('reader chrome uses double-tap and long-press gestures', (
    tester,
  ) async {
    final provider = _ReaderProvider(emptyPages: true);
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
          mangaReaderSettingsProvider.overrideWith(_ReaderSettingsNotifier.new),
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
    await tester.pump();

    final actionsGesture = find.byKey(
      const ValueKey<String>('manga-reader-image-actions-gesture'),
    );
    expect(actionsGesture, findsOneWidget);
    final gesture = tester.widget<GestureDetector>(actionsGesture);
    expect(gesture.onDoubleTap, isNotNull);
    expect(gesture.onLongPress, isNotNull);
    expect(gesture.onSecondaryTap, isNotNull);
  });

  testWidgets('Mangayomi image action sheet wires all actions', (tester) async {
    var cover = 0;
    var share = 0;
    var save = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MangaReaderImageActionsSheet(
            isArabic: false,
            onSetCover: () => cover++,
            onShare: () => share++,
            onSave: () => save++,
          ),
        ),
      ),
    );

    expect(find.text('Set as cover'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);

    await tester.tap(find.text('Set as cover'));
    await tester.tap(find.text('Share'));
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(cover, 1);
    expect(share, 1);
    expect(save, 1);
  });

  testWidgets('reader uses the Mangayomi per-manga reading mode', (
    tester,
  ) async {
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

    // The one settings button opens the panel, which starts on this manga's
    // own mode rather than the default.
    await tester.tap(
      find.byKey(const ValueKey<String>('manga-reader-settings-button')),
    );
    await tester.pump();
    final panel = tester.widget<MangaReaderSettingsPanel>(
      find.byType(MangaReaderSettingsPanel),
    );
    expect(panel.mode, MangaReaderMode.webtoon);
  });

  testWidgets(
    'reader settings panel uses Arabic labels and top bar has no bookmark',
    (tester) async {
      final provider = _ReaderProvider(emptyPages: true);
      const chapter = MangaChapter(
        id: 'c1',
        mangaId: 'm1',
        url: 'https://example.test/chapter/1',
        name: 'الفصل 1',
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
            extensionManagerProvider.overrideWith(
              () => _ReaderManager(provider),
            ),
            mangaReadingRepositoryProvider.overrideWithValue(
              _ReaderProgressRepository(),
            ),
            mangaReaderSettingsProvider.overrideWith(
              _ReaderSettingsNotifier.new,
            ),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
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

      expect(find.byIcon(Icons.bookmark_rounded), findsNothing);
      expect(find.byIcon(Icons.bookmark_border_rounded), findsNothing);
      expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);

      // The mode's name shows for a moment as the reader opens; let it go.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));

      // The reading modes live in the settings panel now, in Arabic.
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-settings-button')),
      );
      await tester.pump();
      // The tab and the heading under it.
      expect(find.text('وضع القراءة'), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey<String>('manga-reader-choice-mode-default')),
        findsOneWidget,
      );
      // Each mode under the name the reader has always given it.
      for (final (mode, label) in <(String, String)>[
        ('vertical', 'عمودي'),
        ('pagedLtr', 'من اليسار لليمين'),
        ('pagedRtl', 'من اليمين لليسار'),
        ('verticalContinuous', 'عمودي مستمر'),
        ('webtoon', 'ويب تون'),
        ('horizontalContinuous', 'أفقي مستمر'),
        ('horizontalContinuousRtl', 'أفقي مستمر (RTL)'),
      ]) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey<String>('manga-reader-choice-mode-$mode')),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: label,
        );
      }
    },
  );

  testWidgets('page indicator is a compact LTR dark pill at the screen edge', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(bottom: 30),
          ),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(
              body: MangaReaderPageIndicator(
                visible: true,
                currentPage: 7,
                totalPages: 24,
              ),
            ),
          ),
        ),
      ),
    );

    final label = tester.widget<Text>(find.text('7/24'));
    expect(label.style?.fontSize, lessThanOrEqualTo(13));
    expect(label.textAlign, TextAlign.center);

    final directionality = tester.widget<Directionality>(
      find
          .ancestor(
            of: find.text('7/24'),
            matching: find.byType(Directionality),
          )
          .first,
    );
    expect(directionality.textDirection, TextDirection.ltr);

    final containerFinder = find
        .ancestor(of: find.text('7/24'), matching: find.byType(Container))
        .first;
    final container = tester.widget<Container>(containerFinder);
    expect(container.decoration, isA<BoxDecoration>());
    expect(tester.getRect(containerFinder).bottom, 844);

    final screenSource = File(
      'lib/features/manga/reader/manga_reader_screen.dart',
    ).readAsStringSync();
    expect(
      screenSource,
      isNot(contains('minimum: const EdgeInsets.only(bottom: 4)')),
    );
  });

  testWidgets('reader uses Mangayomi navigation overlay widget', (
    tester,
  ) async {
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

  testWidgets('reader chrome paints through the top and bottom safe areas', (
    tester,
  ) async {
    final provider = _ReaderProvider(emptyPages: true);
    const chapter = MangaChapter(
      id: 'safe-c1',
      mangaId: 'safe-m1',
      url: 'https://example.test/chapter/safe-1',
      name: 'Chapter safe',
      number: 1,
    );
    final manga = MultimediaItem(
      title: 'Safe Reader Manga',
      url: 'https://animewitcher.com/manga/safe-m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: provider.packageName,
    );

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          extensionManagerProvider.overrideWith(() => _ReaderManager(provider)),
          mangaReadingRepositoryProvider.overrideWithValue(
            _ReaderProgressRepository(),
          ),
          mangaReaderSettingsProvider.overrideWith(_ReaderSettingsNotifier.new),
        ],
        child: MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              padding: EdgeInsets.only(top: 40, bottom: 30),
            ),
            child: MangaReaderScreen(
              manga: manga,
              chapter: chapter,
              chapters: const <MangaChapter>[chapter],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The bars take the theme's colours now; they are found by name.
    final topChrome = find.byKey(
      const ValueKey<String>('manga-reader-top-chrome'),
    );
    final bottomChrome = find.byKey(
      const ValueKey<String>('manga-reader-page-bar'),
    );

    expect(topChrome, findsOneWidget);
    expect(bottomChrome, findsOneWidget);
    // Floating, inside the safe areas: clear of the status bar and the
    // gesture bar rather than running under them.
    expect(tester.getRect(topChrome).top, greaterThanOrEqualTo(40));
    expect(tester.getRect(bottomChrome).bottom, lessThanOrEqualTo(844 - 30));
  });

  test('reader retry button sits slightly right of center', () {
    final source = File('lib/features/manga/reader/manga_reader_screen.dart')
        .readAsStringSync();

    expect(source, contains("offset: const Offset(20, 0)"));
  });

  test('reader image failures are manual retry only and manga diagnostics are removed', () {
    final pageImageSource = File(
      'lib/features/manga/reader/widgets/manga_page_image.dart',
    ).readAsStringSync();
    final controllerSource = File(
      'lib/features/manga/reader/manga_reader_controller.dart',
    ).readAsStringSync();
    final providerSource = File(
      'lib/core/extensions/providers/animewitcher_native_provider.dart',
    ).readAsStringSync();

    expect(pageImageSource, isNot(contains('_recoverFromImageError')));
    expect(pageImageSource, isNot(contains('onImageError')));
    expect(controllerSource, isNot(contains('refreshFailedPage')));
    expect(providerSource, isNot(contains('mangaReaderDiagnostics')));
    expect(
      File('lib/core/services/manga_reader_diagnostic_log.dart').existsSync(),
      isFalse,
    );
  });

  group('Mihon bar', () {
    Future<ProviderContainer> pumpReader(WidgetTester tester) async {
      final provider = _ReaderProvider(emptyPages: true);
      const chapter = MangaChapter(
        id: 'c1',
        mangaId: 'm1',
        url: 'https://example.test/chapter/1',
        name: 'الفصل 1',
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
            extensionManagerProvider.overrideWith(
              () => _ReaderManager(provider),
            ),
            mangaReadingRepositoryProvider.overrideWithValue(
              _ReaderProgressRepository(),
            ),
            mangaReaderSettingsProvider.overrideWith(
              _MemoryReaderSettingsNotifier.new,
            ),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
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
      return ProviderScope.containerOf(
        tester.element(find.byType(MangaReaderScreen)),
      );
    }

    testWidgets('names the reading mode as the reader opens', (tester) async {
      await pumpReader(tester);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('manga-reader-toast')),
          matching: find.text('عمودي'),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey<String>('manga-reader-toast')),
        findsNothing,
      );
    });

    testWidgets('chapter buttons around the page slider, tools below', (
      tester,
    ) async {
      final container = await pumpReader(tester);
      for (final key in <String>[
        'manga-reader-previous-chapter',
        'manga-reader-page-pill',
        'manga-reader-next-chapter',
        'manga-reader-bar-mode',
        'manga-reader-bar-rotate',
        'manga-reader-bar-crop',
        'manga-reader-settings-button',
      ]) {
        expect(find.byKey(ValueKey<String>(key)), findsOneWidget, reason: key);
      }

      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-bar-crop')),
      );
      await tester.pump();
      expect(container.read(mangaReaderSettingsProvider).cropBorders, isTrue);

      // The screen's turning, for this manga, named as it changes.
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-bar-rotate')),
      );
      await tester.pump();
      expect(
        container.read(mangaReaderSettingsProvider).orientationForManga('m1'),
        MangaReaderOrientation.portrait,
      );
      expect(find.text('الشاشة طولية'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-bar-mode')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-bar-mode-webtoon')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        container.read(mangaReaderSettingsProvider).modeForManga('m1'),
        MangaReaderMode.webtoon,
      );
    });

    testWidgets('scrolling the settings sheet keeps it open', (tester) async {
      await pumpReader(tester);
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-reader-settings-button')),
      );
      await tester.pump();
      final sheet = find.byKey(
        const ValueKey<String>('manga-reader-settings-panel'),
      );
      expect(sheet, findsOneWidget);

      await tester.drag(
        find.descendant(of: sheet, matching: find.byType(Scrollable)).first,
        const Offset(0, -300),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sheet, findsOneWidget);
    });

    testWidgets('a computer has no rotate button', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpReader(tester);
        expect(
          find.byKey(const ValueKey<String>('manga-reader-bar-rotate')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey<String>('manga-reader-bar-crop')),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 3));
        // Nor the phone's options: system bars, keeping awake, long taps.
        await tester.tap(
          find.byKey(const ValueKey<String>('manga-reader-settings-button')),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey<String>('manga-reader-panel-tab-general')),
        );
        await tester.pump();
        for (final key in <String>[
          'fullscreen',
          'keep-on',
          'long-tap-actions',
        ]) {
          expect(
            find.byKey(ValueKey<String>('manga-reader-switch-$key')),
            findsNothing,
            reason: key,
          );
        }
        expect(
          find.byKey(const ValueKey<String>('manga-reader-switch-page-number')),
          findsOneWidget,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
