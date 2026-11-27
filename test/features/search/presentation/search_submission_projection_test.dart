import 'dart:async';
import 'dart:collection';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/services/artwork_fallback_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:animewitcher/features/search/presentation/search_domain.dart';
import 'package:animewitcher/features/search/presentation/search_provider.dart';
import 'package:animewitcher/features/search/presentation/search_screen.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_result_section.dart';
import 'package:animewitcher/features/search/presentation/widgets/phone_suggestion_box.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/widget_completion.dart';

const _link = 'https://fixture.invalid/watch/episode?q=%2F+b%2520';
const _typedLink = '  $_link  ';

MultimediaItem _work(String key, {String? title}) => MultimediaItem(
  url: 'https://fixture.invalid/catalog/$key',
  title: title ?? 'نتيجة $key',
  posterUrl: '',
  contentType: MultimediaContentType.anime,
  provider: 'fixture.search-submission',
);

class _CountedResults extends ListBase<MultimediaItem> {
  _CountedResults(this._rows);
  final List<MultimediaItem> _rows;
  int reads = 0;

  @override
  int get length => _rows.length;
  @override
  set length(int value) => throw UnsupportedError('read-only catalog response');
  @override
  MultimediaItem operator [](int index) {
    reads++;
    return _rows[index];
  }

  @override
  void operator []=(int index, MultimediaItem value) =>
      throw UnsupportedError('read-only catalog response');
}

class _Source extends AnimeWitcherProvider {
  final suggestionCalls = <String>[];
  final committedCalls = <(String, int)>[];
  final suggestions = Completer<List<MultimediaItem>>();
  final secondPage = Completer<ProviderMediaPage>();
  final firstPageItems = [for (var i = 0; i < 30; i++) _work('committed-$i')];
  final nextWork = _work('page-two');
  @override
  String get packageName => 'fixture.search-submission';
  @override
  String get name => 'Offline Search catalog';
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
      throw StateError('The route boundary is captured, not loaded');
  @override
  Future<List<StreamResult>> loadStreams(String url) async => const [];
  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) {
    suggestionCalls.add(query);
    return suggestions.future;
  }

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async {
    if (query.isEmpty) {
      return const ProviderMediaPage(items: [], nextOffset: 0, hasMore: false);
    }
    committedCalls.add((query, offset));
    if (query != _link) throw StateError('Unexpected committed search $query');
    if (offset == 0) {
      return ProviderMediaPage(
        items: firstPageItems,
        nextOffset: 30,
        hasMore: true,
      );
    }
    if (offset == 30) return secondPage.future;
    throw StateError('Unexpected page offset $offset');
  }
}

class _PagingSource extends _Source {
  static const pageSize = 30;
  static const pageCount = 24;
  int identityReads = 0;
  bool measureIdentity = false;
  final responses = <int, Completer<ProviderMediaPage>>{};
  final published = <MultimediaItem>[];

  MultimediaItem newWork(int key, String title) =>
      _TrackedWork(this, key, title);

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = pageSize,
    CancelToken? cancelToken,
  }) async {
    if (query.isEmpty) {
      return const ProviderMediaPage(items: [], nextOffset: 0, hasMore: false);
    }
    expect(query, _link);
    expect(limit, pageSize);
    expect(offset % pageSize, 0);
    committedCalls.add((query, offset));
    if (offset == 0) {
      final result = page(0);
      return result;
    }
    final response = Completer<ProviderMediaPage>();
    responses[offset] = response;
    return response.future;
  }

  ProviderMediaPage page(int offset) {
    final rows = [
      if (offset > 0) newWork(0, 'duplicate replacement'),
      for (var i = offset > 0 ? 1 : 0; i < pageSize; i++)
        newWork(offset + i, 'عمل ${offset + i}'),
    ];
    published.addAll(offset == 0 ? rows : rows.skip(1));
    final next = offset + pageSize;
    return ProviderMediaPage(
      items: rows,
      nextOffset: next,
      hasMore: next < pageCount * pageSize,
    );
  }
}

class _TrackedWork extends MultimediaItem {
  _TrackedWork(this._source, int key, String title)
    : super(
        title: title,
        url: 'https://fixture.invalid/catalog/paged-$key',
        posterUrl: '',
        contentType: MultimediaContentType.anime,
        provider: 'fixture.search-submission',
      );

  final _PagingSource _source;

  @override
  String get url {
    if (_source.measureIdentity) _source.identityReads++;
    return super.url;
  }
}

class _ActorPagingSource extends _Source {
  @override
  bool get supportsCharacters => true;

  final actorPages = <(String, int), Completer<ProviderCharacterPage>>{};

  @override
  Future<ProviderCharacterPage> searchCharacterPage(
    String query, {
    int page = 0,
  }) {
    final response = Completer<ProviderCharacterPage>();
    actorPages[(query, page)] = response;
    return response.future;
  }
}

class _FilterSource extends _Source {
  final mangaRequests = <ProviderSearchFilters>[];
  final mangaResponses = <Completer<ProviderMediaPage>>[];

  @override
  Set<ProviderType> get supportedTypes => const {
    ProviderType.anime,
    ProviderType.manga,
  };

  @override
  Future<ProviderSearchFilterOptions> getSearchFilterOptions() async =>
      const ProviderSearchFilterOptions(types: ['TV']);

  @override
  Future<ProviderSearchFilterOptions> getMangaSearchFilterOptions() async =>
      const ProviderSearchFilterOptions(genres: ['Action']);

  @override
  Future<ProviderMediaPage> searchPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) async => ProviderMediaPage(
    items: [_work('old-anime')],
    nextOffset: 1,
    hasMore: false,
  );

  @override
  Future<ProviderMediaPage> searchMangaPage(
    String query,
    ProviderSearchFilters filters, {
    int offset = 0,
    int limit = 30,
    CancelToken? cancelToken,
  }) {
    expect(query, isEmpty);
    expect(offset, 0);
    mangaRequests.add(filters);
    final response = Completer<ProviderMediaPage>();
    mangaResponses.add(response);
    return response.future;
  }
}

class _OfflineArtwork extends ArtworkFallbackService {
  _OfflineArtwork(StorageService storage) : super(Dio(), storage);

  @override
  Future<({String? cover, String? banner})> mangaArtwork({
    int? malId,
    String title = '',
  }) async => (cover: null, banner: null);
}

class _Manager extends ExtensionManager {
  _Manager(this.source);
  final AnimeWitcherProvider source;
  @override
  List<AnimeWitcherProvider> build() => [source];
}

Future<({ProviderContainer container, List<DetailsRouteExtra> opened})> _mount(
  WidgetTester tester,
  _Source source,
) async {
  final oldPlatform = debugDefaultTargetPlatformOverride;
  final oldFallback = artworkFallbackEnabled.value;
  final oldUnreachable = malArtworkUnreachable.value;
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  artworkFallbackEnabled.value = false;
  malArtworkUnreachable.value = false;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 690);
  addTearDown(() {
    debugDefaultTargetPlatformOverride = oldPlatform;
    artworkFallbackEnabled.value = oldFallback;
    malArtworkUnreachable.value = oldUnreachable;
    tester.view.reset();
  });
  final storage = MemoryStorageService();
  final container = ProviderContainer(
    overrides: [
      storageServiceProvider.overrideWithValue(storage),
      artworkFallbackServiceProvider.overrideWithValue(
        _OfflineArtwork(storage),
      ),
      extensionManagerProvider.overrideWith(() => _Manager(source)),
      activeProviderProvider.overrideWithValue(source),
      deviceProfileProvider.overrideWith((_) async => const DeviceProfile()),
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
          return const Scaffold(body: Text('Selected Search work'));
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
  return (container: container, opened: opened);
}

void main() {
  testWidgets(
    'applying a new search category and filters queries only the final catalog',
    (tester) async {
      final source = _FilterSource();
      final harness = await _mount(tester, source);
      tester.view.physicalSize = const Size(412, 760);
      final container = harness.container;
      container
          .read(searchProviderFiltersProvider.notifier)
          .set(const ProviderSearchFilters(types: {'TV'}, sort: 'favorites'));
      final section = find.byType(SearchResultSection);
      await pumpUntil(
        tester,
        () => section.evaluate().isNotEmpty,
        'original anime section',
      );
      expect(
        tester.widget<SearchResultSection>(section).results.single.url,
        _work('old-anime').url,
      );

      await tester.tap(find.byTooltip('الفلاتر'));
      final mangaCategory = find.byKey(const ValueKey('filterCategory-manga'));
      await pumpUntil(
        tester,
        () => mangaCategory.hitTestable().evaluate().isNotEmpty,
        'manga category in the filter sheet',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(mangaCategory);
      final genre = find.text('Action');
      await pumpUntil(
        tester,
        () => genre.hitTestable().evaluate().isNotEmpty,
        'manga genre options',
      );
      await tester.tap(genre);
      await tester.pump();
      expect(source.mangaRequests, isEmpty);
      await tester.tap(find.byKey(const ValueKey('filterApply')));
      await pumpUntil(
        tester,
        () => source.mangaRequests.isNotEmpty,
        'filter apply starts a manga request',
      );
      await tester.pump(const Duration(milliseconds: 450));

      final loading = container.read(searchPagedResultsProvider);
      expect(container.read(searchDomainProvider), SearchDomain.manga);
      expect(loading.isLoading, isTrue);
      expect(loading.results, isEmpty, reason: 'do not show old anime');
      final finalRequest = source.mangaRequests.last;
      expect(finalRequest.types, isEmpty);
      expect(finalRequest.genres, {'Action'});
      expect(finalRequest.sort, 'favorites');

      final work = _work('filtered-manga')
          .copyWith(contentType: MultimediaContentType.manga);
      source.mangaResponses.last.complete(
        ProviderMediaPage(items: [work], nextOffset: 1, hasMore: false),
      );
      // Any obsolete requests in the baseline finish after the real response.
      for (final stale in source.mangaResponses.take(
        source.mangaResponses.length - 1,
      )) {
        stale.complete(
          const ProviderMediaPage(items: [], nextOffset: 0, hasMore: false),
        );
      }
      await pumpUntil(
        tester,
        () => section.evaluate().isNotEmpty,
        'final selected manga is shown',
      );
      expect(tester.widget<SearchResultSection>(section).results, [work]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(
        source.mangaRequests,
        hasLength(1),
        reason: 'one Apply must not query intermediate filters',
      );
    },
  );

  testWidgets(
    'committed pasted query and paging never traverse its obsolete suggestions',
    (tester) async {
      final source = _Source();
      final harness = await _mount(tester, source);
      final field = find.byType(TextField);
      await tester.enterText(field, 'اولاً');
      await tester.pump(const Duration(milliseconds: 160));
      await tester.enterText(field, _typedLink);
      await tester.pump(const Duration(milliseconds: 351));
      expect(source.suggestionCalls, [_typedLink]);

      await tester.testTextInput.receiveAction(TextInputAction.search);
      final sectionFinder = find.byType(SearchResultSection);
      await pumpUntil(
        tester,
        () => sectionFinder.evaluate().isNotEmpty,
        'committed first page',
      );
      SearchResultSection section() =>
          tester.widget<SearchResultSection>(sectionFinder);
      expect(section().results, orderedEquals(source.firstPageItems));
      expect(source.committedCalls, [(_link, 0)]);
      expect(find.byType(PhoneSuggestionBox), findsNothing);

      await tester.tap(field);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(source.committedCalls, [(_link, 0)]);

      final scroll = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scroll).position;
      position.jumpTo(position.maxScrollExtent);
      await pumpUntil(
        tester,
        () => source.committedCalls.length == 2,
        'real scroll requests page two',
      );
      expect(source.committedCalls, [(_link, 0), (_link, 30)]);
      expect(
        harness.container.read(searchPagedResultsProvider).isLoadingMore,
        isTrue,
      );
      position.jumpTo(position.maxScrollExtent - 1);
      position.jumpTo(position.maxScrollExtent);
      expect(source.committedCalls, [(_link, 0), (_link, 30)]);

      final stale = _CountedResults([
        for (var i = 0; i < 30; i++) _work('expired-$i'),
      ]);
      source.suggestions.complete(stale);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final staleReads = stale.reads;
      expect(find.byType(PhoneSuggestionBox), findsNothing);
      expect(
        harness.container.read(searchSuggestionControllerProvider).hasResults,
        isFalse,
      );
      expect(
        harness.container.read(searchPagedResultsProvider).isLoadingMore,
        isTrue,
      );
      expect(section().results, orderedEquals(source.firstPageItems));

      source.secondPage.complete(
        ProviderMediaPage(
          items: [
            source.firstPageItems.first.copyWith(
              title: 'replacement duplicate',
            ),
            source.nextWork,
          ],
          nextOffset: 32,
          hasMore: false,
        ),
      );
      await pumpUntil(
        tester,
        () => section().results.length == 31,
        'committed append with first-copy dedupe',
      );
      expect(section().providerId, source.packageName);
      expect(
        section().results,
        orderedEquals([...source.firstPageItems, source.nextWork]),
      );
      expect(section().results.first, same(source.firstPageItems.first));
      expect(source.committedCalls, [(_link, 0), (_link, 30)]);
      expect(source.suggestionCalls, [_typedLink]);
      expect(harness.container.read(searchPagedResultsProvider).nextOffset, 32);

      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      final lastCard = find.byKey(ValueKey(source.nextWork.url));
      await pumpUntil(
        tester,
        () => lastCard.evaluate().isNotEmpty,
        'appended card visible at the scroll end',
      );
      await tester.ensureVisible(lastCard);
      await tester.pump();
      await tester.tap(lastCard);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('Selected Search work'), findsOneWidget);
      expect(harness.opened, isNotEmpty);
      expect(
        harness.opened.map((extras) => (extras.item.url, extras.item.provider)),
        everyElement((source.nextWork.url, source.nextWork.provider)),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(
        staleReads,
        0,
        reason: 'superseded suggestion lists must not be traversed during active paging',
      );
    },
  );

  testWidgets(
    'real Search scroll does not re-index the retained catalog on each page',
    (tester) async {
      final source = _PagingSource();
      final harness = await _mount(tester, source);
      final field = find.byType(TextField);
      await tester.enterText(field, _typedLink);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      final sectionFinder = find.byType(SearchResultSection);
      await pumpUntil(
        tester,
        () => sectionFinder.evaluate().isNotEmpty,
        'first committed catalog page',
      );
      SearchResultSection section() =>
          tester.widget<SearchResultSection>(sectionFinder);
      final first = section().results;
      expect(first, orderedEquals(source.published));

      final scroll = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scroll).position;
      const pageSize = _PagingSource.pageSize;
      for (var page = 1; page < _PagingSource.pageCount; page++) {
        final offset = page * pageSize;
        position.jumpTo(position.maxScrollExtent);
        await pumpUntil(
          tester,
          () => source.responses.containsKey(offset),
          'real scroll requested page $page',
        );
        expect(
          harness.container.read(searchPagedResultsProvider).isLoadingMore,
          isTrue,
        );
        final response = source.page(offset);
        source.measureIdentity = true;
        source.responses[offset]!.complete(response);
        // Let the real notifier publish before a widget frame can read URLs
        // for card keys. Only work in the append itself is counted.
        await Future<void>.value();
        await Future<void>.value();
        source.measureIdentity = false;
        expect(
          harness.container.read(searchPagedResultsProvider).isLoadingMore,
          isFalse,
        );
        await pumpUntil(
          tester,
          () => section().results.length == source.published.length,
          'published page $page',
        );
      }

      expect(first, hasLength(pageSize), reason: 'previous list unchanged');
      expect(section().results, orderedEquals(source.published));
      expect(section().results.first, same(first.first));
      expect(source.committedCalls, [
        for (var p = 0; p < _PagingSource.pageCount; p++) (_link, p * pageSize),
      ]);
      expect(find.byType(PhoneSuggestionBox), findsNothing);
      final last = source.published.last;
      final lastCard = find.byKey(ValueKey(last.url));
      position.jumpTo(position.maxScrollExtent);
      await pumpUntil(
        tester,
        () => lastCard.evaluate().isNotEmpty,
        'appended card appears at end',
      );
      await tester.ensureVisible(lastCard);
      await tester.pump();
      await tester.tap(lastCard);
      await pumpUntil(
        tester,
        () => harness.opened.isNotEmpty,
        'routed appended work',
      );
      expect(harness.opened.last.item, same(last));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(source.identityReads, _PagingSource.pageCount * pageSize);
    },
  );

  test(
    'character index preserves first winners and resets for account change',
    () async {
      final source = _ActorPagingSource();
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWithValue(source),
          extensionManagerProvider.overrideWith(() => _Manager(source)),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(searchDomainProvider.notifier)
          .set(SearchDomain.characters);
      final query = container.read(searchQueryProvider.notifier);
      query.set('actors');
      final notifier = container.read(searchPagedResultsProvider.notifier);
      Future<void> flush() => Future<void>.delayed(Duration.zero);
      await flush();
      final first = Actor(id: '  first  ', name: 'First');
      final sameId = Actor(id: 'first', name: 'Ignored id duplicate');
      final fallback = Actor(name: ' No Id ', image: 'test://same');
      final sameFallback = Actor(name: 'no id', image: 'test://same');
      final differentImage = Actor(name: 'no id', image: 'test://different');
      final last = Actor(id: 'last', name: 'Last');
      source.actorPages[('actors', 0)]!.complete(
        ProviderCharacterPage(
          items: [first, sameId, fallback, sameFallback],
          page: 0,
          hasMore: true,
        ),
      );
      await flush();
      final initial = container.read(searchPagedResultsProvider).characters;
      expect(initial, [first, sameId, fallback, sameFallback]);

      final stageOne = notifier.loadMore();
      source.actorPages[('actors', 1)]!.complete(
        ProviderCharacterPage(
          items: [fallback, differentImage],
          page: 1,
          hasMore: true,
        ),
      );
      await stageOne;
      final previous = container.read(searchPagedResultsProvider).characters;
      expect(previous, [first, fallback, differentImage]);
      expect(initial, [first, sameId, fallback, sameFallback]);

      // A transient append failure leaves retry offset and current rows intact.
      final failing = notifier.loadMore();
      source.actorPages[('actors', 2)]!.completeError(StateError('offline'));
      await failing;
      expect(
        container.read(searchPagedResultsProvider).characters,
        same(previous),
      );
      expect(container.read(searchPagedResultsProvider).nextOffset, 2);

      final stageTwo = notifier.loadMore();
      source.actorPages[('actors', 2)]!.complete(
        ProviderCharacterPage(items: [sameId, last], page: 2, hasMore: true),
      );
      await stageTwo;
      expect(container.read(searchPagedResultsProvider).characters, [
        first,
        fallback,
        differentImage,
        last,
      ]);
      expect(previous, [first, fallback, differentImage]);

      final stale = notifier.loadMore();
      final obsolete = source.actorPages[('actors', 3)]!;
      container.read(accountDataRevisionProvider.notifier).bump();
      expect(container.read(searchPagedResultsProvider).characters, isEmpty);
      await flush();
      final newFirst = Actor(id: 'first', name: 'New account');
      source.actorPages[('actors', 0)]!.complete(
        ProviderCharacterPage(items: [newFirst], page: 0, hasMore: true),
      );
      await flush();
      obsolete.complete(
        ProviderCharacterPage(
          items: [Actor(id: 'not-visible', name: 'Previous account only')],
          page: 3,
          hasMore: false,
        ),
      );
      await stale;
      final current = notifier.loadMore();
      source.actorPages[('actors', 1)]!.complete(
        ProviderCharacterPage(items: [sameId, last], page: 1, hasMore: false),
      );
      await current;
      final state = container.read(searchPagedResultsProvider);
      expect(state.characters, [newFirst, last]);
      expect(state.hasMore, isFalse);
    },
  );

  testWidgets(
    'current autocomplete retains exact independent title and URL dedupe',
    (tester) async {
      final source = _Source();
      final harness = await _mount(tester, source);
      await tester.enterText(find.byType(TextField), 'بحث صالح');
      await tester.pump(const Duration(milliseconds: 351));
      expect(source.suggestionCalls, ['بحث صالح']);
      final first = _work('first', title: '  First choice  ');
      final sameLabel = _work('other-url', title: 'First choice');
      final duplicateUrl = _work('first', title: 'Different label');
      final differentCase = _work('different-case', title: 'first choice');
      final extra = [for (var i = 0; i < 35; i++) _work('valid-$i')];
      final valid = _CountedResults([
        _work('blank', title: '  '),
        first,
        sameLabel,
        duplicateUrl,
        differentCase,
        ...extra,
      ]);
      source.suggestions.complete(valid);
      await pumpUntil(
        tester,
        () => harness.container
            .read(searchSuggestionControllerProvider)
            .hasResults,
        'current autocomplete response ready',
      );
      final state = harness.container.read(searchSuggestionControllerProvider);
      expect(state.items, [first, sameLabel, differentCase, ...extra.take(27)]);
      expect(state.suggestions, [
        'First choice',
        'Different label',
        'first choice',
        ...extra.take(7).map((e) => e.title),
      ]);
      expect(valid.reads, greaterThan(0));
      debugPrint('C20 valid suggestion raw element reads: ${valid.reads}');
      expect(find.byType(PhoneSuggestionBox), findsOneWidget);
      final suggestion = find.byKey(ValueKey('phone-suggestion-${first.url}'));
      expect(suggestion, findsOneWidget);
      expect(source.committedCalls, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
