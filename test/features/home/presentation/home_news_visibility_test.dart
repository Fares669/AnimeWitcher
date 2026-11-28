import 'dart:async';
import 'dart:collection';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/navigation/app_layout_style.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/widgets/home_hero_carousel.dart';
import 'package:animewitcher/features/home/presentation/widgets/media_horizontal_list.dart';
import 'package:animewitcher/features/home/presentation/widgets/news_section.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/news/presentation/news_list_screen.dart';
import 'package:animewitcher/features/onboarding/first_run_setup_screen.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_navigation_bars.dart';
import 'package:animewitcher/shared/widgets/recoverable_network_state.dart';
import 'package:animewitcher/shared/widgets/shimmer_placeholder.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../support/memory_storage_service.dart';

const _wide = Size(1400, 900);
const _phone = Size(390, 844);
final _home = find.byType(HomeScreen);
final _rail = _insideHome(find.byType(MediaHorizontalList));
final _scroll = _insideHome(find.byType(CustomScrollView));

Finder _insideHome(Finder matching) =>
    find.descendant(of: _home, matching: matching);

final class _SignedOut extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot();
}

final class _EmptyHistory extends ContinueWatchingNotifier {
  @override
  List<HistoryItem> build() => const <HistoryItem>[];

  @override
  Future<void> refreshFromServer() async {}
}

final class _HomeSource extends AnimeWitcherProvider {
  @override
  String get packageName => 'fixture.home';

  @override
  String get name => 'Home fixture';

  @override
  String get mainUrl => 'https://home.fixture.invalid';

  @override
  String get version => '1';

  @override
  List<String> get languages => const ['ar'];

  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};

  final catalogs = <Completer<Map<String, List<MultimediaItem>>>>[];
  final news = <Completer<ProviderNewsPage>>[];
  int retryPreparations = 0;

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() {
    final load = Completer<Map<String, List<MultimediaItem>>>();
    catalogs.add(load);
    return load.future;
  }

  @override
  Future<ProviderNewsPage> getHomeNewsPage({int offset = 0, int limit = 10}) {
    final load = Completer<ProviderNewsPage>();
    news.add(load);
    return load.future;
  }

  @override
  void prepareForNetworkRetry() => retryPreparations++;

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const [];

  @override
  Future<MultimediaItem> getDetails(String url) async =>
      throw StateError('No details are opened in these tests');

  @override
  Future<List<StreamResult>> loadStreams(String url) async => const [];

  void loadCatalog(String label) {
    catalogs.last.complete({
      'Trending': const [],
      'New episodes': [
        MultimediaItem(
          title: label,
          url: '$mainUrl/work/$label',
          posterUrl: '',
          provider: packageName,
        ),
      ],
    });
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<_HomeSource> _pumpHome(WidgetTester tester, {Size size = _wide}) async {
  final oldPlatform = debugDefaultTargetPlatformOverride;
  final oldVisibility = VisibilityDetectorController.instance.updateInterval;
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    debugDefaultTargetPlatformOverride = oldPlatform;
    VisibilityDetectorController.instance.updateInterval = oldVisibility;
    tester.view.reset();
  });

  final source = _HomeSource();
  final storage = MemoryStorageService()
    ..settings[FirstRunSetup.storageKey] = 'done'
    ..settings[AppLayoutStyleNotifier.storageKey] =
        AppLayoutStyle.sideRail.name;
  final container = ProviderContainer(
    overrides: [
      storageServiceProvider.overrideWithValue(storage),
      extensionManagerProvider.overrideWithValue([source]),
      activeProviderProvider.overrideWithValue(source),
      animeWitcherAccountControllerProvider.overrideWith(_SignedOut.new),
      continueWatchingProvider.overrideWith(_EmptyHistory.new),
      mangaHasOwnTabProvider.overrideWithValue(false),
      deviceProfileProvider.overrideWith((_) async => const DeviceProfile()),
    ],
  );
  final router = container.read(appRouterProvider);
  addTearDown(router.dispose);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await _frames(tester);
  if (size == _wide) expect(find.byType(AppSideRail), findsOneWidget);
  expect(_insideHome(find.byType(ShimmerPlaceholder)), findsWidgets);
  return source;
}

// Counts full entry passes by the actual Home screen. Snapshot serialization
// also uses entries; take the measurement after the initial load has settled.
final class _CountedCatalogue extends MapBase<String, List<MultimediaItem>> {
  _CountedCatalogue(this._rows);

  final Map<String, List<MultimediaItem>> _rows;
  int entryVisits = 0;

  @override
  Iterable<MapEntry<String, List<MultimediaItem>>> get entries sync* {
    for (final entry in _rows.entries) {
      entryVisits++;
      yield entry;
    }
  }

  @override
  List<MultimediaItem>? operator [](Object? key) => _rows[key];

  @override
  Iterable<String> get keys => _rows.keys;

  @override
  void operator []=(String key, List<MultimediaItem> value) =>
      _rows[key] = value;

  @override
  List<MultimediaItem>? remove(Object? key) => _rows.remove(key);

  @override
  void clear() => _rows.clear();
}

List<Widget> _catalogueChildren(WidgetTester tester) {
  final scroll = tester.widget<CustomScrollView>(_scroll);
  final sliver = scroll.slivers.whereType<SliverList>().single;
  return (sliver.delegate as SliverChildListDelegate).children;
}

void main() {
  testWidgets(
    'Arabic phone lays out current rows after late news and refresh',
    (tester) async {
      final source = await _pumpHome(tester, size: _phone);
      final container = ProviderScope.containerOf(tester.element(_home));
      const hidden = 'فُصول جَديدة';
      const episodes = 'أَحدث الحلقات';
      const added = 'الأَعمال المُضافة حديثاً';
      const popular = 'الأنيميشن الأكثر مشاهدة';
      const anime = 'أنمي مختار';
      const films = 'أفلام';
      // No explicit Trending: the fallback must skip the hidden first row.
      const titles = [hidden, episodes, added, popular, anime, films];
      Map<String, List<MultimediaItem>> rows(
        List<String> keys,
        String edition,
      ) => {
        for (final key in keys)
          key: [
            MultimediaItem(
              title: '$key $edition',
              url: '${source.mainUrl}/$edition/${titles.indexOf(key)}',
              posterUrl: '',
              provider: source.packageName,
            ),
          ],
      };
      final original = _CountedCatalogue(rows(titles, 'الأصلي'));
      source.catalogs.single.complete(original);
      await _frames(tester);

      final hero = _insideHome(find.byType(HomeHeroCarousel));
      final heroFocus = find
          .descendant(of: hero, matching: find.byType(FocusableActionDetector))
          .first;
      final focus = tester
          .widget<FocusableActionDetector>(heroFocus)
          .focusNode!;
      focus.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(focus));
      final scroll = tester.widget<CustomScrollView>(_scroll).controller!;
      expect(tester.state(hero).mounted, isTrue);
      expect(Directionality.of(tester.element(hero)), TextDirection.rtl);
      expect(
        tester.widget<HomeHeroCarousel>(hero).movies,
        same(original[episodes]),
      );
      final initialChildren = _catalogueChildren(tester);
      List<String> titlesOf(List<Widget> children) => [
        for (final child in children)
          if (child is MediaHorizontalList)
            child.title
          else if (child is NewsSection)
            child.title,
      ];
      expect(titlesOf(initialChildren), [
        episodes,
        added,
        popular,
        anime,
        films,
      ]);
      expect(
        initialChildren
            .whereType<MediaHorizontalList>()
            .where((rail) => rail.forcePortrait)
            .map((rail) => rail.title),
        [added],
      );
      final beforeNews = original.entryVisits;
      const latest = NewsItem(id: 'latest', title: 'خبر جديد', imageUrl: '');
      source.news.single.complete(
        const ProviderNewsPage(items: [latest], nextOffset: 1, hasMore: false),
      );
      await _frames(tester);

      final visits = original.entryVisits - beforeNews;
      const stock = bool.fromEnvironment('HOME_CATALOGUE_STOCK');
      debugPrint('HOME_CATALOGUE late_news_entry_visits=$visits');
      expect(visits, stock ? greaterThan(0) : 0);
      final withNews = _catalogueChildren(tester);
      expect(titlesOf(withNews), [
        episodes,
        added,
        popular,
        'الأخبار',
        anime,
        films,
      ]);
      expect(withNews.whereType<NewsSection>().single.items, [latest]);
      expect(
        tester.widget<HomeHeroCarousel>(hero).movies,
        same(original[episodes]),
      );
      expect(FocusManager.instance.primaryFocus, same(focus));
      expect(tester.widget<CustomScrollView>(_scroll).controller, same(scroll));

      // A refresh with identical titles must use current row items, not the
      // cached layout's earlier cards. The same controller and scroll position
      // should stay intact.
      scroll.jumpTo(24);
      await tester.pump();
      final refresh = container
          .read(homeDataProvider.notifier)
          .fetch(keepCurrent: true);
      final replacement = rows(titles, 'بعد التحديث');
      source.catalogs.last.complete(replacement);
      await refresh;
      await _frames(tester);
      expect(_insideHome(find.byType(ShimmerPlaceholder)), findsNothing);
      expect(
        tester.widget<HomeHeroCarousel>(hero).movies,
        same(replacement[episodes]),
      );
      expect(tester.widget<CustomScrollView>(_scroll).controller, same(scroll));
      expect(scroll.offset, 24);
      for (final rail in _catalogueChildren(
        tester,
      ).whereType<MediaHorizontalList>()) {
        expect(rail.mediaList, same(replacement[rail.title]));
        expect(rail.warmProviderPosters, isTrue);
      }

      // An equal number of catalogue keys in a new order must invalidate the
      // plan. With no animation-match title, news follows recent additions.
      final reorder = container
          .read(homeDataProvider.notifier)
          .fetch(keepCurrent: true);
      const reordered = [hidden, films, added, anime, episodes, 'رسوم مميزة'];
      final different = rows(reordered, 'ترتيب جديد');
      source.catalogs.last.complete(different);
      await reorder;
      await _frames(tester);
      final reorderedChildren = _catalogueChildren(tester);
      expect(titlesOf(reorderedChildren), [
        films,
        added,
        'الأخبار',
        anime,
        episodes,
        'رسوم مميزة',
      ]);
      expect(reorderedChildren.whereType<NewsSection>().single.items, [latest]);
      expect(
        tester.widget<HomeHeroCarousel>(hero).movies,
        same(different[films]),
      );
      expect(scroll.offset, 24);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'wide Home keeps its rail and the News button sees late articles',
    (tester) async {
      final source = await _pumpHome(tester);
      source.loadCatalog('original');
      await _frames(tester);
      final rail = tester.widget<MediaHorizontalList>(_rail);
      expect(find.byType(NewsSection), findsNothing);

      const latest = NewsItem(id: 'latest', title: 'خبر جديد', imageUrl: '');
      source.news.single.complete(
        const ProviderNewsPage(items: [latest], nextOffset: 1, hasMore: false),
      );
      await _frames(tester);
      expect(tester.widget<MediaHorizontalList>(_rail), same(rail));
      expect(find.byType(NewsSection), findsNothing);

      tester.view.physicalSize = _phone;
      await _frames(tester);
      expect(tester.widget<NewsSection>(find.byType(NewsSection)).items, [
        latest,
      ]);
      tester.view.physicalSize = _wide;
      await _frames(tester);
      expect(find.byType(NewsSection), findsNothing);

      final newsButton = find.descendant(
        of: find.byType(AppSideRail),
        matching: find.byIcon(Icons.newspaper_rounded),
      );
      await tester.tap(newsButton.hitTestable());
      await _frames(tester);
      final news = tester.widget<NewsListScreen>(find.byType(NewsListScreen));
      expect(news.initialItems, [latest]);
    },
  );

  testWidgets('wide Home still shows errors, retries and refreshes its rail', (
    tester,
  ) async {
    final source = await _pumpHome(tester);
    source.catalogs.single.completeError(StateError('Offline fixture'));
    await _frames(tester);
    final error = _insideHome(find.byType(RecoverableNetworkState));
    expect(error, findsOneWidget);
    await tester.tap(
      find.descendant(of: error, matching: find.byType(FilledButton)),
    );
    await _frames(tester);
    expect(source.retryPreparations, 1);
    expect(source.catalogs, hasLength(2));
    expect(error, findsNothing);
    expect(_insideHome(find.byType(ShimmerPlaceholder)), findsWidgets);

    source.loadCatalog('recovered');
    await _frames(tester);
    final scroll = tester.widget<CustomScrollView>(_scroll).controller;
    expect(
      tester.widget<MediaHorizontalList>(_rail).mediaList.single.title,
      'recovered',
    );
    final gesture = await tester.startGesture(
      tester.getTopLeft(_scroll) + const Offset(200, 100),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 120));
    await gesture.up();
    await _frames(tester);
    expect(source.catalogs, hasLength(3));
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    expect(
      tester.widget<MediaHorizontalList>(_rail).mediaList.single.title,
      'recovered',
    );

    source.loadCatalog('refreshed');
    await _frames(tester);
    expect(
      tester.widget<MediaHorizontalList>(_rail).mediaList.single.title,
      'refreshed',
    );
    expect(tester.widget<CustomScrollView>(_scroll).controller, same(scroll));
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });
}
