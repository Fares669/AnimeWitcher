import 'dart:convert';
import 'dart:typed_data';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/animewitcher_native_provider.dart';
import 'package:animewitcher/core/network/dio_client_provider.dart';
import 'package:animewitcher/core/storage/settings_repository.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/search/data/mal_rankings.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Storage extends StorageService {
  final values = <String, String>{};

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

class _Catalogue extends AnimeWitcherNativeProvider {
  _Catalogue(this.available) : super(Dio(), SettingsRepository(_Storage()));

  final Set<int> available;
  final requestedIds = <List<int>>[];

  @override
  Future<List<MultimediaItem>> getAnimesByMalIds(List<int> malIds) async {
    requestedIds.add(malIds);
    return <MultimediaItem>[
      for (final id in malIds)
        if (available.contains(id))
          MultimediaItem(
            title: 'Anime $id',
            url: 'https://animewitcher.com/watch/$id',
            posterUrl: '',
          ),
    ];
  }
}

class _RankingsAdapter implements HttpClientAdapter {
  _RankingsAdapter(this.respond);

  final Map<String, dynamic> Function(RequestOptions) respond;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(respond(options)),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _rankingPage(List<int> ids, {required bool hasMore}) => {
  'data': {
    'Page': {
      'pageInfo': {'hasNextPage': hasMore},
      'media': [
        for (final id in ids) {'idMal': id},
      ],
    },
  },
};

void main() {
  test(
    'an empty first ten discovers rank eleven and keeps its source cursor',
    () async {
      final adapter = _RankingsAdapter((options) {
        final page = (options.data as Map)['variables']['page'] as int;
        return _rankingPage([
          for (var i = (page - 1) * 10 + 1; i <= page * 10; i++) i,
        ], hasMore: page < 3);
      });
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(_Storage()),
          activeProviderProvider.overrideWithValue(_Catalogue({11, 21})),
          dioClientProvider.overrideWithValue(
            Dio()..httpClientAdapter = adapter,
          ),
        ],
      );
      addTearDown(container.dispose);
      final seed = await container.read(
        homeMalRankingPageProvider(MalRanking.top).future,
      );
      expect(seed.items.single.title, 'Anime 11');
      expect(seed.nextOffset, 20);
      expect(seed.hasMore, isTrue);
      final next = await container.read(malRankingLoaderProvider)(
        MalRanking.top,
        seed.nextOffset,
      );
      expect(next.items.single.title, 'Anime 21');
      expect(next.nextOffset, 30);
      expect(next.hasMore, isFalse);
      expect(
        adapter.requests.map(
          (request) => (request.data as Map)['variables']['page'],
        ),
        [1, 2, 3],
      );
    },
  );

  test(
    'empty Home discovery is bounded and preserves access to further pages',
    () async {
      final adapter = _RankingsAdapter((_) => _rankingPage([1], hasMore: true));
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(_Storage()),
          activeProviderProvider.overrideWithValue(_Catalogue({})),
          dioClientProvider.overrideWithValue(
            Dio()..httpClientAdapter = adapter,
          ),
        ],
      );
      addTearDown(container.dispose);
      final seed = await container.read(
        homeMalRankingPageProvider(MalRanking.top).future,
      );
      expect(seed.items, isEmpty);
      expect(seed.nextOffset, 30);
      expect(seed.hasMore, isTrue);
      expect(adapter.requests, hasLength(3));
    },
  );

  test(
    'offline cached seed retains its sparse-page cursor and exhaustion',
    () async {
      final storage = _Storage();
      storage.values['mal_ranking_anilist_10_page_top'] = jsonEncode({
        'items': [
          MultimediaItem(
            title: 'Kept rank eleven',
            url: 'https://animewitcher.com/watch/11',
            posterUrl: '',
          ).toJson(),
        ],
        'nextOffset': 20,
        'hasMore': false,
      });
      final adapter = _RankingsAdapter((_) => throw StateError('offline'));
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          activeProviderProvider.overrideWithValue(_Catalogue({})),
          dioClientProvider.overrideWithValue(
            Dio()..httpClientAdapter = adapter,
          ),
        ],
      );
      addTearDown(container.dispose);
      final seed = await container.read(
        homeMalRankingPageProvider(MalRanking.top).future,
      );
      expect(seed.items.single.title, 'Kept rank eleven');
      expect(seed.nextOffset, 20);
      expect(seed.hasMore, isFalse);
    },
  );

  test(
    'legacy 25-entry snapshots cannot seed the new ten-entry cursor',
    () async {
      final storage = _Storage();
      storage.values['mal_ranking_top'] = jsonEncode({
        'items': [
          for (var i = 1; i <= 25; i++)
            MultimediaItem(
              title: 'Old $i',
              url: 'https://animewitcher.com/watch/old-$i',
              posterUrl: '',
            ).toJson(),
        ],
      });
      final adapter = _RankingsAdapter(
        (_) => _rankingPage([for (var i = 1; i <= 10; i++) i], hasMore: true),
      );
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          activeProviderProvider.overrideWithValue(
            _Catalogue({for (var i = 1; i <= 10; i++) i}),
          ),
          dioClientProvider.overrideWithValue(
            Dio()..httpClientAdapter = adapter,
          ),
        ],
      );
      addTearDown(container.dispose);
      final first = await container.read(
        malRankingProvider(MalRanking.top).future,
      );
      expect(first.map((item) => item.title), [
        for (var i = 1; i <= 10; i++) 'Anime $i',
      ]);
      expect(adapter.requests, hasLength(1));
      expect(storage.values['mal_ranking_anilist_10_page_top'], isNotNull);
    },
  );

  test(
    'a fresh first page replaces kept ranking titles before pagination',
    () async {
      final storage = _Storage();
      storage.values['mal_ranking_anilist_10_page_top'] = jsonEncode({
        'items': [
          for (var i = 1; i <= 5; i++)
            MultimediaItem(
              title: 'Kept $i',
              url: 'https://animewitcher.com/watch/$i',
              posterUrl: '',
            ).toJson(),
        ],
        'nextOffset': 10,
        'hasMore': true,
      });
      final adapter = _RankingsAdapter((options) {
        final page = (options.data as Map)['variables']['page'] as int;
        return _rankingPage([
          for (var i = (page - 1) * 10 + 1; i <= page * 10; i++) i,
        ], hasMore: page == 1);
      });
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          activeProviderProvider.overrideWithValue(
            _Catalogue({for (var i = 1; i <= 20; i++) i}),
          ),
          dioClientProvider.overrideWithValue(
            Dio()..httpClientAdapter = adapter,
          ),
        ],
      );
      addTearDown(container.dispose);
      final seed = await container.read(
        malRankingProvider(MalRanking.top).future,
      );
      final next = await container.read(malRankingLoaderProvider)(
        MalRanking.top,
        10,
      );
      expect(seed.map((item) => item.title), [
        for (var i = 1; i <= 10; i++) 'Anime $i',
      ]);
      expect(next.items.map((item) => item.title), [
        for (var i = 11; i <= 20; i++) 'Anime $i',
      ]);
      expect(next.nextOffset, 20);
      expect(next.hasMore, isFalse);
      expect(
        adapter.requests.map(
          (request) => (request.data as Map)['variables']['page'],
        ),
        [1, 2],
      );
    },
  );

  test(
    'ranking requests use ten real upstream entries and the next page',
    () async {
      final adapter = _RankingsAdapter((options) {
        final variables = (options.data as Map?)?['variables'] as Map?;
        final page = variables?['page'] as int? ?? 1;
        return _rankingPage([
          for (var id = (page - 1) * 10 + 1; id <= page * 10; id++) id,
        ], hasMore: page == 1);
      });
      final catalogue = _Catalogue({for (var id = 1; id <= 20; id++) id});
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWithValue(catalogue),
          dioClientProvider.overrideWithValue(
            Dio()..httpClientAdapter = adapter,
          ),
        ],
      );
      addTearDown(container.dispose);
      final load = container.read(malRankingLoaderProvider);

      final first = await load(MalRanking.top, 0);
      final next = await load(MalRanking.top, first.nextOffset);

      expect(first.items.length, 10);
      expect(first.nextOffset, 10);
      expect(first.hasMore, isTrue);
      expect(next.items.map((item) => item.title), [
        for (var id = 11; id <= 20; id++) 'Anime $id',
      ]);
      expect(next.nextOffset, 20);
      expect(next.hasMore, isFalse);
      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requests.every(
          (request) => request.uri.host == 'graphql.anilist.co',
        ),
        isTrue,
      );
      expect(
        [
          for (final request in adapter.requests)
            (request.data as Map)['variables']['page'],
        ],
        [1, 2],
      );
      expect(
        [
          for (final request in adapter.requests)
            (request.data as Map)['variables']['perPage'],
        ],
        [10, 10],
      );
    },
  );

  test(
    'sparse catalogue matches still advance the real upstream cursor',
    () async {
      final adapter = _RankingsAdapter((options) {
        final variables = (options.data as Map?)?['variables'] as Map?;
        final page = variables?['page'] as int? ?? 1;
        return _rankingPage(
          page == 1 ? [1, 2, 3] : [11, 12],
          hasMore: page == 1,
        );
      });
      final catalogue = _Catalogue({2, 12});
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWithValue(catalogue),
          dioClientProvider.overrideWithValue(
            Dio()..httpClientAdapter = adapter,
          ),
        ],
      );
      addTearDown(container.dispose);
      final load = container.read(malRankingLoaderProvider);

      final first = await load(MalRanking.airing, 0);
      final next = await load(MalRanking.airing, first.nextOffset);
      expect(first.items.single.title, 'Anime 2');
      expect(first.nextOffset, 10);
      expect(next.items.single.title, 'Anime 12');
      expect(next.nextOffset, 20);
      expect(next.hasMore, isFalse);
    },
  );

  test('an empty mapped page keeps upstream hasNextPage', () async {
    final adapter = _RankingsAdapter(
      (_) => _rankingPage([1, 2], hasMore: true),
    );
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWithValue(_Catalogue({})),
        dioClientProvider.overrideWithValue(Dio()..httpClientAdapter = adapter),
      ],
    );
    addTearDown(container.dispose);
    final page = await container.read(malRankingLoaderProvider)(
      MalRanking.popular,
      10,
    );
    expect(page.items, isEmpty);
    expect(page.nextOffset, 20);
    expect(page.hasMore, isTrue);
  });

  test('GraphQL errors and malformed pages remain retryable errors', () async {
    for (final body in <Map<String, dynamic>>[
      {
        'errors': [
          {'message': 'Rate limited'},
        ],
      },
      {
        'data': {'Page': null},
      },
    ]) {
      final adapter = _RankingsAdapter((_) => body);
      await expectLater(
        fetchMalRanking(Dio()..httpClientAdapter = adapter, MalRanking.top, 2),
        throwsStateError,
      );
    }
  });

  test(
    'ranking categories retain their AniList ordering and filters',
    () async {
      final adapter = _RankingsAdapter(
        (_) => _rankingPage([1], hasMore: false),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      for (final ranking in MalRanking.values) {
        await fetchMalRanking(dio, ranking, 1);
      }
      final variables = [
        for (final request in adapter.requests)
          (request.data as Map)['variables'] as Map,
      ];
      expect(variables.map((entry) => entry['sort']), [
        ['TRENDING_DESC'],
        ['SCORE_DESC'],
        ['POPULARITY_DESC'],
        ['SCORE_DESC'],
      ]);
      expect(variables[0]['status'], 'RELEASING');
      expect(variables[3]['format'], 'MOVIE');
    },
  );
}
