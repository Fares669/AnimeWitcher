import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../support/test_fonts.dart';
import '../../../support/debug_shots.dart';

const _brokenChapterId = 'RxOiaLyVTBIUObsclHrw';

MultimediaItem _item(String title, {String? catalogType}) {
  return MultimediaItem(
    title: title,
    url: 'https://example.test/watch/$title',
    posterUrl: '',
    catalogType: catalogType,
  );
}

class _FakeHomeSource extends AnimeWitcherProvider {
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
            posterUrl: '',
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
}

Widget _app() {
  return ProviderScope(
    overrides: [
      activeProviderProvider.overrideWithValue(_FakeHomeSource()),
      continueWatchingProvider.overrideWith(_EmptyContinueWatching.new),
      deviceProfileProvider.overrideWith(
        (ref) async => const DeviceProfile(),
      ),
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
      File(
        '${artifacts.path}/home_without_new_chapters.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
