import 'dart:async';
import 'dart:ui' as ui;

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
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:animewitcher/features/home/presentation/widgets/news_card.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/news/presentation/news_list_screen.dart';
import 'package:animewitcher/features/onboarding/first_run_setup_screen.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:animewitcher/shared/widgets/app_navigation_bars.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../support/memory_storage_service.dart';

const _area = ValueKey<String>('news-pagination-frame');
final _route = find.byType(NewsListScreen);
final _grid = find.descendant(of: _route, matching: find.byType(GridView));
final _scroll = find.descendant(of: _route, matching: find.byType(Scrollable));

final class _FakeLauncher extends UrlLauncherPlatform {
  final urls = <String>[];

  @override
  Null get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    urls.add(url);
    expect(options.mode, PreferredLaunchMode.externalApplication);
    return true;
  }
}

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

final class _HomeNews extends HomeData {
  _HomeNews(this.seed);
  final List<NewsItem> seed;

  @override
  HomeState build() =>
      HomeSuccess(const {'Trending': <MultimediaItem>[]}, news: seed);
}

final class _Call {
  _Call(this.offset, this.limit);

  final int offset;
  final int limit;
  final response = Completer<ProviderNewsPage>();

  void finish(List<NewsItem> items, {int next = 0, bool more = false}) {
    response.complete(
      ProviderNewsPage(items: items, nextOffset: next, hasMore: more),
    );
  }

  void fail() => response.completeError(StateError('offline fixture failure'));
}

final class _Source extends AnimeWitcherProvider {
  final calls = <_Call>[];

  @override
  String get packageName => 'fixture.news';

  @override
  String get name => 'News fixture';

  @override
  String get mainUrl => 'https://news.fixture.invalid';

  @override
  String get version => '1';

  @override
  List<String> get languages => const ['ar'];

  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};

  @override
  Future<ProviderNewsPage> getNewsPage({int offset = 0, int limit = 20}) {
    final call = _Call(offset, limit);
    calls.add(call);
    return call.response.future;
  }

  @override
  Future<MultimediaItem> getDetails(String url) async =>
      throw StateError('Unexpected fixture details call');

  @override
  Future<List<StreamResult>> loadStreams(String url) async => const [];

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async => const [];
}

NewsItem _article(String id, String edition) => NewsItem(
  id: id,
  title: 'خبر $id · $edition',
  imageUrl: '',
  newsUrl: 'https://news.fixture.invalid/$id/$edition',
);

List<NewsItem> _series(String prefix, int size) => [
  for (var i = 0; i < size; i++) _article('$prefix$i', 'edition'),
];

Future<void> _mount(
  WidgetTester tester,
  _Source source,
  List<NewsItem> seed,
) async {
  final oldPlatform = debugDefaultTargetPlatformOverride;
  final oldVisibility = VisibilityDetectorController.instance.updateInterval;
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    debugDefaultTargetPlatformOverride = oldPlatform;
    VisibilityDetectorController.instance.updateInterval = oldVisibility;
    tester.view.reset();
  });

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
      homeDataProvider.overrideWith(() => _HomeNews(seed)),
      mangaHasOwnTabProvider.overrideWithValue(false),
      deviceProfileProvider.overrideWith((_) async => const DeviceProfile()),
    ],
  );
  final router = container.read(appRouterProvider);
  addTearDown(() {
    router.dispose();
    container.dispose();
  });
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData.dark(),
        builder: (context, child) => RepaintBoundary(key: _area, child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(HomeScreen), findsOneWidget);
  final entry = find.descendant(
    of: find.byType(AppSideRail),
    matching: find.byIcon(Icons.newspaper_rounded),
  );
  await tester.tap(entry.hitTestable());
  await tester.pumpAndSettle();
  expect(_route, findsOneWidget);
  expect(_grid, findsOneWidget);
  expect(Directionality.of(tester.element(_grid)), TextDirection.rtl);
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(_scroll).position;

List<NewsItem> _allCards(WidgetTester tester) {
  final context = tester.element(_grid);
  final delegate =
      tester.widget<GridView>(_grid).childrenDelegate
          as SliverChildBuilderDelegate;
  return [
    for (var index = 0; index < delegate.childCount!; index++)
      if (delegate.builder(context, index) case NewsCard(:final item)) item,
  ];
}

Future<void> _append(WidgetTester tester, _Source source, int offset) async {
  final count = source.calls.length;
  final scroll = _position(tester);
  if (scroll.pixels != 0) scroll.jumpTo(0);
  scroll.jumpTo(scroll.maxScrollExtent);
  await tester.pump(const Duration(milliseconds: 50));
  expect(source.calls, hasLength(count + 1));
  expect(source.calls.last.offset, offset);
  expect(source.calls.last.limit, 20);
  // The lazy grid can defer mounting its new last row, particularly while
  // correcting the viewport after a refresh that shortened the feed.
  final context = tester.element(_grid);
  final delegate =
      tester.widget<GridView>(_grid).childrenDelegate
          as SliverChildBuilderDelegate;
  final tail = delegate.builder(context, delegate.childCount! - 1);
  expect(tail, isA<Padding>());
  expect((tail as Padding).child, isA<Center>());
  expect((tail.child! as Center).child, isA<CircularProgressIndicator>());
}

Future<void> _pull(WidgetTester tester, _Source source) async {
  final count = source.calls.length;
  final scroll = _position(tester);
  if (scroll.pixels != 0) scroll.jumpTo(0);
  await tester.pump();
  final rect = tester.getRect(_grid);
  await tester.dragFrom(
    Offset(rect.center.dx, rect.top + 200),
    const Offset(0, 420),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(source.calls, hasLength(count + 1));
  expect(source.calls.last.offset, 0);
  expect(source.calls.last.limit, 20);
  expect(find.byType(RefreshProgressIndicator), findsOneWidget);
}

Future<String> _frame(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_area),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      return sha256
          .convert(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          )
          .toString();
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets(
    'Arabic Home News append preserves latest payload in first slot',
    (tester) async {
      final launcher = _FakeLauncher();
      final oldLauncher = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() => UrlLauncherPlatform.instance = oldLauncher);

      final source = _Source();
      final start = _series('seed', 12);
      final seedLast = _article('seed1', 'seedLast');
      final seed = [start[0], start[1], seedLast, ...start.skip(2)];
      await _mount(tester, source, seed);
      expect(source.calls, isEmpty);
      expect(_allCards(tester), seed);
      final frames = [await _frame(tester)];

      // The reference expectation is maintained explicitly (not derived with
      // the production merge): old positions stay put, new IDs append once.
      final expected = [start[0], seedLast, ...start.skip(2)];
      for (var page = 0; page < 8; page++) {
        await _append(tester, source, page * 20);
        final added = _series('page${page}x', 18);
        final replacement = _article('seed0', 'replacement$page');
        final newLast = _article(added[0].id, 'newLast$page');
        source.calls.last.finish(
          [_article('seed0', 'old$page'), ...added, newLast, replacement],
          next: (page + 1) * 20,
          more: true,
        );
        await tester.pumpAndSettle();
        expected[0] = replacement;
        expected.addAll([newLast, ...added.skip(1)]);
        expect(_allCards(tester), expected);
      }
      expect(_allCards(tester), hasLength(156));

      await _append(tester, source, 160);
      source.calls.last.finish(const [], next: 180, more: true);
      await tester.pumpAndSettle();
      expect(_allCards(tester), expected);
      _position(tester).jumpTo(0);
      frames.add(await _frame(tester));
      final first = find.widgetWithText(NewsCard, expected.first.title);
      final second = find.widgetWithText(NewsCard, expected[1].title);
      expect(
        tester.getRect(first).center.dx,
        greaterThan(tester.getRect(second).center.dx),
      );
      await tester.tap(first.hitTestable());
      await tester.pumpAndSettle();
      expect(launcher.urls, [expected.first.newsUrl]);

      await _append(tester, source, 180);
      source.calls.last.fail();
      await tester.pumpAndSettle();
      expect(_allCards(tester), expected);
      await _pull(tester, source);
      source.calls.last.fail();
      await tester.pumpAndSettle();
      expect(_allCards(tester), expected);
      _position(tester).jumpTo(_position(tester).maxScrollExtent);
      await tester.pumpAndSettle();
      expect(source.calls, hasLength(11)); // Pagination stops until refresh.
      _position(tester).jumpTo(0);
      frames.add(await _frame(tester));

      final fresh = _series('fresh', 14);
      final refreshDuplicate = _article(fresh[2].id, 'freshLatest');
      await _pull(tester, source);
      source.calls.last.finish(
        [...fresh.take(3), refreshDuplicate, ...fresh.skip(3)],
        next: 320,
        more: true,
      );
      await tester.pumpAndSettle();
      expect(_allCards(tester), [
        ...fresh.take(3),
        refreshDuplicate,
        ...fresh.skip(3),
      ]);
      frames.add(await _frame(tester));

      // A refresh finishing while an append is pending replaces the old list.
      // The later append must normalize and merge that refreshed list, not
      // write into the prior owned feed.
      await _append(tester, source, 320);
      final pending = source.calls.last;
      await _pull(tester, source);
      final latest = _series('latest', 10);
      final lastDuplicate = _article(latest[2].id, 'latestLast');
      source.calls.last.finish(
        [...latest.take(3), lastDuplicate, ...latest.skip(3)],
        next: 400,
        more: true,
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 250));
      expect(_allCards(tester), [
        ...latest.take(3),
        lastDuplicate,
        ...latest.skip(3),
      ]);
      final article = _article('appended', 'fromPending');
      pending.finish([article], next: 340);
      await tester.pumpAndSettle();
      expect(_allCards(tester), [
        ...latest.take(2),
        lastDuplicate,
        ...latest.skip(3),
        article,
      ]);
      frames.add(await _frame(tester));

      expect(source.calls.map((c) => c.offset), [
        0,
        20,
        40,
        60,
        80,
        100,
        120,
        140,
        160,
        180,
        0,
        0,
        320,
        0,
      ]);
      debugPrint('C26_NEWS_RENDER ${frames.join(",")}');
      await tester.tap(find.byType(AppBackButton).hitTestable());
      await tester.pumpAndSettle();
      expect(_route, findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
