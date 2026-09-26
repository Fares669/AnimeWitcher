import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/navigation/taskbar_destination.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/widgets/home_section_header.dart';
import 'package:animewitcher/features/manga/presentation/manga_home_screen.dart';
import 'package:animewitcher/features/manga/presentation/manga_view_all_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Storage extends StorageService {
  @override
  bool isHighQualityPostersEnabled() => false;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;
}

MultimediaItem _manga(String title) => MultimediaItem(
  title: title,
  url: 'https://animewitcher.com/manga/${Uri.encodeComponent(title)}',
  posterUrl: '',
  contentType: MultimediaContentType.manga,
);

final class _MangaSource extends AnimeWitcherNativeProvider {
  _MangaSource() : super(Dio(), SettingsRepository(_Storage()));

  int popularCalls = 0;

  @override
  Future<ProviderMediaPage> searchMangaPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async {
    popularCalls++;
    return ProviderMediaPage(
      items: <MultimediaItem>[
        for (var i = offset; i < offset + 20; i++) _manga('Popular $i'),
      ],
      nextOffset: offset + 20,
      hasMore: offset < 20,
    );
  }

  @override
  Future<MangaLatestChapterPage> getLatestMangaPage({
    int offset = 0,
    int limit = 30,
  }) async => MangaLatestChapterPage(
    items: <MangaLatestChapter>[
      MangaLatestChapter(
        manga: _manga('Fresh Chapter Manga'),
        chapter: const MangaChapter(
          id: 'c9',
          mangaId: 'm9',
          url: '',
          name: 'الفصل 9',
          number: 9,
        ),
      ),
    ],
    nextOffset: 1,
    hasMore: false,
  );
}

final class _Manager extends ExtensionManager {
  _Manager(this.provider);
  final AnimeWitcherProvider provider;

  @override
  List<AnimeWitcherProvider> build() => <AnimeWitcherProvider>[provider];
}

void main() {
  test('manga has no tab until the viewer turns it on', () {
    const settings = GeneralSettings();
    expect(settings.hiddenTaskbarItems, contains('manga'));
    expect(
      visibleTaskbarDestinations(
        settings.taskbarOrder,
        settings.hiddenTaskbarItems,
      ),
      isNot(contains(TaskbarDestination.manga)),
    );
    expect(
      visibleTaskbarDestinations(settings.taskbarOrder, const <String>{}),
      contains(TaskbarDestination.manga),
    );
  });

  test('the manga tab comes after every existing branch', () {
    expect(TaskbarDestination.manga.branchIndex, 5);
    expect(TaskbarDestination.manga.route, '/manga');
  });

  Future<_MangaSource> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = _MangaSource();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          extensionManagerProvider.overrideWith(() => _Manager(source)),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MangaHomeScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return source;
  }

  testWidgets('the manga page shows new chapters and two rows of most read', (
    tester,
  ) async {
    final source = await pumpPage(tester);

    expect(find.text('المانجا'), findsOneWidget);
    expect(find.text('فصول جديدة'), findsOneWidget);
    expect(find.text('Fresh Chapter Manga'), findsWidgets);
    expect(find.text('الأكثر قراءة'), findsOneWidget);
    expect(find.text('Popular 0'), findsWidgets);
    // Two rows only; the rest are behind "عرض الكل".
    expect(find.text('Popular 19'), findsNothing);
    expect(find.byType(HomeViewAllButton), findsNWidgets(2));
    expect(source.popularCalls, 1);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('عرض الكل on most read opens every manga, a page at a time', (
    tester,
  ) async {
    final source = await pumpPage(tester);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('manga-popular-header')),
        matching: find.byType(HomeViewAllButton),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MangaViewAllScreen<MultimediaItem>), findsOneWidget);
    expect(find.text('Popular 0'), findsWidgets);
    expect(source.popularCalls, greaterThan(1));
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('عرض الكل on new chapters opens them all', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(HomeViewAllButton).first);
    await tester.pumpAndSettle();

    expect(
      find.byType(MangaViewAllScreen<MangaLatestChapter>),
      findsOneWidget,
    );
    expect(find.text('Fresh Chapter Manga'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 100));
  });
}
