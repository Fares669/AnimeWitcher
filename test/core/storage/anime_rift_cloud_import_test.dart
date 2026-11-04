import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/core/storage/anime_rift_cloud_sync.dart';
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

  @override
  Future<bool> restoreAccountSession() async {
    if (linked && restoredAccountId != null) {
      AnimeRiftLocalAccountScope.activate(restoredAccountId!);
    }
    return linked;
  }

  @override
  Future<Map<String, dynamic>> fetchMyListOverview() async => {
    'items': {'my_list_favorites': favorites.length},
  };

  @override
  Future<Map<String, dynamic>> fetchFavoriteAnime() =>
      favoritesGate?.future ?? Future.value({'items': favorites});

  @override
  Future<Map<String, dynamic>> fetchMyList(String category) async => {
    'items': lists[category] ?? <Object>[],
  };

  @override
  Future<Map<String, dynamic>> fetchWatchHistoryLatest() async => {
    'items': history,
  };

  @override
  Future<Map<String, dynamic>> fetchWatchHistoryFull() async => {
    'items': history,
  };
}

void main() {
  tearDown(AnimeRiftLocalAccountScope.reset);

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
