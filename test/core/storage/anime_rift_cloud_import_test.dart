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

class _CloudReader implements AnimeRiftCloudAccountReader {
  bool linked = true;
  String? restoredAccountId;
  final favorites = <Object>[];
  final lists = <String, List<Object>>{};
  final history = <Object>[];
  Completer<Map<String, dynamic>>? favoritesGate;
  bool completeOverview = true;
  final requests = <String>[];

  @override
  Future<bool> restoreAccountSession() async {
    if (linked && restoredAccountId != null) {
      AnimeRiftLocalAccountScope.activate(restoredAccountId!);
    }
    return linked;
  }

  @override
  Future<Map<String, dynamic>> fetchMyListOverview() async => {
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

  @override
  Future<Map<String, dynamic>> fetchFavoriteAnime() => (() {
    requests.add('favorite');
    return favoritesGate?.future ?? Future.value({'items': favorites});
  })();

  @override
  Future<Map<String, dynamic>> fetchMyList(String category) async {
    requests.add(category);
    return {'items': lists[category] ?? <Object>[]};
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
      final library = ProviderLocalLibrary(storage, _rift);
      final history = ProviderLocalHistory(storage, _rift);
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

  test(
    'one unavailable anime detail does not hide other valid favorites',
    () async {
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
      expect(result.favorites, 1);
      expect(result.skipped, 1);
      expect(
        ProviderLocalLibrary(
          storage,
          _rift,
        ).isFavorite('https://anime-rift.com/anime/valid'),
        isTrue,
      );
    },
  );
}
