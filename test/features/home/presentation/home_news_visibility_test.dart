import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/navigation/app_layout_style.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
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

Future<_HomeSource> _pumpHome(WidgetTester tester) async {
  final oldPlatform = debugDefaultTargetPlatformOverride;
  final oldVisibility = VisibilityDetectorController.instance.updateInterval;
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  tester.view.physicalSize = _wide;
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
  expect(find.byType(AppSideRail), findsOneWidget);
  expect(_insideHome(find.byType(ShimmerPlaceholder)), findsWidgets);
  return source;
}

void main() {
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
