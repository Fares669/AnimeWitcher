import 'dart:async';

import 'package:animewitcher/core/domain/entity/multimedia_item.dart';
import 'package:animewitcher/core/extensions/extension_manager.dart';
import 'package:animewitcher/core/router/app_router.dart';
import 'package:animewitcher/core/services/notification_service.dart';
import 'package:animewitcher/core/storage/storage_service.dart';
import 'package:animewitcher/features/library/presentation/history_provider.dart';
import 'package:animewitcher/features/more/presentation/recent_watched_screen.dart';
import 'package:animewitcher/l10n/generated/app_localizations.dart';
import 'package:animewitcher/shared/widgets/anime_catalog_shimmer.dart';
import 'package:animewitcher/shared/widgets/app_back_button.dart';
import 'package:animewitcher/shared/widgets/catalog_page.dart';
import 'package:animewitcher/shared/widgets/multimedia_card.dart';
import 'package:crypto/crypto.dart';
// Match the app's Material compatibility API.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../support/memory_storage_service.dart';

const _screenshot = ValueKey('recent-watched-render-work');
const _emptyLabel = 'لا توجد مشاهدات حتى الآن';
const _font = 'C21RecentReadex';

class _OfflineHistory extends WatchHistory {
  _OfflineHistory(this.initial);

  final List<HistoryItem> initial;
  final List<Completer<void>> requests = [];
  final List<MultimediaItem> removed = [];

  @override
  List<HistoryItem> build() => initial;

  @override
  Future<void> refreshFromServer() {
    final request = Completer<void>();
    requests.add(request);
    return request.future;
  }

  void publish(List<HistoryItem> rows) {
    state = List<HistoryItem>.unmodifiable(rows);
  }

  @override
  Future<void> removeForItem(MultimediaItem item) async {
    removed.add(item);
    publish(state.where((row) => row.item.url != item.url).toList());
  }
}

class _Notifications extends NotificationService {
  final List<String> messages = [];

  @override
  void showSuccess(
    String message, {
    String? title,
    IconData? icon,
    Duration duration = NotificationService.defaultDuration,
  }) {
    messages.add(message);
  }
}

List<HistoryItem> _rows([int count = 96]) => List.generate(
  count,
  (i) => HistoryItem(
    item: MultimediaItem(
      title: 'حكاية ${i + 1}',
      url: 'https://fixture.test/title/$i',
      posterUrl: '',
      contentType: MultimediaContentType.anime,
      year: 2000 + i % 20,
    ),
    timestamp: count - i,
    position: 2000,
    duration: 9000,
  ),
  growable: false,
);

Future<void> _open(
  WidgetTester tester,
  _OfflineHistory offline, {
  required Size size,
  required _Notifications notifications,
  required List<MultimediaItem> visited,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => const RecentWatchedScreen()),
              ),
              child: const Text('افتح قائمة المشاهدات'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/details',
        builder: (context, state) {
          final item = (state.extra! as DetailsRouteExtra).item;
          if (visited.isEmpty || !identical(visited.last, item))
            visited.add(item);
          return Scaffold(
            body: Center(
              child: TextButton(
                onPressed: context.pop,
                child: Text('عودة من ${item.title}'),
              ),
            ),
          );
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        watchHistoryProvider.overrideWith(() => offline),
        notificationServiceProvider.overrideWithValue(notifications),
        storageServiceProvider.overrideWithValue(MemoryStorageService()),
        activeProviderProvider.overrideWithValue(null),
      ],
      child: RepaintBoundary(
        key: _screenshot,
        child: MaterialApp.router(
          theme: ThemeData(fontFamily: _font),
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          routerConfig: router,
        ),
      ),
    ),
  );
  await tester.tap(find.text('افتح قائمة المشاهدات'));
  await tester.pump();
  // Use bounded pumps: the empty initial pull has a running shimmer.
  await tester.pump(const Duration(milliseconds: 350));
  expect(find.byType(RecentWatchedScreen), findsOneWidget);
  expect(offline.requests, hasLength(1));
  expect(
    Directionality.of(tester.element(find.byType(RecentWatchedBody))),
    TextDirection.rtl,
  );
}

Future<String?> _rgba(WidgetTester tester) => tester.runAsync(() async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_screenshot),
  );
  final image = await boundary.toImage();
  try {
    final bytes = (await image.toByteData())!;
    return sha256
        .convert(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        )
        .toString();
  } finally {
    image.dispose();
  }
});

Map<Key, MultimediaCard> _mountedCards(WidgetTester tester) => {
  for (final card in tester.widgetList<MultimediaCard>(
    find.byType(MultimediaCard),
  ))
    card.key!: card,
};

int _outerPaintBoundaries(WidgetTester tester, Key key) {
  final card = find.byKey(key);
  RenderObject? parent = tester.renderObject<RenderObject>(card).parent;
  var count = 0;
  while (parent != null && parent is! RenderSliverGrid) {
    if (parent is RenderRepaintBoundary) count++;
    parent = parent.parent;
  }
  expect(parent, isA<RenderSliverGrid>());
  expect(
    find.descendant(of: card, matching: find.byType(RepaintBoundary)),
    findsWidgets,
  );
  return count;
}

void main() {
  setUpAll(() async {
    final loader = FontLoader(_font)
      ..addFont(
        rootBundle.load('assets/fonts/readex_pro/ReadexPro-Regular.ttf'),
      );
    await loader.load();
  });

  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets(
      'populated RTL Recent Watched avoids work on no-op refreshes at ${size.width}',
      (tester) async {
        addTearDown(tester.view.reset);
        final rows = _rows();
        final offline = _OfflineHistory(rows);
        final notifications = _Notifications();
        addTearDown(notifications.dispose);
        final visited = <MultimediaItem>[];
        await _open(
          tester,
          offline,
          size: size,
          notifications: notifications,
          visited: visited,
        );

        await tester.pumpAndSettle();
        final cardFinder = find.byType(MultimediaCard);
        final gridFinder = find.byType(CatalogBody);
        final firstKey = ValueKey('recent-${rows.first.item.url}');
        final initialCards = _mountedCards(tester);
        expect(initialCards, contains(firstKey));
        expect(initialCards.length, greaterThan(3));
        final visible = cardFinder.hitTestable();
        final outerBoundaries = initialCards.keys.fold<int>(
          0,
          (total, key) => total + _outerPaintBoundaries(tester, key),
        );
        final hashes = <String?>[await _rgba(tester)];
        var gridUpdates = 0;
        var rowUpdates = 0;

        Future<void> finishRefresh({required bool fail}) async {
          final beforeGrid = tester.widget<CatalogBody>(gridFinder);
          final before = _mountedCards(tester);
          if (fail) {
            offline.requests.last.completeError(
              StateError('offline rehearsal'),
            );
          } else {
            offline.requests.last.complete();
          }
          await tester.pumpAndSettle();
          final afterGrid = tester.widget<CatalogBody>(gridFinder);
          if (!identical(beforeGrid, afterGrid)) gridUpdates++;
          final after = _mountedCards(tester);
          expect(after.keys, orderedEquals(before.keys));
          for (final key in before.keys) {
            if (!identical(before[key], after[key])) rowUpdates++;
          }
        }

        await finishRefresh(fail: false);
        hashes.add(await _rgba(tester));
        for (var i = 0; i < 5; i++) {
          final refresh = tester.state<RefreshIndicatorState>(
            find.byType(RefreshIndicator),
          );
          unawaited(refresh.show());
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          expect(offline.requests, hasLength(i + 2));
          await finishRefresh(fail: i == 2);
        }
        hashes.add(await _rgba(tester));

        // Compare matched interaction stages across A/B. Route focus and
        // refresh-indicator frames need not be identical to each other.
        expect(hashes, everyElement(isNotNull));
        expect(visible, findsWidgets);

        // Exercise a true changed playback snapshot, including reordering and
        // replacing a title; this is intentionally not a cached no-op.
        final newest = HistoryItem(
          item: MultimediaItem(
            title: 'عنوان محدّث',
            url: rows[3].item.url,
            posterUrl: '',
            contentType: MultimediaContentType.anime,
          ),
          position: 6000,
          duration: 9000,
          timestamp: 120,
        );
        offline.publish([
          for (final row in rows)
            if (!identical(row, rows[3])) row,
          newest,
        ]);
        await tester.pumpAndSettle();
        final newestKey = ValueKey('recent-${newest.item.url}');
        expect(_mountedCards(tester).keys.first, newestKey);
        expect(find.text('عنوان محدّث'), findsWidgets);
        hashes.add(await _rgba(tester));

        await tester.tap(find.byKey(newestKey));
        await tester.pumpAndSettle();
        expect(visited.single, same(newest.item));
        await tester.tap(find.text('عودة من عنوان محدّث'));
        await tester.pumpAndSettle();
        expect(_mountedCards(tester).keys.first, newestKey);

        await tester.longPress(find.byKey(newestKey));
        await tester.pumpAndSettle();
        expect(offline.removed.single, same(newest.item));
        expect(notifications.messages.single, contains('عنوان محدّث'));
        expect(find.byKey(newestKey), findsNothing);
        expect(_mountedCards(tester).keys.first, firstKey);
        hashes.add(await _rgba(tester));

        // Scroll with the real sliver and keep the published order after returning.
        final grid = find.byType(GridView);
        await tester.drag(grid, const Offset(0, -420));
        await tester.pumpAndSettle();
        expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .pixels,
          greaterThan(0),
        );
        final back = find.byType(AppBackButton).hitTestable().last;
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(find.byType(RecentWatchedScreen), findsNothing);
        expect(find.text('افتح قائمة المشاهدات'), findsOneWidget);

        debugPrint(
          'C21_RECENT ${size.width} mounted=${initialCards.length} outer=$outerBoundaries grids=$gridUpdates rows=$rowUpdates rgba=${hashes.join(',')}',
        );
        const isStock = bool.fromEnvironment('C21_RECENT_STOCK');
        expect(gridUpdates, isStock ? 6 : 0);
        expect(rowUpdates, isStock ? greaterThan(0) : 0);
        expect(outerBoundaries, isStock ? initialCards.length : 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('empty Recent Watched exits initial shimmer and can retry', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    final offline = _OfflineHistory(const []);
    final notifications = _Notifications();
    addTearDown(notifications.dispose);
    await _open(
      tester,
      offline,
      size: const Size(390, 844),
      notifications: notifications,
      visited: [],
    );
    expect(find.byType(AnimeCatalogShimmer), findsOneWidget);
    expect(find.text(_emptyLabel), findsNothing);
    offline.requests.single.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.byType(AnimeCatalogShimmer), findsNothing);
    expect(find.text(_emptyLabel), findsOneWidget);

    final refresh = tester.state<RefreshIndicatorState>(
      find.byType(RefreshIndicator),
    );
    unawaited(refresh.show());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(offline.requests, hasLength(2));
    offline.publish(_rows(4));
    offline.requests.last.complete();
    await tester.pumpAndSettle();
    expect(find.text(_emptyLabel), findsNothing);
    expect(find.byType(MultimediaCard), findsNWidgets(4));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
