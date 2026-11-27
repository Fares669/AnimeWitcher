import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/services/download_v2/manga_chapter_manifest_v2.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_controller.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_page_cache.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_screen.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_settings_panel.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_paged_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_image_actions_sheet.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_continuous_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_navigation_overlay.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_reader_page_indicator.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:visibility_detector/visibility_detector.dart';

const pages = <MangaPage>[
  MangaPage(index: 0, imageUrl: 'http://127.0.0.1:1/1.webp'),
  MangaPage(index: 1, imageUrl: 'http://127.0.0.1:1/2.webp'),
  MangaPage(index: 2, imageUrl: 'http://127.0.0.1:1/3.webp'),
];

final class _ReaderProvider extends AnimeWitcherProvider {
  _ReaderProvider({this.emptyPages = false});

  final bool emptyPages;
  final List<String> requestedChapterIds = <String>[];
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
    return emptyPages ? const <MangaPage>[] : pages;
  }
}

final class _RecordingReaderPageCache extends MangaReaderPageCache {
  _RecordingReaderPageCache({required super.cacheDirectory});

  final Map<String, Completer<void>> _writeWaiters =
      <String, Completer<void>>{};

  Future<void> waitUntilWritten(String chapterId) => _writeWaiters
      .putIfAbsent(chapterId, Completer<void>.new)
      .future
      .timeout(const Duration(seconds: 2));

  @override
  Future<void> put(
    String mangaId,
    MangaChapter chapter,
    List<MangaPage> pages,
  ) async {
    await super.put(mangaId, chapter, pages);
    final waiter = _writeWaiters.putIfAbsent(chapter.id, Completer<void>.new);
    if (!waiter.isCompleted) waiter.complete();
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

/// Serves real local image files as chapter pages, so the full screen
/// can stream chapters whose images actually load.
final class _LocalStreamProvider extends AnimeWitcherProvider {
  _LocalStreamProvider(this.directory, {this.extension = 'bmp'});

  final Directory directory;
  final String extension;
  final List<String> requestedChapterIds = <String>[];

  @override
  String get packageName => 'test.reader.stream';
  @override
  String get name => 'Stream reader';
  @override
  String get mainUrl => 'https://example.test';
  @override
  String get version => '1';
  @override
  List<String> get languages => const <String>['en'];
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
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
  @override
  Future<List<MangaPage>> getMangaChapterPages(
    String mangaUrl,
    MangaChapter chapter,
  ) async {
    requestedChapterIds.add(chapter.id);
    return <MangaPage>[
      for (var i = 0; i < 3; i++)
        MangaPage(
          index: i,
          imageUrl: File(
            '${directory.path}/page-${i + 1}.$extension',
          ).uri.toString(),
        ),
    ];
  }
}

final class _ReaderCachePathProvider extends PathProviderPlatform {
  _ReaderCachePathProvider(this.root);

  final String root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

final class _CacheUiIoProbe extends IOOverrides {
  _CacheUiIoProbe(this.directory);

  final String directory;
  int synchronousListings = 0;
  int synchronousStats = 0;
  Duration synchronousListTime = Duration.zero;
  Duration synchronousStatTime = Duration.zero;

  @override
  Directory createDirectory(String path) {
    final delegate = super.createDirectory(path);
    return path == directory ? _TracedCacheDirectory(delegate, this) : delegate;
  }

  @override
  FileStat statSync(String path) {
    if (!path.startsWith('$directory${Platform.pathSeparator}')) {
      return super.statSync(path);
    }
    final timer = Stopwatch()..start();
    final result = super.statSync(path);
    synchronousStats++;
    synchronousStatTime += timer.elapsed;
    return result;
  }
}

final class _TracedCacheDirectory implements Directory {
  _TracedCacheDirectory(this._delegate, this._probe);

  final Directory _delegate;
  final _CacheUiIoProbe _probe;

  @override
  String get path => _delegate.path;

  @override
  Future<bool> exists() => _delegate.exists();

  @override
  Future<Directory> create({bool recursive = false}) =>
      _delegate.create(recursive: recursive);

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) {
    final timer = Stopwatch()..start();
    final result = _delegate.listSync(
      recursive: recursive,
      followLinks: followLinks,
    );
    _probe.synchronousListings++;
    _probe.synchronousListTime += timer.elapsed;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _WebtoonStreamSettingsNotifier extends MangaReaderSettingsNotifier {
  _WebtoonStreamSettingsNotifier({this.preloadWidth = 6});

  final int preloadWidth;

  @override
  MangaReaderSettings build() => MangaReaderSettings(
    defaultMode: MangaReaderMode.webtoon,
    showReadingMode: false,
    keepScreenOn: false,
    fullScreen: false,
    pagePreloadAmount: preloadWidth,
  );
}

final class _ContinuousStreamSettingsNotifier
    extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() => const MangaReaderSettings(
    defaultMode: MangaReaderMode.verticalContinuous,
    showReadingMode: false,
    keepScreenOn: false,
    fullScreen: false,
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

final class _DelayedReaderProgressRepository extends MangaReadingRepository {
  _DelayedReaderProgressRepository() : super(_ReaderStorage());

  final Completer<void> firstSaveStarted = Completer<void>();
  final Completer<void> releaseFirstSave = Completer<void>();
  var saves = 0;

  @override
  Future<void> save(MangaReadingProgress progress) async {
    if (++saves == 1) {
      firstSaveStarted.complete();
      await releaseFirstSave.future;
    }
  }
}

final class _NoOtherDownloadedChapters extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const [];
}

void main() {
  setUpAll(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  final webtoonFixtures = ValueVariant<({int preloadWidth, int count})>({
    (preloadWidth: 6, count: 8),
    (preloadWidth: 2, count: 8),
    (preloadWidth: 2, count: 192),
  });
  testWidgets('Webtoon resumes a completed chapter and persists physical scroll', (
    tester,
  ) async {
    final (:preloadWidth, :count) = webtoonFixtures.currentValue!;
    const chapter = MangaChapter(
      id: 'plain-webtoon-chapter',
      mangaId: 'plain-webtoon-manga',
      url: 'https://example.test/webtoon/chapter',
      name: 'Plain Webtoon chapter',
    );
    const resume = 3;
    final dir = Directory.systemTemp.createTempSync('webtoon_offsets_');
    addTearDown(() => dir.delete(recursive: true));
    final digests = <int, String>{};
    final colors = <int, List<int>>{};
    await tester.runAsync(() async {
      for (var i = 0; i < count; i++) {
        final color = [20 + (i * 31) % 211, 30 + (i * 47) % 201, 88];
        colors[i] = color;
        final picture = img.Image(width: 24, height: 16);
        img.fill(picture, color: img.ColorRgb8(color[0], color[1], color[2]));
        final file = File('${dir.path}/${(i + 1).toString().padLeft(4, '0')}.gif');
        await file.writeAsBytes(img.encodeGif(picture), flush: true);
        digests[i] = await MangaChapterManifestV2.pageDigest(file);
      }
      await MangaChapterManifestV2(
        version: MangaChapterManifestV2.currentVersion,
        mangaId: chapter.mangaId,
        chapterId: chapter.id,
        pageCount: count,
        completedIndexes: digests.keys.toSet(),
        isComplete: true,
        // Exercise both legacy chapters and integrity-checked downloads.
        pageDigests: count > 8 ? digests : const <int, String>{},
      ).writeTo(dir);
    });
    final provider = _ReaderProvider(emptyPages: true);
    final progress = _RecordingReaderProgressRepository();
    await progress.save(MangaReadingProgress(
      mangaId: chapter.mangaId,
      chapterId: chapter.id,
      pageIndex: resume,
      pageCount: count,
      updatedAt: 1,
    ));
    final scrollView = find.byType(CustomScrollView);
    final webtoon = find.byType(MangaWebtoonReader);
    final launcher = find.text('Open local Webtoon');

    Widget app() => ProviderScope(
      overrides: [
        extensionManagerProvider.overrideWith(() => _ReaderManager(provider)),
        mangaReadingRepositoryProvider.overrideWithValue(progress),
        mangaReaderSettingsProvider.overrideWith(
          () => _WebtoonStreamSettingsNotifier(preloadWidth: preloadWidth),
        ),
        downloadsProvider.overrideWith(_NoOtherDownloadedChapters.new),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(builder: (_) => MangaReaderScreen(
                manga: MultimediaItem(
                  title: 'Plain Webtoon manga',
                  url: 'https://example.test/webtoon',
                  posterUrl: '',
                  provider: provider.packageName,
                  contentType: MultimediaContentType.manga,
                ),
                chapter: chapter,
                chapters: const [chapter],
                localChapterDirectory: dir.path,
              )),
            ),
            child: const Text('Open local Webtoon'),
          ),
        )),
      ),
    );

    int? savedPage() => progress.get(chapter.mangaId, chapter.id)?.pageIndex;
    Future<void> eventually(String stage, bool Function() ready) async {
      // A hashed chapter performs sequential async filesystem checks. Give
      // each real IO completion a fake-clock turn before counting paint.
      final openingHashedChapter = count > 8 && stage == 'local chapter open';
      final turns = openingHashedChapter ? 2048 : 480;
      final delay = Duration(milliseconds: openingHashedChapter ? 2 : 6);
      for (var i = 0; i < turns; i++) {
        await tester.runAsync(() => Future<void>.delayed(delay));
        await tester.pump(const Duration(milliseconds: 32));
        if (ready()) {
          debugPrint('Webtoon fixture: $stage ready; saved=${savedPage()}');
          return;
        }
        // Stop on a real product error instead of calling it a slow fixture.
        final screen = find.byType(MangaReaderScreen);
        if (screen.evaluate().isNotEmpty) {
          final label = AppLocalizations.of(tester.element(screen))?.retry;
          if (label != null && find.text(label).evaluate().isNotEmpty) {
            fail('Webtoon fixture: $stage hit the reader retry UI');
          }
        }
      }
      final screens = find.byType(MangaReaderScreen).evaluate().length;
      fail('Webtoon fixture: $stage pending; '
          'screen=$screens reader=${webtoon.evaluate().length} '
          'saved=${savedPage()} provider=${provider.requestedChapterIds}');
    }

    Finder row(int index) => find.byKey(ValueKey('manga-webtoon-$index-$index'));
    Finder painted(int index) =>
        find.descendant(of: row(index), matching: find.byType(RawImage));
    Future<void> expectPixels(int index) async {
      await eventually('decoded page $index', () => painted(index).evaluate().any(
        (element) => (element.widget as RawImage).image != null,
      ));
      final raw = tester.widget<RawImage>(painted(index));
      final image = raw.image!;
      final byteData = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      expect(byteData, isNotNull);
      expect([for (var i = 0; i < 3; i++) byteData!.getUint8(i)], colors[index]);
    }

    void expectLayout(int anchor, {Key? sessionCenter}) {
      final scroll = tester.widget<CustomScrollView>(scrollView);
      final slivers = scroll.slivers.whereType<SliverList>().toList();
      expect(slivers, hasLength(2));
      expect(slivers.first.delegate.estimatedChildCount, anchor);
      expect(slivers.last.delegate.estimatedChildCount, count - anchor);
      expect(scroll.center, isNotNull);
      expect(scroll.center, slivers.last.key);
      if (sessionCenter != null) expect(scroll.center, same(sessionCenter));
    }

    void expectVisibleGap(int page) {
      final gap = find.descendant(
        of: row(page),
        matching: find.byKey(const ValueKey('manga-reader-page-gap')),
      );
      expect(gap, findsOneWidget);
      expect(tester.widget<Padding>(gap).padding,
          const EdgeInsets.only(bottom: 8));
      expect(tester.getRect(painted(page)).overlaps(tester.getRect(scrollView)),
          isTrue);
    }

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    debugPrint('Webtoon fixture: open local chapter count=$count resume=$resume');
    await tester.tap(launcher);
    await eventually('local chapter open', () => webtoon.evaluate().isNotEmpty);
    final state = tester.state(webtoon);
    final initial = tester.widget<MangaWebtoonReader>(webtoon);
    expect(initial.initialPage, resume);
    expect(initial.pages, hasLength(count));
    expect(
      initial.pages.map((page) => page.imageUrl),
      [
        for (var i = 0; i < count; i++)
          File('${dir.path}/${(i + 1).toString().padLeft(4, '0')}.gif')
              .uri.toString(),
      ],
    );
    expect(initial.doublePage, isFalse);
    expect(initial.sectionDividers, isEmpty);
    expect(initial.settings.showPageGaps, isTrue);
    expect(initial.settings.pagePreloadAmount, preloadWidth);
    final controller = initial.controller;
    final sessionCenter = tester.widget<CustomScrollView>(scrollView).center;
    expect(controller, isNotNull);
    expectLayout(resume);
    await expectPixels(resume);
    expectVisibleGap(resume);
    expect(provider.requestedChapterIds, isEmpty);

    await tester.drag(scrollView, const Offset(0, -620));
    await eventually('progress after forward', () => (savedPage() ?? -1) > resume);
    final advanced = savedPage()!;
    await expectPixels(advanced);
    expect(tester.state(webtoon), same(state));
    expect(tester.widget<MangaWebtoonReader>(webtoon).controller, same(controller));
    expectLayout(resume, sessionCenter: sessionCenter);
    expectVisibleGap(advanced);
    await tester.drag(scrollView, const Offset(0, 620));
    await eventually('progress after reverse', () => (savedPage() ?? -1) < advanced);
    final reversed = savedPage()!;
    await expectPixels(reversed);
    expect(tester.state(webtoon), same(state));
    expectLayout(resume, sessionCenter: sessionCenter);
    expectVisibleGap(reversed);
    await tester.drag(scrollView, const Offset(0, -620));
    await eventually('progress after second forward', () => (savedPage() ?? -1) > reversed);
    final last = savedPage()!;
    await expectPixels(last);
    expect(tester.state(webtoon), same(state));
    expectLayout(resume, sessionCenter: sessionCenter);
    expectVisibleGap(last);
    expect(provider.requestedChapterIds, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await eventually('exit reader route', () =>
        webtoon.evaluate().isEmpty && launcher.hitTestable().evaluate().isNotEmpty);
    expect(savedPage(), last);
    // Reopen with the file-image cache still warm: image settlement can
    // notify Webtoon synchronously while Flutter is laying out a row.
    await tester.tap(launcher);
    await eventually('local chapter open', () => webtoon.evaluate().isNotEmpty);
    expect(tester.widget<MangaWebtoonReader>(webtoon).initialPage, last);
    expect(tester.state(webtoon), isNot(same(state)));
    expectLayout(last);
    await expectPixels(last);
    expectVisibleGap(last);
    expect(provider.requestedChapterIds, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(() async {
      for (var i = 0; i < count; i++) {
        final file = File('${dir.path}/${(i + 1).toString().padLeft(4, '0')}.gif');
        expect(await MangaChapterManifestV2.pageDigest(file), digests[i]);
      }
    });
  }, variant: webtoonFixtures);

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

  test('reader cache trims oldest entries only after durable publication', () async {
    final directory = await Directory.systemTemp.createTemp('reader_trim_');
    addTearDown(() => directory.delete(recursive: true));
    final cache = MangaReaderPageCache(cacheDirectory: directory);
    final otherCache = MangaReaderPageCache(cacheDirectory: directory);
    final now = DateTime.now();
    Future<File> sparseFile(String name, int mebibytes, int age) async {
      final file = File('${directory.path}/$name');
      final handle = await file.open(mode: FileMode.write);
      await handle.truncate(mebibytes * 1024 * 1024);
      await handle.close();
      await file.setLastModified(now.subtract(Duration(minutes: age)));
      return file;
    }
    final old = await sparseFile('old.json', 20, 4);
    final newer = await sparseFile('newer.json', 85, 2);
    final unrelated = await sparseFile('unrelated.tmp', 105, 6);
    const chapter = MangaChapter(
      id: 'evict',
      mangaId: 'm1',
      url: '/evict',
      name: 'Evict',
    );
    const oldPages = <MangaPage>[MangaPage(index: 0, imageUrl: 'old')];
    const freshPages = <MangaPage>[
      MangaPage(
        index: 7,
        imageUrl: ' https://example.test/new.webp ',
        headers: {'Referer': 'https://example.test'},
      ),
    ];
    await cache.put('m1', chapter, oldPages);
    await otherCache.put('m1', chapter, freshPages);
    final fresh = (await cache.get(' m1 ', chapter))!.single;
    expect(fresh.index, 7);
    expect(fresh.imageUrl, 'https://example.test/new.webp');
    expect(fresh.headers, {'Referer': 'https://example.test'});
    expect(await cache.get('different-owner', chapter), isNull);
    await Future.wait<void>([
      cache.waitForMaintenance(),
      otherCache.waitForMaintenance(),
    ]);
    expect(await old.exists(), isFalse);
    expect(await newer.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    expect((await cache.get('m1', chapter))?.single.imageUrl, fresh.imageUrl);
    expect((await directory.list().toList()).where(
      (file) => file.path.endsWith('.tmp') && file.path != unrelated.path,
    ), isEmpty);
  });

  test('a descending chapter list still navigates in reading order', () async {
    final temp = await Directory.systemTemp.createTemp('aw_reader_order_');
    addTearDown(() => temp.delete(recursive: true));
    final provider = _ReaderProvider();
    final cache = _RecordingReaderPageCache(cacheDirectory: temp);
    const first = MangaChapter(
      id: 'ord-c1',
      mangaId: 'ord-m1',
      url: 'https://example.test/chapter/ord-1',
      name: 'Chapter 1',
      number: 1,
    );
    const second = MangaChapter(
      id: 'ord-c2',
      mangaId: 'ord-m1',
      url: 'https://example.test/chapter/ord-2',
      name: 'Chapter 2',
      number: 2,
    );
    final manga = MultimediaItem(
      title: 'Reader Manga',
      url: 'https://animewitcher.com/manga/ord-m1',
      posterUrl: '',
      contentType: MultimediaContentType.manga,
      provider: provider.packageName,
    );
    // The downloads page hands the reader its display order — newest
    // first when sorted descending. Inside the reader the order is
    // always reading order: chapter 1 still has a next, chapter 2 a
    // previous, regardless of how the list arrived.
    final controller = MangaReaderController(
      provider: provider,
      progressRepository: _ReaderProgressRepository(),
      manga: manga,
      chapter: first,
      chapters: const <MangaChapter>[second, first],
      pageCache: cache,
    );
    addTearDown(controller.dispose);

    expect(controller.chapters.map((c) => c.id), <String>['ord-c1', 'ord-c2']);
    await controller.load();
    expect(controller.canNext, isTrue);
    expect(controller.canPrevious, isFalse);

    await controller.nextChapter();
    expect(controller.currentChapter.id, 'ord-c2');
    expect(controller.canNext, isFalse);
    expect(controller.canPrevious, isTrue);
  });

  test('reader preloads the adjacent chapter after current chapter loads', () async {
    final temp = await Directory.systemTemp.createTemp('aw_reader_preload_');
    addTearDown(() => temp.delete(recursive: true));
    final provider = _ReaderProvider();
    final cache = _RecordingReaderPageCache(cacheDirectory: temp);
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
      pageCache: cache,
    );
    addTearDown(controller.dispose);

    await controller.load();
    // Provider entry precedes the background write; teardown needs the latter.
    await cache.waitUntilWritten('c2');

    expect(provider.requestedChapterIds, containsAll(<String>['c1', 'c2']));
    expect(
      (await cache.get('m1', second))?.map((page) => page.imageUrl),
      pages.map((page) => page.imageUrl),
    );
  });

  test('latest stream chapter wins when an older progress flush is delayed', () async {
    final temp = await Directory.systemTemp.createTemp('aw_reader_adoption_');
    addTearDown(() => temp.delete(recursive: true));
    final provider = _ReaderProvider();
    final progress = _DelayedReaderProgressRepository();
    const first = MangaChapter(
      id: 'adopt-1', mangaId: 'm1',
      url: 'https://example.test/chapter/adopt-1', name: 'Chapter 1', number: 1,
    );
    const second = MangaChapter(
      id: 'adopt-2', mangaId: 'm1',
      url: 'https://example.test/chapter/adopt-2', name: 'Chapter 2', number: 2,
    );
    const third = MangaChapter(
      id: 'adopt-3', mangaId: 'm1',
      url: 'https://example.test/chapter/adopt-3', name: 'Chapter 3', number: 3,
    );
    final controller = MangaReaderController(
      provider: provider,
      progressRepository: progress,
      manga: MultimediaItem(
        title: 'Reader Manga', url: 'https://animewitcher.com/manga/m1',
        posterUrl: '', contentType: MultimediaContentType.manga,
        provider: provider.packageName,
      ),
      chapter: first,
      chapters: const <MangaChapter>[first, second, third],
      pageCache: MangaReaderPageCache(cacheDirectory: temp),
    );
    addTearDown(controller.dispose);
    await controller.load();

    final stale = controller.adoptStreamChapter(second, pages, 1);
    await progress.firstSaveStarted.future;
    final latest = controller.adoptStreamChapter(third, pages, 2);
    await latest;
    progress.releaseFirstSave.complete();
    await stale;

    expect(controller.currentChapter.id, 'adopt-3');
    expect(controller.pageIndex, 2);
  });

  test(
    'stream fetch and adopt move between chapters without reopening',
    () async {
      final temp = await Directory.systemTemp.createTemp('aw_reader_stream_');
      addTearDown(() => temp.delete(recursive: true));
      final provider = _ReaderProvider();
      final cache = _RecordingReaderPageCache(cacheDirectory: temp);
      const first = MangaChapter(
        id: 's1',
        mangaId: 'm1',
        url: 'https://example.test/chapter/s1',
        name: 'Chapter 1',
        number: 1,
      );
      const second = MangaChapter(
        id: 's2',
        mangaId: 'm1',
        url: 'https://example.test/chapter/s2',
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
        pageCache: cache,
      );
      addTearDown(controller.dispose);

      await controller.load();
      await cache.waitUntilWritten('s2');

      // The stream resolves the next chapter's pages while the first
      // chapter stays open.
      final fetched = await controller.fetchChapterPages(second);
      expect(
        fetched.map((page) => page.imageUrl),
        pages.map((p) => p.imageUrl),
      );
      expect(controller.currentChapter.id, 's1');

      // Adopting the segment moves the reading position into it — chapter,
      // pages and index — with no further source request for that chapter.
      final requestsBefore = provider.requestedChapterIds.length;
      await controller.adoptStreamChapter(second, fetched, 2);
      expect(controller.currentChapter.id, 's2');
      expect(controller.pageIndex, 2);
      expect(
        controller.pages.map((page) => page.imageUrl),
        pages.map((p) => p.imageUrl),
      );
      expect(provider.requestedChapterIds.length, requestsBefore);
    },
  );

  group('connected chapter stream (webtoon screen)', () {
    Future<Directory> writeBmpPages(WidgetTester tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'aw_reader_stream_',
      );
      addTearDown(() => directory.delete(recursive: true));
      const width = 40;
      const height = 40;
      final data = Uint8List(54 + width * height * 4);
      final header = ByteData.sublistView(data)
        ..setUint8(0, 0x42)
        ..setUint8(1, 0x4d)
        ..setUint32(2, data.length, Endian.little)
        ..setUint32(10, 54, Endian.little)
        ..setUint32(14, 40, Endian.little)
        ..setInt32(18, width, Endian.little)
        ..setInt32(22, height, Endian.little)
        ..setUint16(26, 1, Endian.little)
        ..setUint16(28, 32, Endian.little)
        ..setUint32(34, width * height * 4, Endian.little);
      for (var offset = 54; offset < data.length; offset += 4) {
        header.setUint32(offset, 0xff326496, Endian.little);
      }
      // Real file IO must run outside the fake-async test zone, or the
      // writes never complete and the test hangs.
      await tester.runAsync(() async {
        for (var i = 0; i < 3; i++) {
          File('${directory.path}/page-${i + 1}.bmp').writeAsBytesSync(data);
        }
      });
      return directory;
    }

    const firstChapter = MangaChapter(
      id: 'stream-c1',
      mangaId: 'stream-m1',
      url: 'https://example.test/chapter/1',
      name: 'Chapter 1',
      number: 1,
    );
    const secondChapter = MangaChapter(
      id: 'stream-c2',
      mangaId: 'stream-m1',
      url: 'https://example.test/chapter/2',
      name: 'Chapter 2',
      number: 2,
    );
    const thirdChapter = MangaChapter(
      id: 'stream-c3',
      mangaId: 'stream-m1',
      url: 'https://example.test/chapter/3',
      name: 'Chapter 3',
      number: 3,
    );
    const streamChapters = <MangaChapter>[firstChapter, secondChapter];
    const streamChapters3 = <MangaChapter>[
      firstChapter,
      secondChapter,
      thirdChapter,
    ];

    Future<void> pumpStreamScreen(
      WidgetTester tester,
      _LocalStreamProvider provider,
      MangaChapter openChapter, {
      List<MangaChapter> chapters = streamChapters,
      bool continuous = false,
    }) async {
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
              continuous
                  ? _ContinuousStreamSettingsNotifier.new
                  : _WebtoonStreamSettingsNotifier.new,
            ),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: MangaReaderScreen(
              manga: MultimediaItem(
                title: 'Stream manga',
                url: 'https://example.test/manga',
                posterUrl: '',
                provider: provider.packageName,
                contentType: MultimediaContentType.manga,
              ),
              chapter: openChapter,
              chapters: chapters,
            ),
          ),
        ),
      );
    }

    Future<MangaWebtoonReader> webtoonWhen(
      WidgetTester tester,
      bool Function(MangaWebtoonReader) condition,
    ) async {
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        final found = find.byType(MangaWebtoonReader).evaluate();
        if (found.isNotEmpty) {
          final reader = tester.widget<MangaWebtoonReader>(
            find.byType(MangaWebtoonReader),
          );
          if (condition(reader)) return reader;
        }
      }
      fail('webtoon stream did not reach the expected state');
    }

    testWidgets('mock remote Webtoon paints and reopens with a warm disk cache', (
      tester,
    ) async {
      const entries = 2400;
      final root = Directory.systemTemp.createTempSync('reader_warm_cache_');
      final directory = Directory(
        '${root.path}/${MangaReaderPageCache.cacheFolderName}',
      )..createSync();
      final image = img.Image(width: 24, height: 16);
      img.fill(image, color: img.ColorRgb8(35, 81, 122));
      final bytes = img.encodeGif(image);
      await tester.runAsync(() async {
        for (var i = 1; i <= 3; i++) {
          File('${root.path}/page-$i.gif').writeAsBytesSync(bytes);
        }
        final seed = jsonEncode({
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'pages': [{'imageUrl': File('${root.path}/page-1.gif').uri.toString()}],
        });
        for (var i = 0; i < entries; i++) {
          File('${directory.path}/seed-$i.json').writeAsStringSync(seed);
        }
      });
      addTearDown(() => root.delete(recursive: true));
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _ReaderCachePathProvider(root.path);
      addTearDown(() => PathProviderPlatform.instance = previousPaths);
      final probe = _CacheUiIoProbe(directory.path);
      final provider = _LocalStreamProvider(root, extension: 'gif');
      final row = find.byKey(const ValueKey('manga-webtoon-0-0'));
      final painted = find.descendant(of: row, matching: find.byType(RawImage));

      Future<void> expectFirstPagePixels() async {
        for (var attempt = 0; attempt < 100; attempt++) {
          final images = tester.widgetList<RawImage>(painted)
              .where((widget) => widget.image != null);
          if (images.isNotEmpty) {
            final pixels = await tester.runAsync(
              () => images.first.image!.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ),
            );
            expect([for (var i = 0; i < 3; i++) pixels!.getUint8(i)], [35, 81, 122]);
            return;
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        fail('the mock remote first page did not paint');
      }

      await IOOverrides.runWithIOOverrides(() async {
        final open = Stopwatch()..start();
        await pumpStreamScreen(tester, provider, firstChapter, chapters: const [firstChapter]);
        await webtoonWhen(tester, (reader) => reader.pages.length == 3);
        final readerReady = open.elapsedMicroseconds;
        await expectFirstPagePixels();
        debugPrint(
          'reader-cache-fixture: entries=$entries '
          'ui_list_sync=${probe.synchronousListings} '
          'ui_stat_sync=${probe.synchronousStats} '
          'list_us=${probe.synchronousListTime.inMicroseconds} '
          'stat_us=${probe.synchronousStatTime.inMicroseconds} '
          'reader_ready_us=$readerReady first_rgba_us=${open.elapsedMicroseconds}',
        );
        expect(provider.requestedChapterIds, [firstChapter.id]);
        expect(probe.synchronousListings, isZero);
        expect(probe.synchronousStats, isZero);
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpStreamScreen(tester, provider, firstChapter, chapters: const [firstChapter]);
        await webtoonWhen(tester, (reader) => reader.pages.length == 3);
        await expectFirstPagePixels();
        expect(provider.requestedChapterIds, [firstChapter.id]);
        await tester.pumpWidget(const SizedBox.shrink());
      }, probe);
    });

    testWidgets('opening a chapter leaves the previous one out of the stream', (
      tester,
    ) async {
      final directory = await writeBmpPages(tester);
      final provider = _LocalStreamProvider(directory);
      await pumpStreamScreen(tester, provider, secondChapter);

      var reader = await webtoonWhen(
        tester,
        (reader) => reader.pages.isNotEmpty,
      );
      // Give a would-be prepend every chance to land, then check again:
      // the stream grows forward only, so chapter 1 stays out of it.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      reader = tester.widget<MangaWebtoonReader>(
        find.byType(MangaWebtoonReader),
      );
      expect(reader.pages.length, 3);
      expect(reader.initialPage, 0);
      expect(reader.sectionDividers, isEmpty);
    });

    testWidgets('the next chapter joins below without a chapter jump', (
      tester,
    ) async {
      final directory = await writeBmpPages(tester);
      final provider = _LocalStreamProvider(directory);
      await pumpStreamScreen(tester, provider, firstChapter);

      var reader = await webtoonWhen(
        tester,
        (reader) => reader.pages.length == 3,
      );
      final stateBefore = tester.state(find.byType(MangaWebtoonReader));
      final scrollController = reader.controller!;
      expect(reader.initialPage, 0);

      for (var i = 0; i < 40 && reader.pages.length < 6; i++) {
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -1200),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        reader = tester.widget<MangaWebtoonReader>(
          find.byType(MangaWebtoonReader),
        );
      }

      expect(reader.pages.length, 6);
      expect(reader.sectionDividers.keys, <int>[3]);
      // Appending the chapter preserves the reader and its scroll position.
      expect(tester.state(find.byType(MangaWebtoonReader)), same(stateBefore));
      expect(reader.controller, same(scrollController));
      expect(scrollController.offset, greaterThan(0));
    });

    testWidgets('the chrome follows the stream into the appended chapter', (
      tester,
    ) async {
      final directory = await writeBmpPages(tester);
      final provider = _LocalStreamProvider(directory);
      await pumpStreamScreen(tester, provider, firstChapter);

      var reader = await webtoonWhen(
        tester,
        (reader) => reader.pages.length == 3,
      );
      final webtoon = find.byType(MangaWebtoonReader);
      final state = tester.state(webtoon);
      final controller = reader.controller;
      final topBar = find.byKey(const ValueKey('manga-reader-top-bar'));
      // Scroll to the very bottom: chapter 2 joins below, then its pages
      // take over the screen.
      for (var i = 0; i < 60; i++) {
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -1200),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        reader = tester.widget<MangaWebtoonReader>(
          find.byType(MangaWebtoonReader),
        );
        if (reader.pages.length == 6 && reader.initialPage >= 3) {
          break;
        }
      }

      expect(reader.pages.length, 6);
      expect(reader.initialPage, greaterThanOrEqualTo(3));
      expect(reader.sectionDividers.keys, [3]);
      expect(find.descendant(of: topBar, matching: find.text('Chapter 2')),
          findsOneWidget);

      // Real reverse scroll crosses the same seam without navigation or
      // re-creating the Webtoon slivers/controller.
      for (var i = 0; i < 30 && reader.initialPage >= 3; i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, 800));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        reader = tester.widget<MangaWebtoonReader>(webtoon);
      }
      expect(reader.initialPage, lessThan(3));
      expect(reader.sectionDividers.keys, [3]);
      expect(tester.state(webtoon), same(state));
      expect(reader.controller, same(controller));
      expect(find.descendant(of: topBar, matching: find.text('Chapter 1')),
          findsOneWidget);
    });

    testWidgets('the chrome follows from a mid-list chapter into the next', (
      tester,
    ) async {
      final directory = await writeBmpPages(tester);
      final provider = _LocalStreamProvider(directory);
      await pumpStreamScreen(
        tester,
        provider,
        secondChapter,
        chapters: streamChapters3,
      );

      var reader = await webtoonWhen(
        tester,
        (reader) => reader.pages.isNotEmpty,
      );
      // Scroll to the very bottom: chapter 3 joins below, then its pages
      // take over the screen.
      for (var i = 0; i < 80; i++) {
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -1200),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        reader = tester.widget<MangaWebtoonReader>(
          find.byType(MangaWebtoonReader),
        );
        if (reader.pages.length == 6 &&
            find.text('Chapter 3').evaluate().isNotEmpty) {
          break;
        }
      }

      expect(reader.pages.length, 6);
      expect(find.text('Chapter 3'), findsWidgets);
    });

    testWidgets('the chrome follows the stream in vertical continuous mode', (
      tester,
    ) async {
      final directory = await writeBmpPages(tester);
      final provider = _LocalStreamProvider(directory);
      await pumpStreamScreen(
        tester,
        provider,
        secondChapter,
        chapters: streamChapters3,
        continuous: true,
      );

      Future<MangaContinuousReader?> continuousReader() async {
        final found = find.byType(MangaContinuousReader).evaluate();
        if (found.isEmpty) return null;
        return tester.widget<MangaContinuousReader>(
          find.byType(MangaContinuousReader),
        );
      }

      MangaContinuousReader? reader;
      for (var i = 0; i < 80 && reader == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        reader = await continuousReader();
      }
      expect(reader, isNotNull);

      for (var i = 0; i < 80; i++) {
        await tester.drag(
          find.byType(SuperListView),
          const Offset(0, -1200),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        reader = await continuousReader();
        if (reader != null &&
            reader.pages.length == 6 &&
            find.text('Chapter 3').evaluate().isNotEmpty) {
          break;
        }
      }

      expect(reader?.pages.length, 6);
      expect(find.text('Chapter 3'), findsWidgets);
    });
  });

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

  testWidgets('reader reserves holds, doubles and right-click actions', (
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
    expect(gesture.onTapUp, isNotNull);
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
            onSetCover: () => cover++,
            onShare: () => share++,
            onSave: () => save++,
          ),
        ),
      ),
    );

    expect(find.text('تعيين كغلاف'), findsOneWidget);
    expect(find.text('مشاركة'), findsOneWidget);
    expect(find.text('حفظ'), findsOneWidget);

    await tester.tap(find.text('تعيين كغلاف'));
    await tester.tap(find.text('مشاركة'));
    await tester.tap(find.text('حفظ'));
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
        name: '  ٠١ &amp; <b>خاص</b>  ',
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
      expect(find.text('  ٠١ &amp; <b>خاص</b>  '), findsOneWidget);

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
