import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/features/search/presentation/search_domain.dart';
import 'package:animewitcher/features/search/presentation/search_provider.dart';
import 'package:animewitcher/features/search/presentation/search_screen.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_action_buttons.dart';
import 'package:animewitcher/features/search/presentation/widgets/search_result_section.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../support/memory_storage_service.dart';
import '../../../support/widget_completion.dart';

import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixtureExtensions extends ExtensionManager {
  _FixtureExtensions(this.provider);
  final AnimeWitcherProvider provider;
  @override
  List<AnimeWitcherProvider> build() => [provider];
}

final class _Storage extends StorageService {
  @override
  bool isHighQualityPostersEnabled() => false;

  @override
  bool isEpisodeImagesFromAniZipEnabled() => false;
}

/// Stands in for the catalog: settings documents answer empty, the manga
/// index answers two records, and every search's parameters are kept.
Dio _server(
  List<String> searches, {
  List<Map<String, dynamic>> Function()? mangaHits,
}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final url = options.uri.toString();
        if (url.contains('algolia')) {
          final body = options.data;
          final params = body is Map ? '${body['params'] ?? ''}' : '$body';
          searches.add(Uri.decodeQueryComponent(params));
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'hits':
                    mangaHits?.call() ??
                    <Map<String, dynamic>>[
                      {
                        'objectID': 'b',
                        'name': 'Beta',
                        'details': {'year': '2020', 'status': 'مستمر'},
                      },
                      {
                        'objectID': 'a',
                        'name': 'Alpha',
                        'details': {'year': '2023', 'status': 'مكتمل'},
                      },
                    ],
                'nbPages': 1,
              },
            ),
          );
          return;
        }
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{},
          ),
        );
      },
    ),
  );
  return dio;
}

class _ReadCountingName {
  int reads = 0;

  @override
  String toString() {
    reads++;
    return 'ZZZ';
  }
}

void main() {
  test('a sorted manga search reads the catalog lean, and sorts it', () async {
    final searches = <String>[];
    final provider = AnimeWitcherNativeProvider(
      _server(searches),
      SettingsRepository(_Storage()),
      algoliaSearchApiKey: 'synthetic-catalog-fixture',
    );

    final page = await provider.searchMangaPage(
      '',
      const ProviderSearchFilters(sort: 'name_asc'),
    );

    expect(page.items.map((item) => item.title), <String>['Alpha', 'Beta']);
    final catalogRead = searches.lastWhere((s) => s.contains('hitsPerPage'));
    // Only the card's fields, and no highlighted copies of them: about a
    // seventh of the full records' size.
    expect(catalogRead, contains('attributesToHighlight=[]'));
    expect(catalogRead, contains('attributesToRetrieve='));
    expect(catalogRead, isNot(contains('story')));
    for (final field in <String>['name', 'poster', 'tags', 'details', 'type']) {
      expect(
        AnimeWitcherNativeProvider.mangaCatalogAttributes,
        contains(field),
      );
    }

    // Paging through the same search reads nothing more.
    final before = searches.length;
    await provider.searchMangaPage(
      '',
      const ProviderSearchFilters(sort: 'name_asc'),
      offset: 1,
    );
    expect(searches.length, before);
  });

  test(
    'warm pages only prepare their catalog once and still map new items',
    () async {
      final name = _ReadCountingName();
      var hits = <Map<String, dynamic>>[
        for (var i = 24; i >= 0; i--)
          {
            'objectID': '$i',
            'name': 'Manga ${i.toString().padLeft(2, '0')}',
            'tags': <String>['أكشن'],
          },
        {
          'objectID': 'z',
          'name': name,
          'tags': <String>['أكشن'],
        },
        {
          'objectID': 'h',
          'name': 'Horror',
          'tags': <String>['رعب'],
        },
      ];
      final searches = <String>[];
      final provider = AnimeWitcherNativeProvider(
        _server(searches, mangaHits: () => hits),
        SettingsRepository(_Storage()),
        algoliaSearchApiKey: 'synthetic-catalog-fixture',
      );
      final genres = <String>{'اكشن'};
      final filters = ProviderSearchFilters(sort: 'name_asc', genres: genres);
      final first = await provider.searchMangaPage(
        'sample',
        filters,
        limit: 10,
      );
      final before = searches.length;
      final preparedReads = name.reads;
      expect(preparedReads, greaterThan(0));
      expect(first.items.first.title, 'Manga 00');
      expect(first.items.last.title, 'Manga 09');
      expect(first.nextOffset, 10);
      expect(first.hasMore, isTrue);

      final next = await provider.searchMangaPage(
        'sample',
        const ProviderSearchFilters(sort: 'name_asc', genres: <String>{'أكشن'}),
        offset: first.nextOffset,
        limit: 10,
      );
      final again = await provider.searchMangaPage(
        ' SAMPLE ',
        filters,
        limit: 10,
      );
      expect(next.items.first.title, 'Manga 10');
      expect(next.items.last.title, 'Manga 19');
      expect(next.nextOffset, 20);
      expect(again.items.first.url, first.items.first.url);
      expect(identical(again.items.first, first.items.first), isFalse);
      expect(name.reads, preparedReads, reason: 'off-page keys are not reread');
      expect(searches.length, before);

      genres
        ..clear()
        ..add('رعب');
      final changed = await provider.searchMangaPage(
        'sample',
        filters,
        limit: 10,
      );
      expect(changed.items.single.title, 'Horror');
      expect(changed.nextOffset, 1);
      expect(changed.hasMore, isFalse);
      expect(searches.length, before);

      // The existing four raw-catalog entries fill and evict sample. Its old
      // prepared view must never be served for the next snapshot of that query.
      for (var i = 0; i < 4; i++) {
        await provider.searchMangaPage('separate-$i', filters, limit: 10);
      }
      hits = <Map<String, dynamic>>[
        {
          'objectID': 'new',
          'name': 'New data',
          'tags': <String>['رعب'],
        },
      ];
      final replaced = await provider.searchMangaPage(
        'sample',
        filters,
        limit: 10,
      );
      expect(replaced.items.single.title, 'New data');
    },
  );

  testWidgets(
    'filtered Manga Search keeps provider, ordered pages, and selected work',
    (tester) async {
      final rows = <Map<String, dynamic>>[
        for (var index = 139; index >= 0; index--)
          {
            'objectID': 'entry-$index',
            'name': index.isEven
                ? '   أمل Alpha ${index % 11} '
                : 'غير مطابق $index',
            'tags': [index.isEven ? ' أكشن ' : 'خيال', 'دراما', ' أَكشن '],
            'details': {
              'year': index % 3 == 0
                  ? '2024'
                  : index % 3 == 1
                  ? null
                  : 2024,
              'status': index < 70 ? 'مستمر' : 'مكتمل',
            },
          },
        {
          'objectID': 'entry-0',
          'name': '  أمل Alpha 5  ',
          'tags': ['اكشن'],
        },
        {
          'objectID': 'entry-2',
          'name': '  أمل Alpha 10  ',
          'tags': ['اكشن'],
        },
        {
          'objectID': 'empty-title',
          'name': '',
          'tags': ['اكشن'],
        },
      ];
      List<Map<String, dynamic>> matchingInput() => [
        for (final row in rows)
          if ((row['tags'] as List<String>).first != 'خيال') row,
      ];
      var expectedInput = matchingInput()
        ..sort(
          (a, b) => (a['name'] as String).trim().toLowerCase().compareTo(
            (b['name'] as String).trim().toLowerCase(),
          ),
        );
      var expectedPos = 0;
      List<(String, String)> referencePage() {
        final seen = <String>{};
        final rows = <(String, String)>[];
        while (rows.length < 30 && expectedPos < expectedInput.length) {
          final input = expectedInput[expectedPos++];
          final title = (input['name'] as String).trim();
          final url = 'https://animewitcher.com/manga/${input['objectID']}';
          if (title.isNotEmpty && seen.add(url)) rows.add((title, url));
        }
        return rows;
      }

      final firstExpected = referencePage();
      final firstPos = expectedPos;
      final nextExpected = referencePage();
      final secondPos = expectedPos;

      final requests = <String>[];
      final transport = _server(requests, mangaHits: () => rows);
      addTearDown(() => transport.close(force: true));
      final provider = AnimeWitcherNativeProvider(
        transport,
        SettingsRepository(_Storage()),
        algoliaSearchApiKey: 'synthetic-catalog-fixture',
      );
      final storage = MemoryStorageService();
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          extensionManagerProvider.overrideWith(
            () => _FixtureExtensions(provider),
          ),
          activeProviderProvider.overrideWithValue(provider),
          deviceProfileProvider.overrideWith(
            (_) async => const DeviceProfile(),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(searchDomainProvider.notifier).set(SearchDomain.manga);
      container
          .read(searchProviderFiltersProvider.notifier)
          .set(const ProviderSearchFilters(sort: 'name_asc', genres: {'اكشن'}));
      container.read(searchQueryProvider.notifier).set('عينة mixed');
      MangaDetailsRouteExtra? selected;
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SearchScreen()),
          GoRoute(
            path: '/manga-details',
            builder: (_, state) {
              selected = state.extra! as MangaDetailsRouteExtra;
              return const Scaffold(body: Text('Recorded work route'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      tester.view.physicalSize = const Size(412, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
      final sectionFinder = find.byType(SearchResultSection);
      SearchResultSection section() =>
          tester.widget<SearchResultSection>(sectionFinder);
      await pumpUntil(
        tester,
        () => sectionFinder.evaluate().isNotEmpty,
        'filtered manga first page through SearchScreen',
      );
      List<(String, String)> shown() =>
          section().results.map((item) => (item.title, item.url)).toList();
      SearchAggregateState paged() =>
          container.read(searchPagedResultsProvider);
      expect(section().providerId, provider.packageName);
      expect(shown(), firstExpected);
      expect(paged().nextOffset, firstPos);
      expect(paged().hasMore, isTrue);

      final resultScroll = find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(resultScroll).position;
      position.jumpTo(position.maxScrollExtent);
      await pumpUntil(
        tester,
        () => paged().nextOffset == secondPos,
        'next page triggered by reaching search scroll edge',
      );
      final seen = <String>{};
      final expectedMerged = [
        for (final row in [...firstExpected, ...nextExpected])
          if (seen.add(row.$2)) row,
      ];
      // The pager deduplicates within a page; Search combines later pages.
      expect(
        [...firstExpected, ...nextExpected].length - expectedMerged.length,
        1,
      );
      expect(shown(), expectedMerged);
      expect(section().providerId, provider.packageName);
      expect(
        requests.where((call) => call.contains('hitsPerPage=1000')).length,
        1,
      );

      position.jumpTo(0);
      await tester.pumpAndSettle();
      final sortMenu = find.descendant(
        of: find.byType(SearchActionButtons),
        matching: find.byType(PopupMenuButton<String>),
      );
      await tester.tap(sortMenu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('تاريخ الإنتاج (تنازلي)'));

      int? year(Map<String, dynamic> row) {
        final details = row['details'] as Map<String, Object?>?;
        return int.tryParse('${details?['year'] ?? ''}');
      }

      expectedInput = matchingInput()
        ..sort((a, b) {
          final ay = year(a), by = year(b);
          return by == null
              ? (ay == null ? 0 : -1)
              : ay == null
              ? 1
              : by.compareTo(ay);
        });
      expectedPos = 0;
      final sortedExpected = referencePage();
      await pumpUntil(
        tester,
        () =>
            !paged().isLoading &&
            sectionFinder.evaluate().isNotEmpty &&
            shown().length == sortedExpected.length &&
            shown().firstOrNull == sortedExpected.first,
        'changed year sort from the live Search menu',
      );
      expect(container.read(searchProviderFiltersProvider).sort, 'year_desc');
      expect(shown(), sortedExpected);
      expect(paged().nextOffset, expectedPos);
      expect(
        requests.where((call) => call.contains('hitsPerPage=1000')).length,
        1,
      );

      final firstCard = find.byKey(ValueKey(sortedExpected.first.$2));
      expect(firstCard, findsOneWidget);
      await tester.tap(firstCard);
      await tester.pumpAndSettle();
      expect(find.text('Recorded work route'), findsOneWidget);
      expect(selected?.item.title, sortedExpected.first.$1);
      expect(selected?.item.url, sortedExpected.first.$2);
      expect(selected?.item.provider, provider.packageName);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
