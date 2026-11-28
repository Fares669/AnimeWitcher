import 'dart:io';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/network/poster_cache.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/services/download_v2/download_v2_provider.dart';
import 'package:animewitcher/core/services/download_v2/logical_download_store_v2.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:animewitcher/features/details/presentation/details_controller.dart';
import 'package:animewitcher/features/details/presentation/details_screen.dart';
import 'package:animewitcher/features/library/presentation/downloads_provider.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/features/search/presentation/search_screen.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_result_section.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:animewitcher/shared/widgets/fallback_poster_image.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
// Match the application's Material compatibility imports.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/widget_completion.dart';

const _original = 'المسلسلات العربية';
const _replacement = 'مسلسلات ثانية';
const _imageUrl = 'https://fixture.invalid/search-route-art.png';
const _color = Color(0xff4266ac);

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

List<MultimediaItem> _rows(String key) => [
  for (var i = 0; i < 30; i++)
    MultimediaItem(
      url: 'https://fixture.invalid/watch/$key-$i',
      title: 'مسلسل $key $i',
      posterUrl: _imageUrl,
      bannerUrl: _imageUrl,
      provider: 'fixture.search-route',
      contentType: MultimediaContentType.anime,
      description: 'الوصف الحقيقي للعمل $key $i',
      episodes: [
        Episode(
          url: 'https://fixture.invalid/episode/$key-$i',
          name: 'الحلقة ١',
          season: 1,
          episode: 1,
        ),
      ],
    ),
];

class _Catalog extends AnimeWitcherProvider {
  final original = _rows('first');
  final replacement = _rows('new');
  final requests = <(String, int)>[];
  final suggestions = <String>[];

  @override
  String get packageName => 'fixture.search-route';
  @override
  String get name => 'Local catalogue';
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
  Future<MultimediaItem> getDetails(String url) async =>
      throw StateError('The local Details controller owns this route: $url');
  @override
  Future<List<StreamResult>> loadStreams(String url) async => const [];

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    suggestions.add(query);
    return const [];
  }

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async {
    requests.add((query, offset));
    final items = switch (query) {
      '' => const <MultimediaItem>[],
      _original => original,
      _replacement => replacement,
      _ => throw StateError('Unexpected query $query'),
    };
    return ProviderMediaPage(
      items: items,
      nextOffset: items.length,
      hasMore: false,
    );
  }
}

class _Extensions extends ExtensionManager {
  _Extensions(this.source);
  final AnimeWitcherProvider source;

  @override
  List<AnimeWitcherProvider> build() => [source];
}

class _Library extends Library {
  @override
  LibraryState build() =>
      const LibraryEmpty(LibraryCategory.favorite, LibraryMediaKind.anime);
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
  _Details(this.item, this.entries);
  final MultimediaItem item;
  final List<String> entries;

  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncData(item),
    episodes: AsyncData(item.episodes!),
    cast: const AsyncData(<Actor>[]),
    trailers: const AsyncData(<Trailer>[]),
    related: const AsyncData(<MultimediaItem>[]),
    recommendations: const AsyncData(<MultimediaItem>[]),
    seasonMap: {1: item.episodes!},
    item: item,
    basicDetailsResolved: true,
    nextAiringResolved: true,
  );

  @override
  Future<void> loadDetails(
    MultimediaItem opened, {
    bool autoPlay = false,
  }) async {
    entries.add(opened.url);
  }

  @override
  Future<void> loadEpisodesOnDemand({bool forceReload = false}) async {}
}

Finder _paintedInside(Finder card) => find.descendant(
  of: card,
  matching: find.byWidgetPredicate(
    (widget) => widget is RawImage && widget.image != null,
  ),
);

Future<int> _paintedColor(WidgetTester tester, Finder card) async {
  final images = _paintedInside(card);
  for (var i = 0; i < 100 && images.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  final image = tester.widget<RawImage>(images.first).image!.clone();
  try {
    return (await tester.runAsync(() async {
      final bytes = (await image.toByteData())!;
      return bytes.getUint32(0);
    }))!;
  } finally {
    image.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late PathProviderPlatform previousPaths;
  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('aw-search-cursor-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(temporary.path);
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(_color, ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(80, 120);
    picture.dispose();
    try {
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await posterCacheManager.putFile(
        _imageUrl,
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        fileExtension: 'png',
        maxAge: const Duration(hours: 1),
      );
    } finally {
      image.dispose();
    }
  });

  tearDownAll(() async {
    await posterCacheManager.dispose();
    PathProviderPlatform.instance = previousPaths;
    await temporary.delete(recursive: true);
  });

  for (final (size, platform) in [
    (const Size(390, 844), TargetPlatform.android),
    (const Size(1280, 900), TargetPlatform.windows),
  ]) {
    testWidgets('RTL Search cursor and Details return at ${size.width}', (
      tester,
    ) async {
      final oldPlatform = debugDefaultTargetPlatformOverride;
      final oldFallback = artworkFallbackEnabled.value;
      debugDefaultTargetPlatformOverride = platform;
      artworkFallbackEnabled.value = false;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      const secure = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secure, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(secure, null);
        tester.view.reset();
        debugDefaultTargetPlatformOverride = oldPlatform;
        artworkFallbackEnabled.value = oldFallback;
        imageCache
          ..clear()
          ..clearLiveImages();
      });

      final source = _Catalog();
      final enteredDetails = <String>[];
      final storage = MemoryStorageService();
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          extensionManagerProvider.overrideWith(() => _Extensions(source)),
          activeProviderProvider.overrideWithValue(source),
          deviceProfileProvider.overrideWith(
            (_) async => const DeviceProfile(),
          ),
          libraryProvider.overrideWith(_Library.new),
          downloadsProvider.overrideWith(_Downloads.new),
          logicalDownloadStoreV2Provider.overrideWithValue(
            InMemoryLogicalDownloadStoreV2(),
          ),
          for (final item in [...source.original, ...source.replacement])
            detailsControllerProvider(detailsControllerKey(item))
                .overrideWith(() => _Details(item, enteredDetails)),
        ],
      );
      addTearDown(container.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SearchScreen()),
          GoRoute(
            path: '/details',
            builder: (_, state) =>
                DetailsScreen(item: (state.extra! as DetailsRouteExtra).item),
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

      final search = find.byType(SearchScreen);
      final details = find.byType(DetailsScreen);
      final field = find.descendant(
        of: search,
        matching: find.byType(TextField),
      );
      final section = find.byType(SearchResultSection);
      await tester.enterText(field, _original);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await pumpUntil(
        tester,
        () => section.evaluate().isNotEmpty,
        'search grid',
      );
      expect(
        tester.widget<SearchResultSection>(section).results,
        source.original,
      );
      expect(Directionality.of(tester.element(search)), TextDirection.rtl);

      final scrollable = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(100);
      await tester.pump();
      final mounted = find.byType(MultimediaCard).hitTestable().first;
      final title = tester.widget<MultimediaCard>(mounted).title;
      final work = source.original.singleWhere((item) => item.title == title);
      final selected = find.byKey(ValueKey(work.url));
      expect(await _paintedColor(tester, selected), 0x4266acff);

      Future<({int route, int grid, int cards, int artwork})>
      editCursor() async {
        await tester.showKeyboard(field);
        await tester.pump();
        final editor = tester.widget<TextField>(field);
        expect(editor.focusNode!.hasFocus, isTrue);
        var route = 0;
        var grid = 0;
        var cards = 0;
        var artwork = 0;
        final priorProbe = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, _) {
          final widget = element.widget;
          if (widget is SearchScreen) route++;
          if (widget is SearchResultSection) grid++;
          if (widget is MultimediaCard) cards++;
          if (widget is FallbackPosterImage && widget.imageUrl == _imageUrl) {
            artwork++;
          }
        };
        try {
          for (var i = 1; i <= 8; i++) {
            final selection = i.isEven
                ? TextSelection.collapsed(offset: i)
                : TextSelection(baseOffset: 1, extentOffset: i + 1);
            final composing = i.isEven
                ? const TextRange(start: 1, end: 4)
                : TextRange.empty;
            final editing = TextEditingValue(
              text: _original,
              selection: selection,
              composing: composing,
            );
            if (i.isEven) {
              // Exercise the raw composing notification separately; the
              // framework mock input can strip the IME range itself.
              editor.controller!.value = editing;
            } else {
              tester.testTextInput.updateEditingValue(editing);
            }
            await tester.pump();
            expect(editor.controller!.selection, selection);
            expect(editor.controller!.value.composing, composing);
            expect(position.pixels, 100);
          }
        } finally {
          debugOnRebuildDirtyWidget = priorProbe;
        }
        return (route: route, grid: grid, cards: cards, artwork: artwork);
      }

      Future<void> openAndReturn() async {
        await tester.tap(selected.hitTestable());
        await tester.pump(const Duration(milliseconds: 450));
        await pumpUntil(tester, () => details.evaluate().isNotEmpty, 'details');
        expect(tester.widget<DetailsScreen>(details).item.url, work.url);
        final back = find
            .descendant(of: details, matching: find.byType(AppBackButton))
            .hitTestable()
            .first;
        await tester.tap(back);
        await tester.pump(const Duration(milliseconds: 450));
        await pumpUntil(
          tester,
          () => section.evaluate().isNotEmpty,
          'search Back',
        );
        expect(tester.widget<TextField>(field).controller!.text, _original);
        expect(position.pixels, 100);
        expect(await _paintedColor(tester, selected), 0x4266acff);
      }

      final first = await editCursor();
      await openAndReturn();
      final returned = await editCursor();
      await openAndReturn();
      expect(enteredDetails, [work.url, work.url]);
      expect(source.requests, [('', 0), (_original, 0)]);
      expect(source.suggestions, isEmpty);

      expect(first, (route: 0, grid: 0, cards: 0, artwork: 0));
      expect(returned, (route: 0, grid: 0, cards: 0, artwork: 0));

      await tester.enterText(field, _replacement);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await pumpUntil(
        tester,
        () =>
            section.evaluate().isNotEmpty &&
            identical(
              tester.widget<SearchResultSection>(section).results,
              source.replacement,
            ),
        'new committed search grid',
      );
      expect(position.pixels, 0);
      expect(source.requests, [('', 0), (_original, 0), (_replacement, 0)]);
      await tester.showKeyboard(field);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpUntil(
        tester,
        () =>
            tester.widget<TextField>(field).controller!.text.isEmpty &&
            section.evaluate().isEmpty,
        'Escape returns to the search start',
      );
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
