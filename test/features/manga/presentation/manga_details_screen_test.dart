import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/storage/manga_reading_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
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

final class _MangaProvider extends AnimeWitcherProvider {
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
        syncData: const <String, String>{
          'mangaId': 'm1',
          'awScore': '9.2',
        },
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

  testWidgets('manga details keeps horizontal tab swiping enabled', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_MangaProvider()));
    await _pumpUntil(
      tester,
      () => find.byType(TabBarView).evaluate().isNotEmpty,
      reason: 'manga tab view did not render',
    );

    final tabView = tester.widget<TabBarView>(find.byType(TabBarView));
    expect(tabView.physics, isNot(isA<NeverScrollableScrollPhysics>()));
  });

  testWidgets('long pressing manga title copies it like anime details', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData' && call.arguments is Map) {
          clipboardText = Map<Object?, Object?>.from(
            call.arguments as Map,
          )['text'] as String?;
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

    final title = find.descendant(
      of: find.byKey(const ValueKey('manga-details-hero')),
      matching: find.text('Solo Leveling'),
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

  testWidgets('manga details renders only details and chapters tabs', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_MangaProvider()));
    await _pumpUntil(
      tester,
      () => find.text('Manga description').evaluate().isNotEmpty,
      reason: 'manga details content did not render',
    );

    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.indicatorSize, isNull);

    expect(find.text('التفاصيل'), findsOneWidget);
    expect(find.textContaining('الفصول'), findsOneWidget);
    expect(find.text('Solo Leveling'), findsWidgets);
    expect(find.text('Manga description'), findsOneWidget);
    expect(find.text('9.2'), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-details-hero')), findsOneWidget);
    expect(find.byKey(const ValueKey('manga-rate-action')), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
    expect(find.byIcon(Icons.bookmark_border_rounded), findsOneWidget);
    expect(find.text('المراجعات'), findsNothing);

    final actionGenre = find.byKey(const ValueKey('manga-genre-Action'));
    expect(actionGenre, findsOneWidget);
    expect(
      find.ancestor(of: actionGenre, matching: find.byType(InkWell)),
      findsNothing,
    );

    await tester.tap(find.textContaining('الفصول'));
    await _pumpUntil(
      tester,
      () => find.text('الفصل 12.5').evaluate().isNotEmpty,
      reason: 'chapter tab did not render loaded chapter',
    );

    expect(find.text('الفصل 12.5'), findsOneWidget);
    expect(find.text('الحلقات'), findsNothing);
    expect(find.text('التعليقات'), findsNothing);
    expect(find.text('المراجعات'), findsNothing);
    expect(find.text('الشخصيات'), findsNothing);
    expect(find.text('متشابهة'), findsNothing);
    expect(find.text('ذات صلة'), findsNothing);
  });
}
