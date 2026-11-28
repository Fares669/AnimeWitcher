import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/latest_episodes_provider.dart';
import 'package:animewitcher/features/home/presentation/widgets/media_horizontal_list.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../support/test_fonts.dart';
import '../../../support/debug_shots.dart';
import '../../../support/memory_storage_service.dart';

const _brokenChapterId = 'RxOiaLyVTBIUObsclHrw';

MultimediaItem _item(String title, {String? catalogType}) {
  return MultimediaItem(
    title: title,
    url: 'https://example.test/watch/$title',
    posterUrl: '',
    catalogType: catalogType,
  );
}

class _FakeHomeSource extends AnimeWitcherNativeProvider {
  _FakeHomeSource() : super(Dio(), SettingsRepository(MemoryStorageService()));

  @override
  String get packageName => 'fake.home';

  @override
  String get name => 'Fake';

  @override
  String get mainUrl => 'https://example.test';

  @override
  String get version => '1';

  @override
  List<String> get languages => const <String>['ar'];

  @override
  Set<ProviderType> get supportedTypes => const {
    ProviderType.anime,
    ProviderType.manga,
  };

  @override
  Future<ProviderNewsPage> getHomeNewsPage({
    int offset = 0,
    int limit = 10,
  }) async => const ProviderNewsPage(items: [], nextOffset: 0, hasMore: false);

  @override
  Future<MangaLatestChapterPage> getLatestMangaPage({
    int offset = 0,
    int limit = 30,
  }) async {
    return MangaLatestChapterPage(
      items: <MangaLatestChapter>[
        MangaLatestChapter(
          manga: MultimediaItem(
            title: 'Latest Manga',
            url: 'https://animewitcher.com/manga/latest',
            posterUrl: 'https://example.test/latest-manga.jpg',
            contentType: MultimediaContentType.manga,
            provider: packageName,
          ),
          chapter: const MangaChapter(
            id: '44',
            mangaId: 'latest',
            url: 'https://mangalik.net/manga/latest/chapter-44/',
            name: 'الفصل 44',
            number: 44,
          ),
        ),
      ],
      nextOffset: 1,
      hasMore: false,
    );
  }

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async {
    return <String, List<MultimediaItem>>{
      'Trending': <MultimediaItem>[_item('Hero Show')],
      'الحلقات الجديدة': <MultimediaItem>[_item('Episode Show')],
      'فصول جديدة': <MultimediaItem>[
        _item(_brokenChapterId, catalogType: 'مانهوا'),
        _item('zQY3tAdwWaVZ5O31zMVd', catalogType: 'مانهوا'),
        _item('ggsM4RzcTrOWXpJudOnj', catalogType: 'مانهوا'),
      ],
      'آخر الأعمال المضافة': <MultimediaItem>[_item('Added Show')],
    };
  }

  @override
  Future<MapEntry<String, List<MultimediaItem>>> getLatestHomeEpisodes() async {
    const title = 'الحلقات الجديدة';
    return MapEntry(title, (await getHome())[title]!);
  }

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    return const <MultimediaItem>[];
  }

  @override
  Future<MultimediaItem> getDetails(String url) async {
    return MultimediaItem(title: 'Details', url: url, posterUrl: '');
  }

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    return const <StreamResult>[];
  }
}

class _EmptyContinueWatching extends ContinueWatchingNotifier {
  @override
  List<HistoryItem> build() => const <HistoryItem>[];

  @override
  Future<void> refreshFromServer() async {}
}

Widget _app({
  bool withRankings = false,
  bool emptyRankings = false,
  int rankingOffset = 10,
  ProviderMediaPage Function(MalRanking)? loadRanking,
  AnimeWitcherProvider? secondarySource,
}) {
  final source = _FakeHomeSource();
  final storage = MemoryStorageService();
  return ProviderScope(
    overrides: [
      storageServiceProvider.overrideWithValue(storage),
      extensionManagerProvider.overrideWithValue(<AnimeWitcherProvider>[
        source,
        ?secondarySource,
      ]),
      if (secondarySource == null)
        activeProviderProvider.overrideWithValue(source),
      mangaHasOwnTabProvider.overrideWithValue(false),
      continueWatchingProvider.overrideWith(_EmptyContinueWatching.new),
      homeMalRankingPageProvider.overrideWith(
        (ref, ranking) async =>
            loadRanking?.call(ranking) ??
            ProviderMediaPage(
              items: withRankings && !emptyRankings
                  ? [for (var i = 0; i < 10; i++) _item('${ranking.name} $i')]
                  : [],
              nextOffset: rankingOffset,
              hasMore: withRankings,
            ),
      ),
      deviceProfileProvider.overrideWith((ref) async => const DeviceProfile()),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'NotoSansArabic',
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFEEC60A),
          surface: Color(0xFF000000),
          onSurface: Color(0xFFE5E7EB),
        ),
      ),
      home: const RepaintBoundary(
        key: ValueKey('home-no-new-chapters'),
        child: HomeScreen(),
      ),
    ),
  );
}

Future<void> _loadHomeSuccess(WidgetTester tester) async {
  await tester.pumpWidget(_app());
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  tearDown(() {
    VisibilityDetectorController.instance.notifyNow();
  });

  testWidgets('optional latest episodes follow the active rail and source', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var home = Completer<String>();
    final requests = <String>[];
    final witanime = WitanimeProvider((uri, {cancelToken}) async {
      requests.add(uri.path.isEmpty ? '/' : uri.path);
      return uri.path == '/new-episodes'
          ? '<main><a href="/anime/other"><h3>Another show</h3></a></main>'
          : home.future;
    });
    const nativeTitle = 'الحلقات الجديدة';
    const witTitle = 'أحدث الحلقات';
    const witSecondaryTitle = 'أحدث الحلقات (Witanime)';
    const nativeSecondaryTitle = 'أحدث الحلقات (Fake)';
    const html =
        '<main><section><h2>أحدث الحلقات</h2>'
        '<a href="/watch/new/7"><h3>Wit episode</h3></a></section></main>';

    await tester.pumpWidget(_app(secondarySource: witanime));
    await tester.pumpAndSettle();
    expect(find.text(nativeTitle), findsOneWidget);
    expect(find.text(witSecondaryTitle), findsNothing);
    expect(requests, isEmpty);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeScreen)),
    );
    final settings = container.read(latestEpisodesSettingsProvider.notifier);
    final native = container.read(activeProviderProvider)!;
    await settings.setEnabled(witanime.packageName, true);
    await tester.pumpAndSettle();
    expect(requests, ['/']);
    expect(find.text(nativeTitle), findsOneWidget);
    expect(find.text(witSecondaryTitle), findsNothing);

    home.completeError(StateError('Witanime unavailable'));
    await tester.pumpAndSettle();
    expect(find.text(nativeTitle), findsOneWidget);
    expect(find.text(witSecondaryTitle), findsNothing);

    home = Completer<String>()..complete(html);
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    final titles = tester
        .widgetList<MediaHorizontalList>(find.byType(MediaHorizontalList))
        .map((rail) => rail.title);
    expect(titles.take(2), [nativeTitle, witSecondaryTitle]);
    final secondaryRail = tester.widget<MediaHorizontalList>(
      find.widgetWithText(MediaHorizontalList, witSecondaryTitle),
    );
    final item = secondaryRail.mediaList.single;
    expect(item.provider, WitanimeProvider.id);
    expect(
      item.syncData?[WitanimeProvider.watchUrlKey],
      endsWith('/watch/new/7'),
    );
    final page = await secondaryRail.loadViewAllPage!(0);
    expect(page.items.single.title, 'Another show');
    expect(requests.last, '/new-episodes');

    await container.read(activeProviderProvider.notifier).set(witanime);
    await tester.pumpAndSettle();
    expect(find.text(witTitle), findsOneWidget);
    expect(find.text(witSecondaryTitle), findsNothing);
    expect(find.text(nativeTitle), findsNothing);

    await settings.setEnabled(native.packageName, true);
    await tester.pumpAndSettle();
    final nativeSecondary = find.text(nativeSecondaryTitle);
    expect(nativeSecondary, findsOneWidget);
    expect(
      tester.getTopLeft(nativeSecondary).dy,
      greaterThan(tester.getTopLeft(find.text(witTitle)).dy),
    );
    await settings.setEnabled(native.packageName, false);
    await tester.pumpAndSettle();
    expect(nativeSecondary, findsNothing);
    expect(find.text(witTitle), findsOneWidget);
  });

  testWidgets(
    'each Home anime ranking seeds ten titles and the next source offset',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(withRankings: true));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();
      for (final (ranking, title) in [
        (MalRanking.airing, 'رائج الآن'),
        (MalRanking.top, 'الأفضل'),
        (MalRanking.popular, 'الأكثر مشاهدة'),
      ]) {
        final rail = tester.widget<MediaHorizontalList>(
          find.byKey(ValueKey('home-mal-${ranking.name}')),
        );
        expect(rail.title, title);
        expect(rail.mediaList, hasLength(10));
        expect(rail.initialViewAllOffset, 10);
        expect(rail.loadViewAllPage, isNotNull);
      }
    },
  );

  testWidgets('Home starts and refreshes only the three rendered rankings', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var version = 1;
    final calls = <MalRanking, int>{};
    await tester.pumpWidget(
      _app(
        loadRanking: (ranking) {
          calls.update(ranking, (count) => count + 1, ifAbsent: () => 1);
          return ProviderMediaPage(
            items: [_item('${ranking.name} version $version')],
            nextOffset: 10,
            hasMore: true,
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, {
      MalRanking.airing: 1,
      MalRanking.top: 1,
      MalRanking.popular: 1,
    });
    final railFinder = find.byKey(const ValueKey('home-mal-top'));
    expect(
      tester.widget<MediaHorizontalList>(railFinder).mediaList.single.title,
      'top version 1',
    );
    version = 2;
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pumpAndSettle();
    expect(calls, {
      MalRanking.airing: 2,
      MalRanking.top: 2,
      MalRanking.popular: 2,
    });
    expect(
      tester.widget<MediaHorizontalList>(railFinder).mediaList.single.title,
      'top version 2',
    );
  });

  testWidgets(
    'empty ranking discovery keeps View all and its actual next cursor',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(withRankings: true, emptyRankings: true, rankingOffset: 30),
      );
      await tester.pumpAndSettle();
      for (final ranking in [
        MalRanking.airing,
        MalRanking.top,
        MalRanking.popular,
      ]) {
        final railFinder = find.byKey(ValueKey('home-mal-${ranking.name}'));
        final rail = tester.widget<MediaHorizontalList>(railFinder);
        expect(rail.mediaList, isEmpty);
        expect(rail.initialViewAllOffset, 30);
        expect(rail.initialViewAllHasMore, isTrue);
        expect(
          find.descendant(of: railFinder, matching: find.text('عرض الكل')),
          findsOneWidget,
        );
      }
    },
  );

  testWidgets('home renders the new manga rail without legacy broken ids', (
    tester,
  ) async {
    const size = Size(390, 1800);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _loadHomeSuccess(tester);

    expect(find.text('فصول جديدة'), findsOneWidget);
    expect(find.text('Latest Manga'), findsWidgets);
    expect(find.text(_brokenChapterId), findsNothing);
    expect(find.text('zQY3tAdwWaVZ5O31zMVd'), findsNothing);
    expect(find.text('ggsM4RzcTrOWXpJudOnj'), findsNothing);

    expect(find.text('الحلقات الجديدة'), findsOneWidget);
    expect(find.text('آخر الأعمال المضافة'), findsOneWidget);
    expect(find.text('Episode Show'), findsWidgets);
    expect(find.text('Added Show'), findsWidgets);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsNothing);
    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('latest manga chapters render directly below new episodes', (
    tester,
  ) async {
    const size = Size(390, 2200);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _loadHomeSuccess(tester);
    await tester.pumpAndSettle();

    expect(find.text('الحلقات الجديدة'), findsOneWidget);
    expect(find.text('فصول جديدة'), findsOneWidget);
    expect(find.text('Latest Manga'), findsWidgets);
    expect(find.text('آخر الأعمال المضافة'), findsOneWidget);

    final episodesY = tester.getTopLeft(find.text('الحلقات الجديدة')).dy;
    final chaptersY = tester.getTopLeft(find.text('فصول جديدة')).dy;
    final addedY = tester.getTopLeft(find.text('آخر الأعمال المضافة')).dy;
    expect(episodesY, lessThan(chaptersY));
    expect(chaptersY, lessThan(addedY));
  });

  testWidgets('home with New Chapters screenshot for walkthrough', (
    tester,
  ) async {
    await tester.runAsync(TestFonts.loadWalkthroughFonts);

    const size = Size(390, 1800);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _loadHomeSuccess(tester);

    expect(find.text('فصول جديدة'), findsOneWidget);
    expect(find.text('آخر الأعمال المضافة'), findsOneWidget);

    final artifacts = debugShotDirectory();
    if (artifacts == null) {
      return;
    }

    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('home-no-new-chapters')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${artifacts.path}/home_without_new_chapters.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
