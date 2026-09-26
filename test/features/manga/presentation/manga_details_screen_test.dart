import 'dart:io';

import 'package:animewitcher/features/manga/presentation/widgets/manga_chapter_row.dart';
import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/services/artwork_fallback_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/features/manga/presentation/manga_details_screen.dart';
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
  _MangaProvider({this.chapterCount});

  /// Serves this many chapters instead of the single 12.5.
  final int? chapterCount;

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
    return const <MangaChapter>[
      MangaChapter(
        id: '12.5',
        mangaId: 'm1',
        url: 'chapter://12.5',
        name: 'الفصل 12.5',
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

Widget _app(AnimeWitcherProvider provider) => ProviderScope(
  overrides: [
    extensionManagerProvider.overrideWith(() => _Manager(provider)),
    artworkFallbackServiceProvider.overrideWithValue(_NoArtwork()),
    storageServiceProvider.overrideWithValue(_MangaDetailsReadingStorage()),
    mangaReaderSettingsProvider.overrideWith(
      _MangaDetailsReaderSettingsNotifier.new,
    ),
    mangaReaderCustomCoversProvider.overrideWith(
      _MangaDetailsEmptyCoverNotifier.new,
    ),
    mangaReadingRepositoryProvider.overrideWithValue(
      MangaReadingRepository(_MangaDetailsReadingStorage()),
    ),
  ],
  child: MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MangaDetailsScreen(
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
  testWidgets('manga details loads details before chapters on route open', (
    tester,
  ) async {
    final provider = _MangaProvider();

    expect(provider.detailsCalls, 0);
    expect(provider.chaptersCalls, 0);

    await tester.pumpWidget(_app(provider));
    await _pumpUntil(
      tester,
      () => provider.chaptersCalls == 1,
      reason: 'manga chapters did not finish loading',
    );

    expect(provider.detailsCalls, 1);
    expect(provider.chaptersCalls, 1);
    expect(provider.chaptersStartedBeforeDetailsFinished, isFalse);
  });

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
          widget is Text && widget.data == 'Solo Leveling' && widget.maxLines == 3,
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
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey<String>('manga-chapter-row-12.5')),
      200,
      scrollable: page,
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

      await tester.pumpWidget(_app(_MangaProvider()));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey<String>('manga-details-wide'))
            .evaluate()
            .isNotEmpty,
        reason: 'the wide page did not appear',
      );
      // The rows are built as the page scrolls to them.
      final page = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('manga-chapter-row-12.5')),
        200,
        scrollable: page,
      );

      expect(
        find.byKey(const ValueKey<String>('manga-details-wide')),
        findsOneWidget,
      );
      // One page, not the phone's two tabs.
      expect(find.byType(TabBarView), findsNothing);
      // Nothing read yet, so the white pill starts the manga.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('manga-read-pill')),
          matching: find.text('ابدأ القراءة'),
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
    'chapter sort control shares the chapters heading row',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_app(_MangaProvider()));
      await _pumpUntil(
        tester,
        () => find.text('الفصول (1)').evaluate().isNotEmpty,
        reason: 'the chapters heading did not appear',
      );

      final page = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('manga-chapter-sort-toggle')),
        200,
        scrollable: page,
      );
      final titleCenter = tester.getCenter(find.text('الفصول (1)'));
      final sortCenter = tester.getCenter(
        find.byKey(const ValueKey<String>('manga-chapter-sort-toggle')),
      );
      expect((titleCenter.dy - sortCenter.dy).abs(), lessThan(12));
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
        find.byKey(const ValueKey<String>('manga-chapter-range-menu')),
        200,
        scrollable: page,
      );
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
