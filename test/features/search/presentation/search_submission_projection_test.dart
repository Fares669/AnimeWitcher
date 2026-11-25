import 'dart:async';
import 'dart:collection';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
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
  final container = ProviderContainer(
    overrides: [
      storageServiceProvider.overrideWithValue(MemoryStorageService()),
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
