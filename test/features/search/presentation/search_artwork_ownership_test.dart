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

void _configure(WidgetTester tester) {
  final originalFallback = artworkFallbackEnabled.value;
  final originalUnreachable = malArtworkUnreachable.value;
  artworkFallbackEnabled.value = true;
  malArtworkUnreachable.value = false;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 900);
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
  _DelayedArtwork artwork,
) async {
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
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
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
}
