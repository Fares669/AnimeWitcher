import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/services/artwork_fallback_service.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:animewitcher/features/search/data/recent_searches.dart';
import 'package:animewitcher/features/search/presentation/search_domain.dart';
import 'package:animewitcher/features/search/presentation/search_provider.dart';
import 'package:animewitcher/features/search/presentation/search_screen.dart';
import 'package:animewitcher/features/search/presentation/widgets/phone_suggestion_box.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_result_section.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
// Match SearchScreen's Material compatibility imports.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/widget_completion.dart';

const _stock = bool.fromEnvironment('C26_SEARCH_STOCK');
const _first = 'بحث أول';
const _second = 'بحث ثان';
const _short = 'بحث قصير';
const _old = 'البحث السابق';

MultimediaItem _row(
  String id,
  String title, {
  MultimediaContentType kind = MultimediaContentType.anime,
}) => MultimediaItem(
  title: title,
  url: 'https://fixture.invalid/work/$id',
  posterUrl: '',
  provider: 'animewitcher',
  contentType: kind,
);

class _Counted<T> extends ListBase<T> {
  _Counted(this.values);

  final List<T> values;
  int reads = 0;

  @override
  int get length => values.length;

  @override
  set length(int value) => throw UnsupportedError('read-only query response');

  @override
  T operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('read-only query response');
}

class _Response {
  _Response(List<MultimediaItem> anime, int animation, int manga, String key)
    : anime = _Counted(anime),
      animation = _Counted([
        for (var i = 0; i < animation; i++)
          _row('$key-animation-$i', 'رسم متحرك $i'),
      ]),
      manga = _Counted([
        for (var i = 0; i < manga; i++)
          _row('$key-manga-$i', 'مانجا $i', kind: MultimediaContentType.manga),
      ]);

  final _Counted<MultimediaItem> anime;
  final _Counted<MultimediaItem> animation;
  final _Counted<MultimediaItem> manga;
}

class _Source extends AnimeWitcherNativeProvider {
  _Source(Dio dio, StorageService storage)
    : super(dio, SettingsRepository(storage));

  final requests = <(String, String, int, int)>[];
  final first = _Response(
    [
      _row('blank', '  '),
      _row('first', '  First choice  '),
      _row('first-another', 'First choice'),
      _row('first', 'Separate title'),
      _row('different-case', 'first choice'),
      for (var i = 0; i < 35; i++) _row('first-$i', 'أول $i'),
    ],
    20,
    20,
    'first',
  );
  final second = _Response(
    [
      for (var i = 0; i < 30; i++) _row('same-$i', 'نفس العنوان'),
      for (var i = 0; i < 20; i++) _row('second-$i', 'ثان $i'),
    ],
    20,
    20,
    'second',
  );
  final short = _Response(
    [_row('short-0', 'بداية'), _row('short-1', 'نهاية')],
    2,
    8,
    'short',
  );
  final committed = _row('committed', 'نتيجة مؤكدة');

  _Response _response(String query) => switch (query) {
    _first => first,
    _second => second,
    _short => short,
    _ => throw StateError('Unexpected typed query: $query'),
  };

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    requests.add(('typed-anime', query, 0, 0));
    return _response(query).anime;
  }

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async {
    requests.add(('committed-anime', query, offset, limit));
    return ProviderMediaPage(
      items: query == _short ? [committed] : const [],
      nextOffset: 0,
      hasMore: false,
    );
  }

  @override
  Future<ProviderMediaPage> searchAnimationPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async {
    requests.add(('animation', query, offset, limit));
    return ProviderMediaPage(
      items: limit == 20 && query.isNotEmpty
          ? _response(query).animation
          : const [],
      nextOffset: 0,
      hasMore: false,
    );
  }

  @override
  Future<ProviderMediaPage> searchMangaPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async {
    requests.add(('manga', query, offset, limit));
    return ProviderMediaPage(
      items: limit == 20 && query.isNotEmpty
          ? _response(query).manga
          : const [],
      nextOffset: 0,
      hasMore: false,
    );
  }

  @override
  Future<ProviderCharacterPage> getCharacterPage({int page = 0}) async =>
      ProviderCharacterPage(items: [], page: page, hasMore: false);

  @override
  Future<ProviderCharacterPage> searchCharacterPage(
    String query, {
    int page = 0,
  }) async {
    requests.add(('characters', query, page, 0));
    return ProviderCharacterPage(items: [], page: page, hasMore: false);
  }
}

class _Extensions extends ExtensionManager {
  _Extensions(this.source);

  final AnimeWitcherProvider source;

  @override
  List<AnimeWitcherProvider> build() => [source];
}

class _OfflineArtwork extends ArtworkFallbackService {
  _OfflineArtwork(Dio dio, StorageService storage) : super(dio, storage);

  @override
  Future<({String? cover, String? banner})> mangaArtwork({
    int? malId,
    String title = '',
  }) async => (cover: null, banner: null);
}

Future<String> _previewDigest(
  WidgetTester tester,
  Finder capture,
  Finder preview,
) async {
  final root = tester.renderObject<RenderRepaintBoundary>(capture);
  final rect = tester.getRect(preview).shift(-tester.getTopLeft(capture));
  final width = tester.getSize(capture).width.round();
  return (await tester.runAsync(() async {
    final image = await root.toImage(pixelRatio: 1);
    try {
      final raw = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      final bytes = BytesBuilder(copy: false);
      for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
        bytes.add(
          Uint8List.sublistView(
            raw,
            4 * (y * width + rect.left.ceil()),
            4 * (y * width + rect.right.floor()),
          ),
        );
      }
      return sha256.convert(bytes.takeBytes()).toString();
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  testWidgets(
    'Arabic Search renders the same ranked suggestions with bounded work',
    (tester) async {
      final originalPlatform = debugDefaultTargetPlatformOverride;
      final originalFallback = artworkFallbackEnabled.value;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      artworkFallbackEnabled.value = false;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 800);
      final messenger = tester.binding.defaultBinaryMessenger;
      const secure = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      messenger.setMockMethodCallHandler(secure, (_) async => null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(secure, null);
        tester.view.reset();
        artworkFallbackEnabled.value = originalFallback;
        debugDefaultTargetPlatformOverride = originalPlatform;
      });

      final unexpected = <Uri>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              unexpected.add(options.uri);
              handler.reject(DioException(requestOptions: options));
            },
          ),
        );
      addTearDown(() => dio.close(force: true));
      final storage = MemoryStorageService();
      final source = _Source(dio, storage);
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          artworkFallbackServiceProvider.overrideWithValue(
            _OfflineArtwork(dio, storage),
          ),
          extensionManagerProvider.overrideWith(() => _Extensions(source)),
          activeProviderProvider.overrideWithValue(source),
          deviceProfileProvider.overrideWith(
            (_) async => const DeviceProfile(),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(searchDomainProvider.notifier).set(SearchDomain.all);
      container.read(recentSearchesProvider.notifier).record(_old);
      final opened = <MultimediaItem>[];
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SearchScreen()),
          GoRoute(
            path: '/details',
            builder: (_, state) {
              final item = (state.extra! as DetailsRouteExtra).item;
              opened.add(item);
              return Scaffold(body: Text(item.title));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      const captureKey = ValueKey<String>('search-work-capture');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(
            key: captureKey,
            child: MaterialApp.router(
              routerConfig: router,
              locale: const Locale('ar'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
            ),
          ),
        ),
      );
      final field = find.byType(TextField);
      final preview = find.byKey(const ValueKey('phone-suggestion-box'));
      await pumpUntil(
        tester,
        () => !container.read(searchPagedResultsProvider).isLoading,
        'idle Search catalogue',
      );
      expect(Directionality.of(tester.element(field)), TextDirection.rtl);
      expect(find.text(_old), findsOneWidget);

      Future<void> type(
        String query,
        _Response incoming, {
        required List<String> expectedLabels,
        required List<MultimediaItem> expectedItems,
        required int expectedPrimaryReads,
        required int stockReads,
        required List<MultimediaItem> shown,
        required int animationReads,
        required int mangaReads,
      }) async {
        final requestsBefore = source.requests.length;
        await tester.enterText(field, query);
        await tester.pump(const Duration(milliseconds: 349));
        expect(source.requests, hasLength(requestsBefore));
        await pumpUntil(tester, () {
          final suggestions = container.read(
            searchSuggestionControllerProvider,
          );
          return suggestions.query == query &&
              suggestions.hasResults &&
              preview.evaluate().isNotEmpty;
        }, 'ready phone preview for $query');
        final suggestions = container.read(searchSuggestionControllerProvider);
        expect(suggestions.suggestions, expectedLabels);
        expect(suggestions.items, expectedItems);
        expect(suggestions.animation, same(incoming.animation));
        expect(suggestions.manga, same(incoming.manga));
        final rowKeys = find
            .descendant(
              of: preview,
              matching: find.byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key as ValueKey<String>).value.startsWith(
                      'phone-suggestion-https://fixture.invalid/work/',
                    ),
              ),
            )
            .evaluate()
            .map((element) => element.widget.key)
            .toList();
        expect(rowKeys, [
          for (final item in shown)
            ValueKey<String>('phone-suggestion-${item.url}'),
        ]);
        expect(source.requests.skip(requestsBefore).map((r) => r.$1).toSet(), {
          'typed-anime',
          'animation',
          'manga',
          'characters',
        });
        expect(source.requests.skip(requestsBefore), hasLength(4));
        expect(
          incoming.anime.reads,
          _stock ? stockReads : expectedPrimaryReads,
        );
        expect(
          incoming.animation.reads,
          _stock ? incoming.animation.length : animationReads,
        );
        expect(
          incoming.manga.reads,
          _stock ? incoming.manga.length : mangaReads,
        );
        final digest = await _previewDigest(
          tester,
          find.byKey(captureKey),
          preview,
        );
        debugPrint(
          'C26_SEARCH $query primary=${incoming.anime.reads} '
          'animation=${incoming.animation.reads} manga=${incoming.manga.reads} '
          'rgba=$digest',
        );
        expect(tester.takeException(), isNull);
      }

      final first = source.first.anime.values;
      await type(
        _first,
        source.first,
        expectedLabels: [
          'First choice',
          'Separate title',
          'first choice',
          for (var i = 0; i < 7; i++) 'أول $i',
        ],
        expectedItems: [
          first[1],
          first[2],
          first[4],
          ...first.skip(5).take(27),
        ],
        shown: [first[1], first[2], first[4], ...first.skip(5).take(3)],
        expectedPrimaryReads: 32,
        stockReads: 72,
        animationReads: 0,
        mangaReads: 0,
      );

      final second = source.second.anime.values;
      await type(
        _second,
        source.second,
        expectedLabels: ['نفس العنوان', for (var i = 0; i < 9; i++) 'ثان $i'],
        expectedItems: second.take(30).toList(),
        shown: second.take(6).toList(),
        expectedPrimaryReads: 39,
        stockReads: 80,
        animationReads: 0,
        mangaReads: 0,
      );

      final short = source.short.anime.values;
      await type(
        _short,
        source.short,
        expectedLabels: ['بداية', 'نهاية'],
        expectedItems: short,
        shown: [
          ...short,
          ...source.short.animation.values,
          ...source.short.manga.values.take(2),
        ],
        expectedPrimaryReads: 2,
        stockReads: 4,
        animationReads: 2,
        mangaReads: 2,
      );

      final open = find.byKey(ValueKey('phone-suggestion-${short.first.url}'));
      await tester.tap(open);
      await tester.pump(const Duration(milliseconds: 400));
      await pumpUntil(tester, () => opened.isNotEmpty, 'open first result');
      expect(opened.single, same(short.first));
      router.pop();
      await tester.pump(const Duration(milliseconds: 400));
      await pumpUntil(
        tester,
        () => preview.evaluate().isNotEmpty,
        'Back restores the typed preview',
      );
      expect(tester.widget<TextField>(field).controller!.text, _short);
      expect(find.text(_old), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('phone-suggestion-see-all')));
      await pumpUntil(
        tester,
        () => find.byType(SearchResultSection).evaluate().isNotEmpty,
        'See All submits the exact query',
      );
      expect(container.read(searchQueryProvider), _short);
      expect(container.read(recentSearchesProvider), [_short, _old]);
      expect(find.byType(PhoneSuggestionBox), findsNothing);
      expect(
        tester
            .widget<SearchResultSection>(find.byType(SearchResultSection))
            .results,
        [source.committed],
      );
      expect(unexpected, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
