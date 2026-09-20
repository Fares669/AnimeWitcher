import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_controller.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_screen.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_paged_reader.dart';
import 'package:animewitcher/features/manga/reader/widgets/manga_webtoon_reader.dart';
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
  ) async => pages;
}

final class _ReaderManager extends ExtensionManager {
  _ReaderManager(this.provider);

  final AnimeWitcherProvider provider;

  @override
  List<AnimeWitcherProvider> build() => <AnimeWitcherProvider>[provider];
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

  testWidgets('reader owns the persistent iOS header without details actions', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final staleHeader = applePersistentGlassHeaderController.value;
    if (staleHeader != null) {
      applePersistentGlassHeaderController.hide(staleHeader.owner);
    }

    final provider = _ReaderProvider();
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
