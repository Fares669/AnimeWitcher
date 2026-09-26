import 'package:animewitcher/core/account/account_providers.dart';
import 'package:animewitcher/core/account/animewitcher_account_service.dart';
import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/storage/history_repository.dart';
import 'package:animewitcher/core/storage/secure_token_storage.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/library/presentation/library_screen.dart';
import 'package:animewitcher/features/library/presentation/widgets/library_phone_shelves.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_storage_service.dart';

MultimediaItem _item(
  String title, {
  MultimediaContentType type = MultimediaContentType.anime,
  int? year,
}) => MultimediaItem(
  title: title,
  url: 'https://example.test/${type.name}/$title',
  posterUrl: '',
  contentType: type,
  year: year,
);

final class _LibraryStorage extends MemoryStorageService {
  _LibraryStorage(this.lists);

  final Map<String, List<MultimediaItem>> lists;
  final Map<String, String?> strings = <String, String?>{};
  String selectedCategory = 'watching';

  @override
  String? getString(String key) => strings[key];

  @override
  Future<void> setString(String key, String? value) async {
    strings[key] = value;
  }

  @override
  String getSelectedLibraryCategory() => selectedCategory;

  @override
  Future<void> setSelectedLibraryCategory(String category) async {
    selectedCategory = category;
  }

  int reads = 0;
  int dateLookups = 0;

  @override
  List<MultimediaItem> getLibraryItems({String? category}) =>
      _read(category);

  List<MultimediaItem> _read(String? category) {
    reads++;
    return _items(category);
  }

  List<MultimediaItem> _items(String? category) => category == null
      ? [for (final list in lists.values) ...list]
      : lists[category] ?? const <MultimediaItem>[];

  @override
  int getLibraryItemUpdatedAt(String url) {
    dateLookups++;
    return 0;
  }

  @override
  bool isLibraryItemFavorite(String url) => false;

  @override
  String? getLibraryItemCategory(String url) => null;
}

final class _History extends WatchHistory {
  _History(this.items);

  final List<HistoryItem> items;

  @override
  List<HistoryItem> build() => items;

  @override
  Future<void> refreshFromServer() async {}
}

Future<_LibraryStorage> _pump(
  WidgetTester tester, {
  required Size size,
  String kind = 'manga',
  List<HistoryItem> history = const <HistoryItem>[],
  Map<String, String> strings = const <String, String>{},
}) async {
  final storage =
      _LibraryStorage({
          'watching': [
            _item('Frieren'),
            _item('Berserk', type: MultimediaContentType.manga, year: 1989),
            _item('Vagabond', type: MultimediaContentType.manga, year: 1998),
          ],
          'pinned': [_item('Dandadan', type: MultimediaContentType.manga)],
        })
        ..strings['library_media_kind'] = kind
        ..strings.addAll(strings);
  final account = AnimeWitcherAccountService(
    storage: storage,
    secureStorage: SecureTokenStorage(storage),
  );
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        storageServiceProvider.overrideWithValue(storage),
        animeWitcherAccountServiceProvider.overrideWithValue(account),
        watchHistoryProvider.overrideWith(() => _History(history)),
      ],
      child: MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const LibraryScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return storage;
}

void main() {
  testWidgets('phone: manga lists are rows, empty ones one line', (
    tester,
  ) async {
    await _pump(tester, size: const Size(400, 860));

    expect(find.byKey(const ValueKey('library-search')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('library-shelf-manga-watching')),
      findsOneWidget,
    );
    expect(find.text('أقرأها حاليًا · 2'), findsOneWidget);
    expect(find.text('أرغب بقراءتها · 1'), findsOneWidget);
    expect(find.text('المفضلة · 0'), findsOneWidget);
    // Anime titles stay on the other tab.
    expect(find.text('Frieren'), findsNothing);
    expect(tester.takeException(), isNull);
    // The poster fallback batches its artwork lookups on a short timer.
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('phone: search folds the rows into one tagged grid', (
    tester,
  ) async {
    await _pump(tester, size: const Size(400, 860));

    await tester.enterText(find.byKey(const ValueKey('library-search')), 'vag');
    await tester.pump(const Duration(milliseconds: 200));
    // Still typing: the rows stay until the pause.
    expect(find.byKey(const ValueKey('library-grid-manga')), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('library-grid-manga')), findsOneWidget);
    expect(find.text('Vagabond'), findsWidgets);
    expect(find.text('Berserk'), findsNothing);
    expect(find.text('مانجا 1'), findsOneWidget);
    expect(find.text('أنمي 0'), findsOneWidget);
    // The poster fallback batches its artwork lookups on a short timer.
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('phone: the filter sheet hides empty lists and keeps it', (
    tester,
  ) async {
    final storage = await _pump(tester, size: const Size(400, 860));

    await tester.tap(find.byKey(const ValueKey('library-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-filter-hide-empty')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();

    expect(find.text('المفضلة · 0'), findsNothing);
    expect(find.text('أقرأها حاليًا · 2'), findsOneWidget);
    expect(storage.strings['library_shelves_hide_empty'], 'true');
    // The poster fallback batches its artwork lookups on a short timer.
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('phone: the grid view sorts by year', (tester) async {
    await _pump(
      tester,
      size: const Size(400, 860),
      strings: {'library_shelves_view': 'grid', 'library_shelves_sort': 'year'},
    );

    final vagabond = tester.getTopRight(find.text('Vagabond').first);
    final berserk = tester.getTopRight(find.text('Berserk').first);
    // Right to left: the newer one comes first, on the right.
    expect(vagabond.dx, greaterThan(berserk.dx));
    // The poster fallback batches its artwork lookups on a short timer.
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('PC: every list in the side column, both halves', (tester) async {
    await _pump(
      tester,
      size: const Size(1400, 900),
      kind: 'anime',
      history: [
        HistoryItem(
          item: _item('One Piece'),
          position: 10,
          duration: 20,
          timestamp: 1,
        ),
      ],
    );

    expect(find.byKey(const ValueKey('library-side-list')), findsOneWidget);
    expect(find.text('أشاهده حاليًا'), findsOneWidget);
    expect(find.text('أقرأها حاليًا'), findsOneWidget);
    expect(find.text('آخر المشاهدات'), findsOneWidget);
    expect(find.text('Frieren'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('library-side-manga-pinned')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Dandadan'), findsWidgets);
    expect(find.text('Frieren'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('library-side-recent')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('library-recent')), findsOneWidget);
    expect(find.text('One Piece'), findsWidgets);
    // The poster fallback batches its artwork lookups on a short timer.
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('PC: the filter hides empty lists from the side column', (
    tester,
  ) async {
    final storage = await _pump(
      tester,
      size: const Size(1400, 900),
      kind: 'anime',
    );
    expect(
      find.byKey(const ValueKey('library-side-manga-favorite')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('library-side-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-filter-hide-empty')));
    await tester.pumpAndSettle();

    expect(storage.strings['library_shelves_hide_empty'], 'true');
    expect(
      find.byKey(const ValueKey('library-side-manga-favorite')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('library-side-manga-watching')),
      findsOneWidget,
    );
    // The list on screen keeps its row.
    expect(
      find.byKey(const ValueKey('library-side-anime-watching')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('PC: the filter sort orders آخر المشاهدات too', (tester) async {
    await _pump(
      tester,
      size: const Size(1400, 900),
      kind: 'anime',
      strings: {'library_shelves_sort': 'year'},
      history: [
        HistoryItem(
          item: _item('Older', year: 1999),
          position: 0,
          duration: 0,
          timestamp: 2,
        ),
        HistoryItem(
          item: _item('Newer', year: 2026),
          position: 0,
          duration: 0,
          timestamp: 1,
        ),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('library-side-recent')));
    await tester.pump();
    await tester.pump();

    final newer = tester.getTopRight(find.text('Newer').first);
    final older = tester.getTopRight(find.text('Older').first);
    // By year, not by when it was watched: 2026 first, on the right.
    expect(newer.dx, greaterThan(older.dx));
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('phone: a row shows ten titles, عرض الكل shows every one', (
    tester,
  ) async {
    final storage = _LibraryStorage({
      'pinned': [
        for (var i = 1; i <= 12; i++)
          _item('Manga $i', type: MultimediaContentType.manga),
      ],
    })..strings['library_media_kind'] = 'manga';
    final account = AnimeWitcherAccountService(
      storage: storage,
      secureStorage: SecureTokenStorage(storage),
    );
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageServiceProvider.overrideWithValue(storage),
          animeWitcherAccountServiceProvider.overrideWithValue(account),
          watchHistoryProvider.overrideWith(() => _History(const [])),
        ],
        child: MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const LibraryScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final row = find.byKey(const ValueKey('library-shelf-manga-pinned'));
    expect(find.text('أرغب بقراءتها · 12'), findsOneWidget);
    final list = tester.widget<ListView>(
      find.descendant(of: row, matching: find.byType(ListView)),
    );
    // Ten posters and the nine gaps between them.
    expect(list.childrenDelegate.estimatedChildCount, 10 + 9);

    await tester.tap(find.descendant(of: row, matching: find.text('عرض الكل')));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryListPage), findsOneWidget);
    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(grid.childrenDelegate.estimatedChildCount, 12);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('PC: favourite characters sit under the anime lists', (
    tester,
  ) async {
    await _pump(tester, size: const Size(1400, 900), kind: 'anime');

    await tester.tap(find.byKey(const ValueKey('library-side-characters')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('library-characters')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('library-pane-title')))
          .data,
      'الشخصيات المفضلة',
    );
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('phone: the anime tab ends with the favourite characters', (
    tester,
  ) async {
    await _pump(tester, size: const Size(400, 860), kind: 'anime');
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('library-characters')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('الشخصيات المفضلة'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('phone: typing a search does not read the library again', (
    tester,
  ) async {
    final storage = await _pump(tester, size: const Size(400, 860));
    final before = storage.reads;

    await tester.enterText(find.byKey(const ValueKey('library-search')), 'ber');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Berserk'), findsWidgets);
    await tester.enterText(find.byKey(const ValueKey('library-search')), '');
    await tester.pump(const Duration(milliseconds: 600));

    // The lists are kept: searching and clearing read nothing from storage,
    // and newest-first needs no date looked up per title.
    expect(storage.reads, before);
    expect(storage.dateLookups, 0);
    await tester.pump(const Duration(milliseconds: 100));
  });
}
