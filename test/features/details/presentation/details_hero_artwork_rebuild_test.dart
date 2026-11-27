import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/network/poster_cache.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/details_screen.dart';
import 'package:animewitcher/features/details/presentation/widgets/details_desktop_hero.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/fallback_poster_image.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
// Match the route's Material compatibility API.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/memory_storage_service.dart';

const _route = 'local://hero-artwork-fixture';
const _open = 'افتح التفاصيل';
const _item = 'عمل عربي في الاختبار';
const _cover = 'https://fixture.invalid/c14-hero-cover.png';
const _banner = 'https://fixture.invalid/c14-hero-banner.png';
const _alternateBanner = 'https://fixture.invalid/c14-hero-banner-fresh.png';
const _viewer = 'https://fixture.invalid/c14-hero-viewer-old.png';
const _freshViewer = 'https://fixture.invalid/c14-hero-viewer-fresh.png';
const _background = Color(0xff365aa4);
const _foreground = Color(0xffb75c27);
const _revised = Color(0xff298443);
const _frame = ValueKey<String>('c14-details-artwork-frame');
const _posterKey = ValueKey<String>('details-hero-poster');
const _scrollKey = PageStorageKey<String>('desktop-details-info-tab');

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _Library extends Library {
  @override
  LibraryState build() =>
      const LibraryEmpty(LibraryCategory.favorite, LibraryMediaKind.anime);

  void refreshOtherTitles() =>
      state = LibraryEmpty(LibraryCategory.favorite, LibraryMediaKind.anime);

  @override
  bool isFavorite(String url, {String? providerId}) => false;

  @override
  LibraryCategory? itemCategory(
    String url, {
    String? providerId,
    bool manga = false,
  }) => null;
}

class _Downloads extends DownloadsNotifier {
  @override
  Future<List<DownloadItem>> build() async => const [];
}

class _Details extends DetailsController {
  _Details(this.initial);
  final MultimediaItem initial;

  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncData(initial),
    episodes: AsyncData(initial.episodes!),
    cast: const AsyncData(<Actor>[]),
    trailers: const AsyncData(<Trailer>[]),
    related: const AsyncData(<MultimediaItem>[]),
    recommendations: const AsyncData(<MultimediaItem>[]),
    seasonMap: {1: initial.episodes!},
    item: initial,
    basicDetailsResolved: true,
    nextAiringResolved: true,
  );
  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
  }) async {}
  @override
  Future<void> loadEpisodesOnDemand({bool forceReload = false}) async {}

  void publishArtwork(MultimediaItem item) =>
      state = state.copyWith(item: item, details: AsyncData(item));
}

Future<Uint8List> _png(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..drawColor(color, ui.BlendMode.src);
  // A visible second band catches unexpected crop or geometry changes.
  canvas.drawRect(
    Rect.fromLTWH(0, height * .75, width.toDouble(), height * .25),
    ui.Paint()..color = color.withValues(red: color.r / 2),
  );
  final picture = recorder.endRecording();
  final pixels = picture.toImageSync(width, height);
  picture.dispose();
  try {
    final rgba = (await pixels.toByteData(format: ui.ImageByteFormat.png))!;
    return rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes);
  } finally {
    pixels.dispose();
  }
}

Finder _art(String url) => find.byWidgetPredicate(
  (widget) => widget is FallbackPosterImage && widget.imageUrl == url,
);

Finder _raw(String url) => find.descendant(
  of: _art(url),
  matching: find.byWidgetPredicate(
    (widget) => widget is RawImage && widget.image != null,
  ),
);

Future<void> _pumpDecoded(WidgetTester tester, List<String> urls) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    if (urls.every((url) => _raw(url).evaluate().length == 1)) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('hero artwork did not decode on this route: $urls');
}

Future<String> _frameHash(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_frame),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final pixels = (await image.toByteData())!;
      return sha256
          .convert(
            pixels.buffer.asUint8List(
              pixels.offsetInBytes,
              pixels.lengthInBytes,
            ),
          )
          .toString();
    } finally {
      image.dispose();
    }
  }))!;
}

Future<int> _decodedColor(WidgetTester tester, String url) async {
  final image = tester.widget<RawImage>(_raw(url)).image!;
  return (await tester.runAsync(() async {
    final bytes = (await image.toByteData())!;
    return bytes.getUint32(0);
  }))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform previousPaths;
  late DefaultCacheManager fullCache;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('c14-details-art-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    fullCache = DefaultCacheManager();
    final cover = await _png(400, 600, _foreground);
    await posterCacheManager.putFile(
      _cover,
      cover,
      fileExtension: 'png',
      maxAge: const Duration(hours: 1),
    );
    await posterCacheManager.putFile(
      _banner,
      await _png(2000, 1120, _background),
      fileExtension: 'png',
      maxAge: const Duration(hours: 1),
    );
    await posterCacheManager.putFile(
      _alternateBanner,
      await _png(2000, 1120, _revised),
      fileExtension: 'png',
      maxAge: const Duration(hours: 1),
    );
    for (final url in [_viewer, _freshViewer, _cover]) {
      await fullCache.putFile(
        url,
        cover,
        fileExtension: 'png',
        maxAge: const Duration(hours: 1),
      );
    }
  });

  tearDownAll(() async {
    try {
      await posterCacheManager.dispose();
      await fullCache.dispose();
      await directory.delete(recursive: true);
    } finally {
      PathProviderPlatform.instance = previousPaths;
    }
  });

  for (final size in [const Size(390, 844), const Size(1280, 900)]) {
    testWidgets(
      'routed RTL Details preserves artwork leaves at ${size.width}',
      (tester) async {
        final compact = size.width == 390;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final quality = highQualityArtwork.value;
        final fallback = artworkFallbackEnabled.value;
        highQualityArtwork.value = true;
        artworkFallbackEnabled.value = false;
        imageCache
          ..clear()
          ..clearLiveImages();
        final messenger = tester.binding.defaultBinaryMessenger;
        const secure = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage',
        );
        messenger.setMockMethodCallHandler(secure, (_) async => null);
        addTearDown(() {
          highQualityArtwork.value = quality;
          artworkFallbackEnabled.value = fallback;
          imageCache
            ..clear()
            ..clearLiveImages();
          messenger.setMockMethodCallHandler(secure, null);
          debugOnRebuildDirtyWidget = null;
        });

        final source = MultimediaItem(
          url: _route,
          title: _item,
          posterUrl: _cover,
          bannerUrl: _banner,
          fullPosterUrl: _viewer,
          provider: 'Local',
          contentType: MultimediaContentType.anime,
          description: List.filled(
            18,
            'هذه حكاية المسلسل في المدينة.',
          ).join(' '),
          episodes: [
            for (var i = 1; i <= 14; i++)
              Episode(
                name: 'الحلقة $i',
                url: 'episode://hero/$i',
                season: 1,
                episode: i,
              ),
          ],
        );
        final provider = detailsControllerProvider(_route);
        final container = ProviderContainer(
          overrides: [
            provider.overrideWith(() => _Details(source)),
            storageServiceProvider.overrideWithValue(MemoryStorageService()),
            libraryProvider.overrideWith(_Library.new),
            downloadsProvider.overrideWith(_Downloads.new),
            logicalDownloadStoreV2Provider.overrideWithValue(
              InMemoryLogicalDownloadStoreV2(),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          RepaintBoundary(
            key: _frame,
            child: UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                locale: const Locale('ar'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                theme: ThemeData.dark(),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => DetailsScreen(item: source),
                        ),
                      ),
                      child: const Text(_open),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text(_open));
        await _pumpDecoded(tester, [_banner, _cover]);
        final route = find.byType(DetailsScreen);
        expect(route, findsOneWidget);
        expect(Directionality.of(tester.element(route)), TextDirection.rtl);
        expect(
          tester
              .widget<DetailsDesktopHero>(find.byType(DetailsDesktopHero))
              .compact,
          compact,
        );
        expect(await _decodedColor(tester, _banner), 0x365aa4ff);
        expect(await _decodedColor(tester, _cover), 0xb75c27ff);
        final banner = tester.widget<FallbackPosterImage>(_art(_banner));
        final cover = tester.widget<FallbackPosterImage>(_art(_cover));
        final bannerWidth = banner.memCacheWidth;
        final coverWidth = cover.memCacheWidth;
        final before = await _frameHash(tester);

        var routeBuilds = 0;
        var bannerBuilds = 0;
        var coverBuilds = 0;
        debugOnRebuildDirtyWidget = (element, _) {
          final widget = element.widget;
          if (widget is DetailsScreen) routeBuilds++;
          if (widget is FallbackPosterImage) {
            if (widget.imageUrl == _banner) bannerBuilds++;
            if (widget.imageUrl == _cover) coverBuilds++;
          }
        };
        final library = container.read(libraryProvider.notifier) as _Library;
        for (var i = 0; i < 12; i++) {
          library.refreshOtherTitles();
          await tester.pump();
        }
        debugOnRebuildDirtyWidget = null;
        expect(routeBuilds, 12);
        expect(bannerBuilds, 0); // measured branch expectation
        expect(coverBuilds, 0); // measured branch expectation
        final after = await _frameHash(tester);
        expect(after, before);

        final scroll = find.byKey(_scrollKey);
        final scrollable = find
            .descendant(of: scroll, matching: find.byType(Scrollable))
            .first;
        await tester.drag(scroll, const Offset(0, -200));
        await tester.pumpAndSettle();
        expect(
          tester.state<ScrollableState>(scrollable).position.pixels,
          greaterThan(0),
        );
        tester.state<ScrollableState>(scrollable).position.jumpTo(0);
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pumpAndSettle();
        expect(await _frameHash(tester), before);

        highQualityArtwork.value = false;
        await tester.pump();
        expect(
          tester.widget<FallbackPosterImage>(_art(_banner)).memCacheWidth,
          isNot(bannerWidth),
        );
        expect(
          tester.widget<FallbackPosterImage>(_art(_cover)).memCacheWidth,
          isNot(coverWidth),
        );
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = Size((size.width + 20) * 2, size.height * 2);
        await tester.pump();
        expect(
          tester.widget<FallbackPosterImage>(_art(_banner)).memCacheWidth,
          ((size.width + 20) * 2).clamp(160, 2048),
        );
        expect(
          tester.widget<FallbackPosterImage>(_art(_cover)).memCacheWidth,
          compact ? 240 : 340,
        );

        final controller = container.read(provider.notifier) as _Details;
        controller.publishArtwork(
          source.copyWith(
            bannerUrl: _alternateBanner,
            fullPosterUrl: _freshViewer,
          ),
        );
        await _pumpDecoded(tester, [_alternateBanner, _cover]);
        expect(_art(_banner), findsNothing);
        expect(await _decodedColor(tester, _alternateBanner), 0x298443ff);
        expect(await _decodedColor(tester, _cover), 0xb75c27ff);
        final updated = await _frameHash(tester);

        await tester.tap(find.byKey(_posterKey));
        await tester.pump(const Duration(milliseconds: 220));
        expect(find.byType(InteractiveViewer), findsOneWidget);
        final viewer = tester.widgetList<CachedNetworkImage>(
          find.descendant(
            of: find.byType(InteractiveViewer),
            matching: find.byType(CachedNetworkImage),
          ),
        );
        expect(viewer.map((image) => image.imageUrl), contains(_freshViewer));
        expect(viewer.map((image) => image.imageUrl), isNot(contains(_viewer)));
        final navigation = tester.state<NavigatorState>(find.byType(Navigator));
        navigation.pop();
        await tester.pumpAndSettle();
        expect(await _frameHash(tester), updated);
        navigation.pop();
        await tester.pumpAndSettle();
        expect(find.text(_open), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({
        size.width == 390 ? TargetPlatform.android : TargetPlatform.windows,
      }),
    );
  }
}
