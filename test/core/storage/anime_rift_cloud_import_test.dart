import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/core/storage/anime_rift_cloud_sync.dart';
import 'package:animewitcher/core/storage/anime_rift_cloud_pending.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/provider_local_history.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _rift = 'com.animerift.provider';

class _MemoryStorage extends StorageService {
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

class _CountingStorage extends _MemoryStorage {
  int providerLibraryWrites = 0;

  @override
  Future<void> setString(String key, String? value) async {
    if (key.startsWith('provider_library_v1_')) providerLibraryWrites++;
    return super.setString(key, value);
  }
}

class _CloudReader
    implements AnimeRiftCloudAccountReader, AnimeRiftCloudPagedReader {
  bool linked = true;
  String? restoredAccountId;
  final favorites = <Object>[];
  final lists = <String, List<Object>>{};
  final history = <Object>[];
  Completer<Map<String, dynamic>>? favoritesGate;
  Completer<Map<String, dynamic>>? listGate;
  Completer<Map<String, dynamic>>? overviewGate;
  bool completeOverview = true;
  bool staleHasNext = false;
  final requests = <String>[];
  int overviewCalls = 0;
  int? pageSize;
  int pageBase = 1;
  int? failOnPage;
  Object? pageFailure;
  bool ignorePage = false;
  Completer<Map<String, dynamic>>? pageGate;

  Map<String, dynamic> _paged(List<Object> all, {int? page}) {
    final limit = pageSize;
    if (limit == null) return {'items': all};
    final first = page == null || ignorePage;
    final start = first ? 0 : ((page - pageBase) * limit).clamp(0, all.length);
    final end = (start + limit).clamp(0, all.length);
    return {
      'items': all.sublist(start, end),
      'hasNext': staleHasNext || end < all.length,
    };
  }

  @override
  Future<bool> restoreAccountSession() async {
    if (linked && restoredAccountId != null) {
      AnimeRiftLocalAccountScope.activate(restoredAccountId!);
    }
    return linked;
  }

  @override
  Future<Map<String, dynamic>> fetchMyListOverview() async {
    overviewCalls++;
    if (overviewGate != null) return overviewGate!.future;
    return {
      'items': {
        'my_list_favorites': favorites.length,
        if (completeOverview) ...{
          'my_list_currently_watching': lists['currently']?.length ?? 0,
          'my_list_plan_to_watch': lists['want_to']?.length ?? 0,
          'my_list_finished_watching': lists['finished']?.length ?? 0,
          'my_list_on_hold': lists['later']?.length ?? 0,
          'my_list_dropped': lists['dropped']?.length ?? 0,
        },
      },
    };
  }

  @override
  Future<Map<String, dynamic>> fetchFavoriteAnime() => (() {
    requests.add('favorite');
    return favoritesGate?.future ?? Future.value({'items': favorites});
  })();

  @override
  Future<Map<String, dynamic>> fetchMyList(String category) async {
    requests.add(category);
    if (listGate != null) return listGate!.future;
    return _paged(lists[category] ?? <Object>[]);
  }

  @override
  Future<Map<String, dynamic>> fetchMyListPage(
    String category,
    int page,
  ) async {
    requests.add('$category:page:$page');
    if (page == failOnPage) {
      throw pageFailure ?? const AnimeRiftAccessUnavailable();
    }
    if (pageGate != null) return pageGate!.future;
    return _paged(lists[category] ?? <Object>[], page: page);
  }

  @override
  Future<Map<String, dynamic>> fetchFavoriteAnimePage(int page) async {
    requests.add('favorite:page:$page');
    if (page == failOnPage) {
      throw pageFailure ?? const AnimeRiftAccessUnavailable();
    }
    return _paged(favorites, page: page);
  }

  @override
  Future<Map<String, dynamic>> fetchWatchHistoryLatest() async {
    requests.add('history-latest');
    return {'items': history};
  }

  @override
  Future<Map<String, dynamic>> fetchWatchHistoryFull() async {
    requests.add('history-full');
    return {'items': history};
  }
}

void main() {
  tearDown(AnimeRiftLocalAccountScope.reset);

  test(
    'three confirmed Rift items ignore stale hasNext without page requests',
    () async {
      AnimeRiftLocalAccountScope.activate('three-items');
      final reader = _CloudReader()
        ..pageSize = 30
        ..staleHasNext = true
        ..lists['currently'] = [
          for (var i = 0; i < 3; i++)
            {
              'anime': {'_id': 'three$i', 'title': 'Title $i'},
            },
        ];
      final cloud = AnimeRiftCloudSync(reader);
      final storage = _MemoryStorage();
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.watching,
      );
      expect(cloud.selectedListPage(LibraryCategory.watching)?.loadedCount, 3);
      expect(cloud.selectedListPage(LibraryCategory.watching)?.totalCount, 3);
      expect(
        cloud.selectedListPage(LibraryCategory.watching)?.hasMore,
        isFalse,
      );
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.watching,
        loadNextPage: true,
      );
      expect(reader.requests, ['currently']);
    },
  );

  test(
    'opening multiple Rift shelves reuses one authenticated overview',
    () async {
      AnimeRiftLocalAccountScope.activate('overview-shared');
      final reader = _CloudReader()
        ..lists['currently'] = [
          {
            'anime': {'_id': 'watch1', 'title': 'Watching'},
          },
        ]
        ..lists['finished'] = [
          {
            'anime': {'_id': 'finish1', 'title': 'Finished'},
          },
        ];
      final cloud = AnimeRiftCloudSync(reader);
      final storage = _MemoryStorage();
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.watching,
      );
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.completed,
      );
      expect(reader.requests, ['currently', 'finished']);
      expect(reader.overviewCalls, 1);
    },
  );

  test(
    'Rift list and overview begin together instead of serial GETs',
    () async {
      AnimeRiftLocalAccountScope.activate('parallel-overview');
      final reader = _CloudReader()
        ..pageSize = 30
        ..listGate = Completer<Map<String, dynamic>>()
        ..overviewGate = Completer<Map<String, dynamic>>();
      final cloud = AnimeRiftCloudSync(reader);
      final pending = cloud.importSelectedList(
        storage: _MemoryStorage(),
        category: LibraryCategory.watching,
      );
      try {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(reader.requests, ['currently']);
        expect(
          reader.overviewCalls,
          1,
          reason: 'Overview must not wait for the slow list request',
        );
      } finally {
        reader.listGate!.complete({'items': <Object>[]});
        reader.overviewGate!.complete({
          'items': {'my_list_currently_watching': 0},
        });
      }
      await pending;
    },
  );

  test('three legacy Rift cards fetch missing details concurrently', () async {
    AnimeRiftLocalAccountScope.activate('legacy-three');
    final reader = _CloudReader()
      ..lists['currently'] = [
        for (var i = 0; i < 3; i++)
          {
            'anime': {'_id': 'legacy$i'},
          },
      ];
    final cloud = AnimeRiftCloudSync(reader);
    final blocked = Completer<void>();
    var calls = 0;
    final future = cloud.importSelectedList(
      storage: _MemoryStorage(),
      category: LibraryCategory.watching,
      hydrate: (url) async {
        calls++;
        await blocked.future;
        return MultimediaItem(
          url: url,
          title: 'Full ${url.split('/').last}',
          posterUrl: '',
          provider: _rift,
          contentType: MultimediaContentType.anime,
        );
      },
    );
    try {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 3);
    } finally {
      blocked.complete();
    }
    await future;
  });

  test('30 Rift records persist as one local library write', () async {
    AnimeRiftLocalAccountScope.activate('bulk-library');
    final storage = _CountingStorage();
    final reader = _CloudReader()
      ..pageSize = 30
      ..lists['currently'] = [
        for (var i = 0; i < 30; i++)
          {
            'anime': {'_id': 'bulk$i', 'title': 'Bulk $i'},
          },
      ];
    await AnimeRiftCloudSync(
      reader,
    ).importSelectedList(storage: storage, category: LibraryCategory.watching);
    expect(storage.providerLibraryWrites, 1);
    expect(
      ProviderLocalLibrary(storage, _rift).items(LibraryCategory.watching),
      hasLength(30),
    );
  });

  test(
    'visible shelf imports 30 then explicitly advances with server total',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..pageSize = 30
        ..lists['finished'] = [
          for (var n = 0; n < 95; n++)
            {
              'anime': {'_id': 'lazy$n', 'title': 'Lazy $n'},
            },
        ];
      final cloud = AnimeRiftCloudSync(reader);
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.completed,
      );
      expect(reader.requests, ['finished']);
      expect(cloud.selectedListPage(LibraryCategory.completed)?.totalCount, 95);
      expect(
        cloud.selectedListPage(LibraryCategory.completed)?.loadedCount,
        30,
      );
      expect(
        cloud.selectedListPage(LibraryCategory.completed)?.hasMore,
        isTrue,
      );
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.completed,
        loadNextPage: true,
      );
      expect(reader.overviewCalls, 1);
      expect(
        cloud.selectedListPage(LibraryCategory.completed)?.loadedCount,
        60,
      );
      expect(
        ProviderLocalLibrary(storage, _rift).items(LibraryCategory.completed),
        hasLength(60),
      );
      AnimeRiftLocalAccountScope.activate('bob');
      expect(cloud.selectedListPage(LibraryCategory.completed), isNull);
    },
  );

  test('startup reads first page only without hidden page requests', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final storage = _MemoryStorage();
    final reader = _CloudReader()
      ..pageSize = 30
      ..lists['finished'] = [
        for (var n = 0; n < 290; n++)
          {
            'anime': {'_id': 'startup$n', 'title': 'Series $n'},
          },
      ];
    final cloud = AnimeRiftCloudSync(reader);
    final result = await cloud.importToLocal(storage: storage);
    expect(result.categories, 30);
    expect(
      reader.requests.where((request) => request.contains(':page:')),
      isEmpty,
    );
    expect(cloud.selectedListPage(LibraryCategory.completed)?.totalCount, 290);
  });

  test('a full Rift list response feeds additional 30-card pages without duplicate GETs', () async {
    AnimeRiftLocalAccountScope.activate('single-response');
    final storage = _MemoryStorage();
    final reader = _CloudReader()
      ..lists['finished'] = [
        for (var i = 0; i < 74; i++)
          {
            'anime': {'_id': 'full$i', 'title': 'Full $i'},
          },
      ];
    final cloud = AnimeRiftCloudSync(reader);
    for (final expected in [30, 60, 74]) {
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.completed,
        loadNextPage: expected != 30,
      );
      expect(
        cloud.selectedListPage(LibraryCategory.completed)?.loadedCount,
        expected,
      );
    }
    expect(cloud.selectedListPage(LibraryCategory.completed)?.hasMore, false);
    expect(reader.requests, ['finished']);
  });

  test(
    'one selected Rift shelf reports server totals for unopened tabs',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final reader = _CloudReader()
        ..lists['currently'] = [
          {
            'anime': {'_id': 'watching1', 'title': 'Watching'},
          },
        ]
        ..lists['finished'] = [
          for (var i = 0; i < 42; i++)
            {
              'anime': {'_id': 'finished$i', 'title': 'Finished'},
            },
        ];
      final cloud = AnimeRiftCloudSync(reader);
      await cloud.importSelectedList(
        storage: _MemoryStorage(),
        category: LibraryCategory.watching,
      );
      expect(reader.requests, ['currently']);
      expect(cloud.serverListTotal(LibraryCategory.watching), 1);
      expect(cloud.serverListTotal(LibraryCategory.completed), 42);
      expect(cloud.selectedListUrls(LibraryCategory.watching), [
        'https://anime-rift.com/anime/watching1',
      ]);
      AnimeRiftLocalAccountScope.activate('bob');
      expect(cloud.serverListTotal(LibraryCategory.completed), isNull);
      expect(cloud.selectedListUrls(LibraryCategory.watching), isNull);
    },
  );

  for (final base in [0, 1]) {
    test('explicit pages complete a $base-based shelf and stop', () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..pageSize = 30
        ..pageBase = base
        ..lists['finished'] = [
          for (var n = 0; n < 95; n++)
            {
              'anime': {'_id': 'page$n', 'title': 'Series $n'},
            },
        ];
      final cloud = AnimeRiftCloudSync(reader);
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.completed,
      );
      for (var n = 0; n < 3; n++) {
        await cloud.importSelectedList(
          storage: storage,
          category: LibraryCategory.completed,
          loadNextPage: true,
        );
      }
      expect(
        cloud.selectedListPage(LibraryCategory.completed)?.loadedCount,
        95,
      );
      expect(
        cloud.selectedListPage(LibraryCategory.completed)?.hasMore,
        isFalse,
      );
      final requestCount = reader.requests.length;
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.completed,
        loadNextPage: true,
      );
      expect(reader.requests, hasLength(requestCount));
      expect(
        ProviderLocalLibrary(storage, _rift).items(LibraryCategory.completed),
        hasLength(95),
      );
    });
  }

  test(
    'partial refresh preserves items beyond first page and pending edits',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..pageSize = 30
        ..lists['finished'] = [
          for (var n = 0; n < 60; n++)
            {
              'anime': {'_id': 'saved$n', 'title': 'Saved $n'},
            },
        ];
      final cloud = AnimeRiftCloudSync(reader);
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.completed,
      );
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.completed,
        loadNextPage: true,
      );
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.completed,
      );
      expect(
        ProviderLocalLibrary(storage, _rift).items(LibraryCategory.completed),
        hasLength(60),
      );
    },
  );

  test(
    'failed page retries same cursor and account switch prevents import',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..pageSize = 30
        ..pageBase = 0
        ..lists['finished'] = [
          for (var n = 0; n < 60; n++)
            {
              'anime': {'_id': 'alice$n', 'title': 'Alice $n'},
            },
        ];
      final cloud = AnimeRiftCloudSync(reader);
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.completed,
      );
      reader.failOnPage = 1;
      reader.pageFailure = const AnimeRiftAccessUnavailable(statusCode: 403);
      await expectLater(
        cloud.importSelectedList(
          storage: storage,
          category: LibraryCategory.completed,
          loadNextPage: true,
        ),
        throwsA(isA<AnimeRiftAccessUnavailable>()),
      );
      expect(
        cloud.selectedListPage(LibraryCategory.completed)?.loadedCount,
        30,
      );
      reader.failOnPage = null;
      reader.pageGate = Completer<Map<String, dynamic>>();
      final loading = cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.completed,
        loadNextPage: true,
      );
      final checked = expectLater(
        loading,
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      await Future<void>.delayed(Duration.zero);
      AnimeRiftLocalAccountScope.activate('bob');
      reader.pageGate!.complete({
        'items': [
          {
            'anime': {'_id': 'alice30', 'title': 'Private'},
          },
        ],
      });
      await checked;
      expect(ProviderLocalLibrary(storage, _rift).allItems(), isEmpty);
      expect(cloud.selectedListPage(LibraryCategory.completed), isNull);
    },
  );

  test('server ignoring cursor stops after bounded duplicate probes', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final storage = _MemoryStorage();
    final reader = _CloudReader()
      ..pageSize = 30
      ..ignorePage = true
      ..lists['finished'] = [
        for (var n = 0; n < 290; n++)
          {
            'anime': {'_id': 'ignored$n', 'title': 'Series $n'},
          },
      ];
    final cloud = AnimeRiftCloudSync(reader);
    await cloud.importSelectedList(
      storage: storage,
      category: LibraryCategory.completed,
    );
    expect(reader.requests, ['finished']);
    await cloud.importSelectedList(
      storage: storage,
      category: LibraryCategory.completed,
      loadNextPage: true,
    );
    expect(reader.requests, ['finished', 'finished:page:1', 'finished:page:2']);
    expect(cloud.selectedListPage(LibraryCategory.completed)?.hasMore, isFalse);
    expect(cloud.selectedListPage(LibraryCategory.completed)?.loadedCount, 30);
  });

  test('large first response is capped at 30 without detail fanout', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final storage = _MemoryStorage();
    var detailsCalls = 0;
    final reader = _CloudReader()
      ..lists['finished'] = [
        for (var n = 0; n < 290; n++)
          {
            'anime': {'_id': 'id$n'},
          },
      ];
    final result = await AnimeRiftCloudSync(reader).importSelectedList(
      storage: storage,
      category: LibraryCategory.completed,
      hydrate: (url) async {
        detailsCalls++;
        throw const AnimeRiftAccessUnavailable();
      },
    );
    expect(result.categories, 30);
    expect(result.skipped, 0);
    expect(detailsCalls, 0);
    expect(
      ProviderLocalLibrary(storage, _rift).items(LibraryCategory.completed),
      hasLength(30),
    );
  });

  test(
    'opening one Rift shelf reads only that shelf and leaves others cached',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..lists['currently'] = [
          {
            'anime': {'_id': 'watch1', 'title': 'Currently watching'},
          },
        ]
        ..lists['finished'] = [
          {
            'anime': {'_id': 'finish1', 'title': 'Finished already'},
          },
        ];
      final cloud = AnimeRiftCloudSync(reader);
      final library = ProviderLocalLibrary(storage, _rift);
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.watching,
      );
      expect(reader.requests, ['currently']);
      expect(
        library.items(LibraryCategory.watching).single.title,
        'Currently watching',
      );
      expect(library.items(LibraryCategory.completed), isEmpty);

      reader.requests.clear();
      await cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.completed,
      );
      expect(reader.requests, ['finished']);
      expect(
        library.items(LibraryCategory.watching).single.title,
        'Currently watching',
      );
      expect(
        library.items(LibraryCategory.completed).single.title,
        'Finished already',
      );
    },
  );

  test(
    'Rift history refresh does not fetch every cloud library list',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..history.add({
          'anime': {'_id': 'history-one', 'title': 'From Rift'},
          'last_episode_viewed': 4,
        })
        ..lists['currently'] = [
          {
            'anime': {'_id': 'watch1', 'title': 'Watching'},
          },
        ];
      final result = await AnimeRiftCloudSync(reader)
          .importHistoryToLocal(storage: storage);
      expect(reader.requests, ['history-full']);
      expect(result.history, 1);
      final history = ProviderLocalHistory(storage, _rift);
      expect(history.continueWatching().single.episode, 4);
      expect(
        ProviderLocalLibrary(storage, _rift).items(LibraryCategory.watching),
        isEmpty,
      );
    },
  );

  test(
    'large Rift watch history does not issue a detail request per item',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..history.addAll([
          for (var n = 0; n < 35; n++)
            {
              'anime': {'_id': 'watched$n'},
              'last_episode_viewed': n + 1,
            },
        ]);
      var details = 0;
      Future<MultimediaItem?> hydrate(String url) async {
        details++;
        return MultimediaItem(
          title: 'Loaded',
          posterUrl: '',
          url: url,
          provider: _rift,
        );
      }

      final cloud = AnimeRiftCloudSync(reader);
      final result = await cloud.importHistoryToLocal(
        storage: storage,
        hydrate: hydrate,
      );
      expect(result.history, 35);
      expect(details, 0);
      await cloud.importToLocal(storage: storage, hydrate: hydrate);
      expect(details, 0);
      expect(ProviderLocalHistory(storage, _rift).history(), hasLength(35));
    },
  );

  test(
    'account switching during a Rift shelf GET cannot import foreign rows',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..favoritesGate = Completer<Map<String, dynamic>>();
      final cloud = AnimeRiftCloudSync(reader);
      final loading = cloud.importSelectedList(
        storage: storage,
        category: LibraryCategory.favorite,
      );
      // Wait for the request to enter its first awaited HTTP read.
      await Future<void>.delayed(Duration.zero);
      expect(reader.requests, ['favorite']);
      AnimeRiftLocalAccountScope.activate('bob');
      reader.favoritesGate!.complete({
        'items': [
          {
            'anime': {'_id': 'alice-only', 'title': 'Private'},
          },
        ],
      });
      await expectLater(
        loading,
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(
        ProviderLocalLibrary(storage, _rift).items(LibraryCategory.favorite),
        isEmpty,
      );
    },
  );

  test('Rift list cache stays intact offline and incomplete snapshots cannot delete', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final storage = _MemoryStorage();
    final reader = _CloudReader()
      ..lists['currently'] = [
        {
          'anime': {'_id': 'cached1', 'title': 'Cached anime'},
        },
      ];
    final cloud = AnimeRiftCloudSync(reader);
    final library = ProviderLocalLibrary(storage, _rift);
    final url = 'https://anime-rift.com/anime/cached1';
    await cloud.importSelectedList(
      storage: storage,
      category: LibraryCategory.watching,
    );
    reader.lists['currently'] = [];
    reader.completeOverview = false;
    await cloud.importSelectedList(
      storage: storage,
      category: LibraryCategory.watching,
    );
    expect(library.category(url), LibraryCategory.watching);
    reader.completeOverview = true;
    await cloud.importSelectedList(
      storage: storage,
      category: LibraryCategory.watching,
    );
    expect(library.category(url), isNull);
  });

  test('Rift direct shelf refresh preserves local pending edits and account isolation', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final storage = _MemoryStorage();
    final reader = _CloudReader()
      ..lists['currently'] = [
        {
          'anime': {'_id': 'shared', 'title': 'Remote version'},
        },
      ];
    final url = 'https://anime-rift.com/anime/shared';
    final library = ProviderLocalLibrary(storage, _rift);
    final local = MultimediaItem(
      title: 'Local version',
      url: url,
      posterUrl: '',
      provider: _rift,
    );
    await library.setCategory(local, LibraryCategory.completed);
    await AnimeRiftCloudPendingJournal(storage)
        .queueCategory(url, LibraryCategory.completed);
    await AnimeRiftCloudSync(
      reader,
    ).importSelectedList(storage: storage, category: LibraryCategory.watching);
    expect(library.category(url), LibraryCategory.completed);
    AnimeRiftLocalAccountScope.activate('bob');
    expect(
      ProviderLocalLibrary(storage, _rift).items(LibraryCategory.completed),
      isEmpty,
    );
  });

  test(
    'native finished list imports into the completed library category',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..lists['finished'] = [
          {
            'anime': {'_id': 'done1', 'title': 'Finished anime'},
          },
        ];
      await AnimeRiftCloudSync(reader).importToLocal(storage: storage);
      expect(
        ProviderLocalLibrary(
          storage,
          _rift,
        ).category('https://anime-rift.com/anime/done1'),
        LibraryCategory.completed,
      );
    },
  );

  test(
    'remote category moves update local items without overriding pending edits',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..lists['currently'] = [
          {
            'anime': {'_id': 'move1', 'title': 'Moved'},
          },
        ];
      final cloud = AnimeRiftCloudSync(reader);
      final url = 'https://anime-rift.com/anime/move1';
      final library = ProviderLocalLibrary(storage, _rift);
      await cloud.importToLocal(storage: storage);
      expect(library.category(url), LibraryCategory.watching);
      reader.lists['currently'] = [];
      reader.lists['finished'] = [
        {
          'anime': {'_id': 'move1', 'title': 'Moved'},
        },
      ];
      await cloud.importToLocal(storage: storage);
      expect(library.category(url), LibraryCategory.completed);

      final pending = AnimeRiftCloudPendingJournal(storage);
      await pending.queueCategory(url, LibraryCategory.planToWatch);
      await library.setCategory(
        library.item(url)!,
        LibraryCategory.planToWatch,
      );
      reader.lists['finished'] = [];
      reader.lists['dropped'] = [
        {
          'anime': {'_id': 'move1', 'title': 'Moved'},
        },
      ];
      await cloud.importToLocal(storage: storage);
      expect(library.category(url), LibraryCategory.planToWatch);
    },
  );

  test(
    'complete remote list removal clears only previously synced items',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..lists['currently'] = [
          {
            'anime': {'_id': 'old1', 'title': 'Server item'},
          },
        ];
      final cloud = AnimeRiftCloudSync(reader);
      final library = ProviderLocalLibrary(storage, _rift);
      await cloud.importToLocal(storage: storage);
      final oldUrl = 'https://anime-rift.com/anime/old1';
      expect(library.category(oldUrl), LibraryCategory.watching);
      final local = MultimediaItem(
        title: 'Local only',
        url: 'https://anime-rift.com/anime/local1',
        posterUrl: '',
        provider: _rift,
      );
      await library.setCategory(local, LibraryCategory.watching);

      reader.lists['currently'] = [];
      reader.completeOverview = false;
      await cloud.importToLocal(storage: storage);
      expect(
        library.category(oldUrl),
        LibraryCategory.watching,
        reason: 'Missing server totals cannot authorize deletions',
      );

      reader.completeOverview = true;
      await cloud.importToLocal(storage: storage);
      expect(library.category(oldUrl), isNull);
      expect(
        library.category('https://anime-rift.com/anime/local1'),
        LibraryCategory.watching,
        reason: 'Unrelated local-only items must not be deleted',
      );
    },
  );

  test(
    'complete remote favorite removal preserves other list memberships',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..favorites.add({
          'anime': {'_id': 'fav2', 'title': 'Favorite item'},
        })
        ..lists['currently'] = [
          {
            'anime': {'_id': 'fav2', 'title': 'Favorite item'},
          },
        ];
      final library = ProviderLocalLibrary(storage, _rift);
      final cloud = AnimeRiftCloudSync(reader);
      final url = 'https://anime-rift.com/anime/fav2';
      await cloud.importToLocal(storage: storage);
      expect(library.isFavorite(url), isTrue);
      reader.favorites.clear();
      await cloud.importToLocal(storage: storage);
      expect(library.isFavorite(url), isFalse);
      expect(library.category(url), LibraryCategory.watching);
    },
  );

  test(
    'Rift watched episode arrays import without overriding unuploaded unmarks',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..history.add({
          'anime': {'_id': 'resume9', 'title': 'Remote watched'},
          'last_episode_viewed': 9,
          'watched_episodes': [7, 9],
          'not_watched_episodes': [8],
        });
      final cloud = AnimeRiftCloudSync(reader);
      final local = ProviderLocalHistory(storage, _rift);
      final url = 'https://anime-rift.com/anime/resume9';
      Episode numbered(int number) => Episode(
        name: 'Episode $number',
        url: '$url/episode/opaque-$number',
        episode: number,
      );
      await cloud.importToLocal(storage: storage);
      expect(local.isWatched(url, numbered(7)), isTrue);
      expect(local.isWatched(url, numbered(8)), isFalse);
      expect(local.isWatched(url, numbered(9)), isTrue);

      await local.setWatched(url, numbered(9), false);
      await AnimeRiftCloudPendingJournal(storage).queueWatched(url, 9, false);
      await cloud.importToLocal(storage: storage);
      expect(local.isWatched(url, numbered(9)), isFalse);
    },
  );

  test(
    'explicit server watched episode strings import without inferring gaps',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..history.add({
          'anime': {'_id': 'mixed8', 'title': 'Watched'},
          'last_episode_viewed': {'episode_number': '8'},
          'watched_episodes': [
            '3',
            {'episode_number': '8'},
          ],
          'not_watched_episodes': [
            {'episode_number': '5'},
          ],
        });
      await AnimeRiftCloudSync(reader).importHistoryToLocal(storage: storage);
      final history = ProviderLocalHistory(storage, _rift);
      const url = 'https://anime-rift.com/anime/mixed8';
      Episode episode(int n) =>
          Episode(name: 'Episode $n', url: '$url/episode/$n', episode: n);
      expect(history.isWatched(url, episode(3)), true);
      expect(history.isWatched(url, episode(5)), false);
      expect(history.isWatched(url, episode(8)), true);
      expect(history.isWatched(url, episode(4)), isNull);
    },
  );

  test('imports real cloud favorites, categories and watched titles', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final storage = _MemoryStorage();
    final library = ProviderLocalLibrary(storage, _rift);
    final history = ProviderLocalHistory(storage, _rift);
    final reader = _CloudReader()
      ..favorites.add({
        'anime': {'_id': 'fav1', 'title': 'Favorite anime'},
      })
      ..lists['currently'] = [
        {
          'anime': {'_id': 'active1', 'title': 'Watching anime'},
        },
      ]
      ..lists['want_to'] = [
        {
          'anime': {'_id': 'future1', 'title': 'Watch later'},
        },
      ]
      ..history.add({
        'anime': {'_id': 'watched1', 'title': 'Watched anime'},
      });

    final result = await AnimeRiftCloudSync(reader)
        .importToLocal(storage: storage);

    expect(result.favorites, 1);
    expect(result.categories, 2);
    expect(result.history, 1);
    expect(library.isFavorite('https://anime-rift.com/anime/fav1'), isTrue);
    expect(
      library.category('https://anime-rift.com/anime/active1'),
      LibraryCategory.watching,
    );
    expect(
      library.category('https://anime-rift.com/anime/future1'),
      LibraryCategory.planToWatch,
    );
    expect(history.history().single.item.title, 'Watched anime');

    // Repeated imports must remain idempotent and cannot erase local favorites.
    await AnimeRiftCloudSync(reader).importToLocal(storage: storage);
    expect(library.allItems(), hasLength(3));
    expect(history.history(), hasLength(1));
  });

  test('Rift last watched episode appears in Continue Watching without inventing seconds', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final storage = _MemoryStorage();
    final reader = _CloudReader()
      ..history.add({
        'anime': {'_id': 'resume7', 'title': 'Remote resume'},
        'last_episode_viewed': 7,
      });
    await AnimeRiftCloudSync(reader).importToLocal(storage: storage);
    final history = ProviderLocalHistory(storage, _rift);
    expect(history.history().single.episode, 7);
    final lastEpisode = Episode(
      name: 'Episode 7',
      url: 'https://anime-rift.com/anime/resume7/episode/safe-7',
      episode: 7,
    );
    final preceding = Episode(
      name: 'Episode 6',
      url: 'https://anime-rift.com/anime/resume7/episode/safe-6',
      episode: 6,
    );
    expect(
      history.isWatched('https://anime-rift.com/anime/resume7', lastEpisode),
      isTrue,
      reason: 'A server-confirmed last viewed episode is watched',
    );
    expect(
      history.isWatched('https://anime-rift.com/anime/resume7', preceding),
      isNull,
      reason: 'Do not guess earlier episodes were all watched',
    );
    final entry = history.continueWatching().single;
    expect(entry.item.title, 'Remote resume');
    expect(entry.episode, 7);
    expect(entry.lastEpisodeUrl?.isEmpty ?? true, isTrue);
    expect(entry.position, 0);
    expect(entry.duration, 0);

    // Existing precise device playback must not be replaced by remote title
    // and episode metadata that do not include a position in seconds.
    final item = entry.item;
    await history.saveProgress(item, 123, 456, episode: 8);
    await AnimeRiftCloudSync(reader).importToLocal(storage: storage);
    expect(history.continueWatching().single.episode, 8);
    expect(history.continueWatching().single.position, 123);
    expect(history.continueWatching().single.duration, 456);
  });

  test(
    'account switches during the response never populate another user',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()..favoritesGate = Completer();
      final task = AnimeRiftCloudSync(reader).importToLocal(storage: storage);
      final checked = expectLater(
        task,
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      await Future<void>.delayed(Duration.zero);
      AnimeRiftLocalAccountScope.activate('bob');
      reader.favoritesGate!.complete({
        'items': [
          {
            'anime': {'_id': 'secret', 'title': 'Alice only'},
          },
        ],
      });
      await checked;
      expect(ProviderLocalLibrary(storage, _rift).allItems(), isEmpty);
      AnimeRiftLocalAccountScope.activate('alice');
      expect(ProviderLocalLibrary(storage, _rift).allItems(), isEmpty);
    },
  );

  test(
    'guests and unrecognized cloud rows cannot claim a successful import',
    () async {
      final storage = _MemoryStorage();
      await expectLater(
        AnimeRiftCloudSync(_CloudReader()).importToLocal(storage: storage),
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      AnimeRiftLocalAccountScope.activate('alice');
      final bad = _CloudReader()
        ..favorites.add({'unknownServerRow': 'private'});
      final result = await AnimeRiftCloudSync(bad)
          .importToLocal(storage: storage);
      expect(result.favorites, 0);
      expect(result.skipped, 1);
      expect(ProviderLocalLibrary(storage, _rift).allItems(), isEmpty);
    },
  );

  test(
    'a valid catalog ID can be hydrated when cloud list has no title',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final reader = _CloudReader()..favorites.add({'anime_id': 'identifier1'});
      final result = await AnimeRiftCloudSync(reader).importToLocal(
        storage: storage,
        hydrate: (url) async => MultimediaItem(
          title: 'Resolved anime',
          url: url,
          posterUrl: '',
          provider: _rift,
        ),
      );
      expect(result.favorites, 1);
      expect(
        ProviderLocalLibrary(storage, _rift).allItems().single.title,
        'Resolved anime',
      );
    },
  );

  test(
    'cold-start restore imports to linked account, not guest storage',
    () async {
      final storage = _MemoryStorage();
      final reader = _CloudReader()
        ..restoredAccountId = 'alice'
        ..favorites.add({
          'anime': {'_id': 'linked1', 'title': 'Linked only'},
        });
      final guestKey = ProviderLocalLibrary(storage, _rift).storageKey;

      final imported = await AnimeRiftCloudSync(reader)
          .importToLocal(storage: storage);
      expect(imported.favorites, 1);
      expect(
        ProviderLocalLibrary(
          storage,
          _rift,
        ).isFavorite('https://anime-rift.com/anime/linked1'),
        isTrue,
      );
      expect(storage.values.containsKey(guestKey), isFalse);
    },
  );

  test('cloud list membership ID cannot replace its actual anime ID', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final storage = _MemoryStorage();
    final reader = _CloudReader()
      ..favorites.add({
        '_id': 'membership1',
        'anime_id': 'actual1',
        'title': 'Actual anime',
      })
      ..favorites.add({'anime': 'actual2', 'title': 'Other anime'});

    final imported = await AnimeRiftCloudSync(reader)
        .importToLocal(storage: storage);
    expect(imported.favorites, 2);
    final library = ProviderLocalLibrary(storage, _rift);
    expect(library.isFavorite('https://anime-rift.com/anime/actual1'), isTrue);
    expect(library.isFavorite('https://anime-rift.com/anime/actual2'), isTrue);
    expect(
      library.isFavorite('https://anime-rift.com/anime/membership1'),
      isFalse,
    );
  });

  test('one unavailable anime detail remains available by its confirmed catalog ID', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final storage = _MemoryStorage();
    final reader = _CloudReader()
      ..favorites.add({'anime_id': 'offlineDetails'})
      ..favorites.add({
        'anime': {'_id': 'valid', 'title': 'Visible favorite'},
      });
    final result = await AnimeRiftCloudSync(reader).importToLocal(
      storage: storage,
      hydrate: (_) async => throw const AnimeRiftAccessUnavailable(),
    );
    expect(result.favorites, 2);
    expect(result.skipped, 0);
    expect(
      ProviderLocalLibrary(
        storage,
        _rift,
      ).isFavorite('https://anime-rift.com/anime/offlineDetails'),
      isTrue,
    );
    expect(
      ProviderLocalLibrary(
        storage,
        _rift,
      ).isFavorite('https://anime-rift.com/anime/valid'),
      isTrue,
    );
  });
}
