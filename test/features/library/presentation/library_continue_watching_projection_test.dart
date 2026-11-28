import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_models.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/manga.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_quality.dart';
import 'package:animewitcher/features/home/presentation/home_screen.dart';
import 'package:animewitcher/features/home/presentation/widgets/continue_watching_section.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:animewitcher/features/settings/presentation/general_settings_provider.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
// This exercises the existing Material build of the real Home route.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:visibility_detector/visibility_detector.dart';

const _rowCount = 256;
const _updates = 12;
const _art = 'https://resume-fixture.invalid/cached.png';
const _expectedProjectionReuse = true;
const _witness = bool.fromEnvironment('AW_C26_RESUME_WITNESS');
const _boundaryKey = ValueKey('resume-offline-arabic-frame');

String _url(int index) =>
    'https://animewitcher.com/watch/resume-fixture-$index';
String _episodeUrl(int index) => 'resume-fixture-$index|episode-3';

MultimediaItem _item(int index) => MultimediaItem(
  title: 'عنوان للمتابعة $index',
  url: _url(index),
  posterUrl: _art,
  contentType: MultimediaContentType.anime,
);

final class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

final class _SignedOut extends AnimeWitcherAccountController {
  @override
  Future<AnimeWitcherAccountSnapshot> build() async =>
      const AnimeWitcherAccountSnapshot();
}

final class _Secure extends SecureTokenStorage {
  _Secure(super.storage);

  @override
  Future<String?> read(String key) async => null;
}

final class _Source extends AnimeWitcherNativeProvider {
  _Source(StorageService storage, List<String> unexpected)
    : super(
        Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                unexpected.add(options.path);
                handler.reject(DioException(requestOptions: options));
              },
            ),
          ),
        SettingsRepository(storage),
      );

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() async => const {};

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

class _MutableStorage extends StorageService {
  final rows = [
    <String, dynamic>{'url': _url(1), 'title': 'test', 'position': 9},
  ];
  @override
  List<Map<String, dynamic>> getContinueWatching() => rows;
}

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const Color(0xff4972b3), BlendMode.src);
  canvas.drawCircle(
    const Offset(520, 205),
    170,
    ui.Paint()..color = const Color(0xffdfa9b7),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(800, 420);
  picture.dispose();
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

Future<String> _hash(WidgetTester tester) async {
  final render = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  return (await tester.runAsync(() async {
    final image = await render.toImage();
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

Future<void> _paint(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 70));
  }
}

Finder _card(int index) => find.byKey(ValueKey(_url(index)));

Future<int> _readyWidth(WidgetTester tester, int index) async {
  final images = find.descendant(
    of: _card(index),
    matching: find.byWidgetPredicate(
      (widget) => widget is RawImage && widget.image != null,
    ),
  );
  for (var i = 0; i < 80; i++) {
    if (images.evaluate().length == 1) {
      return tester.widget<RawImage>(images).image!.width;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  fail('Cached image did not render for the current resume entry.');
}

void main() {
  test('storage overrides may edit and reuse their own lists', () {
    final storage = _MutableStorage();
    final account = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: _Secure(storage),
    );
    final repository = HistoryRepository(storage, account);

    final first = repository.getContinueWatching();
    storage.rows.single['position'] = 19;
    final next = repository.getContinueWatching();
    expect(first.single.position, 9);
    expect(next.single.position, 19);
    expect(next, isNot(same(first)));
  });

  testWidgets('Arabic Home reuses only unchanged Hive resume projections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(585, 990);
    tester.view.devicePixelRatio = 1.5;
    final paths = PathProviderPlatform.instance;
    final visibility = VisibilityDetectorController.instance.updateInterval;
    final quality = highQualityArtwork.value;
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    highQualityArtwork.value = true;
    addTearDown(() {
      tester.view.reset();
      VisibilityDetectorController.instance.notifyNow();
      VisibilityDetectorController.instance.updateInterval = visibility;
      highQualityArtwork.value = quality;
      imageCache
        ..clear()
        ..clearLiveImages();
    });

    final fixture = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('aw-resume-route-');
      PathProviderPlatform.instance = _Paths(temp.path);
      final worker = DownloadPersistenceWorker.forDirectory(
        temp.path,
        documentsDirectory: temp.path,
      );
      final storage = StorageService(downloadPersistenceWorker: worker);
      await storage.init();
      final cache = DefaultCacheManager();
      await cache.putFile(
        _art,
        await _png(),
        fileExtension: 'png',
        maxAge: const Duration(hours: 1),
      );
      final font = FontLoader('Readex Pro')
        ..addFont(
          rootBundle.load('assets/fonts/readex_pro/ReadexPro-Regular.ttf'),
        );
      await font.load();
      await storage.recordHistoryOpen(_item(0));
      for (var i = 0; i < _rowCount; i++) {
        await storage.saveContinueWatchingProgress(
          _item(i),
          10000 + i,
          40000,
          lastEpisodeUrl: _episodeUrl(i),
          season: 1,
          episode: 3,
          episodeTitle: 'لقاء',
          episodePosterUrl: _art,
          timestamp: 1000 + i,
        );
      }
      return (temp: temp, worker: worker, storage: storage, cache: cache);
    });
    final storage = fixture!.storage;
    addTearDown(() async {
      try {
        await fixture.cache.dispose();
        await fixture.worker.close();
        await Hive.close();
        await fixture.temp.delete(recursive: true);
      } finally {
        PathProviderPlatform.instance = paths;
      }
    });

    final unexpected = <String>[];
    final source = _Source(storage, unexpected);
    final account = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: _Secure(storage),
    );
    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        animeWitcherAccountServiceProvider.overrideWithValue(account),
        animeWitcherAccountControllerProvider.overrideWith(_SignedOut.new),
        extensionManagerProvider.overrideWithValue([source]),
        activeProviderProvider.overrideWithValue(source),
        mangaHasOwnTabProvider.overrideWithValue(false),
        deviceProfileProvider.overrideWith((_) async => const DeviceProfile()),
        homeMalRankingPageProvider.overrideWith(
          (_, _) async =>
              const ProviderMediaPage(items: [], nextOffset: 0, hasMore: false),
        ),
      ],
    );
    addTearDown(container.dispose);
    final details = <String>[];
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
        GoRoute(
          path: '/details',
          builder: (_, state) {
            final item = (state.extra! as DetailsRouteExtra).item;
            details.add(item.url);
            return Scaffold(body: Text('تفاصيل ${item.title}'));
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
          theme: ThemeData(fontFamily: 'Readex Pro'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) =>
              RepaintBoundary(key: _boundaryKey, child: child),
        ),
      ),
    );
    await _paint(tester);
    const firstIndex = _rowCount - 1;
    expect(find.byType(ContinueWatchingSection), findsOneWidget);
    expect(_card(firstIndex), findsOneWidget);
    final highWidth = await _readyWidth(tester, firstIndex);
    final frame = await _hash(tester);
    final initial = container.read(continueWatchingProvider);
    var previous = initial;
    final raw = storage.getContinueWatching();
    expect(initial.map((entry) => entry.item.url), [
      for (var i = firstIndex; i >= 0; i--) _url(i),
    ]);

    var projected = 0;
    var replacements = 0;
    var lastSection = tester.widget<ContinueWatchingSection>(
      find.byType(ContinueWatchingSection),
    );
    final revision = container.read(accountDataRevisionProvider.notifier);
    for (var i = 0; i < _updates; i++) {
      revision.bump();
      await tester.pump();
      final next = container.read(continueWatchingProvider);
      expect(next, hasLength(_rowCount));
      expect(storage.getContinueWatching(), same(raw));
      for (var row = 0; row < _rowCount; row++) {
        if (!identical(next[row], previous[row])) projected++;
      }
      final section = tester.widget<ContinueWatchingSection>(
        find.byType(ContinueWatchingSection),
      );
      if (!identical(section, lastSection)) replacements++;
      lastSection = section;
      previous = next;
    }
    expect(projected, _expectedProjectionReuse ? 0 : _rowCount * _updates);
    expect(replacements, _expectedProjectionReuse ? 0 : _updates);
    final postSync = await _hash(tester);
    expect(postSync, frame);
    if (_expectedProjectionReuse) {
      expect(() => raw.clear(), throwsUnsupportedError);
      expect(() => raw.first['position'] = -1, throwsUnsupportedError);
      expect(() => previous[0] = previous[1], throwsUnsupportedError);
    }

    // The visual quality setting is independent of the retained history list.
    highQualityArtwork.value = false;
    await _paint(tester);
    final standardImage = find.descendant(
      of: _card(firstIndex),
      matching: find.byType(CachedNetworkImage),
    );
    final standardWidth = tester
        .widget<CachedNetworkImage>(standardImage)
        .memCacheWidth!;
    expect(standardWidth, lessThan(highWidth));
    await _paint(tester);
    final standard = await _hash(tester);

    // Persist through the production notifier, then ensure the edited entry
    // moves to the front, including its episode-specific keys and fields.
    final actions = container.read(continueWatchingProvider.notifier);
    await tester.runAsync(
      () => actions.saveProgress(
        _item(0),
        23000,
        40000,
        lastEpisodeUrl: _episodeUrl(0),
        season: 1,
        episode: 3,
        episodeTitle: 'بداية جديدة',
        episodePosterUrl: _art,
      ),
    );
    await _paint(tester);
    final edited = container.read(continueWatchingProvider);
    expect(edited, isNot(same(previous)));
    expect(edited.first.item.url, _url(0));
    expect(edited.first.position, 23000);
    expect(initial.last.position, 10000);
    final persisted = Hive.box<dynamic>(StorageService.kContinueWatchingBox);
    expect(persisted.get(_url(0))['position'], 23000);
    expect(persisted.get('EP_${_episodeUrl(0)}')['position'], 23000);
    expect(_card(0), findsOneWidget);
    await _readyWidth(tester, 0);
    final afterEdit = await _hash(tester);
    expect(afterEdit, isNot(standard));

    final context = tester.element(_card(0));
    final l10n = AppLocalizations.of(context)!;
    await tester.longPress(_card(0));
    await _paint(tester);
    await tester.tap(find.text(l10n.viewDetails));
    await _paint(tester);
    expect(details, [_url(0)]);
    expect(find.text('تفاصيل ${_item(0).title}'), findsOneWidget);
    router.pop();
    await _paint(tester);
    expect(_card(0), findsOneWidget);
    await _readyWidth(tester, 0);
    final afterBack = await _hash(tester);

    await tester.runAsync(() => actions.completeForItem(_item(0)));
    await _paint(tester);
    expect(_card(0), findsNothing);
    expect(_card(firstIndex), findsOneWidget);
    expect(persisted.get(_url(0)), isNull);
    expect(persisted.get('EP_${_episodeUrl(0)}'), isNull);
    expect(container.read(watchHistoryProvider).single.item.url, _url(0));
    expect(account.isSignedIn, isFalse);
    expect(unexpected, isEmpty);
    final afterComplete = await _hash(tester);
    if (_witness) {
      // Matched A/B prints only deterministic scoped work and pixel digests.
      // ignore: avoid_print
      print(
        'C26_RESUME projected=$projected section=$replacements '
        'decode=$highWidth/$standardWidth frames='
        '${[frame, postSync, standard, afterEdit, afterBack, afterComplete]}',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}
