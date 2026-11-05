import 'dart:async';

import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/extensions/providers/anime_rift_api_client.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/core/storage/anime_rift_auto_sync.dart';
import 'package:animewitcher/core/storage/anime_rift_cloud_pending.dart';
import 'package:animewitcher/core/storage/anime_rift_cloud_sync.dart';
import 'package:animewitcher/core/storage/anime_rift_rating.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/provider_local_history.dart';
import 'package:animewitcher/core/storage/provider_local_library.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _title = 'https://anime-rift.com/anime/safe1';

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
  bool includeHistory = false;

  @override
  Future<bool> restoreAccountSession() async => true;

  @override
  Future<Map<String, dynamic>> fetchMyListOverview() async => {
    'items': <String, dynamic>{},
  };

  @override
  Future<Map<String, dynamic>> fetchFavoriteAnime() async => {
    'items': <Map<String, dynamic>>[
      {
        'anime': {'_id': 'safe1', 'title': 'Remote favorite'},
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> fetchMyList(String category) async => {
    'items': category == 'currently'
        ? <Map<String, dynamic>>[
            {
              'anime': {'_id': 'safe1', 'title': 'Remote watching'},
            },
          ]
        : <Map<String, dynamic>>[],
  };

  @override
  Future<Map<String, dynamic>> fetchWatchHistoryLatest() async => {
    'items': includeHistory
        ? <Map<String, dynamic>>[
            {
              'anime': {'_id': 'safe1', 'title': 'Remote watched'},
            },
          ]
        : <Map<String, dynamic>>[],
  };

  @override
  Future<Map<String, dynamic>> fetchWatchHistoryFull() async => {
    'items': includeHistory
        ? <Map<String, dynamic>>[
            {
              'anime': {'_id': 'safe1', 'title': 'Remote watched'},
            },
          ]
        : <Map<String, dynamic>>[],
  };
}

class _FakeRift extends AnimeRiftProvider {
  _FakeRift(this.accountId);

  String accountId;
  bool linked = true;
  int pullCalls = 0;
  int activePulls = 0;
  int maxActivePulls = 0;
  Completer<void>? pullGate;
  int changed = 0;
  final selectedPulls = <LibraryCategory>[];
  int historyPulls = 0;

  @override
  Future<bool> restoreAccountSession() async {
    if (linked) AnimeRiftLocalAccountScope.activate(accountId);
    return linked;
  }

  @override
  Future<AnimeRiftCloudImportResult> importCloudLibrary(
    StorageService storage,
  ) async {
    pullCalls++;
    activePulls++;
    if (activePulls > maxActivePulls) maxActivePulls = activePulls;
    try {
      await pullGate?.future;
      return AnimeRiftCloudImportResult(
        favorites: 0,
        categories: 0,
        history: 0,
        skipped: 0,
        changed: changed,
      );
    } finally {
      activePulls--;
    }
  }

  @override
  Future<AnimeRiftCloudImportResult> importCloudLibraryCategory(
    StorageService storage,
    LibraryCategory category,
  ) async {
    selectedPulls.add(category);
    return const AnimeRiftCloudImportResult(
      favorites: 0,
      categories: 0,
      history: 0,
      skipped: 0,
      changed: 0,
    );
  }

  @override
  Future<AnimeRiftCloudImportResult> importCloudHistory(
    StorageService storage,
  ) async {
    historyPulls++;
    return const AnimeRiftCloudImportResult(
      favorites: 0,
      categories: 0,
      history: 0,
      skipped: 0,
      changed: 0,
    );
  }
}

class _FakeVerifiedWriter implements AnimeRiftVerifiedCloudWriter {
  final sent = <AnimeRiftCloudPendingChange>[];
  Completer<void>? gate;

  @override
  Future<bool> write(
    String accountHash,
    AnimeRiftCloudPendingChange change,
  ) async {
    AnimeRiftCloudPendingJournal.requireAccount(accountHash);
    sent.add(change);
    await gate?.future;
    return true;
  }
}

class _FavoriteClient extends AnimeRiftApiClient {
  final sent = <String>[];

  @override
  Future<Map<String, dynamic>> setFavoriteAnime(
    String id,
    bool favorite, {
    required String accountHash,
  }) async {
    AnimeRiftCloudPendingJournal.requireAccount(accountHash);
    sent.add('$id:$favorite');
    return {'success': true};
  }
}

void main() {
  tearDown(AnimeRiftLocalAccountScope.reset);

  test(
    'Rift visible shelf flushes only library edits and history only on demand',
    () async {
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice');
      await provider.restoreAccountSession();
      final writer = _FakeVerifiedWriter();
      final coordinator = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        verifiedWriter: writer,
        debounce: const Duration(days: 1),
      );
      addTearDown(coordinator.dispose);
      await coordinator.queueCategory(_title, LibraryCategory.completed);
      await coordinator.queueHistory(_title, false);
      await coordinator.refreshCategory(LibraryCategory.watching);
      expect(provider.selectedPulls, [LibraryCategory.watching]);
      expect(provider.pullCalls, 0);
      expect(provider.historyPulls, 0);
      expect(writer.sent.map((entry) => entry.kind), ['category']);
      await coordinator.refreshHistory();
      expect(provider.historyPulls, 1);
      expect(writer.sent.map((entry) => entry.kind), ['category', 'history']);
    },
  );

  test(
    'Rift history remove/clear uses server record IDs and confirms deletion',
    () async {
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice');
      await provider.restoreAccountSession();
      var records = <Map<String, dynamic>>[
        {
          '_id': 'history-1',
          'anime': {'_id': 'safe1'},
        },
        {
          '_id': 'history-2',
          'anime': {'_id': 'safe2'},
        },
      ];
      final sent = <String>[];
      final writer = AnimeRiftCloudWriter(
        _FavoriteClient().setFavoriteAnime,
        readHistory: () async => {'items': records},
        clearHistoryOne: (record, anime, {required accountHash}) async {
          AnimeRiftCloudPendingJournal.requireAccount(accountHash);
          sent.add('one:$record:$anime');
          records.removeWhere((row) => row['_id'] == record);
          return {};
        },
        clearHistoryMany: (ids, {required accountHash}) async {
          AnimeRiftCloudPendingJournal.requireAccount(accountHash);
          sent.add('many:${ids.join(',')}');
          records = [];
          return {};
        },
      );
      final sync = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        verifiedWriter: writer,
        debounce: const Duration(days: 1),
      );
      addTearDown(sync.dispose);
      await sync.queueHistory(_title, false);
      await sync.refresh();
      expect(sent, ['one:history-1:safe1']);
      await sync.queueHistoryClear();
      await sync.refresh();
      expect(sent, ['one:history-1:safe1', 'many:history-2']);
      expect(
        AnimeRiftCloudPendingJournal(storage)
            .pending(AnimeRiftLocalAccountScope.accountHash!),
        isEmpty,
      );
    },
  );

  test(
    'Rift rating syncs derived general and all four editable scores',
    () async {
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice');
      await provider.restoreAccountSession();
      const rating = AnimeRiftRating(
        story: 9,
        characters: 7,
        animation: 8,
        music: 6,
      );
      AnimeRiftRating? remote;
      final sent = <AnimeRiftRating>[];
      final sync = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        verifiedWriter: AnimeRiftCloudWriter(
          _FavoriteClient().setFavoriteAnime,
          setRating: (id, score, {required accountHash}) async {
            AnimeRiftCloudPendingJournal.requireAccount(accountHash);
            expect(id, 'safe1');
            sent.add(score);
            return {};
          },
          readRating: (url) async => remote,
        ),
        debounce: const Duration(days: 1),
      );
      addTearDown(sync.dispose);
      await sync.queueRating(_title, rating);
      expect(sync.pendingRating(_title), rating);
      await sync.refresh();
      expect(sent, [rating]);
      expect(sync.pendingRating(_title), rating);
      remote = rating;
      await sync.refresh();
      expect(sync.pendingRating(_title), isNull);
    },
  );

  test(
    'Rift rating deletion is queued and acknowledged only when remote clears',
    () async {
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice');
      await provider.restoreAccountSession();
      AnimeRiftRating? remote = const AnimeRiftRating(
        story: 8,
        characters: 8,
        animation: 8,
        music: 8,
      );
      var clearCalls = 0;
      final sync = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        verifiedWriter: AnimeRiftCloudWriter(
          _FavoriteClient().setFavoriteAnime,
          clearRating: (id, {required accountHash}) async {
            AnimeRiftCloudPendingJournal.requireAccount(accountHash);
            expect(id, 'safe1');
            clearCalls++;
            return {};
          },
          readRating: (_) async => remote,
        ),
        debounce: const Duration(days: 1),
      );
      addTearDown(sync.dispose);
      await sync.queueClearRating(_title);
      expect(sync.hasPendingRating(_title), isTrue);
      expect(await sync.pushRatingNow(_title), isFalse);
      expect(clearCalls, 1);
      expect(sync.hasPendingRating(_title), isTrue);
      remote = null;
      expect(await sync.pushRatingNow(_title), isTrue);
      expect(sync.hasPendingRating(_title), isFalse);
    },
  );

  test(
    'Rift rating pushes immediately without a full cloud-library import',
    () async {
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice');
      await provider.restoreAccountSession();
      AnimeRiftRating? remote;
      const rating = AnimeRiftRating(
        story: 9,
        characters: 6,
        animation: 9,
        music: 8,
      );
      final sync = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        verifiedWriter: AnimeRiftCloudWriter(
          _FavoriteClient().setFavoriteAnime,
          setRating: (id, selected, {required accountHash}) async {
            AnimeRiftCloudPendingJournal.requireAccount(accountHash);
            remote = selected;
            return {};
          },
          readRating: (_) async => remote,
        ),
        debounce: const Duration(days: 1),
      );
      addTearDown(sync.dispose);
      await sync.queueRating(_title, rating);
      expect(await sync.pushRatingNow(_title), isTrue);
      expect(sync.hasPendingRating(_title), isFalse);
      expect(remote, rating);
      expect(provider.pullCalls, 0);
    },
  );

  test(
    'uploading a rating never fails behind another pending rating',
    () async {
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice');
      await provider.restoreAccountSession();
      const rating = AnimeRiftRating(
        story: 9,
        characters: 9,
        animation: 9,
        music: 9,
      );
      AnimeRiftRating? remote;
      final sent = <String>[];
      final sync = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        verifiedWriter: AnimeRiftCloudWriter(
          _FavoriteClient().setFavoriteAnime,
          setRating: (id, value, {required accountHash}) async {
            sent.add(id);
            if (id == 'broken') throw StateError('Old server rejection');
            remote = value;
            return {};
          },
          readRating: (_) async => remote,
        ),
        debounce: const Duration(days: 1),
      );
      addTearDown(sync.dispose);
      const stuck = 'https://anime-rift.com/anime/broken';
      await sync.queueRating(stuck, rating);
      await sync.queueRating(_title, rating);
      expect(await sync.pushRatingNow(_title), isTrue);
      expect(sent, ['safe1']);
      expect(sync.hasPendingRating(stuck), isTrue);
      expect(sync.hasPendingRating(_title), isFalse);
    },
  );

  test('verified favorite writer flushes favorites while preserving unsupported edits', () async {
    final storage = _MemoryStorage();
    final provider = _FakeRift('alice');
    await provider.restoreAccountSession();
    final client = _FavoriteClient();
    final sync = AnimeRiftAutoSyncCoordinator(
      storage: storage,
      activeRift: () => provider,
      verifiedWriter: AnimeRiftCloudWriter(client.setFavoriteAnime),
      debounce: const Duration(days: 1),
    );
    addTearDown(sync.dispose);
    await sync.queueHistory(_title, false);
    await sync.queueFavorite(_title, false);
    await sync.refresh();
    expect(client.sent, ['safe1:false']);
    final pending = AnimeRiftCloudPendingJournal(storage)
        .pending(AnimeRiftLocalAccountScope.accountHash!);
    expect(pending.map((change) => change.kind), ['history']);
    expect(provider.pullCalls, 1);
  });

  test(
    'favorite write is acknowledged only after the remote state confirms',
    () async {
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice');
      await provider.restoreAccountSession();
      var visibleRemotely = false;
      final sync = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        verifiedWriter: AnimeRiftCloudWriter(
          _FavoriteClient().setFavoriteAnime,
          readFavorites: () async => {
            'items': visibleRemotely
                ? [
                    {
                      'anime': {'_id': 'safe1'},
                    },
                  ]
                : <Object>[],
          },
        ),
        debounce: const Duration(days: 1),
      );
      addTearDown(sync.dispose);
      await sync.queueFavorite(_title, true);
      await sync.refresh();
      final account = AnimeRiftLocalAccountScope.accountHash!;
      expect(
        AnimeRiftCloudPendingJournal(storage).pending(account),
        hasLength(1),
      );
      visibleRemotely = true;
      await sync.refresh();
      expect(AnimeRiftCloudPendingJournal(storage).pending(account), isEmpty);
    },
  );

  test(
    'every standard Rift list can be pushed, verified and removed',
    () async {
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice');
      await provider.restoreAccountSession();
      final sent = <String?>[];
      String? serverCategory;
      final writer = AnimeRiftCloudWriter(
        _FavoriteClient().setFavoriteAnime,
        setCategory: (id, category, {required accountHash}) async {
          AnimeRiftCloudPendingJournal.requireAccount(accountHash);
          expect(id, 'safe1');
          sent.add(category);
          serverCategory = category;
          return {'success': true};
        },
        readCategory: (key) async => {
          'items': key == serverCategory
              ? [
                  {
                    'anime': {'_id': 'safe1', 'title': 'Server confirmed'},
                  },
                ]
              : <Object>[],
        },
      );
      final sync = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        verifiedWriter: writer,
        debounce: const Duration(days: 1),
      );
      addTearDown(sync.dispose);
      final journal = AnimeRiftCloudPendingJournal(storage);
      final account = AnimeRiftLocalAccountScope.accountHash!;
      const mappings = {
        LibraryCategory.watching: 'currently',
        LibraryCategory.planToWatch: 'want_to',
        LibraryCategory.completed: 'finished',
        LibraryCategory.continueLater: 'later',
        LibraryCategory.notInterested: 'dropped',
      };
      for (final entry in mappings.entries) {
        await sync.queueCategory(_title, entry.key);
        await sync.refresh();
        expect(sent.last, entry.value);
        expect(journal.pending(account), isEmpty);
      }
      await sync.queueCategory(_title, null);
      await sync.refresh();
      expect(sent.last, isNull);
      expect(journal.pending(account), isEmpty);
      expect(provider.pullCalls, mappings.length + 1);
    },
  );

  test(
    'unconfirmed category writes stay pending and protect newer changes',
    () async {
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice');
      await provider.restoreAccountSession();
      final sync = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        verifiedWriter: AnimeRiftCloudWriter(
          _FavoriteClient().setFavoriteAnime,
          setCategory: (id, category, {required accountHash}) async => {},
          // A stale response reports the old category despite an accepted PUT.
          readCategory: (key) async => {
            'items': key == 'currently'
                ? [
                    {
                      'anime': {'_id': 'safe1'},
                    },
                  ]
                : <Object>[],
          },
        ),
        debounce: const Duration(days: 1),
      );
      addTearDown(sync.dispose);
      await sync.queueCategory(_title, LibraryCategory.completed);
      await sync.refresh();
      final account = AnimeRiftLocalAccountScope.accountHash!;
      final pending = AnimeRiftCloudPendingJournal(storage).pending(account);
      expect(pending, hasLength(1));
      expect(
        pending.single.value['category'],
        LibraryCategory.completed.storageKey,
      );
    },
  );

  test(
    'guest and native provider changes never enter the Rift cloud queue',
    () async {
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice')..linked = false;
      final sync = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        debounce: const Duration(days: 1),
      );
      await sync.scheduleLocalChange();
      await sync.queueFavorite(_title, true);
      await sync.queueCategory(_title, null);
      await sync.queuePlayback(_title, position: 1, duration: 2);
      await sync.refresh();
      expect(storage.values, isEmpty);
      expect(provider.pullCalls, 0);

      // A linked Rift account may remain stored while the active provider is
      // AnimeWitcher. That must not schedule new Rift writes either.
      AnimeRiftLocalAccountScope.activate('alice');
      final native = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => null,
        debounce: const Duration(days: 1),
      );
      await native.queueFavorite(_title, true);
      await native.scheduleLocalChange();
      expect(storage.values, isEmpty);
      native.dispose();
      sync.dispose();
    },
  );

  test('guest changes are rejected, and A/B queues remain isolated', () async {
    final storage = _MemoryStorage();
    final journal = AnimeRiftCloudPendingJournal(storage);
    await expectLater(
      journal.queueFavorite(_title, false),
      throwsA(isA<AnimeRiftAuthenticationRequired>()),
    );

    AnimeRiftLocalAccountScope.activate('alice');
    final a = AnimeRiftLocalAccountScope.accountHash!;
    await journal.queueFavorite(_title, false);
    await journal.queueCategory(_title, null);
    await journal.queuePlayback(
      _title,
      episodeIdentity: 'episode-3',
      position: 24,
      duration: 99,
    );
    expect(
      journal.pending(a).map((x) => x.kind),
      containsAll(['favorite', 'category', 'playback']),
    );

    AnimeRiftLocalAccountScope.activate('bob');
    final b = AnimeRiftLocalAccountScope.accountHash!;
    expect(journal.pending(b), isEmpty);
    await journal.queueFavorite(_title, true);
    expect(journal.pending(b).single.value['favorite'], isTrue);
    expect(
      () => journal.pending(a),
      throwsA(isA<AnimeRiftAuthenticationRequired>()),
    );

    AnimeRiftLocalAccountScope.activate('alice');
    expect(AnimeRiftCloudPendingJournal(storage).pending(a), hasLength(3));
    expect(
      journal
          .pending(a)
          .firstWhere((x) => x.kind == 'favorite')
          .value['favorite'],
      isFalse,
    );
  });

  test(
    'Rift watched marks and unmarks are durable per episode and per account',
    () async {
      final storage = _MemoryStorage();
      final journal = AnimeRiftCloudPendingJournal(storage);
      AnimeRiftLocalAccountScope.activate('alice');
      final alice = AnimeRiftLocalAccountScope.accountHash!;
      await journal.queueWatched(_title, 2, true);
      await journal.queueWatched(_title, 3, true);
      await journal.queueWatched(_title, 2, false);
      final changes = journal.pending(alice);
      expect(changes, hasLength(2));
      expect(
        changes
            .firstWhere((c) => c.value['episode_number'] == 2)
            .value['viewed'],
        false,
      );
      expect(
        changes.firstWhere((c) => c.value['episode_number'] == 2).revision,
        2,
      );
      expect(
        changes
            .firstWhere((c) => c.value['episode_number'] == 3)
            .value['viewed'],
        true,
      );
      AnimeRiftLocalAccountScope.activate('bob');
      expect(journal.pending(AnimeRiftLocalAccountScope.accountHash!), isEmpty);
      expect(() => journal.queueWatched(_title, -1, true), throwsArgumentError);
      AnimeRiftLocalAccountScope.activate('alice');
      expect(
        AnimeRiftCloudPendingJournal(storage).pending(alice),
        hasLength(2),
      );
    },
  );

  test('queued viewed and unviewed episode states flush without dropping other pending history', () async {
    final storage = _MemoryStorage();
    final provider = _FakeRift('alice');
    await provider.restoreAccountSession();
    final calls = <String>[];
    final sync = AnimeRiftAutoSyncCoordinator(
      storage: storage,
      activeRift: () => provider,
      verifiedWriter: AnimeRiftCloudWriter(
        _FavoriteClient().setFavoriteAnime,
        setWatched: (id, episode, viewed, {required accountHash}) async {
          AnimeRiftCloudPendingJournal.requireAccount(accountHash);
          calls.add('$id:$episode:$viewed');
          return {'success': true};
        },
      ),
      debounce: const Duration(days: 1),
    );
    addTearDown(sync.dispose);
    await sync.queueWatched(_title, 2, true);
    await sync.queueWatched(_title, 3, false);
    await sync.queueHistory(_title, false);
    await sync.refresh();
    expect(calls, ['safe1:2:true', 'safe1:3:false']);
    final pending = AnimeRiftCloudPendingJournal(storage)
        .pending(AnimeRiftLocalAccountScope.accountHash!);
    expect(pending.map((entry) => entry.kind), ['history']);
  });

  test(
    'rapid playback ticks do not spam cloud queue or remote pulls',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice');
      final sync = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        debounce: const Duration(milliseconds: 1),
      );
      final account = AnimeRiftLocalAccountScope.accountHash!;
      await sync.queuePlayback(
        _title,
        episodeIdentity: 'ep-1',
        position: 10,
        duration: 100,
      );
      await sync.queuePlayback(
        _title,
        episodeIdentity: 'ep-1',
        position: 11,
        duration: 100,
      );
      await sync.queuePlayback(
        _title,
        episodeIdentity: 'ep-1',
        position: 90,
        duration: 100,
      );
      final pending = AnimeRiftCloudPendingJournal(storage).pending(account);
      expect(pending, hasLength(1));
      expect(pending.single.revision, 2);
      expect(pending.single.value['position'], 90);
      expect(provider.pullCalls, 0);
      sync.dispose();
    },
  );

  test('latest local edit wins even when an older send acknowledges', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final journal = AnimeRiftCloudPendingJournal(_MemoryStorage());
    final account = AnimeRiftLocalAccountScope.accountHash!;
    await journal.queueFavorite(_title, true);
    final stale = journal.pending(account).single;
    await journal.queueFavorite(_title, false);
    await journal.acknowledge(account, stale);
    expect(journal.pending(account).single.value['favorite'], isFalse);
    expect(journal.pending(account).single.revision, 2);
  });

  test('rejects unsafe IDs and never persists a signed episode URL', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final journal = AnimeRiftCloudPendingJournal(_MemoryStorage());
    expect(
      () => journal.queueFavorite(
        'https://anime-rift.com/anime/safe1?token=abc',
        true,
      ),
      throwsArgumentError,
    );
    expect(
      () => journal.queuePlayback(
        _title,
        episodeIdentity: 'https://cdn.example/episode?token=abc',
        position: 1,
        duration: 2,
      ),
      throwsArgumentError,
    );
    await journal.queuePlayback(_title, position: 1, duration: 2, episode: 3);
    final stored = journal
        .pending(AnimeRiftLocalAccountScope.accountHash!)
        .single;
    expect(stored.value['episode'], 3);
    expect(stored.toJson().toString(), isNot(contains('token=')));
  });

  test(
    'pending local unfavorite and category removal survive cloud import',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final journal = AnimeRiftCloudPendingJournal(storage);
      await journal.queueFavorite(_title, false);
      await journal.queueCategory(_title, null);

      final imported = await AnimeRiftCloudSync(_CloudReader())
          .importToLocal(storage: storage);
      final library = ProviderLocalLibrary(storage, animeRiftProviderId);
      expect(imported.favorites, 1);
      expect(imported.categories, 1);
      expect(imported.changed, 0);
      expect(library.isFavorite(_title), isFalse);
      expect(library.category(_title), isNull);
    },
  );

  test('remote history cannot resurrect an explicitly removed entry', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final storage = _MemoryStorage();
    final journal = AnimeRiftCloudPendingJournal(storage);
    final reader = _CloudReader()..includeHistory = true;
    await journal.queueHistory(_title, false);
    await AnimeRiftCloudSync(reader).importToLocal(storage: storage);
    expect(
      ProviderLocalHistory(storage, animeRiftProviderId).history(),
      isEmpty,
    );

    await journal.queueHistoryClear();
    await AnimeRiftCloudSync(reader).importToLocal(storage: storage);
    expect(
      ProviderLocalHistory(storage, animeRiftProviderId).history(),
      isEmpty,
    );
    expect(
      journal
          .pending(AnimeRiftLocalAccountScope.accountHash!)
          .map((c) => c.kind),
      contains('history-clear'),
    );
  });

  test(
    'automatic refresh coalesces requests without concurrent imports',
    () async {
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice')..pullGate = Completer<void>();
      var changedEvents = 0;
      final sync = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        onImported: () => changedEvents++,
        debounce: const Duration(days: 1),
      );
      final first = sync.refresh();
      final second = sync.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(provider.pullCalls, 1);
      provider.pullGate!.complete();
      await Future.wait([first, second]);
      expect(provider.pullCalls, 2);
      expect(provider.maxActivePulls, 1);
      expect(changedEvents, 0);
      sync.dispose();
    },
  );

  test('without a verified writer, outbound changes remain durable', () async {
    AnimeRiftLocalAccountScope.activate('alice');
    final storage = _MemoryStorage();
    final provider = _FakeRift('alice');
    final sync = AnimeRiftAutoSyncCoordinator(
      storage: storage,
      activeRift: () => provider,
      debounce: const Duration(days: 1),
    );
    await sync.queueFavorite(_title, true);
    await sync.refresh();
    expect(sync.canPushToCloud, isFalse);
    expect(provider.pullCalls, 1);
    expect(
      AnimeRiftCloudPendingJournal(storage)
          .pending(AnimeRiftLocalAccountScope.accountHash!),
      hasLength(1),
    );
    sync.dispose();
  });

  test(
    'verified writer sends then acks; account switch keeps old pending',
    () async {
      AnimeRiftLocalAccountScope.activate('alice');
      final storage = _MemoryStorage();
      final provider = _FakeRift('alice');
      final writer = _FakeVerifiedWriter()..gate = Completer<void>();
      final sync = AnimeRiftAutoSyncCoordinator(
        storage: storage,
        activeRift: () => provider,
        verifiedWriter: writer,
        debounce: const Duration(days: 1),
      );
      await sync.queueFavorite(_title, false);
      final firstAccount = AnimeRiftLocalAccountScope.accountHash!;
      final ongoing = sync.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(writer.sent, hasLength(1));

      AnimeRiftLocalAccountScope.activate('bob');
      writer.gate!.complete();
      await expectLater(
        ongoing,
        throwsA(isA<AnimeRiftAuthenticationRequired>()),
      );
      expect(provider.pullCalls, 0);
      AnimeRiftLocalAccountScope.activate('alice');
      expect(
        AnimeRiftCloudPendingJournal(storage).pending(firstAccount),
        hasLength(1),
      );
      sync.dispose();
    },
  );
}
