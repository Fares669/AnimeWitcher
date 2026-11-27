import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/network/poster_cache.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:animewitcher/features/home/presentation/view_all_screen.dart';
import 'package:animewitcher/features/home/presentation/widgets/home_hero_carousel.dart';
import 'package:animewitcher/features/home/presentation/widgets/media_horizontal_list.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:animewitcher/shared/widgets/shimmer_placeholder.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../support/memory_storage_service.dart';

const _artHost = 'https://c15-home.fixture.invalid';
const _heroArtwork = '$_artHost/hero.png';
const _bannerColor = ui.Color(0xff9b3c27);
const _rankColor = ui.Color(0xff245d81);
const _firstRankTitle = 'ترتيب airing 0';

final class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

final class _SignedOut extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot();
}

final class _History extends ContinueWatchingNotifier {
  @override
  List<HistoryItem> build() => const [];
  @override
  Future<void> refreshFromServer() async {}
}

final class _Source extends AnimeWitcherNativeProvider {
  _Source(MemoryStorageService storage)
    : super(
        Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) =>
                  handler.reject(DioException(requestOptions: options)),
            ),
          ),
        SettingsRepository(storage),
      );

  final loads = <Completer<Map<String, List<MultimediaItem>>>>[];

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() {
    final pending = Completer<Map<String, List<MultimediaItem>>>();
    loads.add(pending);
    return pending.future;
  }

  @override
  Future<MangaLatestChapterPage> getLatestMangaPage({
    int offset = 0,
    int limit = 30,
  }) async =>
      const MangaLatestChapterPage(items: [], nextOffset: 0, hasMore: false);

  @override
  Future<ProviderNewsPage> getHomeNewsPage({
    int offset = 0,
    int limit = 10,
  }) async => const ProviderNewsPage(items: [], nextOffset: 0, hasMore: false);
}

MultimediaItem _card(String title, String id) => MultimediaItem(
  title: title,
  url: 'https://animewitcher.com/watch/$id',
  posterUrl: '',
  provider: 'animewitcher',
);

final class _RankCard extends MultimediaItem {
  _RankCard(MalRanking ranking, int index, this.onPosterRead)
    : super(
        title: 'ترتيب ${ranking.name} $index',
        url: 'https://animewitcher.com/watch/c15-${ranking.name}-$index',
        posterUrl: '$_artHost/rank-${ranking.name}-$index.png',
        provider: 'animewitcher',
      );

  final VoidCallback onPosterRead;

  @override
  String get posterUrl {
    onPosterRead();
    return super.posterUrl;
  }
}

Map<String, List<MultimediaItem>> _catalogue(String label) => {
  'Trending': [
    MultimediaItem(
      title: label,
      url: 'https://animewitcher.com/watch/c15-hero',
      posterUrl: '',
      bannerUrl: _heroArtwork,
      provider: 'animewitcher',
    ),
  ],
  'أحدث الحلقات': [_card('صف المحتوى المرئي', 'home-first')],
  'فصول جديدة': [_card('صف مخفي', 'hidden')],
  'أعمال أخرى': [_card('صف لاحق', 'home-last')],
};

Future<List<int>> _pixel(ui.Image source) async {
  final image = source.clone();
  try {
    final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    return [for (var n = 0; n < 4; n++) rgba.getUint8(n)];
  } finally {
    image.dispose();
  }
}

Future<List<int>> _png(ui.Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(660, 370);
  picture.dispose();
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

Future<void> _pumpFrames(WidgetTester tester, [int count = 12]) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

ui.Image? _firstFrame(WidgetTester tester, Finder owner) => tester
    .widgetList<RawImage>(
      find.descendant(of: owner, matching: find.byType(RawImage)),
    )
    .map((widget) => widget.image)
    .whereType<ui.Image>()
    .firstOrNull;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalPaths;
  final requests = <String>[];

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('aw-home-ranking-art-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    final hero = await _png(_bannerColor);
    final rank = await _png(_rankColor);
    await http.runWithClient(
      // Create the same shared encoded cache used by both warm work and
      // actual cards with a network-denying local client.
      () async => posterCacheManager.getSingleFile('$_artHost/prime.png'),
      () => MockClient((request) async {
        if (request.url.host != 'c15-home.fixture.invalid') {
          throw StateError('Unexpected artwork origin: ${request.url.host}');
        }
        requests.add(request.url.path);
        return http.Response.bytes(
          request.url.path == '/hero.png' ? hero : rank,
          200,
          headers: const {
            HttpHeaders.cacheControlHeader: 'max-age=3600',
            HttpHeaders.contentTypeHeader: 'image/png',
          },
        );
      }),
    );
  });

  tearDownAll(() async {
    try {
      await directory.delete(recursive: true);
    } finally {
      PathProviderPlatform.instance = originalPaths;
    }
  });

  testWidgets('cached Home warms ranking posters when the rail mounts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final oldVisibility = VisibilityDetectorController.instance.updateInterval;
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    addTearDown(() {
      VisibilityDetectorController.instance.notifyNow();
      VisibilityDetectorController.instance.updateInterval = oldVisibility;
    });
    final storage = MemoryStorageService();
    final source = _Source(storage);
    storage.settings['home_snapshot_${source.packageName}'] = jsonEncode({
      'rows': {
        for (final row in _catalogue('عمل محفوظ').entries)
          row.key: row.value.map((item) => item.toJson()).toList(),
      },
    });
    final started = <MalRanking>[];
    final rankPosterReads = <MalRanking, int>{};
    final navigated = <MultimediaItem>[];
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
        GoRoute(
          path: '/details',
          builder: (context, state) {
            final item = (state.extra! as DetailsRouteExtra).item;
            navigated.add(item);
            return Scaffold(body: Text('تفاصيل ${item.title}'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        extensionManagerProvider.overrideWithValue([source]),
        activeProviderProvider.overrideWithValue(source),
        mangaHasOwnTabProvider.overrideWithValue(false),
        continueWatchingProvider.overrideWith(_History.new),
        animeWitcherAccountControllerProvider.overrideWith(_SignedOut.new),
        deviceProfileProvider.overrideWith((_) async => const DeviceProfile()),
        homeMalRankingPageProvider.overrideWith((ref, ranking) async {
          started.add(ranking);
          return ProviderMediaPage(
            items: [
              for (var i = 0; i < 10; i++)
                _RankCard(ranking, i, () {
                  rankPosterReads.update(
                    ranking,
                    (n) => n + 1,
                    ifAbsent: () => 1,
                  );
                }),
            ],
            nextOffset: 10,
            hasMore: true,
          );
        }),
      ],
    );
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
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
    final hero = find.byType(HomeHeroCarousel);
    await _pumpFrames(tester, 60);
    expect(find.text('عمل محفوظ'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is MultimediaCard && widget.title == 'صف المحتوى المرئي',
      ),
      findsOneWidget,
    );
    expect(find.text('صف مخفي'), findsNothing);
    expect(source.loads, hasLength(1));
    expect(container.read(homeDataProvider), isA<HomeSuccess>());
    expect(started, [MalRanking.airing, MalRanking.top, MalRanking.popular]);
    final heroFrame = _firstFrame(tester, hero);
    expect(heroFrame, isNotNull);
    expect(await tester.runAsync(() => _pixel(heroFrame!)), [155, 60, 39, 255]);
    Finder rail(MalRanking rank) =>
        find.byKey(ValueKey('home-mal-${rank.name}'));
    final firstRail = rail(MalRanking.airing);
    final hidden = started
        .where((rank) => rail(rank).evaluate().isEmpty)
        .toList();
    expect(
      hidden,
      contains(MalRanking.popular),
      reason: 'fixture has offscreen rankings',
    );
    final initialRankRequests = requests
        .where(
          (url) => hidden.any((rank) => url.startsWith('/rank-${rank.name}-')),
        )
        .toSet();
    // The first nearby rail may be built briefly while the sliver lays out
    // its cache. Do not warm deeper rails merely because their data is ready.
    for (final rank in [MalRanking.top, MalRanking.popular]) {
      expect(hidden, contains(rank));
      expect(rankPosterReads[rank] ?? 0, 0);
      expect(
        initialRankRequests.any((url) => url.startsWith('/rank-${rank.name}-')),
        isFalse,
      );
    }

    final navigatorFocus = tester
        .widgetList<FocusableActionDetector>(
          find.descendant(
            of: hero,
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .firstWhere(
          (detector) => detector.focusNode?.debugLabel == 'carousel_anchor',
        );
    navigatorFocus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pumpFrames(tester, 25);
    expect(find.text('تفاصيل عمل محفوظ'), findsOneWidget);
    expect(navigated.last.url, endsWith('/c15-hero'));
    router.pop();
    await _pumpFrames(tester, 25);
    expect(find.text('عمل محفوظ'), findsOneWidget);
    expect(source.loads, hasLength(1));

    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    Future<void> reveal(Finder target) async {
      for (var i = 0; i < 8; i++) {
        if (target.evaluate().isNotEmpty &&
            tester.getTopLeft(target).dy < 180) {
          break;
        }
        scroll.jumpTo(
          (scroll.offset + 150)
              .clamp(0.0, scroll.position.maxScrollExtent)
              .toDouble(),
        );
        await _pumpFrames(tester);
      }
      expect(target, findsOneWidget);
    }

    await reveal(firstRail);
    final loadedRail = tester.widget<MediaHorizontalList>(firstRail);
    expect(loadedRail.title, 'رائج الآن');
    expect(loadedRail.mediaList.first.title, _firstRankTitle);
    expect(loadedRail.initialViewAllOffset, 10);
    expect(loadedRail.initialViewAllHasMore, isTrue);
    await _pumpFrames(tester, 60);
    final firstRankRequests = requests
        .where((url) => url.startsWith('/rank-airing-'))
        .toSet();
    expect(firstRankRequests, hasLength(10));
    final rankFrame = _firstFrame(tester, firstRail);
    expect(rankFrame, isNotNull);
    expect(await tester.runAsync(() => _pixel(rankFrame!)), [36, 93, 129, 255]);
    expect(started, hasLength(3));

    final topRail = rail(MalRanking.top);
    await reveal(topRail);
    await _pumpFrames(tester, 60);
    expect(
      requests.where((url) => url.startsWith('/rank-top-')).toSet(),
      hasLength(10),
    );
    final topFrame = _firstFrame(tester, topRail);
    expect(topFrame, isNotNull);
    expect(await tester.runAsync(() => _pixel(topFrame!)), [36, 93, 129, 255]);
    expect(started, hasLength(3));

    scroll.jumpTo(0);
    source.loads.first.completeError(StateError('offline fixture'));
    await _pumpFrames(tester);
    expect(find.text('عمل محفوظ'), findsOneWidget);
    expect(find.byType(ShimmerPlaceholder), findsNothing);
    final refresh = container
        .read(homeDataProvider.notifier)
        .fetch(keepCurrent: true);
    await _pumpFrames(tester);
    expect(source.loads, hasLength(2));
    expect(find.text('عمل محفوظ'), findsOneWidget);
    source.loads.last.complete(_catalogue('عمل محدث'));
    await refresh;
    await _pumpFrames(tester);
    expect(find.text('عمل محدث'), findsOneWidget);
    expect(find.text('عمل محفوظ'), findsNothing);
    expect(started, hasLength(3));
    await tester.pumpWidget(const SizedBox());
    await _pumpFrames(tester, 12);
    // The JSON cache may have writes queued in this test's clock zone. Drain
    // that queue here rather than awaiting it from tearDownAll's other zone.
    var closed = false;
    unawaited(posterCacheManager.dispose().then((_) => closed = true));
    for (var n = 0; n < 140 && !closed; n++) {
      await _pumpFrames(tester, 1);
    }
    expect(closed, isTrue, reason: 'fixture closes its encoded cache');
  });
}
