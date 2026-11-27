import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/network/poster_cache.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/services/artwork_fallback_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:animewitcher/features/search/presentation/search_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/fallback_poster_image.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/widget_completion.dart';

const _seriesName = 'اختبار Series Alpha';
const _movieName = 'فيلم Movie Beta';
const _seriesArtwork = 'https://fixture.invalid/stale-series.png';
const _movieArtwork = 'https://fixture.invalid/current-movie.png';

final _series = MultimediaItem(
  title: _seriesName,
  url: 'https://fixture.invalid/work-series',
  posterUrl: '',
  provider: 'fixture.search',
  contentType: MultimediaContentType.series,
);
final _movie = MultimediaItem(
  title: _movieName,
  url: 'https://fixture.invalid/work-movie',
  posterUrl: '',
  provider: 'fixture.search',
  contentType: MultimediaContentType.movie,
);

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _ObservedImage extends OneFrameImageStreamCompleter {
  _ObservedImage(super.image);
  int attachmentCount = 0;

  @override
  void addListener(ImageStreamListener listener) {
    attachmentCount++;
    super.addListener(listener);
  }
}

Future<_ObservedImage> _seed(String url, int width, Color colour) async {
  final provider = ResizeImage.resizeIfNeeded(
    width,
    null,
    CachedNetworkImageProvider(url, cacheManager: posterCacheManager),
  );
  final key = await provider.obtainKey(ImageConfiguration.empty);
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(colour, ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(2, 3);
  picture.dispose();
  final stream = _ObservedImage(
    SynchronousFuture<ImageInfo>(ImageInfo(image: image)),
  );
  PaintingBinding.instance.imageCache.putIfAbsent(key, () => stream);
  return stream;
}

class _DelayedArtwork implements ArtworkFallbackService {
  _DelayedArtwork([List<String> titles = const [_seriesName, _movieName]])
    : pending = {for (final title in titles) title: Completer<String?>()};

  final lookups = <String>[];
  final Map<String, Completer<String?>> pending;

  @override
  bool hasResolvedTitle(String title) => false;

  @override
  Future<String?> posterForTitle(String title) {
    lookups.add(title);
    return pending[title]?.future ?? Future<String?>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Catalog extends AnimeWitcherProvider {
  _Catalog([List<MultimediaItem>? rows]) : rows = rows ?? [_series, _movie];
  final List<MultimediaItem> rows;
  final suggestionQueries = <String>[];
  @override
  String get packageName => 'fixture.search';
  @override
  String get name => 'Fixture';
  @override
  String get mainUrl => 'https://fixture.invalid';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['ar'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.anime};
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};
  @override
  Future<MultimediaItem> getDetails(String url) async => _movie;
  @override
  Future<List<StreamResult>> loadStreams(String url) async => const [];
  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    suggestionQueries.add(query);
    return rows;
  }

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async => const ProviderMediaPage(items: [], nextOffset: 0, hasMore: false);
}

class _Manager extends ExtensionManager {
  _Manager(this.provider);
  final AnimeWitcherProvider provider;
  @override
  List<AnimeWitcherProvider> build() => [provider];
}

void _configure(
  WidgetTester tester, {
  double dpr = 2,
  Size logicalViewport = const Size(1200, 900),
}) {
  final originalFallback = artworkFallbackEnabled.value;
  final originalUnreachable = malArtworkUnreachable.value;
  artworkFallbackEnabled.value = true;
  malArtworkUnreachable.value = false;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logicalViewport * dpr;
  addTearDown(() {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    artworkFallbackEnabled.value = originalFallback;
    malArtworkUnreachable.value = originalUnreachable;
    tester.view.reset();
  });
}

Future<List<DetailsRouteExtra>> _mountAndType(
  WidgetTester tester,
  _Catalog source,
  _DelayedArtwork artwork, {
  Key? pixelBoundary,
}) async {
  final storage = MemoryStorageService();
  final container = ProviderContainer(
    overrides: [
      storageServiceProvider.overrideWithValue(storage),
      extensionManagerProvider.overrideWith(() => _Manager(source)),
      activeProviderProvider.overrideWithValue(source),
      deviceProfileProvider.overrideWith((_) async => const DeviceProfile()),
      artworkFallbackServiceProvider.overrideWithValue(artwork),
    ],
  );
  addTearDown(container.dispose);

  final opened = <DetailsRouteExtra>[];
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SearchScreen()),
      GoRoute(
        path: '/details',
        builder: (_, state) {
          opened.add(state.extra! as DetailsRouteExtra);
          return const Scaffold(body: Text('Captured selected work'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: pixelBoundary,
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    ),
  );
  await tester.enterText(find.byType(TextField), 'بحث artwork');
  await tester.pump(const Duration(milliseconds: 351));

  return opened;
}

final _top = find.byKey(const ValueKey('search-instant-top'));
final _movies = find.byKey(const ValueKey('search-instant-tab-movies'));

Finder _topText(String text) =>
    find.descendant(of: _top, matching: find.text(text));

Finder get _topPoster =>
    find.descendant(of: _top, matching: find.byType(FallbackPosterImage));

Finder get _topImage =>
    find.descendant(of: _top, matching: find.byType(CachedNetworkImage));

String _topUrl(WidgetTester tester) =>
    tester.widget<CachedNetworkImage>(_topImage).imageUrl;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform originalPaths;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('search-poster-owner-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
    await posterCacheManager.config.repo.open();
    await posterCacheManager.config.repo.close();
    await posterCacheManager.config.fileSystem.createFile('initialization');
  });

  tearDownAll(() async {
    await posterCacheManager.dispose();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  testWidgets('late artwork cannot replace the active instant Search tab', (
    tester,
  ) async {
    _configure(tester);

    // Exact resize-provider keys. No requests to a real provider, image host,
    // or decoder: we measure visible image stream attachment and wrong-picture
    // adoption, not wall time. The 40px secondary row has its own resize key.
    final stale = await _seed(_seriesArtwork, 180, const Color(0xffcc0000));
    await _seed(_movieArtwork, 180, const Color(0xff00cc00));
    await _seed(_movieArtwork, 100, const Color(0xff00cc00));
    final source = _Catalog();
    final artwork = _DelayedArtwork();
    final opened = await _mountAndType(tester, source, artwork);

    final top = find.byKey(const ValueKey('search-instant-top'));
    final movies = find.byKey(const ValueKey('search-instant-tab-movies'));
    await pumpUntil(
      tester,
      () => top.evaluate().isNotEmpty && artwork.lookups.contains(_seriesName),
      'real typed Search showing a top series with pending artwork',
    );
    expect(source.suggestionQueries, ['بحث artwork']);
    expect(
      find.descendant(of: top, matching: find.text(_seriesName)),
      findsOneWidget,
    );

    final topTileElement = tester.element(top);
    await tester.tap(movies);
    await pumpUntil(
      tester,
      () =>
          find
              .descendant(of: top, matching: find.text(_movieName))
              .evaluate()
              .isNotEmpty &&
          artwork.lookups.contains(_movieName),
      'new movie tab and its independent fallback lookup',
    );

    expect(tester.element(top), same(topTileElement));
    final topImage = find.descendant(
      of: top,
      matching: find.byType(CachedNetworkImage),
    );
    String current() => tester.widget<CachedNetworkImage>(topImage).imageUrl;
    artwork.pending[_movieName]!.complete(_movieArtwork);
    await pumpUntil(
      tester,
      () => topImage.evaluate().isNotEmpty && current() == _movieArtwork,
      'current movie artwork installed before old completion',
    );
    final before = stale.attachmentCount;
    artwork.pending[_seriesName]!.complete(_seriesArtwork);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final observedAfterLateReply = (current(), stale.attachmentCount - before);

    await tester.tap(find.byKey(const ValueKey('search-instant-open')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('Captured selected work'), findsOneWidget);
    expect(opened, isNotEmpty);
    expect(
      opened.map((route) => (route.item.url, route.item.provider)),
      everyElement((_movie.url, _movie.provider)),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // Verify navigation and release the actual route before the intentional
    // stock red, so the control tests inherit no active widgets or lookups.
    expect(
      observedAfterLateReply,
      (_movieArtwork, 0),
      reason: 'late series artwork must not attach while the movies tab is displayed',
    );
  });

  testWidgets('equal artwork inputs keep one active Search poster owner', (
    tester,
  ) async {
    _configure(tester);
    const sharedName = 'same art lookup across works';
    const sharedUrl = 'https://fixture.invalid/shared-artwork.png';
    final shared = await _seed(sharedUrl, 180, const Color(0xff7040a0));
    await _seed(sharedUrl, 100, const Color(0xff7040a0));
    final source = _Catalog([
      _series.copyWith(syncData: const {'englishTitle': sharedName}),
      _movie.copyWith(syncData: const {'englishTitle': sharedName}),
    ]);
    final artwork = _DelayedArtwork([sharedName]);
    await _mountAndType(tester, source, artwork);
    await pumpUntil(
      tester,
      () =>
          _topText(_seriesName).evaluate().isNotEmpty &&
          artwork.lookups.isNotEmpty,
      'initial series mount and pending shared poster',
    );
    artwork.pending[sharedName]!.complete(sharedUrl);
    await pumpUntil(
      tester,
      () => _topImage.evaluate().isNotEmpty && _topUrl(tester) == sharedUrl,
      'current shared image loaded before changing tabs',
    );
    await tester.pump(const Duration(milliseconds: 160));

    final owner = tester.state(_topPoster);
    final lookups = artwork.lookups.length;
    final attachments = shared.attachmentCount;
    await tester.tap(_movies);
    await pumpUntil(
      tester,
      () => _topText(_movieName).evaluate().isNotEmpty,
      'movies tab uses the same artwork inputs',
    );
    expect(tester.state(_topPoster), same(owner));
    expect(artwork.lookups.length, lookups);
    expect(shared.attachmentCount, attachments);
    expect(_topUrl(tester), sharedUrl);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('closing instant Search drops pending poster attachments', (
    tester,
  ) async {
    _configure(tester);
    final stale = await _seed(_seriesArtwork, 180, const Color(0xffcc0000));
    final artwork = _DelayedArtwork([_seriesName]);
    await _mountAndType(tester, _Catalog([_series]), artwork);
    await pumpUntil(
      tester,
      () =>
          _topText(_seriesName).evaluate().isNotEmpty &&
          artwork.lookups.contains(_seriesName),
      'series lookup pending in real Search overlay',
    );
    final owner = tester.state(_topPoster);
    final attachments = stale.attachmentCount;
    await tester.tap(find.byKey(const ValueKey('search-instant-close')));
    await pumpUntil(
      tester,
      () => _top.evaluate().isEmpty && !owner.mounted,
      'Search overlay and poster owner detached',
    );
    artwork.pending[_seriesName]!.complete(_seriesArtwork);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_top, findsNothing);
    expect(stale.attachmentCount, attachments);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final (dpr, wide) in [
    (1.0, false),
    (1.5, false),
    (2.0, false),
    (3.0, false),
    (1.0, true),
  ]) {
    testWidgets(
      'typed Search retains display-sized artwork (DPR $dpr, wide $wide)',
      (tester) async {
        _configure(tester, dpr: dpr, logicalViewport: const Size(1200, 1200));
        artworkFallbackEnabled.value = false;
        final works = [
          for (var i = 0; i < 7; i++)
            MultimediaItem(
              title: i == 0 ? 'Artwork Saga' : 'Artwork Saga: Part $i',
              url: 'https://fixture.invalid/title/$i',
              posterUrl: 'https://fixture.invalid/preview-$dpr-$wide-$i.png',
              provider: 'fixture.search',
              contentType: MultimediaContentType.series,
            ),
        ];
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          final sourceWidth = wide ? 1600 : 600;
          ui.Canvas(recorder)
            ..drawColor(const Color(0xff28619d), ui.BlendMode.src)
            ..drawRect(
              Rect.fromLTWH(sourceWidth / 2, 0, sourceWidth / 2, 900),
              Paint()..color = const Color(0xffc94b36),
            );
          final picture = recorder.endRecording();
          final image = await picture.toImage(sourceWidth, 900);
          picture.dispose();
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          image.dispose();
          for (final work in works) {
            await posterCacheManager.putFile(
              work.posterUrl,
              png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
              fileExtension: 'png',
            );
          }
        });

        const boundary = ValueKey<String>('search-preview-pixels');
        final source = _Catalog(works);
        await _mountAndType(
          tester,
          source,
          _DelayedArtwork([]),
          pixelBoundary: boundary,
        );
        final panel = find.byKey(const ValueKey('search-results-panel'));
        final pictures = find.descendant(
          of: panel,
          matching: find.byWidgetPredicate(
            (widget) => widget is RawImage && widget.image != null,
          ),
        );
        await pumpUntil(
          tester,
          () => pictures.evaluate().length == 13,
          'one Top-match poster, six related posters and six dense results',
        );
        await tester.pump(const Duration(milliseconds: 500));

        expect(source.suggestionQueries, ['بحث artwork']);
        final paintedSizes = <double, int>{};
        final dimensions = <int, int>{};
        final points = <(Offset, Offset)>[];
        var decodedBytes = 0;
        for (final element in pictures.evaluate()) {
          final logo = element.widget as RawImage;
          final box = element.renderObject! as RenderBox;
          final bounds = box.localToGlobal(Offset.zero) & box.size;
          final width = box.size.width;
          expect(box.size.height, closeTo(width * 1.45, 0.01));
          paintedSizes.update(width, (n) => n + 1, ifAbsent: () => 1);
          final decoded = logo.image!;
          dimensions.update(decoded.width, (n) => n + 1, ifAbsent: () => 1);
          final ratio = wide ? 900 / 1600 : 1.5;
          expect(decoded.height, closeTo(decoded.width * ratio, 0.51));
          decodedBytes += decoded.width * decoded.height * 4;
          points.add((
            Offset(bounds.left + width / 4, bounds.center.dy),
            Offset(bounds.right - width / 4, bounds.center.dy),
          ));
        }
        expect(paintedSizes, {72: 1, 92: 6, 40: 6});
        final expected = switch ((dpr, wide)) {
          (1.0, false) => const {90: 1, 115: 6, 50: 6},
          (1.5, false) => const {135: 1, 173: 6, 75: 6},
          _ => const {180: 1, 230: 6, 100: 6},
        };
        expect(dimensions, expected);
        final cache = PaintingBinding.instance.imageCache;
        expect(cache.currentSize, 13);
        expect(cache.currentSizeBytes, decodedBytes);

        // Read pixels from the rendered results surface, not just image headers.
        // The separated paint samples detect lost/cropped or wrong artwork.
        final render = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundary),
        );
        final colors = await tester.runAsync(() async {
          final screenshot = await render.toImage();
          try {
            final rgba = (await screenshot.toByteData())!;
            int at(Offset p) => rgba.getUint32(
              (p.dy.floor() * screenshot.width + p.dx.floor()) * 4,
            );
            return [for (final (left, right) in points) (at(left), at(right))];
          } finally {
            screenshot.dispose();
          }
        });
        expect(colors, everyElement((0x28619dff, 0xc94b36ff)));

        // The same visible result is still actionable, with the original URL.
        await tester.tap(find.byKey(const ValueKey('search-instant-open')));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(find.text('Captured selected work'), findsOneWidget);
        debugPrint(
          'Search artwork DPR=$dpr, wide=$wide: $paintedSizes painted, $dimensions '
          'decoded, ${cache.currentSize} cache keys, $decodedBytes bytes',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
}
