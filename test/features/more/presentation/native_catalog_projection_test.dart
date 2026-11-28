import 'dart:collection';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/utils/artwork_host_fallback.dart';
import 'package:animewitcher/features/more/presentation/coming_soon_screen.dart';
import 'package:animewitcher/features/more/presentation/seasons_screen.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
// Match the app's MaterialApp shell without changing its compatibility path.
// ignore: deprecated_member_use
import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _ProjectionWork {
  int copiedMaps = 0;
  int descriptions = 0;
}

/// Count copies of typed JSON-shaped maps, not the transport wrapper itself.
class _HitMap extends MapBase<String, dynamic> {
  _HitMap(this.fields, this.work);

  final Map<String, dynamic> fields;
  final _ProjectionWork work;

  @override
  dynamic operator [](Object? key) => fields[key];
  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('fixture hits are read-only');
  @override
  void clear() => throw UnsupportedError('fixture hits are read-only');
  @override
  dynamic remove(Object? key) =>
      throw UnsupportedError('fixture hits are read-only');
  @override
  Iterable<String> get keys => fields.keys;

  @override
  Map<K, V> map<K, V>(MapEntry<K, V> Function(String, dynamic) convert) {
    work.copiedMaps++;
    return fields.map(convert);
  }
}

/// Stand-in for a JSON string whose conversion records full row projection.
class _Story {
  _Story(this.work);
  final _ProjectionWork work;

  @override
  String toString() {
    work.descriptions++;
    return '<b>Local</b> &amp; ongoing';
  }
}

class _ArtworkSettings extends MemoryStorageService {
  _ArtworkSettings(this.quality);
  final bool quality;

  @override
  bool isHighQualityPostersEnabled() => quality;
}

typedef _Browse = ({int page, String filters, int limit});

class _BrowseFixture {
  _BrowseFixture({
    required this.pages,
    this.hidden = true,
    this.quality = false,
  }) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          void respond(Object result, {int statusCode = 200}) {
            handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: statusCode,
                data: result,
              ),
            );
          }

          if (options.uri.path.endsWith('/Settings/constants')) {
            respond(const {
              'fields': {
                'seasons': {
                  'mapValue': {
                    'fields': {
                      'current': {'stringValue': 'Catalog season 2026'},
                    },
                  },
                },
                'search_settings': {
                  'mapValue': {
                    'fields': {
                      'app_id_v3': {'stringValue': 'FIXTURE'},
                      'api_key': {'stringValue': 'fixture-search-only'},
                      'browse_api_key': {'stringValue': 'fixture-browse-only'},
                      'is_search_active': {'booleanValue': true},
                    },
                  },
                },
              },
            });
          } else if (options.uri.path.endsWith('/series/browse')) {
            final query = options.uri.queryParameters;
            final page = int.parse(query['page']!);
            requests.add((
              page: page,
              filters: query['filters']!,
              limit: int.parse(query['hitsPerPage']!),
            ));
            if (failAppend && page > 0) {
              respond(const {}, statusCode: 503);
              return;
            }
            respond({'hits': pages[page], 'nbPages': pages.length});
          } else {
            // Reject every unmodeled request rather than hitting a backend.
            handler.reject(DioException(requestOptions: options));
          }
        },
      ),
    );
  }

  final List<List<Map<String, dynamic>>> pages;
  final bool hidden;
  final bool quality;
  bool failAppend = false;
  final dio = Dio();
  final requests = <_Browse>[];

  late final provider = AnimeWitcherNativeProvider(
    dio,
    SettingsRepository(_ArtworkSettings(quality)),
    isEcchiHidden: () => hidden,
  );
}

List<Map<String, dynamic>> _routePage(int page, _ProjectionWork work) => [
  for (var i = 0; i < 100; i++)
    _HitMap({
      'objectID': 'catalog-$page-${i % 80}',
      'name': 'Page $page Title $i',
      'story': _Story(work),
      'details': _HitMap({
        'state': 'لم يتم بثه بعد',
        'year': '2026 summer',
        'type': 'TV',
      }, work),
      'poster': _HitMap(<String, dynamic>{}, work),
      'rating': _HitMap({'rate': 9.2}, work),
      // The first row wins even when the duplicate omits its hidden tag.
      'tags': i < 20 ? ['Drama / إِيتْشِي_'] : ['Drama'],
    }, work),
];

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 24));
  }
}

void main() {
  for (final season in [true, false]) {
    testWidgets(
      '${season ? "Seasons" : "Coming Soon"} native projection skips discarded hits across two pages',
      (tester) async {
        final work = _ProjectionWork();
        final fixture = _BrowseFixture(
          pages: [_routePage(0, work), _routePage(1, work)],
        );
        addTearDown(fixture.dio.close);
        tester.view.physicalSize = const Size(410, 860);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              activeProviderProvider.overrideWithValue(fixture.provider),
            ],
            child: MaterialApp(
              home: season ? const SeasonsScreen() : const ComingSoonScreen(),
            ),
          ),
        );
        await _pump(tester);
        expect(find.text('Page 0 Title 20').hitTestable(), findsWidgets);
        expect(find.text('Page 0 Title 0'), findsNothing);
        expect(fixture.requests.map((request) => request.page), [0]);

        final view = tester.widget<ScrollView>(
          find
              .byWidgetPredicate(
                (widget) =>
                    widget is ScrollView &&
                    widget.controller?.hasClients == true,
              )
              .hitTestable()
              .first,
        );
        final position = view.controller!.position;
        position.jumpTo(position.maxScrollExtent);
        await _pump(tester);
        expect(fixture.requests.map((request) => request.page), [0, 1]);
        expect(fixture.requests.map((request) => request.limit), [100, 100]);
        expect(
          fixture.requests.map((request) => request.filters),
          everyElement(contains(season ? 'details.season' : 'details.state')),
        );
        position.jumpTo(position.maxScrollExtent - 1);
        await _pump(tester);
        final visible = tester.widgetList<MultimediaCard>(
          find.byType(MultimediaCard).hitTestable(),
        );
        expect(visible.map((card) => card.title), contains('Page 1 Title 79'));
        expect(fixture.requests, hasLength(2));
        expect(work.descriptions, 120);
        expect(work.copiedMaps, 0);
      },
    );
  }

  for (final season in [true, false]) {
    testWidgets(
      '${season ? "Seasons" : "Coming Soon"} holds a failed tail until Retry',
      (tester) async {
        final fixture = _BrowseFixture(
          pages: [
            for (var page = 0; page < 2; page++)
              [
                for (var i = 0; i < 60; i++)
                  {
                    'objectID': 'retry-$page-$i',
                    'name': 'Retry fixture $page title $i',
                  },
              ],
          ],
        )..failAppend = true;
        addTearDown(fixture.dio.close);
        tester.view.physicalSize = const Size(410, 860);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              activeProviderProvider.overrideWithValue(fixture.provider),
            ],
            child: MaterialApp(
              home: season ? const SeasonsScreen() : const ComingSoonScreen(),
            ),
          ),
        );
        await _pump(tester);
        expect(
          find.text('Retry fixture 0 title 0').hitTestable(),
          findsWidgets,
        );
        final view = tester.widget<ScrollView>(
          find
              .byWidgetPredicate(
                (widget) =>
                    widget is ScrollView &&
                    widget.controller?.hasClients == true,
              )
              .hitTestable()
              .first,
        );
        final position = view.controller!.position;
        final firstOffset = position.maxScrollExtent - 90;
        position.jumpTo(firstOffset);
        await _pump(tester);
        int appendAttempts() =>
            fixture.requests.where((request) => request.page == 1).length;
        // The native client's four host attempts in one failed page load.
        expect(appendAttempts(), 4);

        final gesture = await tester.startGesture(const Offset(200, 500));
        for (var i = 0; i < 16; i++) {
          await gesture.moveBy(Offset(0, i.isEven ? -36 : 36));
          await tester.pump(const Duration(milliseconds: 32));
        }
        await gesture.up();
        await _pump(tester);
        expect((position.pixels - firstOffset).abs(), lessThan(80));

        expect(appendAttempts(), 4);
        expect(
          fixture.requests.where((request) => request.page == 0),
          hasLength(1),
        );

        // Leave the 503 in place while bringing the actual footer on screen.
        position.jumpTo(position.maxScrollExtent);
        await _pump(tester);
        final retry = find.byTooltip('إعادة المحاولة').hitTestable();
        expect(retry, findsOneWidget);
        final attemptsBeforeRetry = appendAttempts();

        fixture.failAppend = false;
        await tester.tap(retry);
        await _pump(tester);
        expect(appendAttempts(), attemptsBeforeRetry + 1);
        expect(
          fixture.requests.where((request) => request.page == 0),
          hasLength(1),
        );
        expect(retry, findsNothing);

        position.jumpTo(position.maxScrollExtent - 1);
        await _pump(tester);
        final visible = tester.widgetList<MultimediaCard>(
          find.byType(MultimediaCard).hitTestable(),
        );
        expect(
          visible.map((card) => card.title),
          contains('Retry fixture 1 title 59'),
        );
        expect(appendAttempts(), attemptsBeforeRetry + 1);
      },
    );
  }

  test(
    'native browse keeps stable ids, first rows, casts and fallback order',
    () async {
      final fixture = _BrowseFixture(
        hidden: false,
        pages: [
          [
            {
              'name': 'First',
              'anime_id': ' ',
              'anime': {1: 'non-string-key', 'id': 'nested-id'},
              'series': {'id': 'do-not-use-series'},
              'doc_ref': 'anime_list/do-not-use-doc/',
              'objectID': 'do-not-use-object-id',
              'details':
                  '{"year":"Fall 2026","mal_id":"MAL 77b",'
                  '"state":"لم يتم بثه بعد","type":"ONA","dubbed":"مدبلج",'
                  '"english_title":"First English"}',
              'story': ' &lt;b&gt;First &amp; bright&lt;/b&gt; ',
              'poster_uri': ' https://cdn.myanimelist.net/small.jpg ',
              'poster': {
                'large': 'https://cdn.myanimelist.net/large.jpg',
                'medium': 'https://cdn.myanimelist.net/medium.jpg',
              },
              'poster_url_aniList': 'https://anilist.invalid/reachable.jpg',
              'cover_uri': 'https://cdn.myanimelist.net/cover.jpg',
              'tags': ['Drama', ' Drama ', null],
            },
            {'name': 'Wrong duplicate', 'anime_id': 'nested-id'},
            {
              'name': 'Second',
              'doc_ref': 'anime_list/document-id///',
              'objectID': 'ignore-this-id',
              'status': 'completed',
              'poster_uri': 'https://cdn.myanimelist.net/only-primary.jpg',
              'cover_uri': 'https://different.invalid/wide-last-resort.jpg',
            },
            {
              'name': 'Third',
              'objectID': 'simple-id',
              'cover_uri': 'https://different.invalid/only-wide.jpg',
            },
          ],
        ],
      );
      addTearDown(fixture.dio.close);
      addTearDown(() => seedMalArtworkReachability(false));

      seedMalArtworkReachability(false);
      Future<ProviderMediaPage> load() => fixture.provider.getUpcomingPage();
      final initial = await load();
      expect(initial.items.map((item) => item.title), [
        'First',
        'Second',
        'Third',
      ]);
      expect(initial.hasMore, false);
      expect(initial.nextOffset, 100);
      final first = initial.items.first;
      expect(first.url, endsWith('/watch/nested-id'));
      expect(first.description, 'First & bright');
      expect(first.year, 2026);
      expect(first.status, ShowStatus.upcoming);
      expect(first.catalogType, 'ONA');
      expect(first.isDubbed, true);
      expect(first.syncData?['malId'], '77');
      expect(first.syncData?['englishTitle'], 'First English');
      expect(first.tags, ['Drama']);
      expect(first.posterUrl, 'https://cdn.myanimelist.net/small.jpg');
      expect(first.fullPosterUrl, 'https://cdn.myanimelist.net/large.jpg');
      expect(initial.items[1].url, endsWith('/watch/document-id'));
      expect(initial.items[1].status, ShowStatus.completed);
      expect(
        initial.items[2].posterUrl,
        'https://different.invalid/only-wide.jpg',
      );

      seedMalArtworkReachability(true);
      final blocked = await load();
      expect(
        blocked.items.first.posterUrl,
        'https://anilist.invalid/reachable.jpg',
      );
      expect(blocked.items.first.fullPosterUrl, blocked.items.first.posterUrl);
      expect(
        blocked.items.first.bannerUrl,
        'https://cdn.myanimelist.net/cover.jpg',
      );
      expect(
        blocked.items[1].posterUrl,
        'https://cdn.myanimelist.net/only-primary.jpg',
      );

      final highQuality = _BrowseFixture(pages: fixture.pages, quality: true);
      addTearDown(highQuality.dio.close);
      seedMalArtworkReachability(false);
      final high = await highQuality.provider.getSeasonPage(
        'Catalog season 2026',
      );
      expect(
        high.items.first.posterUrl,
        'https://cdn.myanimelist.net/large.jpg',
      );
      expect(high.items.first.fullPosterUrl, high.items.first.posterUrl);
    },
  );
}
