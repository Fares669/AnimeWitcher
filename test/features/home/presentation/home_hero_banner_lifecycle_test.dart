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
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/widgets/home_hero_carousel.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/fallback_poster_image.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../support/memory_storage_service.dart';

const _banners = [
  'https://home-hero.fixture.invalid/a.png',
  'https://home-hero.fixture.invalid/b.png',
  'https://home-hero.fixture.invalid/c.png',
];
const _titles = ['مدينة الورد', 'رحلة الغد', 'ليلة هادئة'];
const _boundary = ValueKey('home-hero-banner-frame');

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

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => {
    'Trending': [
      for (var i = 0; i < _banners.length; i++)
        MultimediaItem(
          title: _titles[i],
          url: 'https://animewitcher.com/watch/fixture-$i',
          posterUrl: '',
          bannerUrl: _banners[i],
          provider: packageName,
        ),
    ],
  };

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

Future<Uint8List> _png(Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..drawColor(color, BlendMode.src);
  final paint = ui.Paint()..color = const Color(0xff9e8fa2);
  canvas.drawRect(const Rect.fromLTWH(250, 81, 900, 350), paint);
  paint.color = const Color(0xff4e7b6b);
  canvas.drawCircle(const Offset(1000, 810), 260, paint);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(1920, 1080);
  picture.dispose();
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

Finder _raw(String url) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is FallbackPosterImage && widget.imageUrl == url,
  ),
  matching: find.byWidgetPredicate(
    (widget) => widget is RawImage && widget.image != null,
  ),
);

Future<void> _readImages(WidgetTester tester, List<int> indices) async {
  for (var retry = 0; retry < 100; retry++) {
    if (indices.every(
      (index) => _raw(_banners[index]).evaluate().length == 1,
    )) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  fail('expected the bundled banners to decode: $indices');
}

Future<String> _frameHash(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
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
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('aw-home-hero-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    final font = FontLoader('Readex Pro')
      ..addFont(
        rootBundle.load('assets/fonts/readex_pro/ReadexPro-Regular.ttf'),
      );
    await font.load();
    const colors = [Color(0xffbd563a), Color(0xff3f529f), Color(0xffd19f46)];
    for (var i = 0; i < _banners.length; i++) {
      await posterCacheManager.putFile(
        _banners[i],
        await _png(colors[i]),
        fileExtension: 'png',
        maxAge: const Duration(hours: 1),
      );
    }
  });

  tearDownAll(() async {
    try {
      await posterCacheManager.dispose();
      await directory.delete(recursive: true);
    } finally {
      PathProviderPlatform.instance = originalPaths;
    }
  });

  testWidgets(
    'Arabic Home retains only the visible banner states through transitions',
    (tester) async {
      tester.view.physicalSize = const Size(585, 870);
      tester.view.devicePixelRatio = 1.5;
      final oldVisibility =
          VisibilityDetectorController.instance.updateInterval;
      final oldQuality = highQualityArtwork.value;
      final oldFallback = artworkFallbackEnabled.value;
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      highQualityArtwork.value = true;
      artworkFallbackEnabled.value = false;
      imageCache
        ..clear()
        ..clearLiveImages();
      addTearDown(() {
        tester.view.reset();
        VisibilityDetectorController.instance.notifyNow();
        VisibilityDetectorController.instance.updateInterval = oldVisibility;
        highQualityArtwork.value = oldQuality;
        artworkFallbackEnabled.value = oldFallback;
        imageCache
          ..clear()
          ..clearLiveImages();
      });
      final storage = MemoryStorageService();
      final source = _Source(storage);
      final navigated = <String>[];
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
          GoRoute(
            path: '/details',
            builder: (_, state) {
              final item = (state.extra! as DetailsRouteExtra).item;
              navigated.add(item.title);
              return Scaffold(body: Text('تفاصيل ${item.title}'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            storageServiceProvider.overrideWithValue(storage),
            extensionManagerProvider.overrideWithValue([source]),
            activeProviderProvider.overrideWithValue(source),
            mangaHasOwnTabProvider.overrideWithValue(false),
            continueWatchingProvider.overrideWith(_History.new),
            animeWitcherAccountControllerProvider.overrideWith(_SignedOut.new),
            deviceProfileProvider.overrideWith(
              (_) async => const DeviceProfile(),
            ),
            homeMalRankingPageProvider.overrideWith(
              (_, _) async => const ProviderMediaPage(
                items: [],
                nextOffset: 0,
                hasMore: false,
              ),
            ),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('ar'),
            theme: ThemeData(fontFamily: 'Readex Pro'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) =>
                RepaintBoundary(key: _boundary, child: child),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });

      final hero = find.byType(HomeHeroCarousel);
      final posters = find.descendant(
        of: hero,
        matching: find.byType(FallbackPosterImage),
      );
      final seen = Set<State<FallbackPosterImage>>.identity();
      final seenRenders = Set<RenderImage>.identity();
      final frames = <String, String>{};
      Future<void> sample(String phase, List<int> order, int width) async {
        expect(
          tester
              .widgetList<FallbackPosterImage>(posters)
              .map((poster) => poster.imageUrl),
          order.map((index) => _banners[index]),
        );
        seen.addAll(tester.stateList<State<FallbackPosterImage>>(posters));
        expect(seen.where((state) => state.mounted), hasLength(order.length));
        for (final index in order) {
          final decoded = _raw(_banners[index]);
          seenRenders.add(tester.renderObject<RenderImage>(decoded));
          final raw = tester.widget<RawImage>(decoded).image!;
          expect(raw.width, width);
          expect(raw.height, (width * 1080 / 1920).round());
        }
        frames[phase] = await _frameHash(tester);
      }

      Future<void> phaseMove({
        required bool forward,
        required int from,
        required int to,
        required String label,
      }) async {
        await tester.fling(hero, Offset(forward ? -220 : 220, 0), 1000);
        await tester.pump();
        await _readImages(tester, [from, to]);
        await tester.pump(const Duration(milliseconds: 176));
        await sample('$label-crossfade', [from, to], 768);
        await tester.pump(const Duration(milliseconds: 256));
        await tester.pump();
        await sample('$label-settled', [to], 768);
      }

      await tester.pump();
      await _readImages(tester, [0]);
      await tester.pump(const Duration(milliseconds: 160));
      expect(Directionality.of(tester.element(hero)), TextDirection.rtl);
      expect(find.text(_titles[0]), findsOneWidget);
      await sample('cold-start', [0], 768);
      expect(seen, hasLength(1));
      await phaseMove(forward: true, from: 0, to: 1, label: 'cold-next');
      expect(seen, hasLength(2));
      expect(find.text(_titles[1]), findsOneWidget);
      await phaseMove(forward: false, from: 1, to: 0, label: 'warm-previous');
      expect(seen, hasLength(3));
      expect(find.text(_titles[0]), findsOneWidget);
      expect(imageCache.currentSize, 2);

      await tester.tap(find.text(_titles[0]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 360));
      expect(navigated, [_titles[0]]);
      expect(find.text('تفاصيل ${_titles[0]}'), findsOneWidget);
      router.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 360));
      await sample('route-return', [0], 768);
      expect(seen, hasLength(3));
      expect(imageCache.currentSize, 2);

      highQualityArtwork.value = false;
      await tester.pump();
      // The quality switch changes the existing state’s provider width.
      for (var i = 0; i < 100; i++) {
        final images = tester.widgetList<RawImage>(_raw(_banners[0]));
        if (images.any((raw) => raw.image?.width == 585)) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 160));
      await sample('standard-quality', [0], 585);
      expect(seen, hasLength(3));
      expect(imageCache.currentSize, 3);
      expect(seenRenders, hasLength(4));
      expect(frames['cold-next-crossfade'], isNot(frames['cold-next-settled']));
      expect(frames['cold-start'], isNot(frames['cold-next-settled']));
      expect(frames['route-return'], frames['warm-previous-settled']);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
