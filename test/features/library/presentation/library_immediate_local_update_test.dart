import 'dart:async';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/providers/device_info_provider.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_screen.dart';
import 'package:animewitcher/features/library/presentation/library_state.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _LibraryEntry {
  _LibraryEntry({
    required this.item,
    this.category,
    this.favorite = false,
    this.updatedAt = 1,
  });

  final MultimediaItem item;
  final String? category;
  final bool favorite;
  final int updatedAt;
}

class _InMemoryLibraryStorage extends MemoryStorageService {
  final Map<String, _LibraryEntry> entries = <String, _LibraryEntry>{};
  String selectedCategory = LibraryCategory.planToWatch.storageKey;
  int _clock = 100;

  @override
  String getSelectedLibraryCategory() => selectedCategory;

  @override
  Future<void> setSelectedLibraryCategory(String category) async {
    selectedCategory = category;
  }

  @override
  Future<void> addToLibrary(
    MultimediaItem item, {
    String? category,
    bool replaceCategory = false,
    bool? favorite,
    int? updatedAt,
    String? syncedAccountUid,
    int? syncedAt,
  }) async {
    final prev = entries[item.url];
    final nextCategory = replaceCategory
        ? category
        : (category == null || category == 'favorite'
              ? prev?.category
              : category);
    final nextFavorite =
        favorite ??
        (category == 'favorite'
            ? true
            : (prev == null && category == null
                  ? true
                  : (prev?.favorite ?? false)));
    if (nextCategory == null && !nextFavorite) {
      entries.remove(item.url);
      return;
    }
    entries[item.url] = _LibraryEntry(
      item: item,
      category: nextCategory,
      favorite: nextFavorite,
      updatedAt: updatedAt ?? ++_clock,
    );
  }

  @override
  Future<void> setLibraryItemCategory(String url, String? category) async {
    final prev = entries[url];
    if (prev == null) return;
    if (category == null && !prev.favorite) {
      entries.remove(url);
      return;
    }
    entries[url] = _LibraryEntry(
      item: prev.item,
      category: category,
      favorite: prev.favorite,
      updatedAt: ++_clock,
    );
  }

  @override
  Future<void> removeFromLibrary(String url) async {
    entries.remove(url);
  }

  @override
  bool isInLibrary(String url) => entries.containsKey(url);

  @override
  bool isLibraryItemFavorite(String url) => entries[url]?.favorite == true;

  @override
  String? getLibraryItemCategory(String url) => entries[url]?.category;

  @override
  List<MultimediaItem> getLibraryItems({String? category}) {
    final filtered = entries.values
        .where((entry) {
          if (category == null) return true;
          if (category == 'favorite') return entry.favorite;
          return entry.category == category;
        })
        .toList(growable: false);
    filtered.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return filtered.map((e) => e.item).toList(growable: false);
  }
}

class _FakeLibraryCursor extends Fake implements AnimeWitcherLibraryCursor {}

class _FakeNativeAccount extends AnimeWitcherAccountService {
  _FakeNativeAccount(StorageService storage)
    : super(storage: storage, secureStorage: SecureTokenStorage(storage));

  final Map<LibraryCategory, List<MultimediaItem>> remoteAnime =
      <LibraryCategory, List<MultimediaItem>>{
        for (final c in LibraryCategory.values) c: <MultimediaItem>[],
      };
  final Map<LibraryCategory, List<MultimediaItem>> remoteManga =
      <LibraryCategory, List<MultimediaItem>>{
        for (final c in LibraryCategory.values) c: <MultimediaItem>[],
      };

  Completer<void>? pageGate;
  Completer<void>? countGate;
  Completer<void>? saveWriteGate;
  List<MultimediaItem>? nextAnimePage;
  bool failMangaSave = false;

  @override
  bool get isSignedIn => true;

  @override
  String get accountUid => 'native-uid';

  @override
  Future<Map<LibraryCategory, int>> fetchLibraryCounts({
    bool manga = false,
  }) async {
    final source = manga ? remoteManga : remoteAnime;
    final snapshot = <LibraryCategory, int>{
      for (final c in LibraryCategory.values) c: source[c]!.length,
    };
    if (countGate != null) {
      await countGate!.future;
    }
    return snapshot;
  }

  @override
  Future<AnimeWitcherLibraryPage> fetchLibraryPage({
    required LibraryCategory category,
    bool manga = false,
    AnimeWitcherLibraryCursor? cursor,
  }) async {
    final source = manga ? remoteManga : remoteAnime;
    final next = manga ? null : nextAnimePage;
    final list = List<MultimediaItem>.of(
      cursor == null ? source[category]! : next!,
    );
    final total = source[category]!.length + (next?.length ?? 0);
    if (pageGate != null) {
      await pageGate!.future;
    }
    return AnimeWitcherLibraryPage(
      items: list,
      total: total,
      nextCursor: cursor == null && next != null ? _FakeLibraryCursor() : null,
    );
  }

  @override
  Future<void> saveLibraryItem(
    MultimediaItem item,
    LibraryCategory? category, {
    bool? favorite,
    dynamic knownFavorites,
  }) async {
    if (saveWriteGate != null) {
      await saveWriteGate!.future;
    }
    for (final c in LibraryCategory.primaryValues) {
      remoteAnime[c]!.removeWhere((entry) => entry.url == item.url);
    }
    if (category != null && category != LibraryCategory.favorite) {
      remoteAnime[category]!.insert(0, item);
    }
    if (favorite != null) {
      remoteAnime[LibraryCategory.favorite]!.removeWhere(
        (entry) => entry.url == item.url,
      );
      if (favorite) {
        remoteAnime[LibraryCategory.favorite]!.insert(0, item);
      }
    }
  }

  @override
  Future<void> removeLibraryItem(
    String itemUrl, {
    bool keepFavorite = false,
  }) async {
    if (saveWriteGate != null) {
      await saveWriteGate!.future;
    }
    for (final c
        in keepFavorite
            ? LibraryCategory.primaryValues
            : LibraryCategory.values) {
      remoteAnime[c]!.removeWhere((entry) => entry.url == itemUrl);
    }
  }

  @override
  Future<void> saveMangaLibraryItem(
    MultimediaItem item,
    LibraryCategory? category, {
    bool? favorite,
  }) async {
    if (failMangaSave) {
      throw StateError('Simulated manga write failure');
    }
  }
}

class _FakeHistory extends WatchHistory {
  @override
  List<HistoryItem> build() => const <HistoryItem>[];

  @override
  Future<void> refreshFromServer() async {}
}

MultimediaItem _anime(String id, {String? title}) => MultimediaItem(
  title: title ?? 'Anime $id',
  url: 'https://animewitcher.com/watch/$id',
  posterUrl: '',
  contentType: MultimediaContentType.anime,
  status: ShowStatus.completed,
);

MultimediaItem _manga(String id) => MultimediaItem(
  title: 'Manga $id',
  url: 'https://animewitcher.com/manga/$id',
  posterUrl: '',
  contentType: MultimediaContentType.manga,
);

void main() {
  test('Native: moving anime updates both shelves, counts, and cached counts immediately', () async {
    final storage = _InMemoryLibraryStorage();
    final account = _FakeNativeAccount(storage);
    final movedItem = _anime('101', title: 'Dekisokonai');
    final existingNotInterested = _anime('202', title: 'Existing');

    await storage.addToLibrary(
      movedItem,
      category: LibraryCategory.planToWatch.storageKey,
    );
    await storage.addToLibrary(
      existingNotInterested,
      category: LibraryCategory.notInterested.storageKey,
    );
    account.remoteAnime[LibraryCategory.planToWatch] = <MultimediaItem>[
      movedItem,
    ];
    account.remoteAnime[LibraryCategory.notInterested] = <MultimediaItem>[
      existingNotInterested,
    ];

    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        animeWitcherAccountServiceProvider.overrideWithValue(account),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(libraryProvider.notifier);
    // Load both shelves from server so receivedRemotePage == true on both.
    await notifier.refreshVisibleFromServer(
      category: LibraryCategory.planToWatch,
      mediaKind: LibraryMediaKind.anime,
    );
    await notifier.refreshVisibleFromServer(
      category: LibraryCategory.notInterested,
      mediaKind: LibraryMediaKind.anime,
    );
    expect(
      notifier.itemsForCategory(
        LibraryMediaKind.anime,
        LibraryCategory.planToWatch,
      ),
      hasLength(1),
    );
    expect(
      notifier.categoryCount(
        LibraryMediaKind.anime,
        LibraryCategory.planToWatch,
      ),
      1,
    );
    expect(
      notifier.categoryCount(
        LibraryMediaKind.anime,
        LibraryCategory.notInterested,
      ),
      1,
    );

    // Hold the background Firestore write open to prove local updates happen immediately.
    account.saveWriteGate = Completer<void>();

    await notifier.addItem(movedItem, category: LibraryCategory.notInterested);

    expect(
      notifier.itemsForCategory(
        LibraryMediaKind.anime,
        LibraryCategory.planToWatch,
      ),
      isEmpty,
    );
    expect(
      notifier.categoryCount(
        LibraryMediaKind.anime,
        LibraryCategory.planToWatch,
      ),
      0,
    );
    expect(
      notifier
          .itemsForCategory(
            LibraryMediaKind.anime,
            LibraryCategory.notInterested,
          )
          .map((e) => e.url)
          .toList(),
      [movedItem.url, existingNotInterested.url],
    );
    expect(
      notifier.categoryCount(
        LibraryMediaKind.anime,
        LibraryCategory.notInterested,
      ),
      2,
    );
    final cached = storage.getCachedLibraryCounts(
      providerKey: 'native',
      accountKey: 'native-uid',
      mediaKindKey: 'anime',
    );
    expect(cached[LibraryCategory.planToWatch.storageKey], 0);
    expect(cached[LibraryCategory.notInterested.storageKey], 2);

    account.saveWriteGate!.complete();
  });

  test('Native: clearItemCategory and setFavorite update loaded shelves and counts immediately', () async {
    final storage = _InMemoryLibraryStorage();
    final account = _FakeNativeAccount(storage);
    final show = _anime('303', title: 'Frieren');

    await storage.addToLibrary(
      show,
      category: LibraryCategory.watching.storageKey,
    );
    account.remoteAnime[LibraryCategory.watching] = <MultimediaItem>[show];
    account.remoteAnime[LibraryCategory.favorite] = <MultimediaItem>[];

    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        animeWitcherAccountServiceProvider.overrideWithValue(account),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(libraryProvider.notifier);
    await notifier.refreshVisibleFromServer(
      category: LibraryCategory.watching,
      mediaKind: LibraryMediaKind.anime,
    );
    await notifier.refreshVisibleFromServer(
      category: LibraryCategory.favorite,
      mediaKind: LibraryMediaKind.anime,
    );

    // Favorite ON
    await notifier.setFavorite(show, true);
    expect(
      notifier
          .itemsForCategory(LibraryMediaKind.anime, LibraryCategory.favorite)
          .map((e) => e.url),
      [show.url],
    );
    expect(
      notifier.categoryCount(LibraryMediaKind.anime, LibraryCategory.favorite),
      1,
    );

    // Remove primary category
    await notifier.clearItemCategory(show.url);
    expect(
      notifier.itemsForCategory(
        LibraryMediaKind.anime,
        LibraryCategory.watching,
      ),
      isEmpty,
    );
    expect(
      notifier.categoryCount(LibraryMediaKind.anime, LibraryCategory.watching),
      0,
    );

    // Favorite OFF
    await notifier.setFavorite(show, false);
    expect(
      notifier.itemsForCategory(
        LibraryMediaKind.anime,
        LibraryCategory.favorite,
      ),
      isEmpty,
    );
    expect(
      notifier.categoryCount(LibraryMediaKind.anime, LibraryCategory.favorite),
      0,
    );
  });

  test('Native: clearing a server-only anime updates the shelf and preserves its favorite', () async {
    final storage = _InMemoryLibraryStorage();
    final account = _FakeNativeAccount(storage);
    final show = _anime('server-only');
    const shelf = LibraryCategory.continueLater;
    const kind = LibraryMediaKind.anime;
    account.remoteAnime[shelf] = [show];
    account.remoteAnime[LibraryCategory.favorite] = [show];

    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        animeWitcherAccountServiceProvider.overrideWithValue(account),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(libraryProvider.notifier);
    await notifier.refreshVisibleFromServer(category: shelf, mediaKind: kind);
    expect(storage.isInLibrary(show.url), isFalse);
    expect(notifier.itemCategory(show.url), shelf);

    await notifier.clearItemCategory(show.url);
    expect(notifier.itemCategory(show.url), isNull);
    expect(notifier.itemsForCategory(kind, shelf), isEmpty);
    expect(notifier.categoryCount(kind, shelf), 0);

    await notifier.refreshVisibleFromServer(category: shelf, mediaKind: kind);
    expect(notifier.itemsForCategory(kind, shelf), isEmpty);
    expect(account.remoteAnime[LibraryCategory.favorite], [show]);
  });

  test(
    'Native: a next page started before removal cannot bring the anime back',
    () async {
      final storage = _InMemoryLibraryStorage();
      final show = _anime('duplicate');
      const shelf = LibraryCategory.continueLater;
      const kind = LibraryMediaKind.anime;
      final account = _FakeNativeAccount(storage)..nextAnimePage = [show];
      account.remoteAnime[shelf] = [show];

      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          animeWitcherAccountServiceProvider.overrideWithValue(account),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(libraryProvider.notifier);
      await notifier.refreshVisibleFromServer(category: shelf, mediaKind: kind);

      final gate = account.pageGate = Completer<void>();
      final stalePage = notifier.loadNextPage(mediaKind: kind, category: shelf);
      await notifier.clearItemCategory(show.url);
      gate.complete();
      await stalePage;

      expect(notifier.itemCategory(show.url), isNull);
      expect(notifier.itemsForCategory(kind, shelf), isEmpty);
    },
  );

  test('Native: in-flight server page/count fetch does not clobber newer local mutation', () async {
    final storage = _InMemoryLibraryStorage();
    final account = _FakeNativeAccount(storage);
    final show = _anime('404', title: 'Bleach');

    await storage.addToLibrary(
      show,
      category: LibraryCategory.planToWatch.storageKey,
    );
    account.remoteAnime[LibraryCategory.planToWatch] = <MultimediaItem>[show];
    account.remoteAnime[LibraryCategory.notInterested] = <MultimediaItem>[];

    final container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        animeWitcherAccountServiceProvider.overrideWithValue(account),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(libraryProvider.notifier);
    account.pageGate = Completer<void>();
    account.countGate = Completer<void>();

    final serverRefresh = notifier.refreshVisibleFromServer(
      category: LibraryCategory.planToWatch,
      mediaKind: LibraryMediaKind.anime,
    );
    await Future<void>.delayed(Duration.zero);

    // Mutate locally while the stale server request is still in flight.
    await notifier.addItem(show, category: LibraryCategory.notInterested);

    expect(
      notifier.itemsForCategory(
        LibraryMediaKind.anime,
        LibraryCategory.planToWatch,
      ),
      isEmpty,
    );
    expect(
      notifier.itemsForCategory(
        LibraryMediaKind.anime,
        LibraryCategory.notInterested,
      ),
      hasLength(1),
    );

    account.pageGate!.complete();
    account.countGate!.complete();
    await serverRefresh;
    await Future<void>.delayed(Duration.zero);

    expect(
      notifier.itemsForCategory(
        LibraryMediaKind.anime,
        LibraryCategory.planToWatch,
      ),
      isEmpty,
    );
    expect(
      notifier.categoryCount(
        LibraryMediaKind.anime,
        LibraryCategory.planToWatch,
      ),
      0,
    );
    expect(
      notifier.categoryCount(
        LibraryMediaKind.anime,
        LibraryCategory.notInterested,
      ),
      1,
    );
  });

  test(
    'Manga: a failed remote save keeps the local move and the shelf counts',
    () async {
      final storage = _InMemoryLibraryStorage();
      final account = _FakeNativeAccount(storage)..failMangaSave = true;
      final manga = _manga('m1');
      const kind = LibraryMediaKind.manga;
      const previous = LibraryCategory.planToWatch;
      const next = LibraryCategory.completed;
      await storage.addToLibrary(manga, category: previous.storageKey);
      account.remoteManga[previous] = [manga];
      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          animeWitcherAccountServiceProvider.overrideWithValue(account),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(libraryProvider.notifier);
      await notifier.refreshVisibleFromServer(
        category: previous,
        mediaKind: kind,
      );
      await notifier.refreshVisibleFromServer(category: next, mediaKind: kind);

      await notifier.addItem(manga, category: next);

      expect(notifier.itemsForCategory(kind, previous), isEmpty);
      expect(notifier.categoryCount(kind, previous), 0);
      expect(notifier.itemsForCategory(kind, next).map((item) => item.url), [
        manga.url,
      ]);
      expect(notifier.categoryCount(kind, next), 1);
    },
  );

  testWidgets(
    'Phone UI updates tab counts and grid cards immediately after moving an anime',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final storage = _InMemoryLibraryStorage();
      final account = _FakeNativeAccount(storage);
      final show = _anime('505', title: 'Dekisokonai to Y');

      await storage.addToLibrary(
        show,
        category: LibraryCategory.planToWatch.storageKey,
      );
      account.remoteAnime[LibraryCategory.planToWatch] = <MultimediaItem>[show];

      final container = ProviderContainer(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          animeWitcherAccountServiceProvider.overrideWithValue(account),
          deviceProfileProvider.overrideWith(
            (ref) async => const DeviceProfile(),
          ),
          watchHistoryProvider.overrideWith(_FakeHistory.new),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            locale: Locale('ar'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: LibraryScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.text('أرغب بمشاهدته 1'), findsOneWidget);
      expect(find.text('لا أرغب بمشاهدته 0'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('library-grid-anime-pinned')),
          matching: find.text('Dekisokonai to Y'),
        ),
        findsWidgets,
      );

      await container
          .read(libraryProvider.notifier)
          .addItem(show, category: LibraryCategory.notInterested);
      await tester.pump();

      expect(find.text('أرغب بمشاهدته 0'), findsOneWidget);
      expect(find.text('لا أرغب بمشاهدته 1'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('library-grid-anime-pinned')),
          matching: find.text('Dekisokonai to Y'),
        ),
        findsNothing,
      );
      expect(
        (container.read(libraryProvider) as LibraryEmpty).category,
        LibraryCategory.planToWatch,
      );

      final notInterestedTab = find.byKey(
        const ValueKey('library-list-tab-noWatching'),
      );
      await tester.ensureVisible(notInterestedTab);
      await tester.pump();
      await tester.tap(notInterestedTab);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('لا أرغب بمشاهدته 1'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('library-grid-anime-noWatching')),
          matching: find.text('Dekisokonai to Y'),
        ),
        findsWidgets,
      );
    },
  );
}
