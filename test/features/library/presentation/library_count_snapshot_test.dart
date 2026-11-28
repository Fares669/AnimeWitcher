import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/anime3rb_account_service.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/account/witanime_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/base_provider.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/extensions/providers/anime3rb_provider.dart';
import 'package:animewitcher/core/extensions/providers/witanime_provider.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/storage/anime3rb_library_service.dart';
import 'package:animewitcher/core/storage/download_persistence_worker.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/core/storage/witanime_library_service.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_screen.dart';
import 'package:animewitcher/features/library/presentation/widgets/bookmarks_tab.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;
  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

class _Storage extends StorageService {
  _Storage(DownloadPersistenceWorker worker)
    : super(downloadPersistenceWorker: worker);

  int scans = 0;
  int diskMaps = 0;
  int shelfReads = 0;
  int boundedReads = 0;
  int hydratedCards = 0;
  int projectionMicros = 0;
  int shelfCategoryReads = 0;
  int batchedReads = 0;
  bool measuringShelf = false;

  void resetWork() {
    scans = 0;
    shelfReads = 0;
    boundedReads = 0;
    hydratedCards = 0;
    projectionMicros = 0;
    shelfCategoryReads = 0;
    batchedReads = 0;
  }

  @override
  List<MultimediaItem> getLibraryItems({String? category}) {
    shelfReads++;
    final timer = Stopwatch()..start();
    final items = super.getLibraryItems(category: category);
    projectionMicros += timer.elapsedMicroseconds;
    hydratedCards += items.length;
    return items;
  }

  @override
  ({List<MultimediaItem> items, int total}) getLocalLibraryShelf({
    required String category,
    required bool manga,
    required int limit,
  }) {
    boundedReads++;
    final timer = Stopwatch()..start();
    measuringShelf = true;
    try {
      final shelf = super.getLocalLibraryShelf(
        category: category,
        manga: manga,
        limit: limit,
      );
      hydratedCards += shelf.items.length;
      return shelf;
    } finally {
      measuringShelf = false;
      projectionMicros += timer.elapsedMicroseconds;
    }
  }

  @override
  Map<String, ({List<MultimediaItem> items, int total})>
  getLocalLibraryShelves({
    required Map<String, int> limits,
    required bool manga,
  }) {
    batchedReads++;
    final timer = Stopwatch()..start();
    measuringShelf = true;
    try {
      final shelves = super.getLocalLibraryShelves(
        limits: limits,
        manga: manga,
      );
      hydratedCards += shelves.values.fold(
        0,
        (sum, shelf) => sum + shelf.items.length,
      );
      return shelves;
    } finally {
      measuringShelf = false;
      projectionMicros += timer.elapsedMicroseconds;
    }
  }

  @override
  Map<String, ({int anime, int manga})> getLocalLibraryCounts() {
    scans++;
    final timer = Stopwatch()..start();
    final counts = super.getLocalLibraryCounts();
    projectionMicros += timer.elapsedMicroseconds;
    return counts;
  }

  @override
  Map<String, int> getCachedLibraryCounts({
    required String providerKey,
    required String accountKey,
    required String mediaKindKey,
  }) {
    diskMaps++;
    return super.getCachedLibraryCounts(
      providerKey: providerKey,
      accountKey: accountKey,
      mediaKindKey: mediaKindKey,
    );
  }
}

class _CountedLibraryRow extends MapBase<String, dynamic> {
  _CountedLibraryRow(this.valuesByKey, this.storage);

  final Map<String, dynamic> valuesByKey;
  final _Storage storage;

  @override
  dynamic operator [](Object? key) {
    if (key == 'libraryCategory' && storage.measuringShelf) {
      storage.shelfCategoryReads++;
    }
    return valuesByKey[key];
  }

  @override
  void operator []=(String key, dynamic value) => valuesByKey[key] = value;

  @override
  void clear() => valuesByKey.clear();

  @override
  Iterable<String> get keys => valuesByKey.keys;

  @override
  dynamic remove(Object? key) => valuesByKey.remove(key);
}

class _NativeAccount extends Fake implements AnimeWitcherAccountService {
  String? owner;
  Map<LibraryCategory, int> remote = {};
  Completer<void>? countGate;
  Completer<void>? pageGate;
  int total = 0;

  @override
  String? get accountUid => owner;

  @override
  bool get isSignedIn => owner != null;

  @override
  Future<Map<LibraryCategory, int>> fetchLibraryCounts({
    bool manga = false,
  }) async {
    final captured = Map.of(remote);
    await countGate?.future;
    return captured;
  }

  @override
  Future<AnimeWitcherLibraryPage> fetchLibraryPage({
    required LibraryCategory category,
    bool manga = false,
    AnimeWitcherLibraryCursor? cursor,
  }) async {
    final captured = total;
    await pageGate?.future;
    return AnimeWitcherLibraryPage(
      items: [],
      total: captured,
      nextCursor: null,
    );
  }
}

class _ActiveCatalog extends ActiveProvider {
  @override
  AnimeWitcherProvider? build() => null;
  void pick(AnimeWitcherProvider? provider) => state = provider;
}

class _WitanimeAccount extends Fake implements WitanimeAccountService {
  bool signedIn = true;
  @override
  bool get isSignedIn => signedIn;
}

class _Anime3rbAccount extends Fake implements Anime3rbAccountService {
  bool signedIn = true;
  @override
  bool get isSignedIn => signedIn;
}

class _WitanimeLibrary extends ChangeNotifier
    implements WitanimeLibraryService {
  @override
  List<MultimediaItem> itemsForCategory(LibraryCategory category) => [];
  @override
  int countForCategory(LibraryCategory category) => 40 + category.index;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Anime3rbLibrary extends ChangeNotifier
    implements Anime3rbLibraryService {
  @override
  List<MultimediaItem> itemsForCategory(LibraryCategory category) => [];
  @override
  int countForCategory(LibraryCategory category) => 50 + category.index;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _Counts = Map<LibraryMediaKind, Map<LibraryCategory, int?>>;

_Counts _individualCounts(Library library, {bool witanimeAnime = false}) => {
  for (final kind in LibraryMediaKind.values)
    kind: {
      for (final category in LibraryCategory.valuesForCatalog(
        witanimeAnime: witanimeAnime && kind == LibraryMediaKind.anime,
      ))
        category: library.categoryCount(kind, category),
    },
};

Map<String, dynamic> _row(
  String url, {
  String type = 'anime',
  String? category,
  Object? favorite,
  int updatedAt = 0,
}) => {
  'url': url,
  'title': 'Title ${updatedAt.toString().padLeft(4, '0')}',
  'posterUrl': 'https://example.test/poster',
  'bannerUrl': 'https://example.test/banner',
  'description': 'Synthetic fixture description',
  'type': type,
  'catalogType': type,
  'year': 1999 + updatedAt % 27,
  'isDubbed': updatedAt.isEven,
  'provider': 'synthetic',
  'status': 'completed',
  if (category != null) 'libraryCategory': category,
  if (favorite != null) 'isFavorite': favorite,
  'updatedAt': updatedAt,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Box<dynamic> box;
  late _Storage storage;
  late _NativeAccount nativeAccount;
  late _WitanimeAccount witAccount;
  late _Anime3rbAccount arAccount;
  late ProviderContainer container;

  setUp(() async {
    final root = await Directory.systemTemp.createTemp('aw-counts-');
    final previous = PathProviderPlatform.instance;
    final worker = DownloadPersistenceWorker.forDirectory(root.path);
    PathProviderPlatform.instance = _Paths(root);
    storage = _Storage(worker);
    await storage.init();
    box = Hive.box<dynamic>(StorageService.kLibraryBox);
    nativeAccount = _NativeAccount();
    witAccount = _WitanimeAccount();
    arAccount = _Anime3rbAccount();
    final witLibrary = _WitanimeLibrary();
    final arLibrary = _Anime3rbLibrary();
    container = ProviderContainer(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        animeWitcherAccountServiceProvider.overrideWithValue(nativeAccount),
        activeProviderProvider.overrideWith(_ActiveCatalog.new),
        witanimeAccountServiceProvider.overrideWithValue(witAccount),
        anime3rbAccountServiceProvider.overrideWithValue(arAccount),
        witanimeLibraryServiceProvider.overrideWithValue(witLibrary),
        anime3rbLibraryServiceProvider.overrideWithValue(arLibrary),
      ],
    );
    addTearDown(() async {
      container.dispose();
      witLibrary.dispose();
      arLibrary.dispose();
      await Hive.close();
      await worker.close();
      PathProviderPlatform.instance = previous;
      await root.delete(recursive: true);
    });
  });

  const anime = LibraryMediaKind.anime;
  const manga = LibraryMediaKind.manga;
  const watching = LibraryCategory.watching;
  const favorite = LibraryCategory.favorite;
  const completed = LibraryCategory.completed;
  const later = LibraryCategory.continueLater;
  const uninterested = LibraryCategory.notInterested;

  testWidgets('phone badges and visible shelf hydration stay bounded', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await storage.setSelectedLibraryCategory(watching.storageKey);
      await box.putAll({
        for (final category in LibraryCategory.primaryValues)
          for (var i = 0; i < 1200; i++)
            '${category.storageKey}-$i': {
              ..._row(
                'https://example.test/${category.storageKey}/$i',
                type: i.isEven ? 'anime' : 'manga',
                category: category.storageKey,
                favorite: i % 3 == 0,
                updatedAt: i,
              ),
              'posterUrl': '',
            },
      });
    });
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    expect(find.text('أشاهده حاليًا 600'), findsOneWidget);
    expect(find.text('المفضلة 1000'), findsOneWidget);
    final library = container.read(libraryProvider.notifier);
    final profiles =
        <({int scans, int reads, int boundedReads, int cards, int micros})>[];
    for (var iteration = 0; iteration < 5; iteration++) {
      storage.resetWork();
      library.refresh();
      await tester.pump();
      profiles.add((
        scans: storage.scans,
        reads: storage.shelfReads,
        boundedReads: storage.boundedReads,
        cards: storage.hydratedCards,
        micros: storage.projectionMicros,
      ));
    }
    debugPrint('library-phone-badge-profile $profiles');
    expect(profiles.map((profile) => profile.scans), everyElement(1));
    expect(profiles.map((profile) => profile.reads), everyElement(0));
    expect(profiles.map((profile) => profile.boundedReads), everyElement(2));
    expect(profiles.map((profile) => profile.cards), everyElement(60));
    LibraryItemsGrid currentGrid() =>
        tester.widget<LibraryItemsGrid>(find.byType(LibraryItemsGrid));
    expect(currentGrid().items, hasLength(30));
    expect(currentGrid().items.first.url, 'https://example.test/watching/1198');
    expect(currentGrid().hasMore, isTrue);

    final shelfScroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(LibraryItemsGrid),
        matching: find.byType(Scrollable),
      ),
    );
    shelfScroll.position.jumpTo(shelfScroll.position.maxScrollExtent);
    await tester.pump();
    expect(currentGrid().items, hasLength(60));
    expect(currentGrid().items.last.url, 'https://example.test/watching/1080');
    expect(currentGrid().hasMore, isTrue);

    await tester.runAsync(() => box.delete('watching-1198'));
    library.refresh();
    await tester.pump();
    expect(find.text('أشاهده حاليًا 599'), findsOneWidget);
    expect(find.text('المفضلة 1000'), findsOneWidget);
    expect(currentGrid().items.first.url, 'https://example.test/watching/1196');

    await tester.runAsync(() => box.delete('watching-0'));
    library.refresh();
    await tester.pump();
    expect(find.text('أشاهده حاليًا 598'), findsOneWidget);
    expect(find.text('المفضلة 999'), findsOneWidget);
  });

  testWidgets(
    'phone library search shares one cold local scan across shelves',
    (tester) async {
      const rowsPerCategory = 480;
      const rowCount = rowsPerCategory * 5;
      await tester.runAsync(() async {
        await storage.setSelectedLibraryCategory(watching.storageKey);
        await box.putAll({
          for (final category in LibraryCategory.primaryValues)
            for (var i = 0; i < rowsPerCategory; i++)
              '${category.storageKey}-$i': _CountedLibraryRow({
                ..._row(
                  'https://example.test/${category.storageKey}/$i',
                  type: i.isEven ? 'anime' : 'manga',
                  category: category.storageKey,
                  favorite: i % 3 == 0,
                  updatedAt: i,
                ),
                'title': i >= rowsPerCategory - 8
                    ? 'Target ${category.storageKey} $i'
                    : 'Other ${category.storageKey} $i',
                'posterUrl': '',
              }, storage),
        });
      });
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      MultimediaItem? opened;
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const LibraryScreen()),
          GoRoute(
            path: '/details',
            builder: (_, state) {
              opened = (state.extra! as DetailsRouteExtra).item;
              return const Scaffold(body: Text('Library selection'));
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
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey<String>('library-search'));
      final library = container.read(libraryProvider.notifier);
      expect(find.text('أشاهده حاليًا 240'), findsOneWidget);
      final reference = <String, MultimediaItem>{};
      for (final category in LibraryCategory.values) {
        for (final item
            in storage
                .getLocalLibraryShelf(
                  category: category.storageKey,
                  manga: false,
                  limit: 30,
                )
                .items) {
          reference.putIfAbsent(item.url, () => item);
        }
      }
      final expected = reference.values
          .where((item) => item.title.startsWith('Target'))
          .map((item) => item.url)
          .toList(growable: false);
      storage.resetWork();

      List<String> shown() => tester
          .widget<LibraryItemsGrid>(find.byType(LibraryItemsGrid))
          .items
          .map((item) => item.url)
          .toList(growable: false);
      await tester.enterText(search, 'tArGeT');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(shown(), expected);
      // Watching was already mounted. The search must not hydrate it again or
      // traverse the box for each of the four remaining primary shelves.
      expect(storage.shelfCategoryReads, rowCount);
      expect(storage.boundedReads, 0);
      expect(storage.batchedReads, 1);
      expect(storage.hydratedCards, 150);

      storage.resetWork();
      await tester.enterText(search, 'target completed');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(shown(), expected.where((url) => url.contains('/completed/')));
      expect(storage.shelfCategoryReads, 0);
      final selected = shown().first;
      await tester.tap(find.byKey(ValueKey(selected)).hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('Library selection'), findsOneWidget);
      expect(opened?.url, selected);
      router.pop();
      await tester.pumpAndSettle();

      // The search cache invalidates on actual Library refresh. A direct Hive
      // deletion affects both search results and the authoritative badge.
      await tester.runAsync(
        () => box.delete('completed-${selected.split('/').last}'),
      );
      library.refresh();
      await tester.pumpAndSettle();
      expect(shown(), isNot(contains(selected)));
      expect(find.text('تمت مشاهدته 239'), findsOneWidget);
      await tester.enterText(search, '');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(shown().first, 'https://example.test/watching/478');
    },
  );

  test('same per-shelf winner before kind filtering, all legacy branches, no stale local data', () async {
    // Insert less-preferred key first and newest. Box getAt orders by key,
    // not insertion or by recency, and the first eligible row wins each shelf.
    await box.putAll({
      'b': _row(
        ' https://animewitcher.com/watch/same/episode-9?mock=1 ',
        category: 'watching',
        favorite: 'TRUE',
        updatedAt: 9999,
      ),
      'a': _row(
        'http://www.animewitcher.com/watch/same#mock',
        category: 'watching',
        type: 'مانهوا',
        favorite: false,
      ),
      'c': _row(
        'https://animewitcher.com/watch/same',
        category: 'completed',
        type: 'manhwa',
        favorite: 1,
      ),
      'd': {
        ..._row('https://example.test/legacy'),
        'type': null,
        'contentType': 'Manga Extra',
        'library_category': 'on_Hold',
        'is_favorite': 0,
      },
      'e': _row('https://example.test/old-bookmark'),
      'f': _row('https://example.test/old-fav', category: 'fav', type: 'tv'),
      'g': _row('https://example.test/no-category', category: 'nonsense'),
      'h': _row('  ', category: 'watching', type: 'manga', favorite: true),
      'i': const <Object>[],
      'j': _row('http://[invalid', category: 'pin', type: 'film'),
      'k': _row(
        'https://example.test/not',
        category: 'no_watching',
        type: 'live',
      ),
    });
    final library = container.read(libraryProvider.notifier);
    expect(
      library.itemsForCategory(manga, watching).single.url,
      'https://animewitcher.com/watch/same',
    );
    final initial = library.categoryCounts(witanimeAnime: false);
    expect(storage.scans, 1);
    expect(initial, _individualCounts(library));
    expect(initial[anime]![watching], 0);
    expect(initial[manga]![watching], 1);
    expect(initial[manga]![completed], 1);
    expect(initial[anime]![favorite], 4);
    expect(initial[manga]![favorite], 0);
    expect(initial[manga]![later], 1);
    expect(initial[anime]![uninterested], 1);
    expect(storage.diskMaps, 0);

    await box.delete('a');
    final afterDelete = library.categoryCounts(witanimeAnime: false);
    expect(afterDelete, _individualCounts(library));
    expect(afterDelete[anime]![watching], 1);
    expect(afterDelete[manga]![watching], 0);
    await storage.setLibraryItemCategory(
      'https://example.test/not',
      'completed',
    );
    final afterMove = library.categoryCounts(witanimeAnime: false);
    expect(afterMove[anime]![uninterested], 0);
    expect(afterMove[anime]![completed], 1);
    expect(initial[manga]![watching], 1);
    await box.clear();
    final cleared = library.categoryCounts(witanimeAnime: false);
    expect(cleared.values.expand((kind) => kind.values), everyElement(0));
    expect(storage.scans, 4);
  });

  test(
    'bounded shelf preserves canonical winners, metadata and sort ties',
    () async {
      await box.putAll({
        'a': {
          ..._row(
            'http://www.animewitcher.com/watch/same#old',
            category: 'watching',
            type: 'manga',
            favorite: 'true',
            updatedAt: 1,
          ),
          'title': 'Zulu',
        },
        'b': {
          ..._row(
            'https://animewitcher.com/watch/same/2',
            category: 'watching',
            favorite: 1,
            updatedAt: 1000,
          ),
          'title': 'Anime duplicate should not win this shelf',
        },
        for (var index = 0; index < 72; index++)
          'item-$index': {
            ..._row(
              'https://example.test/library/$index',
              type: index.isEven ? 'anime' : 'manga',
              category: index % 3 == 0 ? 'completed' : 'watching',
              favorite: index % 3 != 2,
              updatedAt: index % 9,
            ),
            'title': index % 2 == 0 ? 'same' : 'Same',
            'status': index.isEven ? 'completed' : 'upcoming',
          },
      });

      for (final category in [watching, favorite, completed]) {
        final full = storage.getLibraryItems(category: category.storageKey);
        for (final kind in LibraryMediaKind.values) {
          final expected = full.where(kind.accepts).toList();
          for (final limit in [0, 1, 10, 30, 100]) {
            final page = storage.getLocalLibraryShelf(
              category: category.storageKey,
              manga: kind == manga,
              limit: limit,
            );
            expect(page.total, expected.length);
            expect(
              page.items.map((item) => item.toJson()),
              expected.take(limit).map((item) => item.toJson()),
            );
          }
        }
      }
      final limits = <String, int>{
        'watching': 17,
        'favorite': 30,
        'completed': 100,
      };
      for (final kind in LibraryMediaKind.values) {
        final batch = storage.getLocalLibraryShelves(
          limits: limits,
          manga: kind == manga,
        );
        for (final entry in limits.entries) {
          final single = storage.getLocalLibraryShelf(
            category: entry.key,
            manga: kind == manga,
            limit: entry.value,
          );
          expect(batch[entry.key]!.total, single.total);
          expect(
            batch[entry.key]!.items.map((item) => item.toJson()),
            single.items.map((item) => item.toJson()),
          );
        }
      }
      final library = container.read(libraryProvider.notifier);
      expect(
        library.itemsForCategory(anime, watching).map((item) => item.url),
        isNot(contains('https://animewitcher.com/watch/same')),
      );
      await box.delete('a');
      final projected = storage.getLocalLibraryShelf(
        category: watching.storageKey,
        manga: false,
        limit: 1,
      );
      expect(projected.items.single.url, 'https://animewitcher.com/watch/same');
    },
  );

  test(
    'exact remote count precedence and fresh ownership across held requests',
    () async {
      const a = 'synthetic-A';
      const b = 'synthetic-B';
      await box.put(
        'aa',
        _row(
          'https://example.test/preserved',
          category: 'watching',
          favorite: true,
        ),
      );
      await storage.setCachedLibraryCounts(
        providerKey: 'native',
        accountKey: a,
        mediaKindKey: 'anime',
        counts: {'watching': 0, 'favorite': 42, 'completed': 0},
        merge: false,
      );
      await storage.setCachedLibraryCounts(
        providerKey: 'native',
        accountKey: b,
        mediaKindKey: 'anime',
        counts: {'watching': 75, 'favorite': 2},
        merge: false,
      );

      nativeAccount.owner = a;
      final library = container.read(libraryProvider.notifier);
      var view = library.categoryCounts(witanimeAnime: false);
      expect(view[anime]![watching], 1);
      expect(view[anime]![favorite], 42);
      expect(view[anime]![completed], 0);
      expect(view[anime]![later], isNull);
      expect(storage.scans, 1);
      expect(storage.diskMaps, 2);

      nativeAccount
        ..remote = {watching: 0, favorite: 99}
        ..countGate = Completer<void>()
        ..pageGate = Completer<void>()
        ..total = 999;
      final request = library.refreshVisibleFromServer(
        category: favorite,
        mediaKind: anime,
      );
      nativeAccount.owner = b;
      container.read(accountDataRevisionProvider.notifier).bump();
      nativeAccount.countGate!.complete();
      nativeAccount.pageGate!.complete();
      await request;
      view = library.categoryCounts(witanimeAnime: false);
      expect(view[anime]![watching], 75);
      expect(view[anime]![favorite], 2);
      expect(view[anime]![completed], isNull);
      expect(view, _individualCounts(library));

      nativeAccount
        ..remote = {watching: 0, favorite: 6}
        ..total = 13;
      await library.refreshServerCounts(anime);
      await library.refreshVisibleFromServer(
        category: favorite,
        mediaKind: anime,
      );
      view = library.categoryCounts(witanimeAnime: false);
      expect(view[anime]![watching], 0); // confirmed server zero beats local 1.
      expect(view[anime]![favorite], 13); // loaded-page total beats counts.
      expect(view, _individualCounts(library));

      // A complete remote map for both kinds must not do any local scan.
      nativeAccount.remote = {
        for (final c in LibraryCategory.values) c: 8 + c.index,
      };
      // Anime's map is sparse from the earlier valid response.
      await library.refreshServerCounts(manga);
      expect(library.categoryCounts(witanimeAnime: false)[manga]![favorite], 8);

      nativeAccount.owner = 'synthetic-C';
      container.read(accountDataRevisionProvider.notifier).bump();
      await library.refreshServerCounts(anime);
      await library.refreshServerCounts(manga);
      storage
        ..scans = 0
        ..diskMaps = 0;
      view = library.categoryCounts(witanimeAnime: false);
      expect(view[anime]![watching], 9);
      expect(view[manga]![watching], 9);
      expect(storage.scans, 0);
      expect(storage.diskMaps, 0);
      nativeAccount.owner = null;
      container.read(accountDataRevisionProvider.notifier).bump();
      expect(library.categoryCounts(witanimeAnime: false)[anime]![favorite], 1);
      expect(
        library.categoryCounts(witanimeAnime: false)[anime]![completed],
        0,
      );
    },
  );

  test('provider authority is live, keeps Witanime shelf visibility and local manga', () async {
    await box.put(
      'm',
      _row('https://example.test/chapter', category: 'watching', type: 'manga'),
    );
    await box.put(
      'a',
      _row('https://example.test/anime', category: 'watching'),
    );
    final library = container.read(libraryProvider.notifier);
    final active =
        container.read(activeProviderProvider.notifier) as _ActiveCatalog;
    active.pick(
      WitanimeProvider(
        (_, {cancelToken}) async => throw StateError('network forbidden'),
      ),
    );
    storage.resetWork();
    expect(library.itemsForSearchShelves(anime, [watching, completed]), {
      watching: <MultimediaItem>[],
      completed: <MultimediaItem>[],
    }); // Both shelves belong to signed-in Witanime, not the Hive box.
    expect(storage.batchedReads, 0);
    expect(storage.boundedReads, 0);
    var view = library.categoryCounts(witanimeAnime: true);
    expect(view, _individualCounts(library, witanimeAnime: true));
    expect(view[anime]!.length, 4);
    expect(view[anime]![watching], 41);
    expect(view[manga]![watching], 1);

    witAccount.signedIn = false;
    expect(library.categoryCounts(witanimeAnime: true)[anime]![watching], 1);
    active.pick(
      Anime3rbProvider(
        (_, {headers = const {}, cancelToken}) async =>
            throw StateError('network forbidden'),
      ),
    );
    view = library.categoryCounts(witanimeAnime: false);
    expect(view, _individualCounts(library));
    expect(view[anime]!.length, 6);
    expect(view[anime]![watching], 51);
    expect(view[manga]![watching], 1);
    storage.resetWork();
    expect(library.itemsForSearchShelves(anime, [watching, completed]), {
      watching: <MultimediaItem>[],
      completed: <MultimediaItem>[],
    }); // Signed-in Anime3rb is authoritative as well.
    expect(storage.batchedReads, 0);
    expect(storage.boundedReads, 0);
    arAccount.signedIn = false;
    expect(library.categoryCounts(witanimeAnime: false)[anime]![watching], 1);
    nativeAccount.owner = 'native';
    storage.resetWork();
    expect(library.itemsForSearchShelves(anime, [watching, completed]), {
      watching: <MultimediaItem>[],
      completed: <MultimediaItem>[],
    }); // No using Hive rows as a signed-in authoritative initial page.
    expect(storage.batchedReads, 0);
    expect(storage.boundedReads, 0);
  });
}
