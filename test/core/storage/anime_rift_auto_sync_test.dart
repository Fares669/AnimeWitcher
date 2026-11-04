import 'dart:async';

import 'package:animewitcher/core/extensions/providers/anime_rift_provider.dart';
import 'package:animewitcher/core/storage/anime_rift_account_scope.dart';
import 'package:animewitcher/core/storage/anime_rift_auto_sync.dart';
import 'package:animewitcher/core/storage/anime_rift_cloud_pending.dart';
import 'package:animewitcher/core/storage/anime_rift_cloud_sync.dart';
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
}

class _FakeVerifiedWriter implements AnimeRiftVerifiedCloudWriter {
  final sent = <AnimeRiftCloudPendingChange>[];
  Completer<void>? gate;

  @override
  Future<void> write(
    String accountHash,
    AnimeRiftCloudPendingChange change,
  ) async {
    AnimeRiftCloudPendingJournal.requireAccount(accountHash);
    sent.add(change);
    await gate?.future;
  }
}

void main() {
  tearDown(AnimeRiftLocalAccountScope.reset);

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
