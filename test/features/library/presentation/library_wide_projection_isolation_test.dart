import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/network/dio_client_provider.dart';
import 'package:animewitcher/core/storage/library_category.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/library_media_kind.dart';
import 'package:animewitcher/features/library/presentation/library_provider.dart';
import 'package:animewitcher/features/library/presentation/library_screen.dart';
import 'package:animewitcher/features/library/presentation/widgets/bookmarks_tab.dart';
import 'package:animewitcher/features/library/presentation/widgets/library_side_list.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

class _Work {
  int titles = 0;
  int countSnapshots = 0;
}

class _Item extends MultimediaItem {
  _Item(
    this.work, {
    required super.title,
    required super.url,
    required super.contentType,
    super.year,
  }) : super(posterUrl: '');

  final _Work work;

  @override
  String get title {
    work.titles++;
    return super.title;
  }
}

class _Storage extends MemoryStorageService {
  _Storage(this.rows, this.work) {
    settings['library_media_kind'] = 'anime';
    settings['library_shelves_sort'] = 'name';
  }

  final List<MultimediaItem> rows;
  final _Work work;
  String selected = 'watching';

  @override
  List<MultimediaItem> getLibraryItems({String? category}) =>
      category == null || category == 'watching' ? rows : const [];

  @override
  Map<String, ({int anime, int manga})> getLocalLibraryCounts() {
    work.countSnapshots++;
    return super.getLocalLibraryCounts();
  }

  @override
  String getSelectedLibraryCategory() => selected;

  @override
  Future<void> setSelectedLibraryCategory(String value) async {
    selected = value;
  }

  @override
  bool isLibraryItemFavorite(String url) => false;

  @override
  String? getLibraryItemCategory(String url) => 'watching';
}

class _History extends WatchHistory {
  @override
  List<HistoryItem> build() => const <HistoryItem>[];

  void setCount(int count) {
    state = [
      for (var i = 0; i < count; i++)
        HistoryItem(
          item: MultimediaItem(
            title: 'Recent $i',
            url: 'https://fixture.invalid/recent/$i',
            posterUrl: '',
            contentType: MultimediaContentType.movie,
          ),
          position: i,
          duration: 100,
          timestamp: i,
        ),
      HistoryItem(
        item: MultimediaItem(
          title: 'Not watch history',
          url: 'https://fixture.invalid/manga/history',
          posterUrl: '',
          contentType: MultimediaContentType.manga,
        ),
        position: 0,
        duration: 100,
        timestamp: 0,
      ),
    ];
  }

  @override
  Future<void> refreshFromServer() async {}
}

void main() {
  testWidgets('wide library keeps unrelated changes out of its active shelf', (
    tester,
  ) async {
    const capacity = 510;
    const samples = 8;
    final work = _Work();
    final rows = <MultimediaItem>[
      // Reverse insertion order, mixed scripts and content on one local shelf.
      for (var i = capacity - 1; i >= 0; i--)
        _Item(
          work,
          title:
              '${i.isEven ? 'Sa' : 'sA'} ${i.toString().padLeft(3, '0')} عربي',
          url: 'https://fixture.invalid/anime/$i',
          year: 1800 + i,
          contentType: i.isEven
              ? MultimediaContentType.anime
              : MultimediaContentType.movie,
        ),
      for (var i = 2; i >= 0; i--)
        _Item(
          work,
          title: 'Manga $i',
          url: 'https://fixture.invalid/manga/$i',
          year: 2000 + i,
          contentType: MultimediaContentType.manga,
        ),
    ];
    final storage = _Storage(rows, work);
    final account = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: SecureTokenStorage(storage),
    );
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) =>
              handler.reject(DioException(requestOptions: request)),
        ),
      );
    addTearDown(() => dio.close(force: true));
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          dioClientProvider.overrideWithValue(dio),
          animeWitcherAccountServiceProvider.overrideWithValue(account),
          watchHistoryProvider.overrideWith(_History.new),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const LibraryScreen(),
                  ),
                ),
                child: const Text('open library fixture'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open library fixture'));
    await tester.pumpAndSettle();

    final route = find.byType(LibraryScreen);
    final container = ProviderScope.containerOf(tester.element(route));
    final library = container.read(libraryProvider.notifier);
    final history = container.read(watchHistoryProvider.notifier) as _History;
    final gridFinder = find.byType(LibraryItemsGrid);
    LibraryItemsGrid grid() => tester.widget<LibraryItemsGrid>(gridFinder);
    List<String> keys() => grid().items.map((item) => item.url).toList();
    String anime(int i) => 'https://fixture.invalid/anime/$i';

    // Prime the real provider's normal local paging. The timed events below
    // are actual Riverpod updates to its neighboring history badge.
    for (var i = 0; i < capacity ~/ Library.pageSize; i++) {
      if (grid().items.length >= capacity) break;
      await library.loadNextPage(
        mediaKind: LibraryMediaKind.anime,
        category: LibraryCategory.watching,
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final allKeys = List<String>.generate(capacity, anime);
    expect(keys(), allKeys);
    final gridScroll = tester.state<ScrollableState>(
      find.descendant(of: gridFinder, matching: find.byType(Scrollable)).first,
    );
    gridScroll.position.jumpTo(850);
    await tester.pumpAndSettle();

    final recent = find.byKey(const ValueKey('library-side-recent'));
    final titlesBefore = work.titles;
    final countsBefore = work.countSnapshots;
    var rebuiltGrids = 0;
    var previousGrid = grid();
    for (var i = 1; i <= samples; i++) {
      history.setCount(i);
      await tester.pump();
      expect(tester.widget<LibrarySideRow>(recent).count, i);
      final next = grid();
      if (!identical(previousGrid.items, next.items)) rebuiltGrids++;
      previousGrid = next;
      expect(keys(), allKeys);
      expect(gridScroll.position.pixels, 850);
    }
    final historyTitles = work.titles - titlesBefore;
    final historyCounts = work.countSnapshots - countsBefore;
    expect(rebuiltGrids, 0);
    expect(historyTitles, 0);
    expect(historyCounts, 0);

    final filter = find.byKey(const ValueKey('library-side-filter'));
    await tester.tap(filter);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('library-side-manga-favorite')),
      findsOneWidget,
    );
    final beforeFilter = grid().items;
    await tester.tap(find.byKey(const ValueKey('library-filter-hide-empty')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('library-side-manga-favorite')),
      findsNothing,
    );
    expect(identical(grid().items, beforeFilter), isTrue);

    await tester.tap(find.text('السنة').last);
    await tester.pumpAndSettle();
    expect(keys(), allKeys.reversed.toList());
    expect(identical(grid().items, beforeFilter), isFalse);

    await tester.tap(find.text('الاسم').last);
    await tester.pumpAndSettle();
    expect(keys(), allKeys);
    Navigator.of(tester.element(find.byType(Dialog))).pop();
    await tester.pumpAndSettle();

    // A new shelf value (even with the same URL) remains authoritative.
    final editedIndex = rows.indexWhere((item) => item.url == anime(400));
    rows[editedIndex] = _Item(
      work,
      title: '000 changed live',
      url: anime(400),
      year: 2200,
      contentType: MultimediaContentType.anime,
    );
    library.refresh();
    await tester.pumpAndSettle();
    expect(keys().first, anime(400));
    expect(grid().items.first, same(rows[editedIndex]));
    await tester.tap(find.byKey(const ValueKey('library-side-manga-watching')));
    await tester.pumpAndSettle();
    expect(keys(), [
      for (var i = 0; i < 3; i++) 'https://fixture.invalid/manga/$i',
    ]);
    expect(tester.widget<LibrarySideRow>(recent).count, samples);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(route, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
