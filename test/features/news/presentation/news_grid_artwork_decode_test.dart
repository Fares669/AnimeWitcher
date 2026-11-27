import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/features/home/presentation/home_provider.dart';
import 'package:animewitcher/features/home/presentation/home_state.dart';
import 'package:animewitcher/features/home/presentation/widgets/news_card.dart';
import 'package:animewitcher/features/news/presentation/news_list_screen.dart';
import 'package:animewitcher/features/news/presentation/open_news.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _open = ValueKey('open-actual-news');
const _coverageColor = Color(0xff244e9f);
const _otherColor = Color(0xffd77538);
const _artSize = Size(1920, 1080);
const _wideArtSize = Size(1920, 240);

Finder get findByNewsRoute => find.byType(NewsListScreen);

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _FixtureHome extends HomeData {
  _FixtureHome(this.news);
  final List<NewsItem> news;
  @override
  HomeState build() => HomeSuccess(const {}, news: news);
}

class _NewsSource extends Fake implements AnimeWitcherProvider {
  final calls = <(int, int)>[];
  List<NewsItem> refresh = [];
  @override
  Future<ProviderNewsPage> getNewsPage({int offset = 0, int limit = 20}) async {
    calls.add((offset, limit));
    return ProviderNewsPage(items: refresh, nextOffset: 20, hasMore: false);
  }
}

Future<Uint8List> _png(Size size, Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(size.width.toInt(), size.height.toInt());
  picture.dispose();
  try {
    final encoded = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return encoded.buffer.asUint8List(
      encoded.offsetInBytes,
      encoded.lengthInBytes,
    );
  } finally {
    image.dispose();
  }
}

Future<void> _settleArt(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue, reason: 'News decoded image must be ready');
  await tester.pumpAndSettle();
}

Future<void> _launch(
  WidgetTester tester, {
  required List<NewsItem> initial,
  required _NewsSource provider,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeProviderProvider.overrideWithValue(provider),
        homeDataProvider.overrideWith(() => _FixtureHome(initial)),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              key: _open,
              onPressed: () => openNewsScreen(context, ref),
              child: const Text('الأخبار'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(_open));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalPaths;
  late BaseCacheManager originalCache;
  late CacheManager localCache;
  final requests = <String, int>{};
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('aw-news-grid-art-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    originalCache = CachedNetworkImageProvider.defaultCacheManager;
    final coverage = await _png(_artSize, _coverageColor);
    final wide = await _png(_wideArtSize, _otherColor);
    localCache = CacheManager(
      Config(
        'aw_news_fixture',
        repo: JsonCacheInfoRepository(databaseName: 'aw_news_fixture'),
        fileService: HttpFileService(
          httpClient: MockClient((request) async {
            final path = request.url.path;
            requests.update(path, (value) => value + 1, ifAbsent: () => 1);
            return http.Response.bytes(
              path.contains('ultrawide') ? wide : coverage,
              200,
              headers: const {
                HttpHeaders.cacheControlHeader: 'max-age=3600',
                HttpHeaders.contentTypeHeader: 'image/png',
              },
            );
          }),
        ),
      ),
    );
    CachedNetworkImageProvider.defaultCacheManager = localCache;
    for (final (width, high) in [
      (844.0, false),
      (1260.0, false),
      (844.0, true),
      (390.0, false),
    ]) {
      for (final suffix in ['coverage', 'ultrawide']) {
        final path = '/news-$width-$high-$suffix.png';
        await localCache.getSingleFile('https://fixture.invalid$path');
      }
    }
  });
  tearDownAll(() async {
    CachedNetworkImageProvider.defaultCacheManager = originalCache;
    try {
      await localCache.dispose();
      await directory.delete(recursive: true);
    } finally {
      PathProviderPlatform.instance = originalPaths;
    }
  });

  for (final view in [
    (size: const Size(844, 390), dpr: 1.0, high: false),
    (size: const Size(1260, 760), dpr: 1.5, high: false),
    (size: const Size(844, 390), dpr: 1.0, high: true),
    (size: const Size(390, 844), dpr: 1.0, high: false),
  ]) {
    testWidgets('News artwork preserves cover and RTL at $view', (
      tester,
    ) async {
      final oldQuality = highQualityArtwork.value;
      highQualityArtwork.value = view.high;
      addTearDown(() => highQualityArtwork.value = oldQuality);
      tester.view.physicalSize = view.size * view.dpr;
      tester.view.devicePixelRatio = view.dpr;
      addTearDown(tester.view.reset);
      imageCache
        ..clear()
        ..clearLiveImages();
      final basename = '/news-${view.size.width}-${view.high}';
      final initial = [
        NewsItem(
          id: 'coverage',
          title: 'الخبر الأول',
          imageUrl: 'https://fixture.invalid$basename-coverage.png',
        ),
        NewsItem(
          id: 'ultrawide',
          title: 'الخبر الثاني',
          imageUrl: 'https://fixture.invalid$basename-ultrawide.png',
        ),
      ];
      final provider = _NewsSource();
      await _launch(tester, initial: initial, provider: provider);
      final first = find.widgetWithText(NewsCard, 'الخبر الأول');
      final second = find.widgetWithText(NewsCard, 'الخبر الثاني');
      Finder rawOf(Finder card) =>
          find.descendant(of: card, matching: find.byType(RawImage));
      ui.Image? imageOf(Finder card) {
        return tester
            .widgetList<RawImage>(rawOf(card))
            .map((raw) => raw.image)
            .whereType<ui.Image>()
            .firstOrNull;
      }

      await _settleArt(
        tester,
        () => imageOf(first) != null && imageOf(second) != null,
      );

      expect(findByNewsRoute, findsOneWidget);
      expect(Directionality.of(tester.element(first)), TextDirection.rtl);
      final isGrid = view.size.width > view.size.height;
      final one = tester.getRect(first);
      final two = tester.getRect(second);
      if (isGrid) {
        expect(one.center.dy, closeTo(two.center.dy, 1));
        expect(one.center.dx, greaterThan(two.center.dx));
      } else {
        expect(two.top, greaterThan(one.bottom));
      }
      final frames = [imageOf(first)!, imageOf(second)!];
      final bounds = [
        for (final f in [first, second]) tester.getSize(rawOf(f).first),
      ];
      for (var i = 0; i < frames.length; i++) {
        final frame = frames[i];
        final raw = tester.widget<RawImage>(rawOf([first, second][i]).first);
        expect(raw.fit, BoxFit.cover);
        final bytes = await tester.runAsync(
          () => frame.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        expect(bytes!.getUint32(0), i == 0 ? 0x244e9fff : 0xd77538ff);
        expect(
          bytes.getUint32(bytes.lengthInBytes - 4),
          i == 0 ? 0x244e9fff : 0xd77538ff,
        );
      }
      final oldBudget = (view.size.width * view.dpr).ceil();
      if (view.high) {
        expect(frames.first.width, _artSize.width);
        expect(frames.last.width, _wideArtSize.width);
      } else if (!isGrid) {
        expect(frames.first.width, oldBudget);
        expect(frames.last.width, oldBudget);
      } else {
        // Cover should not round below the actual box, and ultrawide media
        // keeps the original standard upper bound when height asks for more.
        expect(frames.first.width, lessThan(oldBudget));
        expect(
          frames.first.width,
          greaterThanOrEqualTo(bounds.first.width * view.dpr),
        );
        expect(
          frames.first.height,
          greaterThanOrEqualTo(bounds.first.height * view.dpr),
        );
        expect(frames.last.width, oldBudget);
      }
      expect(provider.calls, isEmpty); // existing news seed is still respected
      expect(requests['$basename-coverage.png'], 1);
      expect(requests['$basename-ultrawide.png'], 1);
      final beforeBack = requests.values.fold<int>(
        0,
        (sum, count) => sum + count,
      );
      await tester.tap(find.byType(AppBackButton).hitTestable());
      await tester.pumpAndSettle();
      expect(findByNewsRoute, findsNothing);
      await tester.tap(find.byKey(_open));
      await tester.pump();
      await _settleArt(
        tester,
        () => imageOf(first) != null && imageOf(second) != null,
      );
      expect(
        requests.values.fold<int>(0, (sum, count) => sum + count),
        beforeBack,
      );
      expect(provider.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
