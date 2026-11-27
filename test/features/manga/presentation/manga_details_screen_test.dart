import 'dart:io';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/features/manga/presentation/widgets/manga_chapter_row.dart';
import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/services/artwork_fallback_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_screen.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_controller.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_cover_provider.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings.dart';
import 'package:animewitcher/features/manga/reader/manga_reader_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every artwork lookup at once with nothing, so a page that asks
/// for a manga's banner leaves no batch timer behind and makes no request.
final class _NoArtwork extends ArtworkFallbackService {
  _NoArtwork() : super(Dio(), StorageService());

  @override
  Future<({String? cover, String? banner})> mangaArtwork({
    int? malId,
    String title = '',
  }) async => (cover: null, banner: null);
}

final class _MangaProvider extends AnimeWitcherProvider {
  _MangaProvider({this.chapterCount, this.chapterName = 'الفصل 12.5'});

  /// Serves this many chapters instead of the single 12.5.
  final int? chapterCount;
  final String chapterName;

  List<MangaChapter>? _replacementChapters;
  int detailsCalls = 0;
  int chaptersCalls = 0;
  bool detailsFinished = false;
  bool chaptersStartedBeforeDetailsFinished = false;

  @override
  String get packageName => 'test.manga';

  @override
  String get name => 'Manga Provider';

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
  Future<MultimediaItem> getMangaDetails(String url) async {
    detailsCalls += 1;
    await Future<void>.delayed(Duration.zero);
    detailsFinished = true;
    return MultimediaItem(
      title: 'Solo Leveling',
      url: url,
      posterUrl: '',
      description: 'Manga description',
      contentType: MultimediaContentType.manga,
      provider: packageName,
      catalogType: 'مانهوا',
      year: 2018,
      tags: const <String>['Action', 'Fantasy'],
    );
  }

  @override
  Future<List<MangaChapter>> getMangaChapters(String url) async {
    chaptersCalls += 1;
    chaptersStartedBeforeDetailsFinished = !detailsFinished;
    final replacement = _replacementChapters;
    if (replacement != null) return replacement;
    final count = chapterCount;
    if (count != null) {
      return <MangaChapter>[
        for (var i = 1; i <= count; i++)
          MangaChapter(
            id: '$i',
            mangaId: 'm1',
            url: 'chapter://$i',
            name: 'الفصل $i',
            number: i.toDouble(),
          ),
      ];
    }
    return <MangaChapter>[
      MangaChapter(
        id: '12.5',
        mangaId: 'm1',
        url: 'chapter://12.5',
        name: chapterName,
        number: 12.5,
      ),
    ];
  }
}

final class _MangaDetailsReaderSettingsNotifier
    extends MangaReaderSettingsNotifier {
  @override
  MangaReaderSettings build() => const MangaReaderSettings();
}

final class _MangaDetailsEmptyCoverNotifier
    extends MangaReaderCustomCoversNotifier {
  @override
  Map<String, String> build() => const <String, String>{};
}

final class _MangaDetailsReadingStorage extends StorageService {
  final Map<String, String> values = <String, String>{};
  final Map<String, Object?> playerSettings = <String, Object?>{};

  int readingLookups = 0;

  @override
  String? getString(String key) {
    if (key.startsWith('manga_progress:')) readingLookups++;
    return values[key];
  }

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  T? getPlayerSetting<T>(String key, {T? defaultValue}) =>
      (playerSettings[key] ?? defaultValue) as T?;

  @override
  Future<void> setPlayerSetting(String key, dynamic value) async {
    playerSettings[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

final class _Manager extends ExtensionManager {
  _Manager(this.provider);
  final AnimeWitcherProvider provider;

  @override
  List<AnimeWitcherProvider> build() => <AnimeWitcherProvider>[provider];
}

final class _MembershipAccount extends AnimeWitcherAccountService {
  _MembershipAccount(StorageService storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  LibraryMembership membership = (
    category: LibraryCategory.watching,
    favorite: true,
  );
  int reads = 0;
  bool _signedIn = true;
  final _cloudRead = <String>{};

  @override
  bool get isSignedIn => _signedIn;

  @override
  bool isMangaChapterWatchedCached(String mangaId, String chapterId) =>
      _signedIn && mangaId == 'm1' && _cloudRead.contains(chapterId);

  @override
  String get accountUid => 'manga-account';

  @override
  Future<LibraryMembership?> fetchMangaLibraryMembership(
    MultimediaItem item,
  ) async {
    reads++;
    return membership;
  }

  @override
  Future<int?> loadMangaUserRating(String mangaId) async => null;
}

final class _MembershipLibrary extends Library {
  @override
  LibraryState build() =>
      const LibraryEmpty(LibraryCategory.favorite, LibraryMediaKind.manga);

  @override
  bool isFavorite(String url, {String? providerId}) => false;

  @override
  LibraryCategory? itemCategory(
    String url, {
    String? providerId,
    bool manga = false,
  }) => null;

  @override
  Future<void> setFavorite(
    MultimediaItem item,
    bool favorite, {
    LibraryMembership? membership,
  }) async {}
}

final class _MangaDetailsDownloadFeed extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const [];

  void publishProgress(double progress) {
    state = AsyncData([
      DownloadItem(
        task: DownloadTask(
          taskId: 'other-download',
          url: 'https://example.test/fixture.mp4',
          filename: 'fixture.mp4',
        ),
        item: MultimediaItem(
          title: 'Other anime',
          url: 'https://example.test/other',
          posterUrl: '',
          contentType: MultimediaContentType.anime,
        ),
        timestamp: 1,
        status: TaskStatus.running,
        progress: progress,
      ),
    ]);
  }
}

Widget _app(
  AnimeWitcherProvider provider, {
  MangaReadingRepository? progressRepository,
  _MembershipAccount? account,
  _MangaDetailsReadingStorage? readingStorage,
  _MangaDetailsDownloadFeed? downloadFeed,
  ValueChanged<MangaChapter>? onOpenChapter,
}) => ProviderScope(
  overrides: [
    extensionManagerProvider.overrideWith(() => _Manager(provider)),
    if (account != null) ...[
      animeWitcherAccountServiceProvider.overrideWithValue(account),
      libraryProvider.overrideWith(_MembershipLibrary.new),
    ],
    artworkFallbackServiceProvider.overrideWithValue(_NoArtwork()),
    storageServiceProvider.overrideWithValue(
      readingStorage ?? _MangaDetailsReadingStorage(),
    ),
    if (downloadFeed != null)
      downloadsProvider.overrideWith(() => downloadFeed),
    mangaReaderSettingsProvider.overrideWith(
      _MangaDetailsReaderSettingsNotifier.new,
    ),
    mangaReaderCustomCoversProvider.overrideWith(
      _MangaDetailsEmptyCoverNotifier.new,
    ),
    if (readingStorage == null || progressRepository != null)
      mangaReadingRepositoryProvider.overrideWithValue(
        progressRepository ??
            MangaReadingRepository(_MangaDetailsReadingStorage()),
      ),
  ],
  child: MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MangaDetailsScreen(
      onOpenChapter: onOpenChapter,
      item: MultimediaItem(
        title: 'Solo Leveling',
        url: 'https://animewitcher.com/manga/m1',
        posterUrl: '',
        contentType: MultimediaContentType.manga,
        provider: provider.packageName,
        syncData: const <String, String>{'mangaId': 'm1', 'awScore': '9.2'},
      ),
    ),
  ),
);

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String reason = 'expected widget state did not arrive',
}) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (condition()) {
      await tester.pump();
      return;
    }
  }
  fail(reason);
}

/// A phone-sized window, which draws the page's compact header.
void _usePhoneWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('Manga Details keeps reading work scoped to reading changes', (
    tester,
  ) async {
    _usePhoneWindow(tester);
    const count = 1600;
    const tickCount = 8;
    final source = _MangaProvider(chapterCount: count);
    final storage = _MangaDetailsReadingStorage();
    final account = _MembershipAccount(storage);
    final feed = _MangaDetailsDownloadFeed();
    final opened = <String>[];
    await tester.pumpWidget(
      _app(
        source,
        readingStorage: storage,
        account: account,
        downloadFeed: feed,
        onOpenChapter: (chapter) => opened.add(chapter.id),
      ),
    );
    await _pumpUntil(tester, () => source.detailsFinished);
    final toggle = find.byKey(const ValueKey('manga-chapters-toggle'));
    await Scrollable.ensureVisible(tester.element(toggle), alignment: .25);
    await tester.pump();
    expect(toggle.hitTestable(), findsOneWidget);
    await tester.tap(toggle.hitTestable());
    final readPill = find.byKey(const ValueKey('manga-read-pill'));
    await _pumpUntil(tester, () => readPill.evaluate().isNotEmpty);
    await Scrollable.ensureVisible(tester.element(readPill), alignment: .25);
    await tester.pump(const Duration(milliseconds: 260));
    expect(readPill.hitTestable(), findsOneWidget);
    expect(find.text('ابدأ القراءة'), findsOneWidget);
    expect(source.chaptersCalls, 1);
    final routeScope = ProviderScope.containerOf(tester.element(readPill));
    final firstOffset = Scrollable.of(tester.element(readPill)).position.pixels;
    storage.readingLookups = 0;
    for (var tick = 0; tick < tickCount; tick++) {
      feed.publishProgress((tick + 1) / 10);
      await tester.pump(const Duration(milliseconds: 90));
    }
    expect(
      Scrollable.of(tester.element(readPill)).position.pixels,
      firstOffset,
    );
    expect(find.text('ابدأ القراءة'), findsOneWidget);
    expect(source.chaptersCalls, 1);
    // Visible chapter rows still rebuild to display download actions, but
    // unrelated transport ticks must not re-read every chapter's progress.
    expect(storage.readingLookups, lessThan(240));

    account._cloudRead.add('9');
    routeScope.read(accountDataRevisionProvider.notifier).bump();
    await tester.pump();
    expect(find.text('اقرأ · الفصل 1'), findsOneWidget);

    account._signedIn = false;
    routeScope.read(accountDataRevisionProvider.notifier).bump();
    await tester.pump();
    expect(find.text('ابدأ القراءة'), findsOneWidget);

    await routeScope
        .read(mangaReadingRepositoryProvider)
        .save(
          const MangaReadingProgress(
            mangaId: 'm1',
            chapterId: '1',
            pageIndex: 3,
            pageCount: 20,
            updatedAt: 1,
          ),
        );
    await tester.pump();
    expect(find.text('تابع · الفصل 1'), findsOneWidget);
    await tester.tap(readPill.hitTestable());
    await tester.pump();
    expect(opened, ['1']);

    source._replacementChapters = const [
      MangaChapter(
        id: 'new',
        mangaId: 'm1',
        url: 'chapter://new',
        name: 'فصل أحدث',
        number: 0.5,
      ),
      MangaChapter(
        id: '1',
        mangaId: 'm1',
        url: 'chapter://1',
        name: 'الفصل 1',
        number: 1,
      ),
    ];
    await routeScope
        .read(
          mangaDetailsControllerProvider('https://animewitcher.com/manga/m1')
              .notifier,
        )
        .loadChaptersOnDemand(forceReload: true);
    await tester.pump();
    expect(source.chaptersCalls, 2);
    expect(find.text('ابدأ القراءة'), findsOneWidget);
    await Scrollable.ensureVisible(tester.element(readPill), alignment: .25);
    await tester.pump();
    await tester.tap(readPill.hitTestable());
    await tester.pump();
    expect(opened, ['1', 'new']);
  });

  testWidgets('manga details refreshes server membership after reopening', (
    tester,
  ) async {
    _usePhoneWindow(tester);
    final provider = _MangaProvider();
    final account = _MembershipAccount(_MangaDetailsReadingStorage());
    await tester.pumpWidget(_app(provider, account: account));
    await _pumpUntil(
      tester,
      () => find.text('أقرأها حاليًا').evaluate().isNotEmpty,
      reason: 'the list should come from the server even with an empty local library',
    );
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.favorite_rounded));
    await tester.pump();
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.text('أقرأها حاليًا'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    account.membership = (category: LibraryCategory.completed, favorite: true);
    await tester.pumpWidget(_app(provider, account: account));
    await _pumpUntil(
      tester,
      () => find.text('تمت قراءتها').evaluate().isNotEmpty,
      reason: 'reopening should show the list currently on the server',
    );
    expect(account.reads, 2);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
  });

  testWidgets(
    'manga details defers chapters until the collapsed section opens once',
    (tester) async {
      final provider = _MangaProvider();

      expect(provider.detailsCalls, 0);
      expect(provider.chaptersCalls, 0);

      await tester.pumpWidget(_app(provider));
      await _pumpUntil(
        tester,
        () => provider.detailsFinished,
        reason: 'manga details did not finish loading',
      );

      expect(provider.detailsCalls, 1);
      expect(provider.chaptersCalls, 0);
      expect(
        find.byKey(const ValueKey<String>('manga-chapters-toggle')),
        findsOneWidget,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('manga-chapters-toggle')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-chapters-toggle')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        find.byKey(const ValueKey<String>('manga-chapters-reveal')),
        findsOneWidget,
      );
      final reveal = tester.widget<FadeTransition>(
        find.byKey(const ValueKey<String>('manga-chapters-reveal')),
      );
      expect(reveal.opacity.value, greaterThan(0));
      expect(reveal.opacity.value, lessThan(1));

      await _pumpUntil(
        tester,
        () => provider.chaptersCalls == 1,
        reason: 'opening chapters did not start the chapter request',
      );

      expect(provider.chaptersStartedBeforeDetailsFinished, isFalse);

      await tester.tap(
        find.byKey(const ValueKey<String>('manga-chapters-toggle')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-chapters-toggle')),
      );
      await tester.pump();

      expect(provider.chaptersCalls, 1);
    },
  );

  test('completed chapter opens the same local directory as Downloads', () {
    final source = File(
      'lib/features/manga/presentation/manga_details_screen.dart',
    ).readAsStringSync();

    expect(source, contains('completedMangaChapterDownload'));
    expect(
      source,
      contains('localChapterDirectory: completedDownload?.destinationPath'),
    );
  });

  testWidgets('long pressing manga title copies it like anime details', (
    tester,
  ) async {
    _usePhoneWindow(tester);
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData' && call.arguments is Map) {
          clipboardText =
              Map<Object?, Object?>.from(call.arguments as Map)['text']
                  as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(_app(_MangaProvider()));
    await _pumpUntil(
      tester,
      () => find.text('Solo Leveling').evaluate().isNotEmpty,
      reason: 'manga title did not render',
    );

    // The name in the header, not the small one on the poster's stand-in.
    final title = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data == 'Solo Leveling' &&
          widget.maxLines == 3,
    );
    expect(title, findsOneWidget);

    await tester.longPress(title);
    await tester.pump();

    expect(clipboardText, 'Solo Leveling');

    // NotificationService keeps the success toast alive for one second.
    // Let that timer expire so this widget test does not leak a pending timer.
    await tester.pump(const Duration(seconds: 1));
  });

  test('manga details uses the reader custom cover override', () {
    final base = MultimediaItem(
      title: 'Solo Leveling',
      url: 'https://animewitcher.com/manga/m1',
      posterUrl: 'https://example.test/default.webp',
      fullPosterUrl: 'https://example.test/default-full.webp',
      contentType: MultimediaContentType.manga,
      provider: 'test.manga',
    );
    const custom = 'file:///tmp/custom-cover.webp';

    final item = mangaDetailsItemWithCustomCover(base, custom);

    expect(item.posterUrl, custom);
    expect(item.fullPosterUrl, custom);
  });

  testWidgets('a phone gets the anime page layout, compact, on one page', (
    tester,
  ) async {
    _usePhoneWindow(tester);
    await tester.pumpWidget(_app(_MangaProvider()));
    await _pumpUntil(
      tester,
      () => find.text('Manga description').evaluate().isNotEmpty,
      reason: 'manga details content did not render',
    );

    expect(
      find.byKey(const ValueKey<String>('manga-details-wide')),
      findsOneWidget,
    );
    // One page, not the old two tabs.
    expect(find.byType(TabBarView), findsNothing);
    expect(find.text('Solo Leveling'), findsWidgets);
    expect(find.byIcon(Icons.favorite_border_rounded), findsWidgets);

    final page = find.byType(Scrollable).first;
    expect(
      find.byKey(const ValueKey<String>('manga-chapter-row-12.5')),
      findsNothing,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('manga-chapters-toggle')),
      200,
      scrollable: page,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('manga-chapters-toggle')),
    );
    await _pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey<String>('manga-chapter-row-12.5'))
          .evaluate()
          .isNotEmpty,
      reason: 'opening chapters did not render the chapter row',
    );
    expect(find.text('الفصل 12.5'), findsOneWidget);
    // Nothing of the anime page's own sections.
    expect(find.text('الحلقات'), findsNothing);
    expect(find.text('متشابهة'), findsNothing);
    expect(find.text('ذات صلة'), findsNothing);
  });

  testWidgets(
    'a wide window gets the anime page layout, chapters on the page',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const chapterName = '  ٠١٢.٥ &amp; <b>خاص</b>  ';
      final progressRepository = MangaReadingRepository(
        _MangaDetailsReadingStorage(),
      );
      await progressRepository.save(
        const MangaReadingProgress(
          mangaId: 'm1',
          chapterId: '12.5',
          pageIndex: 2,
          pageCount: 20,
          updatedAt: 1,
        ),
      );
      await tester.pumpWidget(
        _app(
          _MangaProvider(chapterName: chapterName),
          progressRepository: progressRepository,
        ),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('manga-details-wide'))
            .evaluate()
            .isNotEmpty,
        reason: 'the wide page did not appear',
      );
      final page = find.byType(Scrollable).first;

      expect(
        find.byKey(const ValueKey<String>('manga-details-wide')),
        findsOneWidget,
      );
      // One page, not the phone's two tabs.
      expect(find.byType(TabBarView), findsNothing);
      // Chapter-only controls stay out of the hero and remain hidden until
      // the collapsed section is opened.
      expect(
        find.byKey(const ValueKey<String>('manga-read-pill')),
        findsNothing,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('manga-chapters-toggle')),
        200,
        scrollable: page,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-chapters-toggle')),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('manga-read-pill'))
            .evaluate()
            .isNotEmpty,
        reason: 'opening chapters did not reveal the read button',
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('manga-read-pill')),
          matching: find.text('تابع · $chapterName'),
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('manga-genre-Action')),
        200,
        scrollable: page,
      );
      expect(
        find.byKey(const ValueKey<String>('manga-genre-Action')),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'chapter sort control sits on the filter row at the physical left',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_app(_MangaProvider()));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('manga-chapters-toggle'))
            .evaluate()
            .isNotEmpty,
        reason: 'the collapsed chapters heading did not appear',
      );

      expect(
        find.byKey(const ValueKey<String>('manga-chapter-sort-toggle')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('manga-chapters-toggle')),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('manga-chapter-sort-toggle'))
            .evaluate()
            .isNotEmpty,
        reason: 'opening chapters did not reveal the sort control',
      );

      final filter = find.byKey(
        const ValueKey<String>('manga-chapter-filter-all'),
      );
      final sort = find.byKey(
        const ValueKey<String>('manga-chapter-sort-toggle'),
      );
      final filterCenter = tester.getCenter(filter);
      final sortCenter = tester.getCenter(sort);

      expect((filterCenter.dy - sortCenter.dy).abs(), lessThan(12));
      expect(sortCenter.dx, lessThan(filterCenter.dx));
    },
  );

  testWidgets(
    'chapter selection controls stay pinned while the manga page scrolls',
    (tester) async {
      _usePhoneWindow(tester);
      await tester.pumpWidget(_app(_MangaProvider(chapterCount: 200)));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('manga-details-wide'))
            .evaluate()
            .isNotEmpty,
        reason: 'the manga page did not appear',
      );

      final page = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('manga-chapters-toggle')),
        200,
        scrollable: page,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-chapters-toggle')),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('manga-chapter-range-menu'))
            .evaluate()
            .isNotEmpty,
        reason: 'opening chapters did not reveal chapter tools',
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('manga-chapter-range-menu')),
        200,
        scrollable: page,
      );
      for (
        var i = 0;
        i < 6 && find.byType(MangaChapterRow).evaluate().isEmpty;
        i++
      ) {
        await tester.drag(page, const Offset(0, -140));
        await tester.pumpAndSettle();
      }
      final visibleRow = find.byType(MangaChapterRow).first;
      expect(visibleRow, findsOneWidget);
      await tester.longPress(visibleRow);
      await tester.pumpAndSettle();
      expect(find.text('تم تحديد 1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('manga-selection-bottom-bar')),
        findsOneWidget,
      );
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.bottomNavigationBar, isNotNull);

      await tester.drag(page, const Offset(0, -400));
      await tester.pumpAndSettle();

      final selectionLabel = find.text('تم تحديد 1');
      expect(selectionLabel, findsOneWidget);
      expect(
        tester.getCenter(selectionLabel).dy,
        greaterThan(tester.view.physicalSize.height * 0.75),
      );
    },
  );

  testWidgets(
    'a long manga on a wide window builds only the chapters in view',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_app(_MangaProvider(chapterCount: 1500)));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('manga-details-wide'))
            .evaluate()
            .isNotEmpty,
        reason: 'the wide page did not appear',
      );
      final page = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('manga-chapters-toggle')),
        200,
        scrollable: page,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga-chapters-toggle')),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('manga-chapter-range-menu'))
            .evaluate()
            .isNotEmpty,
        reason: 'opening chapters did not reveal the range menu',
      );
      // Down to the chapters, and a screen into them.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('manga-chapter-range-menu')),
        200,
        scrollable: page,
      );
      await tester.drag(page, const Offset(0, -600));
      await tester.pumpAndSettle();

      final built = find.byType(MangaChapterRow).evaluate().length;
      expect(built, greaterThan(0));
      // A screenful, not all fifteen hundred.
      expect(built, lessThan(60));

      // "Go to" still reaches a chapter far from any built row.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('manga-chapter-go-to')),
        -200,
        scrollable: page,
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('manga-chapter-go-to')),
        '1200',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('manga-chapter-row-1200')),
        findsOneWidget,
      );
      expect(
        tester
            .getRect(
              find.byKey(const ValueKey<String>('manga-chapter-row-1200')),
            )
            .overlaps(Offset.zero & tester.view.physicalSize),
        isTrue,
      );
    },
  );
}
